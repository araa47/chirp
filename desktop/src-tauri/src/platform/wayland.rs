//! Portal shortcuts observe only actions approved by the compositor, never raw input devices.
use super::{HotkeyHandle, HotkeyReport};
use crate::hotkey::{HotKey, KeyEvent};
use ashpd::desktop::{
    global_shortcuts::{GlobalShortcuts, NewShortcut},
    Session,
};
use futures_util::StreamExt;
use std::{
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::Sender,
    },
    time::Duration,
};
use tokio::sync::oneshot;

const ACTION: &str = "dictate";
static GENERATION: AtomicU64 = AtomicU64::new(0);
static ACTIVE: AtomicBool = AtomicBool::new(false);

pub fn is_active() -> bool {
    ACTIVE.load(Ordering::SeqCst)
}

fn belongs_to(expected: &str, session: &str, id: &str) -> bool {
    expected == session && id == ACTION
}

pub fn start(
    key: HotKey,
    tx: Sender<KeyEvent>,
    preferred: String,
    report: HotkeyReport,
) -> Result<HotkeyHandle, String> {
    crate::settings::validate_portal_trigger(&preferred)?;
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    ACTIVE.store(false, Ordering::SeqCst);
    let (stop, mut stopped) = oneshot::channel();
    std::thread::Builder::new().name("chirp-portal".into()).spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build();
        let Ok(runtime) = runtime else { report(Err("Could not start the desktop shortcut connection".into())); return; };
        let result = runtime.block_on(async {
            let setup = async {
                let proxy = GlobalShortcuts::new().await.map_err(|_| "Your desktop does not provide the Global Shortcuts portal. Use Record, or enable a supported portal backend.")?;
                let session = proxy.create_session(Default::default()).await.map_err(|_| "Could not create a desktop shortcut session")?;
                Ok::<_, String>((proxy, session))
            };
            let (proxy, session) = tokio::select! {
                result = tokio::time::timeout(Duration::from_secs(15), setup) => result.map_err(|_| "Desktop shortcut connection timed out")??,
                _ = &mut stopped => return Ok(()),
            };
            let result = tokio::select! {
                result = listen(&proxy, &session, key, &tx, &preferred, &report, generation) => result,
                _ = &mut stopped => Ok(()),
            };
            // Closing a session also dismisses any outstanding portal binding dialog.
            let _ = tokio::time::timeout(Duration::from_secs(2), session.close()).await;
            result
        });
        if GENERATION.load(Ordering::SeqCst) == generation {
            ACTIVE.store(false, Ordering::SeqCst);
            if let Err(error) = result { report(Err(error)); }
        }
    }).map_err(|_| "Could not start the desktop shortcut worker")?;
    Ok(HotkeyHandle::new(move || {
        let _ = stop.send(());
    }))
}

async fn listen(
    proxy: &GlobalShortcuts,
    session: &Session<GlobalShortcuts>,
    key: HotKey,
    tx: &Sender<KeyEvent>,
    preferred: &str,
    report: &HotkeyReport,
    generation: u64,
) -> Result<(), String> {
    // Session implements the public D-Bus object-path serializer; its internal path accessor
    // is private in ashpd. Retain this path to reject signals for another application/session.
    let path = serde_json::to_value(session)
        .map_err(|_| "Invalid desktop shortcut session")?
        .as_str()
        .ok_or("Invalid desktop shortcut session")?
        .to_owned();
    let activated = proxy
        .receive_activated()
        .await
        .map_err(|_| "Could not watch desktop shortcut presses")?;
    let deactivated = proxy
        .receive_deactivated()
        .await
        .map_err(|_| "Could not watch desktop shortcut releases")?;
    let changed = proxy
        .receive_shortcuts_changed()
        .await
        .map_err(|_| "Could not watch desktop shortcut changes")?;
    let closed = session
        .receive_closed()
        .await
        .map_err(|_| "Could not watch the desktop shortcut session")?;
    futures_util::pin_mut!(activated, deactivated, changed, closed);
    let shortcuts = [NewShortcut::new(ACTION, "Dictate with Chirp").preferred_trigger(preferred)];
    let response = proxy
        .bind_shortcuts(session, &shortcuts, None, Default::default())
        .await
        .map_err(|_| "Desktop shortcut was not enabled. Use Record or try again in settings.")?
        .response()
        .map_err(|_| "Desktop shortcut was not enabled. Use Record or try again in settings.")?;
    let binding = response
        .shortcuts()
        .iter()
        .find(|shortcut| shortcut.id() == ACTION)
        .ok_or("No desktop shortcut was assigned. Use Record or try again in settings.")?;
    if GENERATION.load(Ordering::SeqCst) != generation {
        return Ok(());
    }
    ACTIVE.store(true, Ordering::SeqCst);
    report(Ok(format!(
        "Portal shortcut: {}",
        binding.trigger_description()
    )));
    loop {
        // Biased: when a press and its release are both queued, deliver the press first.
        tokio::select! {
            biased;
            event = activated.next() => {
                let event = event.ok_or("Desktop shortcut connection closed")?;
                if belongs_to(&path, event.session_handle().as_str(), event.shortcut_id()) {
                    tx.send(KeyEvent { key, down: true, other_key_down: false }).map_err(|_| "Shortcut listener closed")?;
                }
            }
            event = deactivated.next() => {
                let event = event.ok_or("Desktop shortcut connection closed")?;
                if belongs_to(&path, event.session_handle().as_str(), event.shortcut_id()) {
                    tx.send(KeyEvent { key, down: false, other_key_down: false }).map_err(|_| "Shortcut listener closed")?;
                }
            }
            event = changed.next() => {
                let event = event.ok_or("Desktop shortcut connection closed")?;
                if event.session_handle().as_str() == path {
                    let binding = event.shortcuts().iter().find(|shortcut| shortcut.id() == ACTION)
                        .ok_or("Your desktop removed the shortcut. Enable it again in settings.")?;
                    report(Ok(format!("Portal shortcut: {}", binding.trigger_description())));
                }
            }
            _ = closed.next() => return Err("Desktop shortcut session closed. Enable it again in settings.".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_this_session_and_action_can_control_recording() {
        assert!(belongs_to("/session/ours", "/session/ours", "dictate"));
        assert!(!belongs_to("/session/ours", "/session/other", "dictate"));
        assert!(!belongs_to(
            "/session/ours",
            "/session/ours",
            "another-action"
        ));
    }
}
