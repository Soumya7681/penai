//! Minimal, dependency-free JSON reader/writer.
//!
//! Only what the launcher needs: read `config/config.json`, emit small status
//! documents. Not a general-purpose library, but it is deliberately strict --
//! a corrupted config produces a real error instead of silently-wrong settings.

use std::collections::BTreeMap;
use std::fmt::Write as _;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(BTreeMap<String, Json>),
}

impl Json {
    pub fn parse(src: &str) -> Result<Json, String> {
        let b = src.as_bytes();
        let mut p = Parser { b, i: 0 };
        p.ws();
        let v = p.value()?;
        p.ws();
        if p.i != b.len() {
            return Err(format!("trailing data at byte {}", p.i));
        }
        Ok(v)
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(m) => m.get(key),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Num(n) => Some(*n),
            _ => None,
        }
    }

    /// Strict: rejects negative, fractional and oversized numbers rather than
    /// truncating them into a plausible-looking wrong value.
    pub fn as_u32(&self) -> Option<u32> {
        match self {
            Json::Num(n) if *n >= 0.0 && n.fract() == 0.0 && *n <= u32::MAX as f64 => {
                Some(*n as u32)
            }
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn obj(pairs: Vec<(&str, Json)>) -> Json {
        Json::Obj(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }

    pub fn s(v: impl Into<String>) -> Json {
        Json::Str(v.into())
    }

    pub fn n(v: impl Into<f64>) -> Json {
        Json::Num(v.into())
    }

    pub fn dump(&self) -> String {
        let mut out = String::new();
        self.write_to(&mut out);
        out
    }

    fn write_to(&self, out: &mut String) {
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(true) => out.push_str("true"),
            Json::Bool(false) => out.push_str("false"),
            Json::Num(n) => {
                if !n.is_finite() {
                    out.push_str("null");
                } else if n.fract() == 0.0 && n.abs() < 1e15 {
                    let _ = write!(out, "{}", *n as i64);
                } else {
                    let _ = write!(out, "{}", n);
                }
            }
            Json::Str(s) => escape_into(s, out),
            Json::Arr(a) => {
                out.push('[');
                for (i, v) in a.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    v.write_to(out);
                }
                out.push(']');
            }
            Json::Obj(m) => {
                out.push('{');
                for (i, (k, v)) in m.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    escape_into(k, out);
                    out.push(':');
                    v.write_to(out);
                }
                out.push('}');
            }
        }
    }
}

fn escape_into(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }

    fn eat(&mut self, lit: &str) -> Result<(), String> {
        if self.b[self.i..].starts_with(lit.as_bytes()) {
            self.i += lit.len();
            Ok(())
        } else {
            Err(format!("expected `{}` at byte {}", lit, self.i))
        }
    }

    fn value(&mut self) -> Result<Json, String> {
        match self
            .peek()
            .ok_or_else(|| "unexpected end of input".to_string())?
        {
            b'{' => self.object(),
            b'[' => self.array(),
            b'"' => Ok(Json::Str(self.string()?)),
            b't' => {
                self.eat("true")?;
                Ok(Json::Bool(true))
            }
            b'f' => {
                self.eat("false")?;
                Ok(Json::Bool(false))
            }
            b'n' => {
                self.eat("null")?;
                Ok(Json::Null)
            }
            c if c == b'-' || c.is_ascii_digit() => self.number(),
            c => Err(format!("unexpected byte `{}` at {}", c as char, self.i)),
        }
    }

    fn object(&mut self) -> Result<Json, String> {
        self.i += 1;
        let mut m = BTreeMap::new();
        self.ws();
        if self.peek() == Some(b'}') {
            self.i += 1;
            return Ok(Json::Obj(m));
        }
        loop {
            self.ws();
            if self.peek() != Some(b'"') {
                return Err(format!("expected object key at byte {}", self.i));
            }
            let k = self.string()?;
            self.ws();
            if self.peek() != Some(b':') {
                return Err(format!("expected `:` at byte {}", self.i));
            }
            self.i += 1;
            self.ws();
            let v = self.value()?;
            m.insert(k, v);
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b'}') => {
                    self.i += 1;
                    return Ok(Json::Obj(m));
                }
                _ => return Err(format!("expected `,` or `}}` at byte {}", self.i)),
            }
        }
    }

    fn array(&mut self) -> Result<Json, String> {
        self.i += 1;
        let mut a = Vec::new();
        self.ws();
        if self.peek() == Some(b']') {
            self.i += 1;
            return Ok(Json::Arr(a));
        }
        loop {
            self.ws();
            a.push(self.value()?);
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b']') => {
                    self.i += 1;
                    return Ok(Json::Arr(a));
                }
                _ => return Err(format!("expected `,` or `]` at byte {}", self.i)),
            }
        }
    }

    fn string(&mut self) -> Result<String, String> {
        self.i += 1;
        let mut s = String::new();
        loop {
            let c = *self
                .b
                .get(self.i)
                .ok_or_else(|| "unterminated string".to_string())?;
            self.i += 1;
            match c {
                b'"' => return Ok(s),
                b'\\' => {
                    let e = *self
                        .b
                        .get(self.i)
                        .ok_or_else(|| "unterminated escape".to_string())?;
                    self.i += 1;
                    match e {
                        b'"' => s.push('"'),
                        b'\\' => s.push('\\'),
                        b'/' => s.push('/'),
                        b'b' => s.push('\u{8}'),
                        b'f' => s.push('\u{c}'),
                        b'n' => s.push('\n'),
                        b'r' => s.push('\r'),
                        b't' => s.push('\t'),
                        b'u' => {
                            let hi = self.hex4()?;
                            let ch = if (0xD800..0xDC00).contains(&hi) {
                                if self.b.get(self.i) == Some(&b'\\')
                                    && self.b.get(self.i + 1) == Some(&b'u')
                                {
                                    self.i += 2;
                                    let lo = self.hex4()?;
                                    if !(0xDC00..0xE000).contains(&lo) {
                                        return Err("invalid low surrogate".into());
                                    }
                                    let cp =
                                        0x10000 + ((hi as u32 - 0xD800) << 10) + (lo as u32 - 0xDC00);
                                    char::from_u32(cp)
                                } else {
                                    return Err("lone high surrogate".into());
                                }
                            } else {
                                char::from_u32(hi as u32)
                            };
                            s.push(ch.ok_or_else(|| "invalid unicode escape".to_string())?);
                        }
                        other => return Err(format!("bad escape `{}`", other as char)),
                    }
                }
                c if c < 0x20 => return Err("control character in string".into()),
                c => {
                    let len = utf8_len(c);
                    let start = self.i - 1;
                    self.i = start + len;
                    let bytes = self
                        .b
                        .get(start..self.i)
                        .ok_or_else(|| "truncated UTF-8".to_string())?;
                    s.push_str(std::str::from_utf8(bytes).map_err(|_| "invalid UTF-8")?);
                }
            }
        }
    }

    fn hex4(&mut self) -> Result<u16, String> {
        let sl = self
            .b
            .get(self.i..self.i + 4)
            .ok_or_else(|| "short unicode escape".to_string())?;
        let s = std::str::from_utf8(sl).map_err(|_| "bad unicode escape")?;
        self.i += 4;
        u16::from_str_radix(s, 16).map_err(|_| "bad unicode hex".to_string())
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        while matches!(self.peek(), Some(c) if c.is_ascii_digit() || matches!(c, b'.' | b'e' | b'E' | b'+' | b'-'))
        {
            self.i += 1;
        }
        let s = std::str::from_utf8(&self.b[start..self.i]).map_err(|_| "bad number")?;
        s.parse::<f64>()
            .map(Json::Num)
            .map_err(|_| format!("invalid number `{}` at byte {}", s, start))
    }
}

fn utf8_len(first: u8) -> usize {
    match first {
        0x00..=0x7F => 1,
        0xC0..=0xDF => 2,
        0xE0..=0xEF => 3,
        _ => 4,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_nested_config_shape() {
        let v = Json::parse(
            r#"{ "port": 8080, "threads": 0, "nested": { "a": [1, 2.5, true, null], "s": "hi" } }"#,
        )
        .unwrap();
        assert_eq!(v.get("port").and_then(Json::as_u32), Some(8080));
        assert_eq!(v.get("threads").and_then(Json::as_u32), Some(0));
        let nested = v.get("nested").unwrap();
        assert_eq!(nested.get("s").and_then(Json::as_str), Some("hi"));
        match nested.get("a").unwrap() {
            Json::Arr(a) => assert_eq!(a.len(), 4),
            _ => panic!("expected array"),
        }
    }

    #[test]
    fn rejects_malformed_input() {
        for bad in [
            "{",
            "{\"a\":}",
            "{\"a\":1,}",
            "[1,2",
            "{'a':1}",
            "1 2",
            "\"unterminated",
            "{\"a\" 1}",
        ] {
            assert!(Json::parse(bad).is_err(), "should have rejected: {}", bad);
        }
    }

    #[test]
    fn as_u32_rejects_bad_numbers() {
        assert_eq!(Json::parse("-1").unwrap().as_u32(), None);
        assert_eq!(Json::parse("1.5").unwrap().as_u32(), None);
        assert_eq!(Json::parse("1e40").unwrap().as_u32(), None);
        assert_eq!(Json::parse("4096").unwrap().as_u32(), Some(4096));
    }

    #[test]
    fn round_trips_through_dump() {
        let src = r#"{"a":[1,"x\"y",true,null],"b":{"c":-2.5}}"#;
        let v = Json::parse(src).unwrap();
        let again = Json::parse(&v.dump()).unwrap();
        assert_eq!(v, again);
    }

    #[test]
    fn escapes_quote_and_control_chars() {
        let s = Json::s("a\nb\"c\\d").dump();
        assert_eq!(s, "\"a\\nb\\\"c\\\\d\"");
    }

    #[test]
    fn handles_surrogate_pairs() {
        let v = Json::parse("\"\\ud83d\\ude00\"").unwrap();
        assert_eq!(v.as_str(), Some("\u{1F600}"));
        assert!(Json::parse("\"\\ud83d\"").is_err());
    }
}
