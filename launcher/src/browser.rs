//! Opening the user's default browser.
//!
//! The URL is always a loopback address this program just constructed, and it
//! is passed as a single argv element -- never interpolated into a shell string.

use std::process::{Command, Stdio};

/// Attempt to open `url`. Returns the mechanism that succeeded, or an error
/// listing what was tried, so the user can be told to open the URL manually.
pub fn open(url: &str) -> Result<&'static str, String> {
    if !is_safe_loopback_url(url) {
        // Defence in depth: this function must never be reachable with anything
        // but our own local URL.
        return Err(format!("refusing to open non-loopback URL: {}", url));
    }

    let mut tried: Vec<String> = Vec::new();

    #[cfg(windows)]
    {
        // `start` is a cmd builtin. The empty "" is the window-title argument;
        // without it cmd treats a quoted URL as the title.
        if run("cmd", &["/C", "start", "", url], &mut tried) {
            return Ok("cmd start");
        }
        if run("rundll32", &["url.dll,FileProtocolHandler", url], &mut tried) {
            return Ok("rundll32");
        }
    }

    #[cfg(target_os = "macos")]
    {
        if run("open", &[url], &mut tried) {
            return Ok("open");
        }
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        // Respect an explicit user preference first.
        if let Ok(b) = std::env::var("BROWSER") {
            if !b.trim().is_empty() && run(&b, &[url], &mut tried) {
                return Ok("BROWSER");
            }
        }
        for tool in ["xdg-open", "gio", "gnome-open", "kde-open", "wslview"] {
            let args: Vec<&str> = if tool == "gio" {
                vec!["open", url]
            } else {
                vec![url]
            };
            if run(tool, &args, &mut tried) {
                return Ok("xdg/gio");
            }
        }
        for b in ["firefox", "chromium", "google-chrome", "brave-browser", "epiphany"] {
            if run(b, &[url], &mut tried) {
                return Ok("direct browser");
            }
        }
    }

    Err(format!(
        "could not launch a browser (tried: {})",
        if tried.is_empty() {
            "nothing available".to_string()
        } else {
            tried.join(", ")
        }
    ))
}

fn run(program: &str, args: &[&str], tried: &mut Vec<String>) -> bool {
    tried.push(program.to_string());
    Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .is_ok()
}

/// Only `http://127.0.0.1:<port>` and `http://localhost:<port>` are acceptable.
pub fn is_safe_loopback_url(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("http://") else {
        return false;
    };
    // Reject credentials, and anything with a path that could confuse a handler.
    if rest.contains('@') || rest.contains('\\') || rest.contains(' ') {
        return false;
    }
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host_only = host.rsplit_once(':').map(|(h, _)| h).unwrap_or(host);
    matches!(host_only, "127.0.0.1" | "localhost")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_our_own_urls() {
        assert!(is_safe_loopback_url("http://127.0.0.1:8080"));
        assert!(is_safe_loopback_url("http://127.0.0.1:8080/"));
        assert!(is_safe_loopback_url("http://localhost:47611/#chat"));
    }

    #[test]
    fn rejects_anything_remote_or_odd() {
        for bad in [
            "http://example.com",
            "https://127.0.0.1:8080",
            "http://127.0.0.1.evil.com:8080",
            "http://user@127.0.0.1:8080",
            "file:///etc/passwd",
            "http://0.0.0.0:8080",
            "http://192.168.1.10:8080",
            "javascript:alert(1)",
            "http://127.0.0.1:8080 --incognito",
            "http://127.0.0.1:8080\\x",
            "",
        ] {
            assert!(!is_safe_loopback_url(bad), "should have rejected {}", bad);
        }
    }

    #[test]
    fn open_refuses_non_loopback_without_spawning_anything() {
        let err = open("http://example.com").unwrap_err();
        assert!(err.contains("refusing to open non-loopback"));
    }
}
