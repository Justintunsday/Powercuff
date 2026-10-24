# Repeatable device validation

No target-device results have been recorded yet. Do not fill this document with predicted numbers. Preserve raw logs and benchmark output before drawing conclusions.

## Establish the environment

Record device model, OS build, jailbreak version, installed ElleKit and PreferenceLoader versions, DEB checksum, full source commit and Actions run URL. Confirm `uname -m`, `sw_vers` or Settings → About, and `dpkg-query -W ellekit preferenceloader com.rpetrich.powercuff` on-device. Note any other thermal/power tweaks, process exclusions and Low Power Mode setting. Avoid simultaneous thermal tweaks during measurement.

Install and respring according to the README. Record thermalmonitord PID before/after each test. Start a unified log stream where Apple's log utility is available (or collect the same subsystem with macOS Console attached to the iPhone):

```sh
log stream --style compact --level debug --predicate 'subsystem == "com.rpetrich.powercuff"'
```

Some rootless devices do not ship Apple's `log` executable. Missing access is an evidence gap, not an empty successful log. Save daemon crash reports from `/var/mobile/Library/Logs/CrashReporter` and `/Library/Logs/CrashReporter` where readable. Check SpringBoard and thermalmonitord for unexpected exits throughout testing.

## Evidence ladder

| Evidence | What it establishes | What it does not establish |
| --- | --- | --- |
| `stage=injection` from each named process | Dylib constructor ran | Hook installed |
| `stage=abi` + `stage=hooks installed=1` | Runtime types matched and method implementations changed | Setter ever called |
| `stage=settings` + `stage=selection` | LPM gate, selected map and matching components | Driver budget accepted |
| `stage=clamp-forwarded` | Original setter was invoked with lower indices | Setter stored them or changed hardware |
| `stage=native-readback`, `setter_accepted=1`, `state_transition=1` | Native getter values match the forwarded request and changed | A hardware budget or throughput changed |
| Native getter/CPMS or driver telemetry before/after | Observed state transition | CPU/GPU throughput or energy savings |
| Repeated controlled benchmark/power samples | Measured practical effect and Off recovery | Universal effects on other devices/workloads |

Run `powercuffctl status` after every selection. It must receive a fresh daemon reply. `mode_supported` means there is a configuration/component match; `clamp_forwarded` means at least one input was lowered in a forwarded call. These fields never claim a hardware effect. An unsupported request exits 3. No daemon reply/incomplete initialization exits 2.

For native readback, inspect method types before using a debugger/runtime inspector: `maxLoadingIndex` is expected to return unsigned int, `getReleaseMaxLI` an int, `thermalPressureLevel` a 64-bit integer in reference headers. Record the actual iOS 16 encodings. Capture these read-only values, component names and native CPMS/driver logs while the normal loop runs; do not call undocumented mutators or write ivars to manufacture a result. If these tools are unavailable, mark native state verification pending.

## Off → Heavy → Off, at least three cycles

1. Fix brightness, workload, ambient conditions, battery charge range and charging state. Keep Low Power Mode consistently Off for the primary comparison. Cool to a comparable starting condition between samples. Record these conditions rather than assuming equivalence.
2. As mobile, set `powercuffctl lpm-only off` and `powercuffctl mode off`. Wait at least 30 seconds and until native telemetry settles. Save status, logs, PID, and 3 identical CPU benchmark runs and 3 GPU runs (same benchmark/version/settings). Save elapsed duration and scores. Do not compare different benchmark workloads.
3. Set `powercuffctl mode heavy`. Save the exact selected caps and matched components. Wait for multiple normal thermal loops; collect status, forwarded values, native readback, and the same repeated CPU/GPU benchmarks.
4. Set `powercuffctl mode off`. Verify new setter calls forward unchanged indices; wait until native releases settle. Repeat the same measurements. The recovered performance must be compared with both initial baseline and ordinary baseline variation.
5. Repeat the complete cycle at least 3 times. Preserve all samples, including failed/unsupported modes. Then repeat comparisons for Light and Moderate. Nominal is an identity cap and should not be described as an independently restrictive level.

For energy, prefer a calibrated external meter under a fixed charging/load protocol, or a trusted instrument that exposes units, sample interval and calibration. Battery percentage changes and instantaneous uncalibrated current are insufficient. Record average power and integrated energy over the same amount of completed work; reduced throughput does not by itself prove energy savings. No automated code in this repository fabricates or estimates watts from loading indices.

## Low Power Mode and failure cases

* Set a supported Heavy mode and `lpm-only on`; toggle iOS LPM off/on/off without reboot. Verify the effective selection transitions Off/Heavy/Off, then measure the cap evidence. Distinguish iOS LPM's own performance effects with an Off+LPM control.
* Change preferences rapidly, respring, gracefully restart thermalmonitord, and reboot/rejailbreak. Check settings reapplication, fresh replies, stable daemon PIDs and absence of crash reports. Settings apply live after initial injection; initialization still requires a respring.
* Select an invalid stored mode or test an unsupported runtime in a controlled test environment. It must remain uncapped and log the reason; never bypass the compatibility checks on a daily-use device.
* Exercise emergency `restore`, verify no later preference notification re-enables caps in that daemon, then set saved mode Off and restart the daemon. Remove the package and verify normal behavior.

## Results to record

For each sample: timestamp, exact commit/DEB hash, device/OS, mode, LPM state, selected and matched caps, before/after native indices, daemon PID, public thermal state, CPU/GPU benchmark name/version/score/duration, power measurement method/units/value, temperature/ambient conditions and any crash or log error. Report medians and dispersion alongside raw samples; do not infer a difference smaller than baseline variation. Keep CPU, GPU, power and restoration conclusions separate. Until these data exist, functional completion remains pending.
