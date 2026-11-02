# Gesture algorithm audit — 2026-11-01

The existing magnitude/energy representation maps a waveform and its global sign reversal to the same features. Increasing the waveform window alone improves one recording session but regresses on another. Broad spectral and combined feature candidates likewise did not consistently improve the saved tests.

The selected update retains a signed initial response: eight time bins per axis plus signed extrema. It normalizes strength using the captured waveform RMS, then fits balanced L2-regularized logistic weights. Scores between the positive and negative thresholds remain unknown. Nearest-template distance still limits the existing double-tap matcher. Default models and version-1 pair profiles retain their existing behavior.

Version-2 profiles rebuild from their saved raw impact waveforms. Their reserved windows are never used to fit weights. Before enabling the new path, a per-profile non-regression guard replays those reserved samples and compares recognized MagSafe impacts and false corner/decay positives with the legacy path. A regression retains the legacy path. The same guard is used during the existing automatic calibration assessment; no prompt or capture procedure changes.

## Recorded replay results

| Test | Legacy | Updated |
|---|---:|---:|
| Current MagSafe impacts, leave-one-window-out | 17/21 | 19/21 |
| Current corner/decay false positives | 1/59 | 1/59 |
| Current valid MagSafe double-tap windows, leave-one-window-out | 4/7 | 7/7 |
| Current negative-window double-tap activations | 0/27 | 0/27 |
| Earlier-session MagSafe impacts, excluded from training | 13/24 | 18/24 |
| Earlier-session corner/decay false positives | 1/130 | 0/130 |
| Earlier-session valid MagSafe double-taps | 4/12 | 11/12 |
| Earlier-session negative-window activations | 0/40 | 0/40 |
| Current reserved MagSafe impacts | 6/6 | 6/6 |
| Current reserved negative-impact false positives | 0/17 | 0/17 |
| Separate labeled bottom-right test false positives, including stored decay | 0/21 | 0/21 |
| Separate bottom-right negative-window activations | 0/5 | 0/5 |

These are replay results from one user and Mac, not cross-user or cross-hardware accuracy estimates. Whole recording windows, including their impacts and decay samples, are excluded from the corresponding training fold. Pair replay preserves existing timing, similarity, cooldown and input guards. Arbitrary free-tapping runs are not labeled positive double-taps: only windows with two appropriately timed impacts count as positive pair tests.

The current reserved set participates in the per-profile non-regression guard and is not an unbiased final test of model selection. The older session and separately labeled bottom-right test are not training or per-profile fallback inputs. They were examined during algorithm selection, so they are exploratory regression tests rather than a fresh blind test. A future independent dataset is still needed to establish generalization.

## Reproduce

```sh
bash scripts/benchmark-gestures.sh PROFILE_JSON OLDER_PROFILE_JSON BOTTOM_RIGHT_TRACE_JSON
```

The command fits models in memory, does not modify profiles, and emits JSON scores. `GestureRecordingChecks.swift` additionally covers sign preservation, strength normalization, reserved-data fallback, continuous capture and 48 sampled ringing/attack cases. No calibration UX, permissions, sensitivity slider, or shared/default model is changed by this algorithm update.
