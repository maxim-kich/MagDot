<p align="center"><img src="assets/app-icon-transparent.png" width="128" alt="MagDot icon"></p>

# MagDot

Your MagSafe connector becomes a status light for **T3 Code agents**.

MagDot is a native macOS menu-bar app for Apple Silicon Macs running macOS 14 or later. It requires an official MagSafe 3 cable and local T3 Code.

## Install

1. Download the DMG from [Releases](https://github.com/maxim-kich/MagDot/releases).
2. Drag MagDot to Applications and open it.
3. Connect MagSafe and approve the background helper in **System Settings → General → Login Items & Extensions** if requested.

No Python, Xcode, or terminal commands are needed to use the app.

## What the light means

| State | LED |
|---|---|
| Working | Alternating green and amber |
| Done | Blinking green |
| Input needed | Blinking amber |
| Idle | Normal macOS charging light |

Input takes priority over Done, followed by Working. Done lasts until you read, snooze, or settle the completed thread, or its selected timer expires. Clearing one thread leaves other pending completions visible.

## Controls and Settings

MagDot activates automatically when opened with MagSafe connected. **Activate** in the menu or General settings turns tracking on or off. While starting or awaiting helper approval, the switch stays on and shows the current status. Switching off or quitting returns LED control to macOS.

Open **Settings…** from the menu bar:

- **General:** Launch at login, Hide from Dock, and Hide menu bar icon when unplugged.
- **States:** adjust speed, preview each sequence, and choose Done’s duration. The default 1× speed is centered on every slider; changes save automatically.
- **About:** check for updates.

Unplugging pauses tracking. Reconnecting resumes it if Activate was on; a manual Off stays off. If the menu-bar icon is hidden, open MagDot from Applications or Spotlight to access Settings.

## Limitations

MagDot currently supports only T3 Code agents. Compatibility depends on T3’s internal database, and MagSafe behavior needs verification on additional Mac models. Brightness dimming and red are not supported. Quit other utilities controlling the same LED. Restarting MagDot clears pending Done notifications.

[Development and testing](docs/DEVELOPMENT.md) · [Contributing](CONTRIBUTING.md) · [MIT license](LICENSE) · [Acknowledgements](ACKNOWLEDGEMENTS.md)
