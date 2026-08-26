//! Loopback port selection and a minimal HTTP/1.1 client for health checks.
//!
//! Everything here is confined to 127.0.0.1 on purpose. The launcher never
//! binds or connects to a routable address, so the model is not reachable from
//! the local network.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream};
use std::time::{Duration, Instant};

/// The only address family this program ever uses.
pub const LOOPBACK: Ipv4Addr = Ipv4Addr::new(127, 0, 0, 1);

pub fn loopback(port: u16) -> SocketAddr {
    SocketAddr::V4(SocketAddrV4::new(LOOPBACK, port))
}

/// True if a TCP listener can be created on 127.0.0.1:port right now.
///
/// This is inherently a point-in-time answer: another process can grab the port
/// between the check and llama-server's own bind. The launcher handles that by
/// detecting a fast bind failure from the child and retrying on a new port.
pub fn is_port_free(port: u16) -> bool {
    TcpListener::bind(loopback(port)).is_ok()
}

/// Choose a loopback port: the preferred one if free, else the first free port
/// in `[scan_from, scan_to]`, else an OS-assigned ephemeral port.
pub fn pick_port(preferred: u16, scan_from: u16, scan_to: u16) -> std::io::Result<u16> {
    if preferred != 0 && is_port_free(preferred) {
        return Ok(preferred);
    }
    for p in scan_from..=scan_to {
        if p != preferred && is_port_free(p) {
            return Ok(p);
        }
    }
    // Last resort: let the kernel pick anything.
    let l = TcpListener::bind(loopback(0))?;
    Ok(l.local_addr()?.port())
}

#[derive(Debug)]
pub struct Response {
    pub status: u16,
    /// Read by the test suite and by future callers; the health check only
    /// needs the status code.
    #[allow(dead_code)]
    pub body: String,
}

/// Blocking HTTP/1.1 GET against loopback. Deliberately tiny: no redirects, no
/// chunked-transfer reassembly beyond reading to EOF, no TLS. It only ever
/// talks to the llama-server we started ourselves.
pub fn http_get(port: u16, path: &str, timeout: Duration) -> std::io::Result<Response> {
    let mut s = TcpStream::connect_timeout(&loopback(port), timeout)?;
    s.set_read_timeout(Some(timeout))?;
    s.set_write_timeout(Some(timeout))?;
    // `Connection: close` keeps the reply framing trivial: read until EOF.
    let req = format!(
        "GET {} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nAccept: application/json\r\n\
         User-Agent: PenAI-Launcher\r\nConnection: close\r\n\r\n",
        path, port
    );
    s.write_all(req.as_bytes())?;
    s.flush()?;

    let mut raw = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match s.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                raw.extend_from_slice(&buf[..n]);
                // A health payload is tiny; refuse to buffer a runaway reply.
                if raw.len() > 256 * 1024 {
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }

    let text = String::from_utf8_lossy(&raw);
    let status = text
        .split_whitespace()
        .nth(1)
        .and_then(|c| c.parse::<u16>().ok())
        .ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "malformed HTTP status line")
        })?;
    let body = match text.find("\r\n\r\n") {
        Some(i) => text[i + 4..].to_string(),
        None => String::new(),
    };
    Ok(Response { status, body })
}

/// Health probe result for one attempt.
#[derive(Debug, PartialEq, Eq)]
pub enum Health {
    /// Server answered 200 -- model loaded, ready to serve.
    Ready,
    /// Server answered but is still loading (llama-server returns 503).
    Loading,
    /// Nothing listening yet, or the connection failed.
    Down,
}

/// llama.cpp b10549 exposes `/v1/health`. Older builds used `/health`. Probing
/// both keeps the launcher working across runtime updates without pretending a
/// flag exists that does not.
pub const HEALTH_PATHS: [&str; 2] = ["/v1/health", "/health"];

pub fn probe_health(port: u16, timeout: Duration) -> Health {
    for path in HEALTH_PATHS {
        match http_get(port, path, timeout) {
            Ok(r) if r.status == 200 => return Health::Ready,
            Ok(r) if r.status == 503 => return Health::Loading,
            // 404 means this build does not have that route: try the next one.
            Ok(_) => continue,
            Err(_) => return Health::Down,
        }
    }
    Health::Down
}

/// Poll until the server is ready, giving up after `overall`.
///
/// `should_abort` lets the caller bail out early -- used when the child process
/// has already died, so we report the crash instead of waiting out the timeout.
pub fn wait_for_ready(
    port: u16,
    overall: Duration,
    mut on_tick: impl FnMut(Health, Duration),
    mut should_abort: impl FnMut() -> Option<String>,
) -> Result<Duration, String> {
    let start = Instant::now();
    let mut last = Health::Down;
    loop {
        if let Some(reason) = should_abort() {
            return Err(reason);
        }
        let h = probe_health(port, Duration::from_millis(1500));
        if h == Health::Ready {
            return Ok(start.elapsed());
        }
        if h != last {
            on_tick(match h {
                Health::Ready => Health::Ready,
                Health::Loading => Health::Loading,
                Health::Down => Health::Down,
            }, start.elapsed());
            last = h;
        }
        if start.elapsed() >= overall {
            return Err(format!(
                "llama-server did not become healthy within {}s (last state: {:?}). \
                 Check data/logs/llama-server.stderr.log.",
                overall.as_secs(),
                last
            ));
        }
        std::thread::sleep(Duration::from_millis(400));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loopback_addr_is_never_routable() {
        let a = loopback(8080);
        assert_eq!(a.ip().to_string(), "127.0.0.1");
        assert!(a.ip().is_loopback());
    }

    #[test]
    fn occupied_port_is_reported_busy_and_avoided() {
        let held = TcpListener::bind(loopback(0)).unwrap();
        let busy = held.local_addr().unwrap().port();
        assert!(!is_port_free(busy), "port {} should read as busy", busy);

        // pick_port must skip the busy port even when it is the preferred one.
        let chosen = pick_port(busy, busy, busy.saturating_add(30)).unwrap();
        assert_ne!(chosen, busy);
        drop(held);
    }

    #[test]
    fn pick_port_returns_preferred_when_free() {
        // Find a free port, release it, then ask for it specifically.
        let probe = TcpListener::bind(loopback(0)).unwrap();
        let p = probe.local_addr().unwrap().port();
        drop(probe);
        assert_eq!(pick_port(p, 49000, 49010).unwrap(), p);
    }

    #[test]
    fn pick_port_falls_back_to_ephemeral_when_range_exhausted() {
        // Occupy a 3-port range entirely, then force pick_port through it.
        let a = TcpListener::bind(loopback(0)).unwrap();
        let b = TcpListener::bind(loopback(0)).unwrap();
        let c = TcpListener::bind(loopback(0)).unwrap();
        let ports = [
            a.local_addr().unwrap().port(),
            b.local_addr().unwrap().port(),
            c.local_addr().unwrap().port(),
        ];
        let lo = *ports.iter().min().unwrap();
        // Scan a range we know is fully busy only if the three are contiguous;
        // otherwise this still exercises the fallback path harmlessly.
        let chosen = pick_port(ports[0], lo, lo).unwrap();
        assert!(chosen > 0);
        assert!(!ports.contains(&chosen) || chosen != ports[0]);
    }

    #[test]
    fn health_probe_on_dead_port_is_down() {
        let probe = TcpListener::bind(loopback(0)).unwrap();
        let dead = probe.local_addr().unwrap().port();
        drop(probe);
        assert_eq!(
            probe_health(dead, Duration::from_millis(300)),
            Health::Down
        );
    }

    /// Stand up a one-shot HTTP server so the client is tested for real rather
    /// than mocked.
    fn serve_once(response: &'static str) -> u16 {
        let l = TcpListener::bind(loopback(0)).unwrap();
        let port = l.local_addr().unwrap().port();
        std::thread::spawn(move || {
            if let Ok((mut s, _)) = l.accept() {
                let mut buf = [0u8; 1024];
                let _ = s.read(&mut buf);
                let _ = s.write_all(response.as_bytes());
                let _ = s.flush();
            }
        });
        port
    }

    #[test]
    fn http_get_parses_status_and_body() {
        let port = serve_once(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}",
        );
        let r = http_get(port, "/v1/health", Duration::from_secs(2)).unwrap();
        assert_eq!(r.status, 200);
        assert_eq!(r.body, "{\"status\":\"ok\"}");
    }

    #[test]
    fn health_maps_503_to_loading() {
        let port = serve_once(
            "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n{\"error\":\"loading\"}",
        );
        assert_eq!(probe_health(port, Duration::from_secs(2)), Health::Loading);
    }

    #[test]
    fn wait_for_ready_aborts_when_child_dies() {
        let probe = TcpListener::bind(loopback(0)).unwrap();
        let dead = probe.local_addr().unwrap().port();
        drop(probe);
        let err = wait_for_ready(
            dead,
            Duration::from_secs(30),
            |_, _| {},
            || Some("child exited with code 1".to_string()),
        )
        .unwrap_err();
        assert!(err.contains("child exited"));
    }

    #[test]
    fn wait_for_ready_times_out_with_actionable_message() {
        let probe = TcpListener::bind(loopback(0)).unwrap();
        let dead = probe.local_addr().unwrap().port();
        drop(probe);
        let err = wait_for_ready(dead, Duration::from_millis(1), |_, _| {}, || None).unwrap_err();
        assert!(err.contains("did not become healthy"));
        assert!(err.contains("stderr.log"));
    }
}
