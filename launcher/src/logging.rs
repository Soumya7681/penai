//! File logging with size-bounded rotation.
//!
//! A pendrive is small and often read-only-ish, so logs must never grow without
//! limit and a failure to write must never take down the launcher: if the
//! destination is not writable we degrade to console-only and say so.

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

/// One rotating log file.
pub struct Sink {
    path: PathBuf,
    file: Option<File>,
    written: u64,
    max_bytes: u64,
    keep: u32,
    /// Set once if opening failed, so we complain exactly one time.
    degraded: bool,
}

impl Sink {
    pub fn open(path: impl Into<PathBuf>, max_bytes: u64, keep: u32) -> Sink {
        let path = path.into();
        let mut s = Sink {
            path,
            file: None,
            written: 0,
            max_bytes: max_bytes.max(64 * 1024),
            keep,
            degraded: false,
        };
        // Rotate up front so each run starts with headroom rather than
        // appending to an already-oversized file.
        if let Ok(md) = fs::metadata(&s.path) {
            if md.len() >= s.max_bytes {
                s.rotate();
            } else {
                s.written = md.len();
            }
        }
        s.reopen();
        s
    }

    fn reopen(&mut self) {
        if let Some(parent) = self.path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        match OpenOptions::new().create(true).append(true).open(&self.path) {
            Ok(f) => {
                self.file = Some(f);
                self.degraded = false;
            }
            Err(e) => {
                if !self.degraded {
                    eprintln!(
                        "[warn] cannot write log {}: {} -- continuing with console output only",
                        self.path.display(),
                        e
                    );
                    self.degraded = true;
                }
                self.file = None;
            }
        }
    }

    /// `foo.log` -> `foo.log.1`, shifting `.1`->`.2` ... and dropping the oldest.
    fn rotate(&mut self) {
        self.file = None;
        let p = &self.path;
        let name = p.to_string_lossy().to_string();
        if self.keep == 0 {
            let _ = fs::remove_file(p);
            self.written = 0;
            return;
        }
        // Drop the oldest, then shift everything down one slot.
        let oldest = PathBuf::from(format!("{}.{}", name, self.keep));
        let _ = fs::remove_file(&oldest);
        for i in (1..self.keep).rev() {
            let from = PathBuf::from(format!("{}.{}", name, i));
            let to = PathBuf::from(format!("{}.{}", name, i + 1));
            if from.exists() {
                let _ = fs::rename(&from, &to);
            }
        }
        let _ = fs::rename(p, PathBuf::from(format!("{}.1", name)));
        self.written = 0;
    }

    pub fn write_line(&mut self, line: &str) {
        let bytes = line.len() as u64 + 1;
        if self.written + bytes > self.max_bytes {
            self.rotate();
            self.reopen();
        }
        if let Some(f) = self.file.as_mut() {
            if writeln!(f, "{}", line).is_ok() {
                self.written += bytes;
            } else {
                // Disk full / drive yanked. Drop to console rather than panic.
                self.file = None;
            }
        }
    }

}

/// The launcher's own log: timestamped, echoed to the console.
#[derive(Clone)]
pub struct Logger {
    sink: Arc<Mutex<Sink>>,
    echo: bool,
}

impl Logger {
    pub fn new(path: impl Into<PathBuf>, max_bytes: u64, keep: u32, echo: bool) -> Logger {
        Logger {
            sink: Arc::new(Mutex::new(Sink::open(path, max_bytes, keep))),
            echo,
        }
    }

    fn emit(&self, level: &str, msg: &str) {
        let line = format!("{} [{}] {}", timestamp(), level, msg);
        if self.echo {
            if level == "error" || level == "warn" {
                eprintln!("{}", render_console(level, msg));
            } else {
                println!("{}", render_console(level, msg));
            }
        }
        // A poisoned lock must not stop logging; recover the inner value.
        match self.sink.lock() {
            Ok(mut g) => g.write_line(&line),
            Err(p) => p.into_inner().write_line(&line),
        }
    }

    pub fn info(&self, msg: impl AsRef<str>) {
        self.emit("info", msg.as_ref());
    }
    pub fn warn(&self, msg: impl AsRef<str>) {
        self.emit("warn", msg.as_ref());
    }
    pub fn error(&self, msg: impl AsRef<str>) {
        self.emit("error", msg.as_ref());
    }
    /// File only -- for verbose child output we do not want on the console.
    pub fn trace(&self, msg: impl AsRef<str>) {
        let line = format!("{} [trace] {}", timestamp(), msg.as_ref());
        match self.sink.lock() {
            Ok(mut g) => g.write_line(&line),
            Err(p) => p.into_inner().write_line(&line),
        }
    }
}

fn render_console(level: &str, msg: &str) -> String {
    match level {
        "error" => format!("  [x] {}", msg),
        "warn" => format!("  [!] {}", msg),
        _ => format!("  {}", msg),
    }
}

/// Seconds-resolution UTC stamp without pulling in a date library.
pub fn timestamp() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = civil_from_unix(secs as i64);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y, mo, d, h, mi, s
    )
}

/// Days-from-civil inverse (Howard Hinnant's algorithm), integer-only.
fn civil_from_unix(secs: i64) -> (i64, u32, u32, u32, u32, u32) {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (
        y,
        m,
        d,
        (rem / 3600) as u32,
        ((rem % 3600) / 60) as u32,
        (rem % 60) as u32,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("pai-log-{}-{}", tag, std::process::id()));
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn writes_lines_to_file() {
        let d = tmpdir("write");
        let f = d.join("a.log");
        let mut s = Sink::open(&f, 1_000_000, 3);
        s.write_line("hello");
        s.write_line("world");
        drop(s);
        let text = fs::read_to_string(&f).unwrap();
        assert!(text.contains("hello") && text.contains("world"));
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn rotates_when_over_size_and_keeps_bounded_history() {
        let d = tmpdir("rot");
        let f = d.join("b.log");
        // 64 KiB floor is enforced, so write enough to cross it several times.
        let mut s = Sink::open(&f, 64 * 1024, 2);
        let chunk = "x".repeat(1000);
        for _ in 0..400 {
            s.write_line(&chunk);
        }
        drop(s);
        assert!(f.exists(), "current log must exist");
        assert!(f.with_extension("log.1").exists(), "one rotation expected");
        // keep=2 means .3 must never appear.
        assert!(!f.with_extension("log.3").exists(), "history must be bounded");
        let total: u64 = fs::read_dir(&d)
            .unwrap()
            .flatten()
            .map(|e| e.metadata().map(|m| m.len()).unwrap_or(0))
            .sum();
        assert!(
            total < 64 * 1024 * 4,
            "total log bytes should stay bounded, got {}",
            total
        );
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn oversized_existing_file_is_rotated_at_open() {
        let d = tmpdir("pre");
        let f = d.join("c.log");
        fs::write(&f, vec![b'z'; 200 * 1024]).unwrap();
        let s = Sink::open(&f, 64 * 1024, 3);
        drop(s);
        assert!(f.with_extension("log.1").exists());
        assert_eq!(fs::metadata(&f).unwrap().len(), 0);
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn unwritable_destination_degrades_instead_of_panicking() {
        // A path whose parent is a *file* can never be created.
        let d = tmpdir("bad");
        let blocker = d.join("blocker");
        fs::write(&blocker, b"x").unwrap();
        let mut s = Sink::open(blocker.join("nested.log"), 64 * 1024, 1);
        s.write_line("this must not panic");
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn logger_is_shareable_across_threads() {
        let d = tmpdir("mt");
        let f = d.join("m.log");
        let lg = Logger::new(&f, 1_000_000, 2, false);
        let hs: Vec<_> = (0..4)
            .map(|i| {
                let lg = lg.clone();
                std::thread::spawn(move || {
                    for j in 0..50 {
                        lg.info(format!("t{} line {}", i, j));
                    }
                })
            })
            .collect();
        for h in hs {
            h.join().unwrap();
        }
        let text = fs::read_to_string(&f).unwrap();
        assert_eq!(text.lines().count(), 200);
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn timestamp_is_iso8601_utc() {
        let t = timestamp();
        assert_eq!(t.len(), 20, "unexpected stamp: {}", t);
        assert!(t.ends_with('Z'));
        assert_eq!(&t[4..5], "-");
        assert_eq!(&t[10..11], "T");
    }

    #[test]
    fn civil_conversion_matches_known_epochs() {
        assert_eq!(civil_from_unix(0), (1970, 1, 1, 0, 0, 0));
        assert_eq!(civil_from_unix(946_684_800), (2000, 1, 1, 0, 0, 0));
        // 2024-02-29T12:34:56Z -- leap day, to exercise the month arithmetic.
        assert_eq!(civil_from_unix(1_709_210_096), (2024, 2, 29, 12, 34, 56));
    }
}
