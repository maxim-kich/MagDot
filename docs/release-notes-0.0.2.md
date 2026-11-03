# MagDot 0.0.2

Less CPU use, clearer activation feedback, and improved Settings behavior.

- **More efficient tracking:** reduced database polling work and unnecessary Settings refreshes, with safeguards against displaying stale activity.
- **More reliable Done notifications:** completed threads stay pending until they are read, snoozed, settled, or the selected duration expires. Clearing one thread leaves other pending completions visible.
- **Clearer activation:** Activate stays on while the helper starts or waits for approval. Startup failures show an explanation, and pending startup can be cancelled.
- **Simpler setup:** onboarding stays separate from Settings. Allow registers a missing helper or opens System Settings for pending approval, rather than doing both at once.
- **Centered speed controls:** 1.00× sits at the middle of every state slider. Existing saved timings are preserved.
- **Improved Dock toggling:** changing Hide from Dock keeps Settings as a normal window, replacing the previous hide-and-reopen workaround.

Requires an Apple Silicon Mac, macOS 14 or later, an official MagSafe 3 cable, and local T3 Code for automatic status tracking.
