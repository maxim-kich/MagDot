# Tap Lab 0.7 — MagSafe connector single taps

Collect individual tap signatures, as in the original positive/negative lab.
MagDot uses the learned connector signature to recognize a **double-tap** when
an agent is done or needs input. Data collection itself needs only single taps.

Build: `bash tools/tap-lab/build.sh`. Open `build/Tap Lab.app` in this folder.
The sensor starts automatically. Hold still for the initial one-second baseline.
No size or surface selection, timed trials, or exactly-two-impact requirement.

1. In **Collect**, click **Collect POSITIVE taps** and tap the attached MagSafe
   plug once at a time. Leave roughly half a second between taps.
2. Click **Collect NEGATIVE taps** and tap the laptop, nearby surfaces, type, or
   handle the cable. These are the gestures the connector detector should reject.
3. Every captured impact saves immediately. Counts show each label and exactly
   how many more taps are needed: at least 12 positive and 12 negative examples.
4. Switch to **Test**, then select positive or negative for the taps you will
   make. Each result shows expected/detected/unknown. Test examples are stored
   separately and never train the model. They test the model existing at that time.
5. Click **Use this model in MagDot** to publish the current connector model
   locally. MagDot reloads it without a restart. Capture more examples and use
   **Update model in MagDot** when ready to replace it.

Collection pauses when Tap Lab loses focus, preventing unrelated keyboard input
from being silently labelled positive. The first 350 ms after selecting a label
are ignored to avoid recording the button click. Late ringing within 350 ms of
an accepted onset is suppressed. This does not require pairing your training taps.
If very light taps are missed, adjust Capture sensitivity toward the right or
recalibrate the quiet baseline. No microphone or typed text is recorded.

## Existing data

On opening, recover timing/shape-consistent pairs from completed, explicitly
labelled connector Train trials in `gesture-connector-v1/`. Store each constituent
impact once using deterministic IDs. Ambiguous isolated impacts and partial/Test
trials are excluded. All old files remain unchanged.

The previous frozen v3 Desk/Lap datasets were captured on the laptop chassis
before the connector study. Their original left/right examples are imported as
**negative** examples for this new connector target. Motion features/windows are
reused; audio features are omitted. Current hardware model must match. The app
bundled chassis model is not edited by this process.

New records live under `~/Library/Application Support/Tap Lab/connector-singles-v1/`.
They contain the explicit label, Train/Test split, source, hardware ID, timestamp,
impact motion features/window, capture threshold when available, and Test prediction.
Recovery is idempotent. No automatic deletion or relabelling of source recordings.

## MagDot handoff

An explicit publish writes a feature-only, two-class connector model under
`~/Library/Application Support/MagDot/Models/magsafe-connector-<hardware>.json`.
Only Train examples fit the model. MagDot validates schema, target, hardware,
feature dimensions/finite values, and both classes before loading it. Its bundled
model remains the fallback until a valid connector model is published. Sensitivity
remains the user's setting. The production app never navigates while Tap Lab is
frontmost. It still requires a double-tap and current agent attention.

Minimum class counts establish model availability, not physical accuracy.
Use fresh positive/negative tests across conditions before trusting it broadly.
Single-tap test results also do not prove double-tap false-trigger rates.

`build/TapLab --self-test` covers record persistence, source reuse/deduplication,
Test exclusion, hardware isolation, and MagDot model encoding/validation in addition
to the earlier detector checks. `--single-status` prints local class counts;
`--recover-previous` with it performs the same recovery as opening the lab.
`--render-single` renders an empty native fixture without starting the sensor or
writing recordings. Legacy double-tap trial classes remain for source-data replay;
the main UI is now `SingleTapApp.swift`.
