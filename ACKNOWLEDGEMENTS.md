# Licenses & Acknowledgements

MagDot uses the following open-source components, macOS technologies, and research references.

## MagDot

MagDot's source code is licensed under [GNU GPL v3 only](LICENSE). The matching source archive accompanies each published release.

## Sparkle — in-app updates

MagDot bundles [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/tree/2.10.1) and its helper tools for checking, downloading, verifying, and installing updates. The bundled binaries target Apple Silicon.

Sparkle and its included components retain their own copyright and license notices. Read the [complete Sparkle license and third-party notices](docs/licenses/Sparkle-LICENSE.txt). A copy is also included in the app at `Contents/Resources/Legal/Sparkle-LICENSE.txt`.

## macOS technologies

MagDot uses Swift and system-provided frameworks including AppKit, Foundation, IOKit, ServiceManagement, and Security. It reads T3 Code's local database through the system SQLite library. These system components are not bundled as separate copies in MagDot.

System fonts and SF Symbols are provided by macOS. Their rights and terms remain with their respective owners.

## MagSafe LED research

The following projects informed research into the MagSafe LED's AppleSMC interface and restoration behavior:

- [MagHue](https://github.com/kamenlevi/MagHue) — Apple Silicon MagSafe LED control and the ACLC key.
- [JuiceLeft](https://github.com/Weta-Technologies/JuiceLeft) — LED read/write and restoration behavior.

These are research acknowledgements, not bundled applications. Their source code and licenses remain available in their repositories.

## T3 Code integration

MagDot reads local T3 Code activity to display agent states. T3 Code is a separate application and is not bundled with MagDot.

## Artwork

The app icon was created with OpenAI image generation and prepared for macOS distribution. The menu-bar connector icon is drawn by MagDot's own code. The project does not bundle Apple's logo or an SF Symbols font.

## Build tools

The build process uses Apple's developer tools and Python. The DMG layout is generated with [dmgbuild](https://github.com/dmgbuild/dmgbuild). These build tools are not included in the installed app.

Product names and trademarks belong to their respective owners. These acknowledgements do not imply endorsement or affiliation.
