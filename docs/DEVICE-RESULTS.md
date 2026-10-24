# Device evidence: iPhone SE 2, iOS 16.1.1

Observed on 24 October 2026, over SSH, on iPhone12,8 / 20B101 with Dopamine rootless, ElleKit 1.2 and PreferenceLoader 2.2.8. No system binary or thermal configuration was modified. The original simulation API was analyzed but never invoked.

## Build and measurement provenance

The repeated CPU comparison used commit `597c1176d2b98f065539fecd055d7a196e2a9334`, built by [Actions run 40081642003](https://github.com/Justintunsday/Powercuff/actions/runs/40081642003), DEB SHA-256 `eaf5015610c3721cf9683dd789ef85fcac81b180eeee7e5e36883e9e743ab716`. Later changes add diagnostic snapshots, tests, package version/description and this documentation; the cap policy and benchmark workload remain the same. The final beta adds read-only native snapshot reporting and an emergency-latch status bit. Its installation checks are supplied in the final task report; the repeated measurements remain explicitly attributed to the tested commit above.

Raw samples, status replies, selection/readback logs and timestamps are in [evidence/device-20B101](evidence/device-20B101). [summary.json](evidence/device-20B101/summary.json) is computed from the actual sample JSON. Device IP, credentials, complete system binaries, and unrelated tweak inventory are not included.

## CPU effect and recovery

Workload: `powercuff-xorshift64-v1`, single-process integer workload, three five-second samples per phase after 15 seconds of settling. Low Power Mode was false for every benchmark sample. Values below are median **million iterations per second**, not Geekbench scores or CPU clock frequencies. An Off recovery phase also serves as the next cycle's starting control.

| Cycle | Off before | Heavy | Off after |
| --- | ---: | ---: | ---: |
| 1 | 409.4 | 125.7 | 441.4 |
| 2 | 441.4 | 85.7 | 441.5 |
| 3 | 441.5 | 143.5 | 441.4 |

Across nine Heavy samples the median was **125.7 M iterations/s**, versus **441.4 M iterations/s** across nine recovered Off samples: about **71.5% lower throughput under Heavy** for this workload. Heavy samples ranged 80.4–192.0 M; recovered Off samples ranged 439.5–441.7 M. The ranges did not overlap. The initial Off control was more variable, 398.6–439.9 M. Performance recovered after every disable in these three cycles. This is actual short-session CPU throttling/restoration evidence, not an energy-efficiency claim.

The daemon PID stayed **62310** throughout all comparison phases and the LPM checks. Each Heavy phase recorded forwarded package inputs and native readback `101/101 → 1/1`, with setter acceptance and a native index transition. Moderate recorded `101/101 → 21/21`; its one three-sample probe had median **402.1 M** (401.7–413.2 M). Moderate was about 8.9% below the recovered Off median, but it was not repeated for three cycles and should be treated as preliminary.

Public thermal state was fair (1) early in the session and nominal (0) later, including during Heavy. A changed public thermal state is not required for an additive cap and is not used to claim an effect.

## Mode coverage

* Off: no added cap, with repeatable CPU recovery.
* Nominal: selected successfully as an identity cap. It intentionally does not force thermal state or unrestricted indices.
* Light: rejected with status exit **3**, active mode Off and `mode_rejected=1`. The device's `dtPackage=101` is unrestricted. No Light restriction is claimed.
* Moderate: limit 21 reached the package controller; native change and one CPU probe observed.
* Heavy: limit 1 reached the package controller; native change and three CPU comparison cycles observed.

Screen, radio, charger and speaker controllers were deliberately left native. GPU effects of the shared package budget are not separately established.

## Low Power Mode

With saved Heavy and “Only in Low Power Mode” enabled, actual user toggles produced **Off → Heavy → Off** automatically, without reboot or a settings rewrite between toggles. SpringBoard's public observer recorded `require_lpm=1 lpm=0/1/0`, and daemon replies followed the effective mode. The LPM-on phase also recorded accepted clamp calls and native index changes. See the LPM JSON files and `springboard-lpm-cycle.json`. These checks distinguish the gate itself from iOS LPM's own performance effects.

## Limits

`powercuffctl benchmark gpu` returned **Metal device unavailable**, exit **2**, in both mobile and root SSH processes. No GPU performance result is fabricated. App-based GPU benchmarking remains pending. Power/energy fields are null: no calibrated meter or trusted power sampling instrument was available. Battery-life improvement, watts and joules are unverified.

The test was performed on a daily-use phone with other tweaks present. Ambient temperature, display state and background workload were not laboratory-controlled; Heavy showed substantial variation. The repeated non-overlapping CPU ranges and Off recovery support this workload's conclusion, but do not establish universal benchmark scores, specific CPU/GPU frequencies, or energy savings.

A health check after 13 minutes found the same daemon PID and no thermalmonitord-named crash reports in the two standard CrashReporter directories, with no read errors. This is short-session stability evidence; long-term stability, reboot/rejailbreak behavior and compatibility on other device/build combinations remain unverified. Other models/builds are disabled by the compatibility gate.

## Recovery checks

Emergency Off removed the active cap and remained Off after another saved Heavy request in the same daemon. The raw `emergency-*` snapshots preserve this result. The preference was then set to Off. Package removal via dpkg exited 0, removed the tweak dylib and CLI, and gracefully restarted thermalmonitord (the new PID was expected). `uninstall.log` and its exit file record the test. The final beta is installed separately with Off selected. No default-branch merge or verified production release is made.
