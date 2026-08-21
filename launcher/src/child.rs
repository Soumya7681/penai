//! Spawning and supervising `llama-server`.
//!
//! Two rules drive this module:
//!   * Arguments are passed as an argv array through `std::process::Command`.
//!     No shell is invoked and no command string is ever concatenated, so a
//!     path containing a space, quote or `&` cannot become code.
//!   * The child must never outlive the launcher. On Linux we ask the kernel to
//!     enforce that with `PR_SET_PDEATHSIG`; on every platform we also stop it
//!     explicitly on the way out.

use crate::config::Config;
use crate::logging::{Logger, Sink};
use crate::paths::Layout;
use std::collections::VecDeque;
use std::ffi::OsString;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Everything the child needs, resolved. Keeping this separate from `Config`
/// makes the argv builder a pure, testable function.
#[derive(Debug, Clone)]
pub struct ServerArgs {
    pub model: OsString,
    pub web_dir: OsString,
    pub port: u16,
    pub ctx_size: u32,
    pub threads: u32,
    pub parallel: u32,
    pub flash_attn: String,
    pub extra: Vec<String>,
}

/// Build the llama-server argv.
///
/// Every flag here was verified against the packaged build
/// (`llama-server --help`, b10549):
///   -m/--model, --host, --port, -c/--ctx-size, -t/--threads, -np/--parallel,
///   --path (static file root), -fa/--flash-attn, --cors-origins.
/// Nothing is invented.
pub fn build_args(a: &ServerArgs) -> Vec<OsString> {
    let mut v: Vec<OsString> = Vec::new();

    v.push(OsString::from("--model"));
    v.push(a.model.clone());

    // Loopback only. This is the single most important security property of the
    // whole project and it is not configurable.
    v.push(OsString::from("--host"));
    v.push(OsString::from("127.0.0.1"));

    v.push(OsString::from("--port"));
    v.push(OsString::from(a.port.to_string()));

    v.push(OsString::from("--ctx-size"));
    v.push(OsString::from(a.ctx_size.to_string()));

    v.push(OsString::from("--threads"));
    v.push(OsString::from(a.threads.to_string()));

    v.push(OsString::from("--parallel"));
    v.push(OsString::from(a.parallel.to_string()));

    // Serve the production React build from the pendrive. This is why no
    // separate static file server and no Node.js runtime are needed.
    v.push(OsString::from("--path"));
    v.push(a.web_dir.clone());

    // NOTE: `--no-webui` is deliberately NOT passed. Verified against b10549:
    // that flag disables llama.cpp's *entire* static file handler, so `--path`
    // stops serving too (both `/` and asset paths return 404). Passing `--path`
    // alone already replaces the built-in UI with ours, which is what we want.

    // Reflect only localhost origins instead of `*`.
    v.push(OsString::from("--cors-origins"));
    v.push(OsString::from("localhost"));

    v.push(OsString::from("--flash-attn"));
    v.push(OsString::from(&a.flash_attn));

    for e in &a.extra {
        v.push(OsString::from(e));
    }
    v
}

/// A running llama-server plus the plumbing that watches it.
pub struct Server {
    child: Child,
    #[allow(dead_code)]
    pub port: u16,
    pub pid: u32,
    /// Last lines of stderr, for a useful crash report.
    tail: Arc<Mutex<VecDeque<String>>>,
    stopped: bool,
}

const TAIL_LINES: usize = 40;

impl Server {
    pub fn spawn(
        layout: &Layout,
        args: &ServerArgs,
        log: &Logger,
        cfg: &Config,
    ) -> std::io::Result<Server> {
        let argv = build_args(args);
        log.info(format!(
            "starting llama-server on 127.0.0.1:{} (ctx {}, threads {})",
            args.port, args.ctx_size, args.threads
        ));
        log.trace(format!(
            "argv: {} {}",
            layout.server_bin.display(),
            argv.iter()
                .map(|a| a.to_string_lossy().to_string())
                .collect::<Vec<_>>()
                .join(" ")
        ));

        let mut cmd = Command::new(&layout.server_bin);
        cmd.args(&argv)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        // Run with the runtime directory as CWD so the platform's own library
        // lookup finds the bundled shared objects / DLLs next to the binary.
        // (The Linux build already carries RUNPATH=$ORIGIN, and Windows checks
        // the executable's directory first, so no library path env var is set.)
        cmd.current_dir(&layout.runtime_dir);

        #[cfg(target_os = "linux")]
        {
            use std::os::unix::process::CommandExt;
            // SAFETY: pre_exec runs in the forked child before exec. `prctl` is
            // async-signal-safe and we touch nothing else.
            unsafe {
                cmd.pre_exec(|| {
                    const PR_SET_PDEATHSIG: i32 = 1;
                    const SIGTERM: i32 = 15;
                    prctl(PR_SET_PDEATHSIG, SIGTERM as u64, 0, 0, 0);
                    Ok(())
                });
            }
        }

        let mut child = cmd.spawn().map_err(|e| {
            std::io::Error::new(
                e.kind(),
                format!(
                    "cannot execute {}: {}{}",
                    layout.server_bin.display(),
                    e,
                    exec_hint(&layout.server_bin, &e)
                ),
            )
        })?;
        let pid = child.id();

        let tail = Arc::new(Mutex::new(VecDeque::with_capacity(TAIL_LINES)));

        // Pump both streams to their own rotating log files.
        if let Some(out) = child.stdout.take() {
            let sink = Sink::open(
                layout.logs_dir.join("llama-server.stdout.log"),
                cfg.log_max_bytes,
                cfg.log_keep,
            );
            pump(out, sink, None);
        }
        if let Some(err) = child.stderr.take() {
            let sink = Sink::open(
                layout.logs_dir.join("llama-server.stderr.log"),
                cfg.log_max_bytes,
                cfg.log_keep,
            );
            // llama.cpp writes its normal progress output to stderr, so this is
            // not an error stream; we keep a tail of it for diagnostics.
            pump(err, sink, Some(Arc::clone(&tail)));
        }

        Ok(Server {
            child,
            port: args.port,
            pid,
            tail,
            stopped: false,
        })
    }

    /// Non-blocking: `Some(description)` once the process is gone.
    pub fn exited(&mut self) -> Option<String> {
        match self.child.try_wait() {
            Ok(Some(status)) => {
                let code = status.code();
                let mut msg = match code {
                    Some(c) => format!("llama-server exited with status {}", c),
                    None => "llama-server was terminated by a signal".to_string(),
                };
                if let Some(reason) = self.diagnose() {
                    msg.push_str(&format!("\n    Likely cause: {}", reason));
                }
                let t = self.tail_text();
                if !t.is_empty() {
                    msg.push_str(&format!("\n    Last output:\n{}", indent(&t)));
                }
                Some(msg)
            }
            Ok(None) => None,
            Err(e) => Some(format!("cannot query llama-server state: {}", e)),
        }
    }

    /// Turn known llama.cpp failure output into a plain-language cause.
    pub fn diagnose(&self) -> Option<String> {
        let text = self.tail_text().to_lowercase();
        let table = [
            ("address already in use", "the chosen port was taken by another process"),
            ("bind", "the server could not bind its port"),
            // These are llama.cpp's actual wordings; verified against b10549
            // output ("error while loading model: bad magic ...").
            ("loading model", "the GGUF model could not be loaded -- it may be truncated, corrupt, or built for a newer llama.cpp"),
            ("failed to load model", "the GGUF model could not be loaded -- it may be truncated, or built for a newer llama.cpp"),
            ("unable to load model", "the GGUF model could not be loaded"),
            ("bad magic", "the model file is not a valid GGUF file"),
            ("no such file", "a required file was missing at the path the server was given"),
            ("unknown model architecture", "this llama.cpp build does not support that model architecture -- update the runtime"),
            ("out of memory", "the machine ran out of RAM while loading the model"),
            ("cannot allocate memory", "the machine ran out of RAM while allocating buffers"),
            ("illegal instruction", "this CPU lacks an instruction set the runtime build requires"),
        ];
        table
            .iter()
            .find(|(needle, _)| text.contains(needle))
            .map(|(_, cause)| cause.to_string())
    }

    pub fn tail_text(&self) -> String {
        match self.tail.lock() {
            Ok(g) => g.iter().cloned().collect::<Vec<_>>().join("\n"),
            Err(p) => p.into_inner().iter().cloned().collect::<Vec<_>>().join("\n"),
        }
    }

    /// Ask nicely, then insist. Idempotent.
    pub fn stop(&mut self, grace: Duration, log: &Logger) {
        if self.stopped {
            return;
        }
        self.stopped = true;
        if matches!(self.child.try_wait(), Ok(Some(_))) {
            return;
        }
        log.info(format!("stopping llama-server (pid {})", self.pid));

        #[cfg(unix)]
        {
            const SIGTERM: i32 = 15;
            // SAFETY: sending a signal to our own child by pid.
            unsafe {
                kill(self.pid as i32, SIGTERM);
            }
            let deadline = Instant::now() + grace;
            while Instant::now() < deadline {
                if matches!(self.child.try_wait(), Ok(Some(_))) {
                    log.info("llama-server stopped cleanly");
                    return;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            log.warn("llama-server ignored SIGTERM; killing it");
        }

        let _ = self.child.kill();
        let _ = self.child.wait();
        log.info("llama-server stopped");
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        // Last-resort safety net: never leave the model resident.
        if !self.stopped {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

fn pump<R: std::io::Read + Send + 'static>(
    reader: R,
    mut sink: Sink,
    tail: Option<Arc<Mutex<VecDeque<String>>>>,
) {
    std::thread::spawn(move || {
        let mut br = BufReader::new(reader);
        let mut buf = Vec::new();
        loop {
            buf.clear();
            // read_until on bytes, because llama.cpp can emit partial UTF-8.
            match br.read_until(b'\n', &mut buf) {
                Ok(0) => break,
                Ok(_) => {
                    let line = String::from_utf8_lossy(&buf).trim_end().to_string();
                    if line.is_empty() {
                        continue;
                    }
                    sink.write_line(&line);
                    if let Some(t) = &tail {
                        let mut g = match t.lock() {
                            Ok(g) => g,
                            Err(p) => p.into_inner(),
                        };
                        if g.len() == TAIL_LINES {
                            g.pop_front();
                        }
                        g.push_back(line);
                    }
                }
                Err(_) => break,
            }
        }
    });
}

fn indent(s: &str) -> String {
    s.lines()
        .map(|l| format!("      {}", l))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Extra guidance for the most common real-world spawn failure: a FAT32 or
/// noexec mount refusing to execute the binary.
fn exec_hint(path: &Path, e: &std::io::Error) -> String {
    if e.kind() == std::io::ErrorKind::PermissionDenied {
        format!(
            "\n    This usually means the filesystem holding {} is mounted without \
             execute permission (FAT32 with `showexec`, or `noexec`). Run the \
             StartAI.sh bootstrap, which stages the runtime to a local directory, \
             or format the drive as exFAT.",
            path.display()
        )
    } else {
        String::new()
    }
}

#[cfg(unix)]
extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
}

#[cfg(target_os = "linux")]
extern "C" {
    fn prctl(option: i32, a: u64, b: u64, c: u64, d: u64) -> i32;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec() -> ServerArgs {
        ServerArgs {
            model: OsString::from("/media/u/My Drive/PendriveAI/models/model.gguf"),
            web_dir: OsString::from("/media/u/My Drive/PendriveAI/web"),
            port: 8080,
            ctx_size: 4096,
            threads: 6,
            parallel: 1,
            flash_attn: "auto".into(),
            extra: vec![],
        }
    }

    fn as_strings(v: &[OsString]) -> Vec<String> {
        v.iter().map(|s| s.to_string_lossy().to_string()).collect()
    }

    #[test]
    fn binds_loopback_only_and_never_wildcard() {
        let a = as_strings(&build_args(&spec()));
        let host = a.iter().position(|x| x == "--host").unwrap();
        assert_eq!(a[host + 1], "127.0.0.1");
        assert!(!a.iter().any(|x| x == "0.0.0.0"));
        assert!(!a.iter().any(|x| x.contains("::")));
    }

    #[test]
    fn passes_every_required_flag() {
        let a = as_strings(&build_args(&spec()));
        for f in [
            "--model",
            "--host",
            "--port",
            "--ctx-size",
            "--threads",
            "--parallel",
            "--path",
            "--cors-origins",
            "--flash-attn",
        ] {
            assert!(a.iter().any(|x| x == f), "missing {} in {:?}", f, a);
        }
        let p = a.iter().position(|x| x == "--port").unwrap();
        assert_eq!(a[p + 1], "8080");
        let c = a.iter().position(|x| x == "--ctx-size").unwrap();
        assert_eq!(a[c + 1], "4096");
        let t = a.iter().position(|x| x == "--threads").unwrap();
        assert_eq!(a[t + 1], "6");
    }

    #[test]
    fn paths_with_spaces_stay_one_argument() {
        let a = build_args(&spec());
        let model = a
            .iter()
            .position(|x| x == "--model")
            .map(|i| a[i + 1].to_string_lossy().to_string())
            .unwrap();
        assert_eq!(model, "/media/u/My Drive/PendriveAI/models/model.gguf");
        assert!(model.contains(' '), "the space must survive unquoted");
        // No argument may be a concatenated command line.
        for arg in as_strings(&a) {
            assert!(!arg.contains(" --"), "looks like a joined command: {}", arg);
        }
    }

    #[test]
    fn shell_metacharacters_in_paths_are_not_split() {
        let mut s = spec();
        s.model = OsString::from("/x/a b&c;d$(whoami)|e/model.gguf");
        let a = build_args(&s);
        let i = a.iter().position(|x| x == "--model").unwrap();
        assert_eq!(
            a[i + 1].to_string_lossy(),
            "/x/a b&c;d$(whoami)|e/model.gguf"
        );
    }

    #[test]
    fn extra_args_are_appended_verbatim() {
        let mut s = spec();
        s.extra = vec!["--no-warmup".into(), "--cache-reuse".into(), "256".into()];
        let a = as_strings(&build_args(&s));
        assert_eq!(&a[a.len() - 3..], &["--no-warmup", "--cache-reuse", "256"]);
    }

    #[test]
    fn static_path_points_at_the_web_build() {
        let a = as_strings(&build_args(&spec()));
        let i = a.iter().position(|x| x == "--path").unwrap();
        assert!(a[i + 1].ends_with("web"));
    }

    /// Regression guard for a behaviour verified empirically against b10549:
    /// `--no-webui` disables the whole static handler, so `--path` stops
    /// serving and the UI 404s. It must never be added back.
    #[test]
    fn never_passes_no_webui_because_it_kills_static_serving() {
        let a = as_strings(&build_args(&spec()));
        assert!(
            !a.iter().any(|x| x == "--no-webui" || x == "--no-ui"),
            "--no-webui breaks --path static file serving; see module docs"
        );
    }

    #[test]
    fn missing_binary_produces_actionable_error() {
        let tmp = std::env::temp_dir().join(format!("pai-nobin-{}", std::process::id()));
        std::fs::create_dir_all(tmp.join("runtime").join(crate::paths::platform_dir())).unwrap();
        std::fs::create_dir_all(tmp.join("data").join("logs")).unwrap();
        let layout = Layout::from_root(&tmp);
        let log = Logger::new(tmp.join("data/logs/t.log"), 65536, 1, false);
        let msg = match Server::spawn(&layout, &spec(), &log, &Config::default()) {
            Ok(_) => panic!("spawning a non-existent binary must fail"),
            Err(e) => e.to_string(),
        };
        assert!(msg.contains("cannot execute"), "{}", msg);
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// Supervision is tested against a real child process rather than a mock.
    #[cfg(unix)]
    #[test]
    fn detects_child_exit_and_reports_output() {
        let tmp = std::env::temp_dir().join(format!("pai-child-{}", std::process::id()));
        let rt = tmp.join("runtime").join(crate::paths::platform_dir());
        std::fs::create_dir_all(&rt).unwrap();
        std::fs::create_dir_all(tmp.join("data").join("logs")).unwrap();

        // Stand in for llama-server: print to stderr, then fail.
        let mut layout = Layout::from_root(&tmp);
        layout.server_bin = std::path::PathBuf::from("/bin/sh");
        let mut s = ServerArgs {
            model: OsString::from("unused"),
            web_dir: OsString::from("unused"),
            port: 1,
            ctx_size: 1,
            threads: 1,
            parallel: 1,
            flash_attn: "auto".into(),
            extra: vec![],
        };
        // Replace the whole argv with our own script.
        s.extra = vec![];
        let log = Logger::new(tmp.join("data/logs/t.log"), 65536, 1, false);

        let mut cmd_layout = layout.clone();
        cmd_layout.runtime_dir = rt.clone();
        // Spawn /bin/sh -c directly to keep this test independent of build_args.
        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "echo 'error while loading model: bad magic' 1>&2; exit 3"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let tail = Arc::new(Mutex::new(VecDeque::new()));
        if let Some(e) = child.stderr.take() {
            pump(
                e,
                Sink::open(tmp.join("data/logs/e.log"), 65536, 1),
                Some(Arc::clone(&tail)),
            );
        }
        let mut srv = Server {
            child,
            port: 1,
            pid: 0,
            tail,
            stopped: false,
        };
        // Give the pump thread a moment to collect the line.
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut msg = None;
        while Instant::now() < deadline {
            if let Some(m) = srv.exited() {
                if m.contains("Last output") {
                    msg = Some(m);
                    break;
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let msg = msg.expect("child exit should have been detected");
        assert!(msg.contains("status 3"), "{}", msg);
        assert!(msg.contains("GGUF model could not be loaded"), "{}", msg);
        srv.stopped = true;
        drop(srv);
        let _ = log;
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[cfg(unix)]
    #[test]
    fn stop_terminates_a_long_running_child() {
        let tmp = std::env::temp_dir().join(format!("pai-stop-{}", std::process::id()));
        std::fs::create_dir_all(tmp.join("data").join("logs")).unwrap();
        let log = Logger::new(tmp.join("data/logs/t.log"), 65536, 1, false);
        let child = std::process::Command::new("/bin/sh")
            .args(["-c", "sleep 120"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let pid = child.id();
        let mut srv = Server {
            child,
            port: 1,
            pid,
            tail: Arc::new(Mutex::new(VecDeque::new())),
            stopped: false,
        };
        srv.stop(Duration::from_secs(3), &log);
        assert!(srv.exited().is_some(), "child should be gone after stop()");
        // Second call must be a no-op, not a panic.
        srv.stop(Duration::from_secs(1), &log);
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn diagnose_maps_known_failures() {
        let mk = |line: &str| {
            let mut q = VecDeque::new();
            q.push_back(line.to_string());
            q
        };
        let cases = [
            ("bind: Address already in use", "port"),
            ("error: failed to load model", "GGUF"),
            ("ggml: cannot allocate memory", "RAM"),
            ("unknown model architecture: 'xyz'", "architecture"),
        ];
        for (line, expect) in cases {
            let s = Server {
                child: std::process::Command::new(if cfg!(windows) { "cmd" } else { "/bin/sh" })
                    .args(if cfg!(windows) { vec!["/C", "exit"] } else { vec!["-c", "exit"] })
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap(),
                port: 1,
                pid: 0,
                tail: Arc::new(Mutex::new(mk(line))),
                stopped: false,
            };
            let d = s.diagnose().unwrap_or_default();
            assert!(d.contains(expect), "line `{}` gave `{}`", line, d);
        }
    }
}
