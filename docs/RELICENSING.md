# Local MIT relicensing audit — 2026-11-05

## Conclusion and scope

No incompatible third-party implementation was identified in the current tracked source. Apply MIT to MagDot's own code, with the owner's explicit authorization covering MagDot, iPhonify, and Drag 2.0. This is a source/provenance assessment, not proof of every historical development input or a legal opinion.

Baseline: `9e2791e732165a747e5f2b20c2b7144bac6cb99e`; working tree was clean before this change. No project or ancestor AGENTS.md file was found; the instructions supplied in the task apply. No other project was edited.

## Authorship and first-party reuse

`git shortlog -sne HEAD` reports all 12 reachable commits as Maxim Kich, under two email addresses (8 and 4 commits). Commit-body coauthor trailers also name Maxim Kich; committers are Maxim Kich or GitHub. Initial helper implementation is `48d73694407d203a04704b5023ae7924db680a7c`. Authorship metadata supports the ownership authorization but does not by itself establish provenance.

`app/UpdateChecker.swift` and `app/InAppUpdater.swift` explicitly identify reuse from the author's DragTwoZero updater. That reuse is covered by the owner's authorization. No separate third-party attribution was found there. Other branch and orchestration checkpoint refs are not part of the audited HEAD source; no history was rewritten.

## AppleSMC provenance comparison

Compared both the initial and current `src/magdot.c` with these upstream references, retrieved on the audit date:

- [MagHue SMC.swift](https://github.com/kamenlevi/MagHue/blob/99f4b698e0b9c20c98408e9ddd0c25385ebff313/Sources/MagHueCore/SMC.swift), whose repository [license](https://github.com/kamenlevi/MagHue/blob/99f4b698e0b9c20c98408e9ddd0c25385ebff313/LICENSE) is GPL v3.
- [JuiceLeft juiceleft-led.c](https://github.com/Weta-Technologies/JuiceLeft/blob/f13296cc38a5aa449885da6e281c2778a495db82/juiceleft-led.c), with a [restrictive repository license](https://github.com/Weta-Technologies/JuiceLeft/blob/f13296cc38a5aa449885da6e281c2778a495db82/LICENSE).

The shared details are the 80-byte kernel packet layout, AppleSMC IOKit calls, selector 2, commands 5/6/9, ACLC key and color values, and seeding the charge color before releasing control after 300 ms. These are interface constraints and observed hardware behavior. MagDot uses its own compact packet declarations, combined read/write function with size validation, error handling, battery-state restoration, ownership checks, watchdog, and streaming state protocol. MagHue uses a Swift API with different abstractions; JuiceLeft has separate read/write functions and a numeric command-line utility. No copied expressive implementation beyond interface details was identified. Neither project's application or source is bundled. Research acknowledgements remain; neither upstream license is converted to MIT.

This conclusion is an inference from source comparison, not a clean-room certification. If copied expressive code or an additional upstream source is later established, obtain compatible permission or replace the affected implementation before distributing it under MIT. Renaming code or changing a header would not remedy that problem.

## Dependencies and assets

- Sparkle 2.10.1 is the bundled non-system framework. Its complete MIT/BSD-style and Ed25519 notices remain unchanged in `docs/licenses/Sparkle-LICENSE.txt`; this file matches the fetched framework's `LICENSE` byte for byte. The build continues copying Sparkle's own notices separately. [Upstream notices](https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE).
- macOS frameworks and system SQLite are linked system components; T3 Code is read through its local database, not bundled. No package manifest, vendored third-party implementation, or git submodule was found in tracked files.
- Python, Apple's build tools, and dmgbuild are build tools, not shipped app dependencies. Artwork provenance is recorded in ACKNOWLEDGEMENTS.md as generated icon art and project-drawn menu icon; no independent asset rights verification was possible from git alone. Apple fonts, symbols, and trademarks retain their own terms.

## Result and validation

The root license, five existing SPDX headers, README, contribution terms, development guide, acknowledgements, and About credit now identify MIT. Both normal and UI-preview builds copy the current project license and acknowledgements into the bundle. About opens the local Legal folder containing MagDot's MIT text and the separate Sparkle notices.

Previously published 0.0.1/0.0.2 artifacts and their GPL notices remain unchanged, as do release notes, version/build numbers, and git history. This local change does not claim that old downloads have been replaced or retroactively relabeled. Third-party notices remain mandatory for future distributions. No push, PR, publication, release, or installed-app replacement is part of this work.

Validation performed: `sh -n` passed for both changed build scripts; a separate ad-hoc-signed build at `.local/mit-audit/MagDot.app` compiled, passed strict signature verification, and passed its built-in lifecycle/state self-tests. All four bundled legal files matched their source bytes. Sparkle notices, release notes, VERSION, and BUILD_NUMBER matched HEAD. `git diff --check` passed. The UI-preview script was syntax-checked but not executed; About's visual layout and Finder interaction were not manually exercised. The installed app was not launched or replaced.
