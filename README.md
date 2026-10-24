# Powercuff for iOS 16 Rootless

Experimental port restricted to iPhone SE 2 (iPhone12,8), iOS 16.1.1 (20B101), Dopamine and ElleKit 1.2. Injection, matching runtime signatures and live settings communication have been observed on the target. CPU throttling and Off recovery were observed in three repeated cycles of a local workload. GPU effects and energy savings remain unverified. See [device results](docs/DEVICE-RESULTS.md). A successful Actions build proves compilation and package structure only.

Fork: https://github.com/Justintunsday/Powercuff

Development branch: `feature/ios16-rootless`
Official builds: https://github.com/Justintunsday/Powercuff/actions/workflows/build.yml?query=branch%3Afeature%2Fios16-rootless

## Thermal behavior and limitations

The old implementation called `CommonProduct -putDeviceInThermalSimulationMode:`. This port probes that signature but **does not invoke forced simulation**. Analysis of the actual 20B101 device binary confirms a non-stub implementation that enables overrides; Nominal writes unrestricted loading indices. That is unsuitable for an additive restriction whose arguments must never weaken Apple's decisions. This is a conservative design change, not a claim that the old API has been proven broken on iOS 16.

The backend hooks `ComponentControl -setMaxLoadingIndex:releaseIndex:` and always forwards the original call on its original thread:

```
forwardedIndex   = min(AppleIndex, selectedDeviceLimit)
forwardedRelease = min(AppleRelease, selectedDeviceLimit)
```

Limits come from the running product's `simulatedThermalMitigationLimits` dictionary. The verified `PackagePowerCC` class with mitigation type 13 maps to `dtPackage`; all other components stay native. Table positions are not component IDs. No guessed offsets, name aliases, percentages or CPMS messages are used. Runtime type checks must pass before hooks install. A missing product, map, valid package cap, or verified component match rejects a restrictive mode and removes the additional cap. `powercuffctl status` and diagnostic snapshots report rejection.

| Mode | Request |
| --- | --- |
| Off | No additional cap; Apple resumes its native update/release behavior. |
| Nominal | No additional cap. Deliberately does not force an unrestricted thermal simulation; no performance difference from Off is expected. |
| Light | Unsupported on this target: `dtPackage=101` means no added restriction. The request is rejected and the cap is removed. |
| Moderate | Device package limit 21, only on the verified package-power controller. |
| Heavy | Device package limit 1, only on the verified package-power controller. |

The component class, ID and selected package limit are listed in logs; screen brightness, radio, charger, speaker and all other components receive their unchanged native inputs. Having a matched dictionary does not prove the daemon uses this setter for CPU/GPU budgets on this firmware. `clamp-forwarded` proves argument forwarding only. Separately, `native-readback` records before/after indices, whether the setter stored the requested indices and whether they changed. This is still not hardware or benchmark evidence. Different mode maps may be identical, and some firmware can route mitigation through another path. These conditions must be diagnosed on the target device rather than reported as effective throttling.

The tweak never patches sensors, thermal shutdown, watchdogs, system files or CPMS, and never sets `allowLIOverride` or disables a native thermal action. Its cap is removed immediately in memory by Off; actual release follows Apple's next updates and release rate. A stuck or bypassed native path requires further diagnosis. Restarting thermalmonitord removes all in-process state.

## Preferences and Low Power Mode

Settings → Powercuff preserves the `com.rpetrich.powercuff` domain, `PowerMode` (0–4), and `RequireLowPowerMode`. SpringBoard reads CFPreferences as mobile and publishes the effective selection through Darwin notify state. Settings apply without reboot. The public `NSProcessInfoPowerStateDidChangeNotification` and `lowPowerModeEnabled` replace `_batterySaverModeChanged:` and `_CDBatterySaver`.

The dlevi309 snapshot also exposed undocumented Apple battery-saver defaults. They have been removed because their iOS 16 behavior was not verified. Existing Apple preferences are never deleted or rewritten by this port, including during uninstall. If an earlier build changed those values, this package does not automatically undo them.

## Install the official CI artifact

1. Open a successful run on the development branch and download `Powercuff-iOS16-rootless-<full-commit-SHA>`. Extract its ZIP and check `SHA256SUMS` against the DEB. `BUILD-INFO.txt` records the run, commit, Theos and Apple SDK.
2. Install the DEB with Sileo on the specified rootless device. ElleKit 1.2+ and PreferenceLoader are required. Do not install a rootful package or attempt to load this build on another iOS major version.
3. Respring once to load the SpringBoard observer. Installation requests one graceful thermalmonitord restart; launchd restarts it. If necessary, run `sudo /var/jb/usr/bin/killall -TERM thermalmonitord` after the respring.
4. Leave Off selected initially. Run `/var/jb/usr/bin/powercuffctl status`. No fresh reply means daemon injection, notifications or daemon health still needs investigation.
5. Follow [device validation](docs/VALIDATION.md) before relying on any thermal or power effect.

Run preference commands as **mobile**, not root:

```sh
/var/jb/usr/bin/powercuffctl mode off
/var/jb/usr/bin/powercuffctl lpm-only off
/var/jb/usr/bin/powercuffctl status
```

`status` requests a fresh nonce-matched daemon reply, so a stale notifyd state cannot be mistaken for a live daemon. Exit 2 means the backend is unavailable or incomplete; exit 3 means a non-Off request was rejected. A supported status is not a benchmark result. Status is diagnostic for a single operator; simultaneous clients can collide and should retry.

## Off, removal and recovery

For routine restoration, select Off or run `powercuffctl mode off` as mobile, wait for several native thermal updates, and validate recovery. Emergency `/var/jb/usr/bin/powercuffctl restore` can also run as root; it clears caps and latches Off in the daemon until that daemon restarts. It does not change the saved selection, so set the preference to Off before restarting.

Uninstall through Sileo. Removal requests emergency Off and then a graceful thermalmonitord restart; respring to unload the SpringBoard observer. Preferences are preserved. If injection causes instability, use Dopamine's option to jailbreak with tweak injection disabled and uninstall Powercuff. With SSH access, root can alternatively run:

```sh
mv /var/jb/Library/MobileSubstrate/DynamicLibraries/Powercuff.dylib \
   /var/jb/Library/MobileSubstrate/DynamicLibraries/Powercuff.dylib.disabled
/var/jb/usr/bin/killall -TERM thermalmonitord
```

Then uninstall using Sileo and respring. Renaming the package's own dylib prevents reinjection. Do not disable thermalmonitord in launchd. A normal reboot exits Dopamine's jailbroken state if SSH/UI recovery is unavailable.

## Build and inspection

All official packages are produced by GitHub Actions, on `macos-15` with Xcode 16.4's Apple iOS 18.5 SDK and an iOS 16.0 deployment target. The newer SDK is a compile-time source of public headers, not a claim about private interfaces on iOS 16. Both arm64 and arm64e slices are required. Theos and Actions are pinned to full commits; Theos submodules are pinned by that commit. Homebrew supplies host utilities and their installed versions are recorded in setup logs. Hosted runner and Homebrew changes mean this is not a bit-reproducible toolchain.

The workflow runs on development pushes and supports manual dispatch after GitHub registers the workflow. GitHub may require a workflow to be on the default branch before displaying manual dispatch; development pushes remain the normal trigger and no merge into the default branch is needed. Failures, warnings, missing binaries, wrong architecture, missing code signatures, rootful payload paths and missing resources fail CI. `scripts/verify_package.py` reads the actual DEB ar/tar contents and Mach-O headers. Logs are retained even after a failed build. Artifacts expire after 30 days; download a local copy while available. No production release is implied. The pinned dm.pl fallback is patched to set numeric root ownership explicitly; CI verifies the resulting ownership.

## Attribution and evidence

Original Powercuff: Ryan Petrich, https://github.com/rpetrich/Powercuff. This fork preserves the full history of https://github.com/dlevi309/Powercuff (base `1674352c1525853378b0b57799972f734afbd85e`) and the original copyright, author and icons. Rootless port: Justintunsday. The supplied upstream tree contained no LICENSE file; none has been invented or substituted. See [compatibility findings](docs/COMPATIBILITY.md) for primary references and the limits of the evidence.

## Diagnostic files and benchmarks

`powercuffctl status` also snapshots bounded in-memory logs to `/var/jb/var/log/Powercuff/thermalmonitord.json`. SpringBoard writes its own snapshot under `/var/jb/var/log/Powercuff/mobile/`, a directory owned by mobile. No continuous log-file writes occur in the thermal loop.

`powercuffctl benchmark cpu 5` measures a fixed xorshift64 integer workload and reports iterations per second with elapsed time, checksum, LPM and coarse thermal state. It is a local comparison tool, not a standard CPU score. `benchmark gpu 5` attempts a real Metal compute workload; this device currently returns no Metal device from either mobile or root SSH processes, so GPU measurement is unavailable in this context. No GPU score, watts or joules is invented. The output leaves unmeasured power fields null.
