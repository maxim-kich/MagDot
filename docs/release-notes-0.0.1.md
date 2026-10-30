# MagDot 0.0.1

Your MagSafe connector becomes a status light for T3 Code.

- **Input:** amber blinking when a thread needs your response.
- **Done:** green blinking when a thread finishes—even if another thread is working.
- **Working:** alternating green and amber.
- **Idle:** normal macOS charging light.

Choose each state's speed, preview it with play/pause, and set Done to last 1, 3, 5, 10 or 20 minutes, or Forever (the default) until you visit the completed chat with T3 foreground and the lid open. Input takes priority over Done, followed by Working. Stopping MagDot clears pending completions and restores the charging light.

Unplugging pauses tracking and hides the menu-bar icon by default; reconnecting resumes automatically if Activate was on. Manual Off stays off across reconnects. Pending completions survive disconnect and sleep. General includes Launch at login, Hide from Dock, and the unplugged icon setting.

Native menu-bar controls, a macOS-managed background helper, and signed in-app updates with manual checks are included. Update downloads and restarts require confirmation.

## Install

Requires an Apple Silicon Mac, macOS 14 or later, an official MagSafe 3 cable, and local T3 Code for automatic status tracking. Open the DMG, drag MagDot to Applications, then launch it. It activates automatically when MagSafe is connected. Approve its background helper under System Settings → General → Login Items & Extensions if requested.

No Python, Xcode, terminal commands or developer account are needed to use the app.

## Known limitations

T3 integration reads its internal local lifecycle database; compatibility can change with T3 versions. Brightness and red are not supported. MagSafe connection detection uses private IORegistry properties and needs verification on additional Mac models. Stop other utilities controlling the same LED. Forever completion notifications last only within the current tracking session.
