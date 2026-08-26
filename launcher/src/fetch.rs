//! Optional web fetch.
//!
//! PenAI is an offline product and this module is the one exception, so it is
//! written to be easy to audit and impossible to trigger by accident:
//!
//!   * it does nothing at all unless `network.enabled` is true in config.json;
//!   * it is reachable only through the loopback sidecar, which already checks
//!     the `Host` and `Origin` headers, so a web page cannot drive it;
//!   * it fetches exactly the URL the user asked for -- there is no crawler, no
//!     link following beyond HTTP redirects, and the model cannot start a fetch
//!     on its own;
//!   * it refuses anything that resolves to a private, loopback or link-local
//!     address, before the request and again after redirects, so a pendrive
//!     plugged into an office network cannot be turned into a port scanner.
//!
//! Transport is `curl`, invoked as a subprocess. The launcher deliberately has
//! no external crates (see Cargo.toml), and hand-rolling TLS is not something
//! to do on a security-sensitive tool. curl ships with Windows 10 1803+ and
//! every mainstream Linux distribution; when it is missing the user is told
//! exactly that rather than being given a vague failure.

use std::fmt;
use std::net::{IpAddr, ToSocketAddrs};
use std::process::Command;
use std::time::Duration;

/// Everything the fetch path is allowed to do, all of it off by default.
#[derive(Clone, Debug)]
pub struct Policy {
    pub enabled: bool,
    pub timeout: Duration,
    pub max_bytes: usize,
    pub user_agent: String,
}

impl Default for Policy {
    fn default() -> Self {
        Policy {
            enabled: false,
            timeout: Duration::from_secs(20),
            max_bytes: 2 * 1024 * 1024,
            user_agent: concat!("PenAI/", env!("CARGO_PKG_VERSION")).to_string(),
        }
    }
}

#[derive(Debug)]
pub struct Page {
    /// The URL actually retrieved, after any redirects.
    pub url: String,
    pub title: String,
    pub text: String,
    /// Bytes received before extraction, for the size shown in the UI.
    pub bytes: usize,
    pub truncated: bool,
}

#[derive(Debug)]
pub enum Error {
    Disabled,
    BadUrl(String),
    Blocked(String),
    NoCurl,
    Transport(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Disabled => write!(
                f,
                "web access is off. Turn it on with \"network\": {{ \"enabled\": true }} in config/config.json, then restart."
            ),
            Error::BadUrl(m) => write!(f, "that is not a fetchable address: {}", m),
            Error::Blocked(m) => write!(f, "refused: {}", m),
            Error::NoCurl => write!(
                f,
                "curl was not found on this computer, and PenAI uses it to make the request. Install curl, or leave web access off."
            ),
            Error::Transport(m) => write!(f, "the request failed: {}", m),
        }
    }
}

/// A URL split into the parts this module cares about. Deliberately not a
/// general parser: anything it does not understand is rejected rather than
/// guessed at.
struct Parsed {
    host: String,
    port: u16,
}

fn parse(url: &str) -> Result<Parsed, Error> {
    let url = url.trim();
    if url.len() > 2048 {
        return Err(Error::BadUrl("the address is too long".into()));
    }
    if url.chars().any(|c| c.is_control() || c == ' ') {
        return Err(Error::BadUrl("it contains spaces or control characters".into()));
    }
    let (scheme, rest) = match url.split_once("://") {
        Some((s, r)) => (s.to_ascii_lowercase(), r),
        None => return Err(Error::BadUrl("it needs to start with http:// or https://".into())),
    };
    if scheme != "http" && scheme != "https" {
        return Err(Error::BadUrl(format!("{} is not a supported scheme", scheme)));
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.is_empty() {
        return Err(Error::BadUrl("there is no host in it".into()));
    }
    if authority.contains('@') {
        // user:password@host smuggles credentials and confuses host checks.
        return Err(Error::BadUrl("addresses with credentials in them are not accepted".into()));
    }
    let (host, port) = split_host_port(authority, &scheme)?;
    if host.is_empty() {
        return Err(Error::BadUrl("there is no host in it".into()));
    }
    Ok(Parsed { host, port })
}

fn split_host_port(authority: &str, scheme: &str) -> Result<(String, u16), Error> {
    let default = if scheme == "https" { 443 } else { 80 };
    if let Some(rest) = authority.strip_prefix('[') {
        // IPv6 literal: [::1]:8080
        let (h, tail) = rest
            .split_once(']')
            .ok_or_else(|| Error::BadUrl("the IPv6 address is not closed".into()))?;
        let port = match tail.strip_prefix(':') {
            Some(p) => p.parse().map_err(|_| Error::BadUrl("the port is not a number".into()))?,
            None => default,
        };
        return Ok((h.to_ascii_lowercase(), port));
    }
    match authority.rsplit_once(':') {
        Some((h, p)) => {
            let port = p.parse().map_err(|_| Error::BadUrl("the port is not a number".into()))?;
            Ok((h.to_ascii_lowercase(), port))
        }
        None => Ok((authority.to_ascii_lowercase(), default)),
    }
}

/// True for anything on this machine or this network: loopback, RFC1918, CGNAT,
/// link-local (including the cloud metadata address), and their IPv6 cousins.
pub fn is_private(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_documentation()
                || v4.is_unspecified()
                || v4.is_multicast()
                // 100.64.0.0/10, carrier-grade NAT.
                || (v4.octets()[0] == 100 && (64..128).contains(&v4.octets()[1]))
        }
        IpAddr::V6(v6) => {
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                // fc00::/7 unique local, fe80::/10 link local.
                || (v6.segments()[0] & 0xfe00) == 0xfc00
                || (v6.segments()[0] & 0xffc0) == 0xfe80
                // ::ffff:a.b.c.d -- an IPv4 address wearing a hat.
                || v6.to_ipv4_mapped().map(|m| is_private(IpAddr::V4(m))).unwrap_or(false)
        }
    }
}

/// Names that never leave the machine or the LAN, refused before any DNS query.
fn host_name_is_local(host: &str) -> bool {
    let h = host.trim_end_matches('.');
    h == "localhost"
        || h.ends_with(".localhost")
        || h.ends_with(".local")
        || h.ends_with(".internal")
        || h.ends_with(".home.arpa")
}

/// Resolve and refuse the whole address if *any* answer is private: a name that
/// resolves to both a public and a private address is a rebinding attempt.
fn check_destination(host: &str, port: u16) -> Result<(), Error> {
    if host_name_is_local(host) {
        return Err(Error::Blocked(format!("{} is on this machine or this network", host)));
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        return if is_private(ip) {
            Err(Error::Blocked(format!("{} is a private address", ip)))
        } else {
            Ok(())
        };
    }
    let addrs = (host, port)
        .to_socket_addrs()
        .map_err(|e| Error::Blocked(format!("{} could not be resolved ({})", host, e)))?;
    let mut any = false;
    for a in addrs {
        any = true;
        if is_private(a.ip()) {
            return Err(Error::Blocked(format!(
                "{} resolves to {}, which is on this machine or this network",
                host,
                a.ip()
            )));
        }
    }
    if any {
        Ok(())
    } else {
        Err(Error::Blocked(format!("{} did not resolve to any address", host)))
    }
}

/// Separator between the response body and the status line curl appends. 0x1e
/// is the ASCII record separator; it cannot appear in a decoded HTML document
/// this module would keep.
const SEP: char = '\u{1e}';

pub fn fetch(url: &str, policy: &Policy) -> Result<Page, Error> {
    if !policy.enabled {
        return Err(Error::Disabled);
    }
    let p = parse(url)?;
    check_destination(&p.host, p.port)?;

    let out = Command::new("curl")
        .arg("--silent")
        .arg("--show-error")
        .arg("--location")
        .arg("--max-redirs").arg("5")
        // Redirects must stay on the web; no file:// or gopher:// hops.
        .arg("--proto").arg("=http,https")
        .arg("--proto-redir").arg("=http,https")
        .arg("--max-time").arg(policy.timeout.as_secs().to_string())
        .arg("--max-filesize").arg(policy.max_bytes.to_string())
        .arg("--user-agent").arg(&policy.user_agent)
        .arg("--header").arg("Accept: text/html,text/plain;q=0.9,*/*;q=0.5")
        .arg("--write-out").arg(format!("{}%{{http_code}} %{{url_effective}}", SEP))
        .arg("--")
        .arg(url)
        .output()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                Error::NoCurl
            } else {
                Error::Transport(e.to_string())
            }
        })?;

    if !out.status.success() && out.stdout.is_empty() {
        let msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(Error::Transport(if msg.is_empty() {
            format!("curl exited with {}", out.status)
        } else {
            msg
        }));
    }

    let raw = String::from_utf8_lossy(&out.stdout).to_string();
    let (body, trailer) = match raw.rsplit_once(SEP) {
        Some((b, t)) => (b, t),
        None => (raw.as_str(), ""),
    };
    let mut parts = trailer.split_whitespace();
    let status: u16 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    let final_url = parts.next().unwrap_or(url).to_string();

    // A redirect can land somewhere the first check would have refused.
    if final_url != url {
        let f = parse(&final_url)?;
        check_destination(&f.host, f.port)?;
    }

    if status == 0 {
        return Err(Error::Transport("no response".into()));
    }
    if !(200..300).contains(&status) {
        return Err(Error::Transport(format!("the site answered {}", status)));
    }

    let bytes = body.len();
    let truncated = bytes >= policy.max_bytes;
    let (title, text) = html_to_text(body);
    Ok(Page { url: final_url, title, text, bytes, truncated })
}

/// Turn a document into something worth putting in a prompt.
///
/// Not a browser: script, style and comment contents are dropped, tags are
/// removed, entities are decoded and runs of blank space collapse. Plain text
/// passes through untouched.
pub fn html_to_text(input: &str) -> (String, String) {
    let looks_like_html = input
        .trim_start()
        .get(..64)
        .map(|h| {
            let l = h.to_ascii_lowercase();
            l.starts_with("<!doctype") || l.starts_with("<html") || l.contains("<head") || l.contains("<body")
        })
        .unwrap_or(false)
        || input.contains("</p>")
        || input.contains("</div>");
    if !looks_like_html {
        return (String::new(), collapse(input));
    }

    let mut title = String::new();
    let mut out = String::with_capacity(input.len() / 2);
    let bytes: Vec<char> = input.chars().collect();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == '<' {
            let rest: String = bytes[i..].iter().take(16).collect::<String>().to_ascii_lowercase();
            if rest.starts_with("<!--") {
                i = skip_to(&bytes, i, "-->");
                continue;
            }
            for tag in ["script", "style", "svg", "noscript"] {
                if rest.starts_with(&format!("<{}", tag)) {
                    i = skip_to(&bytes, i, &format!("</{}>", tag));
                    break;
                }
            }
            if i >= bytes.len() {
                break;
            }
            if bytes[i] != '<' {
                continue;
            }
            if rest.starts_with("<title") {
                let start = skip_to(&bytes, i, ">");
                let end = find(&bytes, start, "</title>");
                title = collapse(&bytes[start..end.min(bytes.len())].iter().collect::<String>());
                i = end;
                continue;
            }
            // Block-level tags become line breaks so paragraphs survive. A
            // close immediately followed by an open is one boundary, not two,
            // so never stack blank lines here.
            if BLOCK.iter().any(|t| {
                rest.starts_with(&format!("<{}", t)) || rest.starts_with(&format!("</{}", t))
            }) && !out.ends_with('\n')
            {
                out.push('\n');
            }
            i = skip_to(&bytes, i, ">");
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    (title, collapse(&decode_entities(&out)))
}

const BLOCK: [&str; 17] = [
    "p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article",
    "header", "footer", "table", "blockquote",
];

fn find(hay: &[char], from: usize, needle: &str) -> usize {
    let n: Vec<char> = needle.to_ascii_lowercase().chars().collect();
    let mut i = from;
    while i + n.len() <= hay.len() {
        if hay[i..i + n.len()]
            .iter()
            .map(|c| c.to_ascii_lowercase())
            .eq(n.iter().copied())
        {
            return i;
        }
        i += 1;
    }
    hay.len()
}

fn skip_to(hay: &[char], from: usize, needle: &str) -> usize {
    let at = find(hay, from, needle);
    (at + needle.chars().count()).min(hay.len())
}

fn decode_entities(s: &str) -> String {
    let mut out = s.to_string();
    for (from, to) in [
        ("&nbsp;", " "),
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&mdash;", "--"),
        ("&ndash;", "-"),
        ("&hellip;", "..."),
    ] {
        if out.contains(from) {
            out = out.replace(from, to);
        }
    }
    out
}

/// Squeeze horizontal runs to one space and vertical runs to one blank line.
fn collapse(s: &str) -> String {
    let mut lines: Vec<String> = Vec::new();
    for line in s.lines() {
        let t = line.split_whitespace().collect::<Vec<_>>().join(" ");
        if t.is_empty() {
            if matches!(lines.last(), Some(l) if l.is_empty()) {
                continue;
            }
            lines.push(String::new());
        } else {
            lines.push(t);
        }
    }
    while matches!(lines.first(), Some(l) if l.is_empty()) {
        lines.remove(0);
    }
    while matches!(lines.last(), Some(l) if l.is_empty()) {
        lines.pop();
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn on() -> Policy {
        Policy { enabled: true, ..Policy::default() }
    }

    #[test]
    fn disabled_by_default() {
        assert!(matches!(fetch("https://example.com", &Policy::default()), Err(Error::Disabled)));
    }

    #[test]
    fn rejects_non_web_schemes() {
        for u in ["file:///etc/passwd", "ftp://example.com", "gopher://x", "javascript:alert(1)"] {
            assert!(matches!(fetch(u, &on()), Err(Error::BadUrl(_))), "{} should be refused", u);
        }
    }

    #[test]
    fn rejects_credentials_in_the_url() {
        assert!(matches!(
            fetch("https://user:pass@example.com/", &on()),
            Err(Error::BadUrl(_))
        ));
    }

    #[test]
    fn refuses_this_machine_and_this_network() {
        for u in [
            "http://127.0.0.1:8080/",
            "http://localhost/",
            "http://[::1]/",
            "http://10.0.0.5/",
            "http://192.168.1.1/",
            "http://172.16.4.4/",
            "http://169.254.169.254/latest/meta-data/",
            "http://nas.local/",
            "http://100.100.0.1/",
        ] {
            match fetch(u, &on()) {
                Err(Error::Blocked(_)) => {}
                other => panic!("{} must be blocked, got {:?}", u, other),
            }
        }
    }

    #[test]
    fn private_ranges_are_recognised() {
        for ip in ["127.0.0.1", "10.1.2.3", "192.168.0.9", "172.31.255.1", "169.254.1.1", "::1", "fe80::1", "fd00::1"] {
            assert!(is_private(ip.parse().unwrap()), "{} should be private", ip);
        }
        for ip in ["1.1.1.1", "93.184.216.34", "2606:4700::1111"] {
            assert!(!is_private(ip.parse().unwrap()), "{} should be public", ip);
        }
    }

    #[test]
    fn extracts_title_and_drops_scripts() {
        let html = "<html><head><title> Hello  world </title>\
            <style>body{color:red}</style></head><body>\
            <script>var x = '<p>not text</p>';</script>\
            <h1>Heading</h1><p>First para.</p><p>Second &amp; last.</p>\
            <!-- a comment --></body></html>";
        let (title, text) = html_to_text(html);
        assert_eq!(title, "Hello world");
        assert!(text.contains("Heading"), "{}", text);
        assert!(text.contains("First para."), "{}", text);
        assert!(text.contains("Second & last."), "{}", text);
        assert!(!text.contains("not text"), "script body leaked: {}", text);
        assert!(!text.contains("color:red"), "style leaked: {}", text);
        assert!(!text.contains("comment"), "comment leaked: {}", text);
    }

    #[test]
    fn plain_text_passes_through() {
        let (title, text) = html_to_text("just a note\n\n\n\nwith a gap");
        assert!(title.is_empty());
        assert_eq!(text, "just a note\n\nwith a gap");
    }

    #[test]
    fn block_tags_become_line_breaks() {
        let (_, text) = html_to_text("<div>one</div><div>two</div>");
        assert_eq!(text, "one\ntwo");
    }
}

