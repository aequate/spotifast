//! Validate an existing Spotify invite for sharing, without visiting it.
//! This does not create, resolve, join or claim to verify a live Jam.
use serde::Serialize;

pub const MAX_INPUT_BYTES: usize = 4096;
pub const MAX_LINK_BYTES: usize = 1024;

#[derive(Debug, Serialize, PartialEq)]
pub struct Invite<'a> {
    pub url: &'a str,
    pub shortened: bool,
}

pub fn parse(input: &str) -> Option<Invite<'_>> {
    if input.len() > MAX_INPUT_BYTES {
        return None;
    }
    let text = input.trim();
    if text.is_empty()
        || text.len() > MAX_LINK_BYTES
        || !text.bytes().all(|b| (b'!'..=b'~').contains(&b))
        || text.contains(['\\', '#'])
    {
        return None;
    }
    let (scheme, rest) = text.split_once("://")?;
    if !scheme.eq_ignore_ascii_case("https") {
        return None;
    }
    let (host, rest) = rest.split_once('/')?;
    let (path, query) = rest.split_once('?').unwrap_or((rest, ""));
    let shortened = if host.eq_ignore_ascii_case("open.spotify.com") {
        let id = path.strip_prefix("socialsession/")?;
        if !token(id) {
            return None;
        }
        false
    } else if host.eq_ignore_ascii_case("spotify.link") {
        if !token(path) {
            return None;
        }
        true
    } else {
        return None;
    };
    if !valid_query(query) {
        return None;
    }
    Some(Invite {
        url: text,
        shortened,
    })
}

fn token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn valid_query(query: &str) -> bool {
    let mut bytes = query.bytes();
    while let Some(byte) = bytes.next() {
        if byte == b'%' {
            let Some(high) = bytes.next().and_then(|b| (b as char).to_digit(16)) else {
                return false;
            };
            let Some(low) = bytes.next().and_then(|b| (b as char).to_digit(16)) else {
                return false;
            };
            let decoded = high * 16 + low;
            if decoded < 32 || decoded == 127 {
                return false;
            }
        } else if !byte.is_ascii_alphanumeric() && !b"-._~!$&'()*+,;=:@/?".contains(&byte) {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    const DIRECT: &str =
        "https://open.spotify.com/socialsession/test-session_123?si=a%2Bb%3D&utm_source=share-link";

    #[test]
    fn keeps_the_exact_invite_and_opaque_query_bytes() {
        let input = format!(" \n{DIRECT}\t ");
        let value = parse(&input).unwrap();
        assert_eq!(value.url, DIRECT);
        assert!(!value.shortened);
        assert_eq!(parse(DIRECT).unwrap().url, DIRECT);
    }
    #[test]
    fn marks_short_links_as_unresolved_instead_of_verifying_a_jam() {
        let address = "https://spotify.link/TestInvite_123?si=A+b%3D";
        let invite = parse(address).unwrap();
        assert!(invite.shortened);
        assert_eq!(invite.url, address);
        assert!(parse("HTTPS://OPEN.SPOTIFY.COM/socialsession/test").is_some());
    }
    #[test]
    fn refuses_foreign_origins_credentials_ports_and_non_invites() {
        for address in [
            "http://open.spotify.com/socialsession/test",
            "https://evil.test/socialsession/test",
            "https://open.spotify.com.evil.test/socialsession/test",
            "https://open.spotify.com@evil.test/socialsession/test",
            "https://user@open.spotify.com/socialsession/test",
            "https://open.spotify.com:443/socialsession/test",
            "https://open.spotify.com./socialsession/test",
            "https://%6fpen.spotify.com/socialsession/test",
            "https://open.spotify.com/track/test",
            "https://open.spotify.com/playlist/test",
            "https://open.spotify.com/socialsession/",
            "https://open.spotify.com/socialsession/test/extra",
            "https://open.spotify.com/socialsession/%2e%2e",
            "https://open.spotify.com/socialsession/test#fragment",
            "https://open.spotify.com/socialsession/test?si=%0aheader",
            "https://open.spotify.com/socialsession/test?si=%00",
            "https://open.spotify.com/socialsession/test?si=%xx",
            "https://open.spotify.com/socialsession/test?si=%2",
            "https://open.spotify.com/socialsession/test?si=white space",
            "https://spotify.link/",
            "https://spotify.link/one/two",
            "spotify:socialsession:test",
        ] {
            assert!(
                parse(address).is_none(),
                "Accepted an unexpected input shape"
            );
        }
    }
    #[test]
    fn bounded_queries_keep_their_byte_identity_through_serialization() {
        // Exhaust the printable ASCII byte domain through percent encoding.
        // No short-link resolver, account or session is involved.
        for byte in 32_u8..=126 {
            let text = format!(
                "https://open.spotify.com/socialsession/test?opaque=%{byte:02X}&si=+%2B%3D"
            );
            let invite = parse(&text).unwrap();
            let value: serde_json::Value =
                serde_json::from_str(&serde_json::to_string(&invite).unwrap()).unwrap();
            assert_eq!(value["url"], text);
            assert_eq!(parse(value["url"].as_str().unwrap()).unwrap(), invite);
        }
    }
    #[test]
    fn appended_host_bytes_never_turn_a_spoofed_host_into_an_invite() {
        for byte in 0_u8..=255 {
            let text = format!(
                "https://open.spotify.com{}evil/socialsession/test",
                char::from(byte)
            );
            assert!(parse(&text).is_none());
        }
    }
    #[test]
    fn enforces_the_qr_payload_bound_without_truncating_invite_tokens() {
        let prefix = "https://open.spotify.com/socialsession/test?si=";
        let at_limit = format!("{prefix}{}", "x".repeat(MAX_LINK_BYTES - prefix.len()));
        assert_eq!(parse(&at_limit).unwrap().url.len(), MAX_LINK_BYTES);
        assert!(parse(&(at_limit + "x")).is_none());
        assert!(parse(&" ".repeat(MAX_INPUT_BYTES + 1)).is_none());
        assert!(parse(&format!("https://spotify.link/{}", "x".repeat(129))).is_none());
    }
}
