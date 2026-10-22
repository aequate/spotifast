//! C ABI: all owned strings are released by sf_string_free. JSON inputs are
//! borrowed only for the call. The host serializes commands and destruction.
use crate::engine::{Callback, Command, Engine, Notify};
use std::{
    ffi::{CStr, CString, c_char, c_void},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
};

fn owned(value: impl Into<Vec<u8>>) -> *mut c_char {
    CString::new(value).map_or(ptr::null_mut(), CString::into_raw)
}

#[unsafe(no_mangle)]
pub extern "C" fn sf_platform_info() -> *mut c_char {
    catch_unwind(|| {
        owned(
            serde_json::json!({
                "os": std::env::consts::OS,
                "arch": std::env::consts::ARCH,
                "osVersion": librespot_core::config::os_version()
            })
            .to_string(),
        )
    })
    .unwrap_or(ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_parse_link(value: *const c_char) -> *mut c_char {
    if value.is_null() {
        return ptr::null_mut();
    }
    catch_unwind(|| {
        let bytes = unsafe { CStr::from_ptr(value) }.to_bytes();
        if bytes.len() > 8192 {
            return ptr::null_mut();
        }
        std::str::from_utf8(bytes)
            .ok()
            .and_then(crate::link::parse)
            .map_or(ptr::null_mut(), owned)
    })
    .unwrap_or(ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_parse_jam_invite(value: *const c_char, length: usize) -> *mut c_char {
    if value.is_null() || length > crate::jam::MAX_INPUT_BYTES {
        return ptr::null_mut();
    }
    catch_unwind(|| {
        // SAFETY: host supplies length valid bytes; an explicit length also
        // prevents an embedded NUL from silently changing the shared invite.
        let bytes = unsafe { std::slice::from_raw_parts(value.cast::<u8>(), length) };
        std::str::from_utf8(bytes)
            .ok()
            .and_then(crate::jam::parse)
            .and_then(|invite| serde_json::to_string(&invite).ok())
            .map_or(ptr::null_mut(), owned)
    })
    .unwrap_or(ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "C" fn sf_eq_presets() -> *mut c_char {
    let presets: Vec<_> = crate::eq::PRESETS
        .iter()
        .map(|preset| serde_json::json!({ "name": preset.name, "bands": preset.bands_db }))
        .collect();
    owned(serde_json::json!({ "frequencies": crate::eq::BANDS, "presets": presets }).to_string())
}

#[unsafe(no_mangle)]
pub extern "C" fn sf_create(callback: Option<Callback>, context: *mut c_void) -> *mut Engine {
    catch_unwind(|| {
        Engine::new(Notify(callback, context as usize))
            .map_or(ptr::null_mut(), |engine| Box::into_raw(Box::new(engine)))
    })
    .unwrap_or(ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_command(engine: *mut Engine, json: *const c_char) -> bool {
    if engine.is_null() || json.is_null() {
        return false;
    }
    // SAFETY: pointers are supplied by the host under the header contract.
    let engine = unsafe { &*engine };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { CStr::from_ptr(json) }.to_bytes();
        if bytes.len() > 1_048_576 {
            return Err("Command too large".to_owned());
        }
        let command: Command =
            serde_json::from_slice(bytes).map_err(|_| "Invalid playback command".to_owned())?;
        engine.command(command)
    }));
    match result {
        Ok(Ok(())) => true,
        Ok(Err(message)) => {
            engine.fail(&message);
            false
        }
        Err(_) => {
            engine.fail("Playback encountered an internal error. Reconnect in Settings.");
            false
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_snapshot(engine: *const Engine) -> *mut c_char {
    if engine.is_null() {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let engine = unsafe { &*engine };
        let mut state = serde_json::to_value(engine.snapshot()).unwrap_or_default();
        state["audioRunning"] = engine
            .pcm
            .running
            .load(std::sync::atomic::Ordering::Acquire)
            .into();
        state["underruns"] = engine
            .pcm
            .underruns
            .load(std::sync::atomic::Ordering::Relaxed)
            .into();
        owned(state.to_string())
    }))
    .unwrap_or(ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_credentials(engine: *const Engine) -> *mut c_char {
    if engine.is_null() {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let credentials = unsafe { &*engine }.credentials();
        credentials
            .and_then(|c| serde_json::to_string(&c).ok())
            .map_or(ptr::null_mut(), owned)
    }))
    .unwrap_or(ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_render(
    engine: *const Engine,
    left: *mut f32,
    right: *mut f32,
    frames: usize,
) {
    if engine.is_null() || left.is_null() || right.is_null() || frames > 65_536 {
        return;
    }
    // SAFETY: the host provides two disjoint buffers of at least frames floats.
    unsafe { &*engine }.pcm.render(
        unsafe { std::slice::from_raw_parts_mut(left, frames) },
        unsafe { std::slice::from_raw_parts_mut(right, frames) },
    );
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_destroy(engine: *mut Engine) {
    if engine.is_null() {
        return;
    }
    // Stop/detach native audio and release every other pointer before this call.
    let mut engine = unsafe { Box::from_raw(engine) };
    engine.disconnect();
    if let Some(runtime) = engine.runtime.take() {
        runtime.shutdown_timeout(std::time::Duration::from_secs(5));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn platform_reporting_uses_the_real_host_instead_of_a_testing_backend() {
        let pointer = sf_platform_info();
        assert!(!pointer.is_null());
        let value: serde_json::Value =
            serde_json::from_slice(unsafe { CStr::from_ptr(pointer) }.to_bytes()).unwrap();
        unsafe {
            sf_string_free(pointer);
        }
        assert_eq!(value["os"], std::env::consts::OS);
        assert_eq!(value["arch"], std::env::consts::ARCH);
        assert!(
            value["osVersion"]
                .as_str()
                .is_some_and(|version| !version.is_empty() && version != "0")
        );
    }
    #[test]
    fn invite_boundary_preserves_urls_and_rejects_embedded_nul_and_invalid_utf8() {
        let address = b"https://spotify.link/TestInvite?si=a%2Bb%3D";
        let output = unsafe { sf_parse_jam_invite(address.as_ptr().cast(), address.len()) };
        assert!(!output.is_null());
        let value: serde_json::Value =
            serde_json::from_slice(unsafe { CStr::from_ptr(output) }.to_bytes()).unwrap();
        assert_eq!(value["url"], std::str::from_utf8(address).unwrap());
        assert_eq!(value["shortened"], true);
        unsafe { sf_string_free(output) };
        for bad in [
            b"https://spotify.link/Test\0discarded".as_slice(),
            b"\xff\xfe".as_slice(),
        ] {
            assert!(unsafe { sf_parse_jam_invite(bad.as_ptr().cast(), bad.len()) }.is_null());
        }
        assert!(unsafe { sf_parse_jam_invite(ptr::null(), usize::MAX) }.is_null());
    }
    #[test]
    fn c_boundary_rejects_malformed_commands_without_echoing_secrets() {
        let engine = sf_create(None, ptr::null_mut());
        assert!(!engine.is_null());
        for input in [
            "not-json SECRET",
            "{\"op\":\"volume\",\"value\":70000}",
            "{\"op\":\"load\",\"uris\":[]}",
        ] {
            let input = CString::new(input).unwrap();
            assert!(!unsafe { sf_command(engine, input.as_ptr()) });
            let snapshot = unsafe { sf_snapshot(engine) };
            let text = unsafe { CStr::from_ptr(snapshot) }.to_str().unwrap();
            assert!(!text.contains("SECRET"));
            unsafe { sf_string_free(snapshot) };
        }
        unsafe { sf_destroy(engine) };
    }
    #[test]
    fn render_returns_silence_without_a_session() {
        let engine = sf_create(None, ptr::null_mut());
        let (mut l, mut r) = ([1.0; 512], [1.0; 512]);
        unsafe { sf_render(engine, l.as_mut_ptr(), r.as_mut_ptr(), 512) };
        assert!(l.into_iter().chain(r).all(|v| v == 0.0));
        unsafe { sf_destroy(engine) };
    }
}
