# Development and implementation

[Back to MagDot](../README.md). This guide covers building, testing, helper permissions, T3 integration, and hardware behavior.

## Installation and privilege model

The app bundles a native controller and SQLite reader. Python and a source checkout are not runtime dependencies.

Distribution releases should be Developer ID signed and Apple notarized. MagDot uses `SMAppService` to register the bundled helper and may require one-time approval in **System Settings → General → Login Items & Extensions**. Once approved, Start/Stop/Quit use local IPC without `osascript` or repeated administrator prompts.

The root helper is socket-activated: macOS starts it when MagDot connects, and it exits after the LED session is restored. It has no KeepAlive job and does not stay running after Quit. It accepts only the MagDot app identifier signed by the same Apple signing team as the helper; the peer is identified using its kernel audit token. No sudoers rules, SIP changes, charging limits, or network services are used.

Quit the app before upgrading, unregistering, or disabling its helper in System Settings. A changed helper may require unregistering and registering again, as required by Service Management. To remove the registered helper before deleting the app:

```sh
/Applications/MagDot.app/Contents/MacOS/MagDot --unregister-helper
```

## Build locally

Requires Xcode with the macOS 26 SDK or later. The app still targets macOS 14 or later. Run the commands below from the repository root. `SIGN_IDENTITY` is a signing identity name from your own Keychain, not a secret.

```sh
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/build-app.sh
open build/MagDot.app
```

Without `SIGN_IDENTITY`, the script uses ad-hoc signing for compilation checks only; this does not enable the privileged service. Build output targets Apple Silicon/macOS 14+. The transparent PNG artwork is packaged into the app icon. Do not move a registered app bundle while its helper is installed.

The independent controller remains available for explicitly authorized hardware tests:

```sh
make
build/magdot read
sudo build/magdot demo 20
sudo build/magdot working 20
sudo build/magdot finished 20
sudo build/magdot attention 20
sudo build/magdot idle
```

Do not run manual LED commands while the app has an active session. All controllers share an exclusive lock.

## T3 integration

The app opens `~/.t3/userdata/statev2.sqlite` read-only and reads only lifecycle metadata from the v2 projections: run IDs, status/timestamps, thread archive/delete state, `lastVisitedAt`, `snoozedUntil`, `settledOverride`, and request kind/status. It does not query message or request bodies, tokens, or credentials.

Only user-facing threads contribute status. Threads whose `lineage.relationshipToParent` is `subagent` are excluded from Working, Done, and Input; ordinary forks and threads without lineage metadata remain eligible.

This is an internal-schema adapter, not a supported T3 public API. Working follows T3 parent runs in `preparing`, `starting`, `running`, or `waiting`, without an elapsed-time cutoff. Newer queued or cancelled requests do not mask an older active run. Provider-turn records are not used for liveness: they can outlive terminated runs or complete before the full parent run. Done follows an observed parent run reaching `completed`, and is suppressed while another run in that same thread is active. A queued request cancelled or failed before starting does not dismiss an earlier unread Done.

Old completions are suppressed on startup. Cancellation, failure, interruption, or rollback clears that run; other threads may still determine the LED state. Schema/read errors temporarily return control to macOS without discarding pending completions. Done is cleared when the completed thread is marked read (`lastVisitedAt` at or after completion), snoozed, settled, archived, or deleted. App focus and lid state do not acknowledge a thread. The `user_input` kind was observed in the live database; approval/permission filters are provisional until observed against a real pending approval.

## Restoration and limits

Only SMC key **ACLC** is read/written, using values 0, 1, 3, and 4. Restoration seeds the full/not-full battery color, waits 300 ms, then releases to system mode. Firmware may subsequently report green/amber rather than literal zero.

Each session has a separate watchdog. App disconnect, a four-second heartbeat expiry, explicit Stop/Quit, and controller termination end the session and attempt restoration. Signals are unblocked explicitly. AppKit deferred Quit uses an off-run-loop socket handshake. Sleep stops the active session; tracking resumes on wake with pending completions retained.

Stop other LED-control utilities first. Unexpected readback stops the controller; identical competing writes cannot be identified. Restoration may supersede a competing controller. SMC failures stop writes; MagSafe reconnection starts a new session. No software can guarantee restoration after killing both controller and watchdog, a kernel failure, or power loss.

## Verification

```sh
build/MagDot.app/Contents/MacOS/MagDot --self-test
build/MagDot.app/Contents/MacOS/MagDot --probe-t3
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/test-service.sh
```

The service test builds a **compile-time fake SMC** and uses an isolated temporary socket, with real code-signature checks. Production binaries have no fake-hardware or alternate-socket environment switch. It covers unsigned-client rejection, repeated Start/Stop, active Quit, and app crash recovery without authentication or LED writes.

`tests/hardware.py` is an opt-in administrator test that really writes the LED via the controller. Do not run it during an active app session.

Protocol sources: [MagHue](https://github.com/kamenlevi/MagHue/blob/main/Sources/MagHueCore/SMC.swift) and [JuiceLeft](https://github.com/Weta-Technologies/JuiceLeft/blob/main/juiceleft-led.c). MagDot's own code uses MIT; these references retain their original terms. See the [provenance audit](RELICENSING.md).

## Sequence settings

Open **Settings…** in the menu bar. The sidebar contains General, States, and About. States shows Working, Done, and Input together, each with its default sequence and adjustable speed. Working alternates green/amber, Done blinks green/off, and Input blinks amber/off. The hardware does not provide a verified red mode.

Lit phases range from 1.6 to 0.4 seconds. Working and Input show 1× at 1 second; Done shows 1× at approximately 0.67 seconds. Blinking presets include an off pause 1.5 times the lit phase. Changes save automatically in local preferences and are applied on subsequent helper heartbeats; Restore Default affects only its own state. Idle and missing T3 data always use system behavior; Stop/Quit always restore system control.


The play/pause control previews one state on the connector until paused, Settings is closed, or MagDot is stopped. Starting another preview replaces the current one. Pausing resumes T3 tracking, or restores system control if MagDot was stopped before the preview.

Done duration: 1, 3, 5, 10, or 20 minutes, or Forever (default). Unread, unsnoozed, unsettled completions keep blinking whether T3 is in the foreground or background. Reading, snoozing, or settling a thread clears only its own Done notification; visiting another thread does not. A thread snoozed until a future deadline or marked settled cannot trigger Done. Cleared completions do not replay when the snooze expires or the thread is unsettled. Starting a new turn in that chat clears its previous completion. The timer starts at completion, including while another thread has priority. Pending completions survive sleep and tracking resumes on wake; finite timers continue to count elapsed time during sleep. Forever lasts within the current tracking session; restarting MagDot clears pending completions. Done’s default 1× is approximately 0.67 seconds green and 1 second off. Input takes priority over Done, then Working, then system control.

About includes signed in-app updates with separate download and restart confirmation. Switch MagDot off before installing an update. Updates require a published GitHub release containing the signed appcast and ZIP.

General includes Launch at login (on by default) and Hide from Dock (on by default). Helper approval is followed automatically by connection; no second activation is needed.

Icon builds retain the original PNG artwork and all ICNS resolutions. Larger representations use macOS JPEG 2000 compression (quality 45) to reduce bundle size; small representations stay unchanged. This is lossy encoding, with no additional build dependency.

### MagSafe connection watcher

MagDot reads the MagSafe port's `ConnectionActive` IORegistry property (`PortType = 17`), independently of battery charging or USB-C power. While disconnected it stops T3 polling and releases the LED session; a lightweight, read-only watcher remains in the app and checks once per second. Reconnection automatically starts a fresh helper session and retains pending tracked completions. Manual Stop remains off across reconnects until manual Start or app relaunch. Quit exits the watcher too; open MagDot again (or enable Launch at login) to restore automatic detection.

General → **Hide menu bar icon when unplugged** defaults to on. Open MagDot from Applications/Spotlight to access Settings while its icon is hidden. Turning this setting off keeps the icon visible without activating LED control. An unknown/unsupported connection state stops LED control but keeps the icon accessible. These private IORegistry properties are verified on the development Mac; other Mac models need hardware validation.

See [Licenses & Acknowledgements](../ACKNOWLEDGEMENTS.md) for third-party components.
