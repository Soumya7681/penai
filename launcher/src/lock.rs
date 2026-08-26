//! Single-instance enforcement.
//!
//! A bound loopback socket is used as the mutex rather than a lock file,
//! because the OS releases it even if the launcher is killed or the drive is
//! yanked -- a stale lock file would otherwise leave the user unable to start
//! again without manual cleanup.
//!
//! A companion `instance.json` records the URL, so a second launch can simply
//! reopen the browser at the already-running server instead of failing.

use crate::json::Json;
use crate::net::loopback;
use std::fs;
use std::net::TcpListener;
use std::path::{Path, PathBuf};

pub const INSTANCE_FILE: &str = "instance.json";

pub struct Guard {
    _listener: TcpListener,
    info_path: PathBuf,
}

impl Drop for Guard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.info_path);
    }
}

pub enum Acquire {
    /// We are the only instance.
    Acquired(Guard),
    /// Another launcher already owns the sentinel port.
    AlreadyRunning { url: Option<String>, pid: Option<u32> },
}

/// Try to become the single instance.
pub fn acquire(sentinel_port: u16, run_dir: &Path) -> Acquire {
    match TcpListener::bind(loopback(sentinel_port)) {
        Ok(l) => Acquire::Acquired(Guard {
            _listener: l,
            info_path: run_dir.join(INSTANCE_FILE),
        }),
        Err(_) => {
            let (url, pid) = read_info(run_dir);
            Acquire::AlreadyRunning { url, pid }
        }
    }
}

impl Guard {
    /// Publish the live endpoint for a second launch (and for troubleshooting).
    pub fn publish(&self, url: &str, llama_port: u16, store_port: Option<u16>) {
        let doc = Json::obj(vec![
            ("pid", Json::n(std::process::id() as f64)),
            ("url", Json::s(url)),
            ("llamaPort", Json::n(llama_port as f64)),
            (
                "storePort",
                match store_port {
                    Some(p) => Json::n(p as f64),
                    None => Json::Null,
                },
            ),
            ("startedAt", Json::s(crate::logging::timestamp())),
        ])
        .dump();
        if let Some(p) = self.info_path.parent() {
            let _ = fs::create_dir_all(p);
        }
        // Best-effort: a read-only pendrive must not stop the launcher.
        let _ = fs::write(&self.info_path, doc);
    }

    #[allow(dead_code)]
    pub fn info_path(&self) -> &Path {
        &self.info_path
    }
}

fn read_info(run_dir: &Path) -> (Option<String>, Option<u32>) {
    let Ok(text) = fs::read_to_string(run_dir.join(INSTANCE_FILE)) else {
        return (None, None);
    };
    let Ok(v) = Json::parse(&text) else {
        return (None, None);
    };
    (
        v.get("url").and_then(Json::as_str).map(|s| s.to_string()),
        v.get("pid").and_then(Json::as_u32),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("pai-lock-{}-{}", tag, std::process::id()));
        fs::create_dir_all(&p).unwrap();
        p
    }

    /// Ask the OS for a port, then let go of it so `acquire` can take it.
    ///
    /// There is an unavoidable gap between releasing the probe socket and
    /// binding it again, and on a busy machine another process can win that
    /// race. Callers retry rather than assert, because the flakiness is in the
    /// probe, not in the code under test.
    fn free_port() -> u16 {
        let l = TcpListener::bind(loopback(0)).unwrap();
        let p = l.local_addr().unwrap().port();
        drop(l);
        p
    }

    /// Acquire on a port that is genuinely free right now, retrying past any
    /// unrelated process that grabs the probed port first.
    fn acquire_free(dir: &Path) -> (u16, Guard) {
        for _ in 0..25 {
            let p = free_port();
            if let Acquire::Acquired(g) = acquire(p, dir) {
                return (p, g);
            }
        }
        panic!("no free sentinel port after 25 attempts");
    }

    #[test]
    fn first_instance_acquires() {
        let d = tmp("first");
        let (_p, _g) = acquire_free(&d);
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn second_instance_is_refused_and_learns_the_url() {
        let d = tmp("second");
        let (p, g) = acquire_free(&d);
        g.publish("http://127.0.0.1:8080", 8080, Some(47611));

        match acquire(p, &d) {
            Acquire::AlreadyRunning { url, pid } => {
                assert_eq!(url.as_deref(), Some("http://127.0.0.1:8080"));
                assert_eq!(pid, Some(std::process::id()));
            }
            _ => panic!("second acquire must be refused"),
        }
        drop(g);
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn lock_is_released_when_guard_drops() {
        let d = tmp("release");
        // Retry the whole scenario: the re-acquire can also lose the port to an
        // unrelated process, which would say nothing about the guard.
        for _ in 0..25 {
            let (p, g) = acquire_free(&d);
            g.publish("http://127.0.0.1:1", 1, None);
            assert!(g.info_path().exists(), "publish must write the info file");
            drop(g);

            // Guard dropped: the info file is gone and the port is free again.
            assert!(!d.join(INSTANCE_FILE).exists(), "info file must be cleaned up");
            if let Acquire::Acquired(_) = acquire(p, &d) {
                fs::remove_dir_all(&d).ok();
                return;
            }
        }
        panic!("port never became reusable after the guard dropped");
    }

    #[test]
    fn corrupt_instance_file_does_not_crash() {
        let d = tmp("corrupt");
        fs::write(d.join(INSTANCE_FILE), b"{ this is not json").unwrap();
        assert_eq!(read_info(&d), (None, None));
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn missing_instance_file_is_fine() {
        let d = tmp("absent");
        assert_eq!(read_info(&d), (None, None));
        fs::remove_dir_all(&d).ok();
    }
}
