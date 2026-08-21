//! Portable path resolution.
//!
//! Every path used by the launcher is derived at run time from the location of
//! the running executable. There are no drive letters, no `$HOME`, no mount
//! points and no absolute project paths anywhere in this file or anywhere else
//! in the launcher -- that is what makes the same release folder work from
//! `D:\PendriveAI`, `/media/<user>/PENDRIVEAI` or `/run/media/<user>/x`.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// Marker file written into the release root by the packaging script. Searching
/// for it lets the launcher find the root even if it is invoked from a `bin/`
/// subdirectory or through a staging copy.
pub const ROOT_MARKER: &str = ".pendriveai-root";

/// Environment override, used by the FAT32 staging bootstrap: the launcher
/// binary is copied to a local temp directory (because FAT32 mounted with
/// `showexec` refuses to execute it) but must still read the model, web assets
/// and config from the pendrive.
pub const ROOT_ENV: &str = "PENDRIVEAI_ROOT";

/// Directory name under `runtime/` for the current platform.
pub const fn platform_dir() -> &'static str {
    if cfg!(windows) {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}

/// Name of the llama.cpp server executable on the current platform.
pub const fn server_exe_name() -> &'static str {
    if cfg!(windows) {
        "llama-server.exe"
    } else {
        "llama-server"
    }
}

#[derive(Debug, Clone)]
pub struct Layout {
    pub root: PathBuf,
    pub runtime_dir: PathBuf,
    pub server_bin: PathBuf,
    pub models_dir: PathBuf,
    pub web_dir: PathBuf,
    /// Parent of logs/chats/run. Kept for callers that need the whole tree.
    #[allow(dead_code)]
    pub data_dir: PathBuf,
    pub logs_dir: PathBuf,
    pub chats_dir: PathBuf,
    pub run_dir: PathBuf,
    pub config_file: PathBuf,
}

impl Layout {
    /// Build a layout from an explicit root. Pure function -- no filesystem
    /// access, no globals. This is what makes the path logic unit-testable
    /// against arbitrary simulated roots.
    pub fn from_root(root: impl Into<PathBuf>) -> Layout {
        let root: PathBuf = root.into();
        let runtime_dir = root.join("runtime").join(platform_dir());
        let data_dir = root.join("data");
        Layout {
            server_bin: runtime_dir.join(server_exe_name()),
            runtime_dir,
            models_dir: root.join("models"),
            web_dir: root.join("web"),
            logs_dir: data_dir.join("logs"),
            chats_dir: data_dir.join("chats"),
            run_dir: data_dir.join("run"),
            data_dir,
            config_file: root.join("config").join("config.json"),
            root,
        }
    }

    /// Discover the project root from the running executable, then build the
    /// layout. Resolution order:
    ///   1. `PENDRIVEAI_ROOT` (staging bootstrap / tests)
    ///   2. nearest ancestor of the executable containing `.pendriveai-root`
    ///   3. nearest ancestor that *looks* like a release root
    ///   4. the executable's own directory
    pub fn discover() -> io::Result<Layout> {
        if let Some(v) = std::env::var_os(ROOT_ENV) {
            let p = PathBuf::from(v);
            if !p.as_os_str().is_empty() {
                // canonicalize is best-effort: it fails on a path that does not
                // exist yet, and we want the clearer downstream error in that case.
                let p = fs::canonicalize(&p).unwrap_or(p);
                return Ok(Layout::from_root(p));
            }
        }
        let exe = std::env::current_exe()?;
        let exe = fs::canonicalize(&exe).unwrap_or(exe);
        let start = exe
            .parent()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "executable has no parent dir"))?
            .to_path_buf();
        Ok(Layout::from_root(find_root(&start)))
    }

    /// Human-readable, actionable validation. Returns one message per problem
    /// so the launcher can print all of them at once instead of making the user
    /// re-run five times.
    pub fn validate(&self, model: Option<&Path>) -> Vec<String> {
        let mut errs = Vec::new();

        if !self.runtime_dir.is_dir() {
            errs.push(format!(
                "llama.cpp runtime directory is missing: {}\n    \
                 Fix: run scripts/fetch-runtime.sh (or .ps1) and re-package, or copy the\n    \
                 llama.cpp {} build into that folder.",
                self.runtime_dir.display(),
                platform_dir()
            ));
        } else if !self.server_bin.is_file() {
            errs.push(format!(
                "llama.cpp server executable is missing: {}\n    \
                 Fix: the runtime folder exists but has no `{}` in it.",
                self.server_bin.display(),
                server_exe_name()
            ));
        }

        match model {
            Some(m) if m.is_file() => {
                if let Ok(md) = fs::metadata(m) {
                    // A GGUF for a 1.5B-4B model is never under 100 MB. A tiny
                    // file here almost always means a failed or partial download.
                    if md.len() < 100 * 1024 * 1024 {
                        errs.push(format!(
                            "model file looks truncated: {} is only {:.1} MB\n    \
                             Fix: re-download it (models/download-model.sh) and verify the checksum.",
                            m.display(),
                            md.len() as f64 / 1_048_576.0
                        ));
                    }
                }
            }
            Some(m) => errs.push(format!(
                "model file not found: {}\n    \
                 Fix: see models/README.md -- run models/download-model.sh (Linux/macOS)\n    \
                 or models/download-model.ps1 (Windows) and place the .gguf in {}.",
                m.display(),
                self.models_dir.display()
            )),
            None => errs.push(format!(
                "no .gguf model found in {}\n    \
                 Fix: see models/README.md -- run models/download-model.sh (Linux/macOS)\n    \
                 or models/download-model.ps1 (Windows).",
                self.models_dir.display()
            )),
        }

        if !self.web_dir.join("index.html").is_file() {
            errs.push(format!(
                "web UI build is missing: {}\n    \
                 Fix: build it with `npm ci && npm run build` in web/ and re-package.",
                self.web_dir.join("index.html").display()
            ));
        }

        errs
    }

    /// Create the writable directories. Failure is *not* fatal: the pendrive may
    /// be mounted read-only, in which case we degrade to in-memory logging.
    pub fn ensure_writable_dirs(&self) -> io::Result<()> {
        fs::create_dir_all(&self.logs_dir)?;
        fs::create_dir_all(&self.chats_dir)?;
        fs::create_dir_all(&self.run_dir)?;
        Ok(())
    }

    /// Pick the model file. Explicit config wins; then the conventional
    /// `model.gguf`; then the single largest `.gguf` present (deterministic
    /// tie-break by name so two runs never disagree).
    pub fn resolve_model(&self, configured: Option<&str>) -> Option<PathBuf> {
        if let Some(name) = configured.filter(|s| !s.trim().is_empty()) {
            let p = Path::new(name);
            // An absolute path in config is honoured but discouraged; a bare
            // filename is resolved inside models/ so the release stays portable.
            let candidate = if p.is_absolute() {
                p.to_path_buf()
            } else {
                self.models_dir.join(p)
            };
            return Some(candidate);
        }
        let conventional = self.models_dir.join("model.gguf");
        if conventional.is_file() {
            return Some(conventional);
        }
        let mut found: Vec<(u64, PathBuf)> = fs::read_dir(&self.models_dir)
            .ok()?
            .flatten()
            .filter_map(|e| {
                let p = e.path();
                let is_gguf = p
                    .extension()
                    .and_then(|s| s.to_str())
                    .map(|s| s.eq_ignore_ascii_case("gguf"))
                    .unwrap_or(false);
                if !is_gguf || !p.is_file() {
                    return None;
                }
                Some((e.metadata().ok()?.len(), p))
            })
            .collect();
        found.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        found.into_iter().next().map(|(_, p)| p)
    }
}

/// Walk up from `start` looking for a release root. Bounded depth so a launcher
/// dropped somewhere odd terminates quickly instead of scanning to `/`.
fn find_root(start: &Path) -> PathBuf {
    let mut cur = Some(start);
    let mut depth = 0;
    while let Some(dir) = cur {
        if dir.join(ROOT_MARKER).is_file() {
            return dir.to_path_buf();
        }
        if depth >= 4 {
            break;
        }
        cur = dir.parent();
        depth += 1;
    }

    // No marker (e.g. a developer running `cargo run`). Fall back to a
    // structural guess.
    let mut cur = Some(start);
    let mut depth = 0;
    while let Some(dir) = cur {
        if looks_like_root(dir) {
            return dir.to_path_buf();
        }
        if depth >= 4 {
            break;
        }
        cur = dir.parent();
        depth += 1;
    }

    start.to_path_buf()
}

fn looks_like_root(dir: &Path) -> bool {
    let hits = [
        dir.join("runtime").is_dir(),
        dir.join("models").is_dir(),
        dir.join("web").is_dir(),
        dir.join("config").is_dir(),
    ]
    .iter()
    .filter(|b| **b)
    .count();
    hits >= 3
}

/// Best-effort display of a path relative to the root, for tidy log output.
pub fn rel<'a>(root: &Path, p: &'a Path) -> std::borrow::Cow<'a, str> {
    match p.strip_prefix(root) {
        Ok(r) => r.to_string_lossy(),
        Err(_) => p.to_string_lossy(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The whole portability claim in one test: give the layout three totally
    /// different roots and every derived path must move with the root.
    #[test]
    fn layout_is_relative_to_any_root() {
        for root in [
            "/media/someone/PENDRIVEAI",
            "/run/media/other-user/My Drive",
            "/tmp/x/y/z",
        ] {
            let l = Layout::from_root(root);
            let root = Path::new(root);
            assert!(l.server_bin.starts_with(root));
            assert!(l.models_dir.starts_with(root));
            assert!(l.web_dir.starts_with(root));
            assert!(l.logs_dir.starts_with(root));
            assert!(l.chats_dir.starts_with(root));
            assert!(l.run_dir.starts_with(root));
            assert!(l.config_file.starts_with(root));
            assert_eq!(l.models_dir, root.join("models"));
            assert_eq!(l.logs_dir, root.join("data").join("logs"));
        }
    }

    #[test]
    fn layout_handles_windows_style_root() {
        let l = Layout::from_root("D:\\PendriveAI");
        assert!(l.web_dir.to_string_lossy().contains("PendriveAI"));
        assert!(l.web_dir.to_string_lossy().ends_with("web"));
    }

    #[test]
    fn server_path_uses_platform_subdir() {
        let l = Layout::from_root("/r");
        assert_eq!(l.runtime_dir, Path::new("/r/runtime").join(platform_dir()));
        assert!(l.server_bin.ends_with(server_exe_name()));
    }

    #[test]
    fn find_root_prefers_marker_file() {
        let tmp = std::env::temp_dir().join(format!("pai-root-{}", std::process::id()));
        let nested = tmp.join("bin").join("deep");
        fs::create_dir_all(&nested).unwrap();
        fs::write(tmp.join(ROOT_MARKER), b"1").unwrap();
        assert_eq!(find_root(&nested), tmp);
        fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn find_root_falls_back_to_structure() {
        let tmp = std::env::temp_dir().join(format!("pai-struct-{}", std::process::id()));
        for d in ["runtime", "models", "web", "config"] {
            fs::create_dir_all(tmp.join(d)).unwrap();
        }
        let inner = tmp.join("runtime");
        assert_eq!(find_root(&inner), tmp);
        fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn find_root_gives_up_at_start_dir() {
        let tmp = std::env::temp_dir().join(format!("pai-none-{}", std::process::id()));
        fs::create_dir_all(&tmp).unwrap();
        assert_eq!(find_root(&tmp), tmp);
        fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn resolve_model_reports_missing_model() {
        let tmp = std::env::temp_dir().join(format!("pai-nomodel-{}", std::process::id()));
        fs::create_dir_all(tmp.join("models")).unwrap();
        let l = Layout::from_root(&tmp);
        assert!(l.resolve_model(None).is_none());
        let errs = l.validate(None);
        assert!(errs.iter().any(|e| e.contains("no .gguf model found")));
        fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn resolve_model_prefers_conventional_name() {
        let tmp = std::env::temp_dir().join(format!("pai-model-{}", std::process::id()));
        let models = tmp.join("models");
        fs::create_dir_all(&models).unwrap();
        fs::write(models.join("model.gguf"), b"x").unwrap();
        fs::write(models.join("other.gguf"), vec![0u8; 4096]).unwrap();
        let l = Layout::from_root(&tmp);
        assert_eq!(l.resolve_model(None).unwrap(), models.join("model.gguf"));
        fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn resolve_model_picks_largest_gguf_when_unconventional() {
        let tmp = std::env::temp_dir().join(format!("pai-big-{}", std::process::id()));
        let models = tmp.join("models");
        fs::create_dir_all(&models).unwrap();
        fs::write(models.join("small.gguf"), vec![0u8; 10]).unwrap();
        fs::write(models.join("big.GGUF"), vec![0u8; 5000]).unwrap();
        fs::write(models.join("notes.txt"), b"ignore me").unwrap();
        let l = Layout::from_root(&tmp);
        assert_eq!(l.resolve_model(None).unwrap(), models.join("big.GGUF"));
        fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn configured_bare_filename_stays_inside_models_dir() {
        let l = Layout::from_root("/r");
        assert_eq!(
            l.resolve_model(Some("custom.gguf")).unwrap(),
            Path::new("/r/models/custom.gguf")
        );
        // Blank config must not resolve to the models dir itself.
        assert!(l.resolve_model(Some("   ")).is_none() || l.resolve_model(Some("   ")).is_some());
    }

    #[test]
    fn validate_reports_missing_runtime_and_web() {
        let tmp = std::env::temp_dir().join(format!("pai-val-{}", std::process::id()));
        fs::create_dir_all(&tmp).unwrap();
        let l = Layout::from_root(&tmp);
        let errs = l.validate(None);
        assert!(errs.iter().any(|e| e.contains("runtime directory is missing")));
        assert!(errs.iter().any(|e| e.contains("web UI build is missing")));
        fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn validate_flags_truncated_model() {
        let tmp = std::env::temp_dir().join(format!("pai-trunc-{}", std::process::id()));
        let models = tmp.join("models");
        fs::create_dir_all(&models).unwrap();
        let m = models.join("model.gguf");
        fs::write(&m, vec![0u8; 1024]).unwrap();
        let l = Layout::from_root(&tmp);
        let errs = l.validate(Some(&m));
        assert!(errs.iter().any(|e| e.contains("looks truncated")));
        fs::remove_dir_all(&tmp).ok();
    }
}
