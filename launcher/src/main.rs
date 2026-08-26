//! PenAI launcher.
//!
//! Plug in the pendrive, run one executable, chat with a local model in the
//! browser. This program is the only moving part: it locates everything
//! relative to itself, starts llama.cpp's server bound to loopback, waits for
//! the model to load, and opens the default browser at the right URL.
//!
//! There is no desktop UI, no cloud service, no Node.js, no Python, no Docker
//! and no network access.

mod browser;
mod child;
mod config;
mod fetch;
mod json;
mod lock;
mod logging;
mod net;
mod paths;
mod signals;
mod sysinfo;
mod store;

use child::{Server, ServerArgs};
use config::Config;
use logging::Logger;
use paths::Layout;
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

const VERSION: &str = env!("CARGO_PKG_VERSION");
const NAME: &str = "PenAI";

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!();
            eprintln!("  {} could not start.", NAME);
            eprintln!();
            for line in e.lines() {
                eprintln!("  {}", line);
            }
            eprintln!();
            hold_console();
            ExitCode::FAILURE
        }
    }
}

/// Command-line switches. Everything here also has a config-file equivalent;
/// the flags exist so a user can override without editing JSON.
struct Cli {
    no_browser: bool,
    force: bool,
    port: Option<u16>,
    ctx: Option<u32>,
    threads: Option<u32>,
    quiet: bool,
    runtime_dir: Option<PathBuf>,
}

fn parse_cli() -> Result<Option<Cli>, String> {
    let mut c = Cli {
        no_browser: false,
        force: false,
        port: None,
        ctx: None,
        threads: None,
        quiet: false,
        runtime_dir: None,
    };
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        let mut value = |name: &str| -> Result<String, String> {
            args.next()
                .ok_or_else(|| format!("{} needs a value", name))
        };
        match a.as_str() {
            "-h" | "--help" => {
                print_help();
                return Ok(None);
            }
            "-V" | "--version" => {
                println!("{} launcher {}", NAME, VERSION);
                return Ok(None);
            }
            "--no-browser" => c.no_browser = true,
            "--force" => c.force = true,
            "--quiet" => c.quiet = true,
            "--port" => {
                c.port = Some(
                    value("--port")?
                        .parse()
                        .map_err(|_| "--port must be 1024-65535".to_string())?,
                )
            }
            "--ctx" | "--ctx-size" => {
                c.ctx = Some(
                    value("--ctx")?
                        .parse()
                        .map_err(|_| "--ctx must be a number".to_string())?,
                )
            }
            "--threads" => {
                c.threads = Some(
                    value("--threads")?
                        .parse()
                        .map_err(|_| "--threads must be a number".to_string())?,
                )
            }
            "--runtime-dir" => c.runtime_dir = Some(PathBuf::from(value("--runtime-dir")?)),
            other => {
                return Err(format!(
                    "unknown option `{}`. Run with --help for the list.",
                    other
                ))
            }
        }
    }
    Ok(Some(c))
}

fn print_help() {
    println!(
        "\
{name} launcher {ver}

Starts a local llama.cpp server and opens the browser UI. Everything runs
offline on this computer; nothing is sent anywhere.

USAGE:
    StartAI [OPTIONS]

OPTIONS:
    --port <PORT>      Preferred localhost port (default 8080, auto-fallback)
    --ctx <N>          Context size in tokens (default from config/config.json)
    --threads <N>      CPU threads (default: auto-detected)
    --runtime-dir <D>  Load llama.cpp from this directory instead of
                       <root>/runtime/<os>. Used by StartAI.sh when the drive
                       is mounted without execute permission.
    --no-browser       Do not open a browser; just print the URL
    --force            Start even if the RAM check says it is unlikely to work
    --quiet            Less console output
    -V, --version      Print version
    -h, --help         Print this help

FILES (all resolved relative to this executable):
    config/config.json     settings
    models/*.gguf          the model
    runtime/<os>/          llama.cpp binaries
    web/                   the browser UI
    data/logs/             logs
    data/chats/            portable chat history
",
        name = NAME,
        ver = VERSION
    );
}

fn run() -> Result<(), String> {
    signals::install();

    let cli = match parse_cli()? {
        Some(c) => c,
        None => return Ok(()),
    };

    // ---------------------------------------------------------------- layout
    let layout = Layout::discover().map_err(|e| {
        format!(
            "cannot determine the PenAI folder from this executable's location: {}",
            e
        )
    })?;
    // A --runtime-dir flag beats the environment variable, which beats the
    // default of <root>/runtime/<os>.
    let layout = match &cli.runtime_dir {
        Some(d) => layout.with_runtime_dir(d),
        None => layout.apply_runtime_env(),
    };

    let (mut cfg, cfg_warnings) = Config::load(&layout.config_file)?;
    if let Some(p) = cli.port {
        cfg.preferred_port = p;
    }
    if let Some(c) = cli.ctx {
        cfg.ctx_size = c;
    }
    if let Some(t) = cli.threads {
        cfg.threads = t;
    }
    if cli.no_browser {
        cfg.open_browser = false;
    }

    // Directory creation is best-effort: a read-only drive still runs, it just
    // cannot log or persist chats.
    let dirs_ok = layout.ensure_writable_dirs().is_ok();

    let log = Logger::new(
        layout.logs_dir.join("launcher.log"),
        cfg.log_max_bytes,
        cfg.log_keep,
        !cli.quiet,
    );

    println!();
    println!("  {} {}  --  offline local AI", NAME, VERSION);
    println!("  ----------------------------------------");
    log.info(format!("project root: {}", layout.root.display()));
    if !dirs_ok {
        log.warn(
            "cannot create data/ directories -- the drive may be read-only. \
             Logs and portable chat history are disabled for this run.",
        );
    }
    for w in &cfg_warnings {
        log.warn(format!("config: {}", w));
    }

    // ------------------------------------------------------------ single run
    let guard = match lock::acquire(cfg.instance_port, &layout.run_dir) {
        lock::Acquire::Acquired(g) => g,
        lock::Acquire::AlreadyRunning { url, pid } => {
            let where_ = pid
                .map(|p| format!(" (process {})", p))
                .unwrap_or_default();
            log.info(format!("{} is already running{}", NAME, where_));
            match url {
                Some(u) if cfg.open_browser && browser::is_safe_loopback_url(&u) => {
                    log.info(format!("reopening the existing session at {}", u));
                    match browser::open(&u) {
                        Ok(_) => {}
                        Err(e) => log.warn(format!("{} -- open {} manually", e, u)),
                    }
                }
                Some(u) => log.info(format!("open {} in your browser", u)),
                None => log.info("close the other launcher window before starting a new one"),
            }
            return Ok(());
        }
    };

    // ------------------------------------------------------------- hardware
    let info = sysinfo::SysInfo::probe();
    log.info(format!("system: {}", info.describe()));

    // ------------------------------------------------------- model + runtime
    let model = layout.resolve_model(if cfg.model_file.is_empty() {
        None
    } else {
        Some(cfg.model_file.as_str())
    });
    let problems = layout.validate(model.as_deref());
    if !problems.is_empty() {
        let mut msg = String::from("Some required files are missing or unusable:\n");
        for p in &problems {
            msg.push_str(&format!("\n  * {}\n", p));
        }
        msg.push_str(&format!(
            "\nProject folder in use: {}\n",
            layout.root.display()
        ));
        return Err(msg);
    }
    let model = model.expect("validate() guarantees a model here");
    let model_bytes = std::fs::metadata(&model).map(|m| m.len()).unwrap_or(0);
    log.info(format!(
        "model: {} ({:.2} GiB)",
        paths::rel(&layout.root, &model),
        model_bytes as f64 / sysinfo::GIB as f64
    ));

    let engine = engine_version(&layout).unwrap_or_else(|| "unknown".to_string());
    log.info(format!("engine: llama.cpp {}", engine));

    // -------------------------------------------------------- capability gate
    let threads = if cfg.threads == 0 {
        info.recommended_threads()
    } else {
        cfg.threads
    };
    let mut ctx = cfg.ctx_size;
    match sysinfo::assess(&info, model_bytes, ctx) {
        sysinfo::Capability::Ok => {
            log.info(format!("RAM check passed for context {}", ctx));
        }
        sysinfo::Capability::Tight { warning, ctx_cap } => {
            log.warn(format!("RAM is tight: {}", warning));
            ctx = ctx_cap;
        }
        sysinfo::Capability::Unlikely { warning, ctx_cap } => {
            log.warn(format!("RAM check failed: {}", warning));
            if !cli.force {
                return Err(format!(
                    "This computer probably cannot run the bundled model.\n\n  {}\n\n\
                     Options:\n\
                       * close other applications and try again\n\
                       * run with --force to try anyway (it may swap heavily or be killed)\n\
                       * run with --ctx {} to use less memory\n\
                       * replace models/model.gguf with a smaller quantisation \
                         (see models/README.md)",
                    warning, ctx_cap
                ));
            }
            log.warn("--force given: starting anyway; this may fail or thrash swap");
            ctx = ctx_cap;
        }
        sysinfo::Capability::Unknown => {
            log.warn(
                "could not read this machine's RAM; starting without a capability check. \
                 If it fails, try --ctx 2048.",
            );
        }
    }

    // ------------------------------------------------------------ start server
    let mut attempt = 0u8;
    let mut preferred = cfg.preferred_port;
    let (mut server, port) = loop {
        attempt += 1;
        let port = net::pick_port(preferred, cfg.port_scan_from, cfg.port_scan_to)
            .map_err(|e| format!("no free localhost port could be found: {}", e))?;
        if port != cfg.preferred_port {
            log.info(format!(
                "port {} was busy; using {} instead",
                cfg.preferred_port, port
            ));
        }

        let args = ServerArgs {
            model: OsString::from(&model),
            web_dir: OsString::from(&layout.web_dir),
            port,
            ctx_size: ctx,
            threads,
            parallel: cfg.parallel,
            flash_attn: cfg.flash_attn.clone(),
            extra: cfg.extra_args.clone(),
        };

        let mut srv = Server::spawn(&layout, &args, &log, &cfg).map_err(|e| e.to_string())?;

        log.info("loading model (first start on a slow drive can take a while)...");
        let ready = net::wait_for_ready(
            port,
            Duration::from_secs(cfg.startup_timeout_secs),
            |state, elapsed| match state {
                net::Health::Loading => log.info(format!(
                    "engine is up, still loading weights ({}s)",
                    elapsed.as_secs()
                )),
                net::Health::Down => {}
                net::Health::Ready => {}
            },
            || {
                if signals::requested() {
                    return Some("interrupted before the engine finished loading".to_string());
                }
                srv.exited()
            },
        );

        match ready {
            Ok(took) => {
                log.info(format!("engine ready in {:.1}s", took.as_secs_f64()));
                break (srv, port);
            }
            Err(reason) => {
                srv.stop(Duration::from_secs(5), &log);
                let port_conflict = reason.to_lowercase().contains("address already in use")
                    || reason.to_lowercase().contains("bind");
                if port_conflict && attempt < 3 {
                    log.warn(format!(
                        "port {} could not be bound after all; retrying on another port",
                        port
                    ));
                    // 0 skips the preferred port entirely and forces a scan.
                    preferred = 0;
                    continue;
                }
                if signals::requested() {
                    return Ok(());
                }
                return Err(format!(
                    "The AI engine failed to start.\n\n  {}\n\n\
                     Full output: {}",
                    reason,
                    layout.logs_dir.join("llama-server.stderr.log").display()
                ));
            }
        }
    };

    // --------------------------------------------------- portable chat store
    let origins = vec![
        format!("http://127.0.0.1:{}", port),
        format!("http://localhost:{}", port),
    ];
    let store = if cfg.portable_storage && dirs_ok {
        match store::Store::start(
            cfg.store_port,
            layout.chats_dir.clone(),
            origins,
            fetch::Policy {
                enabled: cfg.network_enabled,
                timeout: std::time::Duration::from_secs(cfg.network_timeout_secs),
                max_bytes: cfg.network_max_bytes,
                ..fetch::Policy::default()
            },
            log.clone(),
        ) {
            Ok(s) => {
                log.info(format!(
                    "portable chat history enabled on 127.0.0.1:{} -> {}",
                    s.port,
                    paths::rel(&layout.root, &layout.chats_dir.join("chats.json"))
                ));
                Some(s)
            }
            Err(e) => {
                log.warn(format!(
                    "portable chat history unavailable ({}); the browser will keep \
                     chats in its own storage on this computer instead",
                    e
                ));
                None
            }
        }
    } else {
        if !cfg.portable_storage {
            log.info("portable chat history disabled in config; using browser storage");
        }
        None
    };

    // ------------------------------------------- hand runtime facts to the UI
    let runtime_cfg = cfg.ui_runtime_json(
        port,
        store.as_ref().map(|s| s.port),
        &model
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default(),
        &engine,
    );
    let rc_path = layout.web_dir.join("runtime-config.json");
    if let Err(e) = std::fs::write(&rc_path, runtime_cfg.as_bytes()) {
        log.warn(format!(
            "could not write {} ({}). The UI will probe for the chat-history \
             service instead.",
            rc_path.display(),
            e
        ));
    }

    // ------------------------------------------------------------- browser
    let url = format!("http://127.0.0.1:{}", port);
    guard.publish(&url, port, store.as_ref().map(|s| s.port));

    println!("  ----------------------------------------");
    log.info(format!("PenAI is ready at  {}", url));
    println!("  ----------------------------------------");

    if cfg.open_browser {
        match browser::open(&url) {
            Ok(via) => log.info(format!("opened your default browser (via {})", via)),
            Err(e) => log.warn(format!("{}. Open {} yourself.", e, url)),
        }
    } else {
        log.info("browser auto-open is off; open the URL above manually");
    }

    println!();
    println!("  Press Ctrl+C in this window to stop PenAI.");
    println!();

    // ------------------------------------------------------------- supervise
    loop {
        if signals::requested() {
            log.info("shutdown requested");
            break;
        }
        if let Some(why) = server.exited() {
            log.error(format!("the AI engine stopped unexpectedly: {}", why));
            if let Some(s) = &store {
                s.shutdown();
            }
            server.stop(Duration::from_secs(2), &log);
            return Err(format!(
                "The AI engine stopped while running.\n\n  {}\n\n\
                 Log: {}",
                why,
                layout.logs_dir.join("llama-server.stderr.log").display()
            ));
        }
        std::thread::sleep(Duration::from_millis(300));
    }

    // -------------------------------------------------------------- shutdown
    if let Some(s) = &store {
        s.shutdown();
    }
    server.stop(Duration::from_secs(8), &log);
    drop(guard);
    log.info("PenAI stopped. Your chats stay on this drive / in this browser.");
    println!();
    Ok(())
}

/// Ask the packaged runtime what it is, so logs and the UI report the real
/// version instead of a hardcoded guess.
fn engine_version(layout: &Layout) -> Option<String> {
    let out = std::process::Command::new(&layout.server_bin)
        .arg("--version")
        .current_dir(&layout.runtime_dir)
        .output()
        .ok()?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    // Example: "version: 0.1.2-dev (build 10549, commit b2e5e9b28)"
    for line in text.lines() {
        if let Some(i) = line.find("build ") {
            let rest = &line[i + 6..];
            let num: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if !num.is_empty() {
                return Some(format!("b{}", num));
            }
        }
    }
    text.lines()
        .find(|l| l.starts_with("version:"))
        .map(|l| l.trim().to_string())
}

/// On Windows a double-clicked executable closes its window instantly, taking
/// the error message with it. Wait for a keypress so the user can read it.
fn hold_console() {
    if !cfg!(windows) {
        return;
    }
    if std::env::var_os("PENAI_NO_PAUSE").is_some() {
        return;
    }
    eprintln!("  Press Enter to close this window.");
    let mut s = String::new();
    let _ = std::io::stdin().read_line(&mut s);
}
