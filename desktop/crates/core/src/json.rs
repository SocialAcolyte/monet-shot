//! JSON exactly as the Mac writes it (`JSONEncoder.app`): pretty printed with
//! two-space indents and `"key" : value`, keys sorted by code unit, `/`
//! escaped, numbers in Swift's own shortest form (`2`, `0.07`, `1e-05`),
//! empty containers as `[\n\n  ]`, no trailing newline. Dates are ISO 8601
//! in whole seconds, UTC.

use serde::{de::DeserializeOwned, Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

/// Encodes `value` byte-for-byte as Swift's `JSONEncoder.app` would.
pub fn to_swift_json<T: Serialize + ?Sized>(value: &T) -> serde_json::Result<String> {
    let v = serde_json::to_value(value)?;
    let mut out = String::new();
    write_value(&v, 0, &mut out);
    Ok(out)
}

pub fn from_json<T: DeserializeOwned>(data: &[u8]) -> serde_json::Result<T> {
    serde_json::from_slice(data)
}

fn indent(n: usize, out: &mut String) {
    for _ in 0..n {
        out.push_str("  ");
    }
}

fn write_value(v: &Value, depth: usize, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                out.push_str(&i.to_string())
            } else if let Some(u) = n.as_u64() {
                out.push_str(&u.to_string())
            } else {
                out.push_str(&swift_double(n.as_f64().unwrap_or(0.0)))
            }
        }
        Value::String(s) => write_string(s, out),
        Value::Array(a) => {
            out.push_str("[\n");
            if a.is_empty() {
                out.push('\n');
            }
            for (i, x) in a.iter().enumerate() {
                indent(depth + 1, out);
                write_value(x, depth + 1, out);
                if i + 1 < a.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            indent(depth, out);
            out.push(']');
        }
        Value::Object(m) => {
            out.push_str("{\n");
            if m.is_empty() {
                out.push('\n');
            }
            // serde_json's map is a BTreeMap: byte order, which for UTF-8 is
            // code point order, as Swift's sortedKeys.
            let n = m.len();
            for (i, (k, x)) in m.iter().enumerate() {
                indent(depth + 1, out);
                write_string(k, out);
                out.push_str(" : ");
                write_value(x, depth + 1, out);
                if i + 1 < n {
                    out.push(',');
                }
                out.push('\n');
            }
            indent(depth, out);
            out.push('}');
        }
    }
}

fn write_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '/' => out.push_str("\\/"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// A Double as Swift prints it: shortest digits that round-trip, positional
/// for decimal exponents -4 ..< 16, otherwise `1e-05` / `1.2e+17`; whole
/// numbers without `.0`.
pub fn swift_double(v: f64) -> String {
    if !v.is_finite() {
        // Swift's encoder refuses these; never written by the app.
        return "0".into();
    }
    if v == 0.0 {
        return if v.is_sign_negative() { "-0".into() } else { "0".into() };
    }
    // Rust's `{:e}` is the shortest round-trip form: "1.2345e-7".
    let e = format!("{:e}", v);
    let (mant, exp) = e.split_once('e').unwrap();
    let exp: i32 = exp.parse().unwrap();
    let neg = mant.starts_with('-');
    let digits: String = mant.chars().filter(|c| c.is_ascii_digit()).collect();
    let mut out = String::new();
    if neg {
        out.push('-');
    }
    if (-4..16).contains(&exp) {
        if exp < 0 {
            out.push_str("0.");
            for _ in 0..(-exp - 1) {
                out.push('0');
            }
            out.push_str(&digits);
        } else {
            let int_len = exp as usize + 1;
            if digits.len() <= int_len {
                out.push_str(&digits);
                for _ in 0..(int_len - digits.len()) {
                    out.push('0');
                }
            } else {
                out.push_str(&digits[..int_len]);
                out.push('.');
                out.push_str(&digits[int_len..]);
            }
        }
    } else {
        out.push_str(&digits[..1]);
        if digits.len() > 1 {
            out.push('.');
            out.push_str(&digits[1..]);
        }
        out.push('e');
        out.push(if exp < 0 { '-' } else { '+' });
        out.push_str(&format!("{:02}", exp.abs()));
    }
    out
}

/// A moment in whole seconds since 1970, written ISO 8601 in UTC
/// (`2026-11-02T05:57:48Z`), as the Mac's `.iso8601` strategy does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct IsoDate(pub i64);

impl IsoDate {
    pub fn now() -> IsoDate {
        IsoDate(chrono::Utc::now().timestamp())
    }

    pub fn from_secs_f64(s: f64) -> IsoDate {
        IsoDate(s.floor() as i64)
    }

    pub fn to_iso(self) -> String {
        let days = self.0.div_euclid(86_400);
        let secs = self.0.rem_euclid(86_400);
        let (y, m, d) = civil_from_days(days);
        format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, secs / 3600, secs / 60 % 60, secs % 60)
    }

    /// Reads `YYYY-MM-DDTHH:MM:SS` with `Z` or `±HH:MM` (fractions are
    /// dropped, which the Mac never writes anyway).
    pub fn parse(s: &str) -> Option<IsoDate> {
        let b = s.as_bytes();
        if b.len() < 19 || b[4] != b'-' || b[7] != b'-' || (b[10] != b'T' && b[10] != b't') || b[13] != b':' || b[16] != b':' {
            return None;
        }
        let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
        let (y, mo, d, h, mi, se) = (num(0..4)?, num(5..7)?, num(8..10)?, num(11..13)?, num(14..16)?, num(17..19)?);
        let mut rest = &s[19..];
        if let Some(r) = rest.strip_prefix('.') {
            rest = r.trim_start_matches(|c: char| c.is_ascii_digit());
        }
        let offset = match rest {
            "Z" | "z" | "" => 0,
            r if r.len() == 6 && (r.starts_with('+') || r.starts_with('-')) => {
                let oh: i64 = r[1..3].parse().ok()?;
                let om: i64 = r[4..6].parse().ok()?;
                let o = oh * 3600 + om * 60;
                if r.starts_with('-') { -o } else { o }
            }
            _ => return None,
        };
        Some(IsoDate(days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + se - offset))
    }
}

// Howard Hinnant's civil calendar algorithms.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

impl Serialize for IsoDate {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_iso())
    }
}

impl<'de> Deserialize<'de> for IsoDate {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        IsoDate::parse(&s).ok_or_else(|| serde::de::Error::custom(format!("not an ISO 8601 date: {s}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles_print_as_swift() {
        let cases: &[(f64, &str)] = &[
            (0.0, "0"), (2.0, "2"), (-0.0, "-0"), (0.1, "0.1"), (1e-5, "1e-05"), (0.0001, "0.0001"),
            (1e16, "1e+16"), (1e15, "1000000000000000"), (123456789012345680.0, "1.2345678901234568e+17"),
            (16.0 / 9.0, "1.7777777777777777"), (94.97, "94.97"), (1e-7, "1e-07"), (3.0e20, "3e+20"),
            (-2.5, "-2.5"), (5e-324, "5e-324"), (0.000123, "0.000123"),
        ];
        for (v, want) in cases {
            assert_eq!(swift_double(*v), *want, "{v}");
        }
    }

    #[test]
    fn dates() {
        let d = IsoDate::parse("2026-11-02T05:57:48Z").unwrap();
        assert_eq!(d.to_iso(), "2026-11-02T05:57:48Z");
        assert_eq!(IsoDate::parse("2026-11-01T21:57:48-08:00"), Some(d));
        assert_eq!(IsoDate::parse("2026-11-02T05:57:48.734Z"), Some(d));
        assert_eq!(IsoDate(0).to_iso(), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn layout() {
        let v: Value = serde_json::from_str(r#"{"s":"a/b\"c\\ \n\t\u0001 é","arr":[],"empty":{},"nested":[[1],[]]}"#).unwrap();
        let want = "{\n  \"arr\" : [\n\n  ],\n  \"empty\" : {\n\n  },\n  \"nested\" : [\n    [\n      1\n    ],\n    [\n\n    ]\n  ],\n  \"s\" : \"a\\/b\\\"c\\\\ \\n\\t\\u0001 é\"\n}";
        assert_eq!(to_swift_json(&v).unwrap(), want);
    }
}
