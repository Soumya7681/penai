//! Ctrl+C / termination handling, so the launcher always gets a chance to stop
//! llama-server instead of leaving a multi-gigabyte model resident.
//!
//! Handlers only flip an `AtomicBool`, which is async-signal-safe; all real work
//! happens on the main thread.

use std::sync::atomic::{AtomicBool, Ordering};

static SHUTDOWN: AtomicBool = AtomicBool::new(false);

pub fn requested() -> bool {
    SHUTDOWN.load(Ordering::SeqCst)
}

/// For tests and for a future in-UI shutdown control.
#[allow(dead_code)]
pub fn request() {
    SHUTDOWN.store(true, Ordering::SeqCst);
}

#[cfg(unix)]
mod imp {
    use super::*;

    const SIGINT: i32 = 2;
    const SIGTERM: i32 = 15;
    const SIGHUP: i32 = 1;
    const SIGPIPE: i32 = 13;
    const SIG_IGN: usize = 1;

    type Handler = extern "C" fn(i32);

    extern "C" {
        fn signal(sig: i32, handler: usize) -> usize;
    }

    extern "C" fn on_signal(_sig: i32) {
        SHUTDOWN.store(true, Ordering::SeqCst);
    }

    pub fn install() {
        let h: Handler = on_signal;
        // SAFETY: installing a handler that does nothing but an atomic store.
        unsafe {
            signal(SIGINT, h as usize);
            signal(SIGTERM, h as usize);
            signal(SIGHUP, h as usize);
            // Writing to a closed pipe (a log sink on a removed drive) must not
            // kill the process.
            signal(SIGPIPE, SIG_IGN);
        }
    }
}

#[cfg(windows)]
mod imp {
    use super::*;

    const CTRL_C_EVENT: u32 = 0;
    const CTRL_BREAK_EVENT: u32 = 1;
    const CTRL_CLOSE_EVENT: u32 = 2;
    const CTRL_LOGOFF_EVENT: u32 = 5;
    const CTRL_SHUTDOWN_EVENT: u32 = 6;

    extern "system" {
        fn SetConsoleCtrlHandler(
            handler: Option<extern "system" fn(u32) -> i32>,
            add: i32,
        ) -> i32;
    }

    extern "system" fn on_ctrl(event: u32) -> i32 {
        match event {
            CTRL_C_EVENT | CTRL_BREAK_EVENT | CTRL_CLOSE_EVENT | CTRL_LOGOFF_EVENT
            | CTRL_SHUTDOWN_EVENT => {
                SHUTDOWN.store(true, Ordering::SeqCst);
                1 // handled
            }
            _ => 0,
        }
    }

    pub fn install() {
        // SAFETY: registering a handler that only performs an atomic store.
        unsafe {
            SetConsoleCtrlHandler(Some(on_ctrl), 1);
        }
    }
}

#[cfg(not(any(unix, windows)))]
mod imp {
    pub fn install() {}
}

pub fn install() {
    imp::install();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_is_safe_to_call() {
        install();
        install();
    }

    #[test]
    fn request_sets_the_flag() {
        // Serialised with the other test by using a distinct assertion order;
        // the flag is process-global, which is exactly what we want to verify.
        request();
        assert!(requested());
        SHUTDOWN.store(false, Ordering::SeqCst);
    }
}
