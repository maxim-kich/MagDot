# MagDot

MagSafe 3 as a T3 Code activity light. Experimental macOS Apple Silicon utility, GPL-3.0-only.

- **Working:** green / amber, 750 ms per phase.
- **Finished:** green / off, 750 ms per phase; T3 completion lasts 15 seconds.
- **Idle:** return LED control to macOS.

## Build and run

Requires macOS developer command-line tools and Python 3 (provided with Xcode tools).

```sh
make
build/magdot read
sudo build/magdot demo 20
sudo build/magdot working 20
sudo build/magdot finished 20
sudo build/magdot idle
osacompile -o MagDot.app scripts/start.applescript
open MagDot.app
```

Keep the app in this checkout. It is a small native AppleScript launcher, not yet a menu-bar app or distributable signed package. Launching starts the unprivileged T3 watcher and requests normal macOS administrator authentication for the LED controller. No sudoers changes, SIP changes, launch daemon, or charging settings are installed. The controller has a hard one-hour lifetime; reopen the app to start another session.

## T3 integration

`scripts/t3-watch.py` opens `~/.t3/userdata/statev2.sqlite` **read-only** and queries `orchestration_v2_projection_provider_turns`. No prompts, messages, tokens, or credentials are read. Any running turn under one hour takes priority across local T3 threads. An observed running → completed transition blinks green for 15 seconds. Cancellation/failure returns idle. Old completions at startup do not trigger a blink.

This is an experimental adapter to T3's internal schema, not a supported public lifecycle API. Schema errors return idle. A hung turn expires after one hour; suspended turns may remain working until that limit. A four-second state lease restores idle if the watcher stops. State is local under `~/.magdot`, outside the repository.

## Safety and limitations

The native controller's only SMC key is ACLC. Each invocation locks `/var/run/magdot.lock`. A separate watchdog restores control on EOF or three seconds without heartbeat, including controller SIGKILL. SIGINT/TERM/HUP exit through the watchdog. Killing both processes, kernel failure, or power loss cannot guarantee cleanup; use `sudo build/magdot idle` after recovery.

Restoration seeds the battery's expected full/not-full color, waits 300 ms, then writes system mode. Firmware may report amber/green after system mode rather than literal zero. Immediate readback can lag a write; it is not visual proof.

Stop other LED-controlling charge apps first. Readback changes between phases stop the controller, but identical writes from another app cannot be detected. Restoration may supersede another controller. Disconnect may not cause SMC errors: patterns can resume on reconnect within the bounded session. SMC errors stop writes and attempt restoration; relaunch after reconnect if necessary. No aggressive retry loop.

To stop: terminate the `magdot watch` process and `t3-watch.py` process using Activity Monitor. Closing the launcher alone does not stop these background processes.

## Provenance and verification

Protocol reference: [MagHue SMC.swift](https://github.com/kamenlevi/MagHue/blob/main/Sources/MagHueCore/SMC.swift), licensed GPL-3.0; [JuiceLeft LED controller](https://github.com/Weta-Technologies/JuiceLeft/blob/main/juiceleft-led.c) documents the restoration latch caveat. MagDot uses GPL-3.0-only and restricts the protocol to ACLC values 0, 1, 3, 4.

On the development Mac, compilation with `-Wall -Wextra -Werror` passed, ACLC reads and privileged writes succeeded, and the user visually confirmed the bounded demo's green/amber then green/off patterns. Restoration returned to firmware amber. Crash recovery, competing apps, and physical disconnect/reconnect still need dedicated hardware tests. No machine logs are committed.
