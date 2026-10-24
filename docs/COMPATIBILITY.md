# Compatibility findings and evidence boundaries

Target: iPhone12,8 / iOS 16.1.1 build 20B101 / Dopamine rootless / ElleKit 1.2.

## Original source audit

The complete tracked upstream source, Makefile, injection filter, PreferenceLoader resource, package control and install/removal scripts were inspected at `1674352c1525853378b0b57799972f734afbd85e`. The uninitialized `framework` gitlink pointed at an old rpetrich Theos revision. It is replaced by modern Theos configured in CI. Upstream history remains intact.

* `CommonProduct initProduct:` captures the product, then calls the thermal simulation selector with `off`, `nominal`, `light`, `moderate`, or `heavy`.
* `ApplyThermals` and `LoadSettings` were cast to the unrelated CFNotification callback ABI. `initProduct:` used implicit `%orig()` argument forwarding. Notification return codes were ignored and the same state token handled producer/consumer concerns.
* The product could initialize before the effective mode was published, or thermalmonitord could restart after SpringBoard without a new publication. There was no independent proof of injection, hook installation, API effect or performance change.
* SpringBoard used the private `_batterySaverModeChanged:` hook and `_CDBatterySaver` singleton; the latter can be unavailable or change signatures.
* Deployment targets were iOS 7/8.4; package architecture was rootful `iphoneos-arm`; resources and icon referenced rootful paths. Install/removal restarted thermalmonitord without tolerating its absence. Removal deleted the entire Apple battery-saver preference file.

## Primary references actually inspected

* [Original CommonProduct source](https://github.com/rpetrich/Powercuff/blob/master/Powercuff.x): establishes Powercuff's mode strings and old communication path, not iOS 16 behavior.
* [iOS 14 CommonProduct header](https://github.com/lechium/iOS14Headers/blob/c0b7e9f0049c6b2571358584eed67c841140624f/usr/libexec/thermalmonitord/CommonProduct.h) and [ComponentControl header](https://github.com/lechium/iOS14Headers/blob/c0b7e9f0049c6b2571358584eed67c841140624f/usr/libexec/thermalmonitord/ComponentControl.h): expose the simulation-limit dictionary, component collection, `nameofComponent`, and unsigned two-argument loading-index setter. Headers establish ABI candidates only.
* [iOS 18.2 CommonProduct decompilation](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/usr/libexec/thermalmonitord/CommonProduct.m) and [ComponentControl decompilation](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/usr/libexec/thermalmonitord/ComponentControl.m): the simulation implementation reads mode-specific mitigation limits and enables forced behavior; Off clears overrides. The normal loading-index setter updates the native indices, and CPMS action derives budgets from them. Decompiled types/field names are imperfect, so they are not copied as firmware layouts. These are later-firmware implementation evidence, **not target iOS 16 binary analysis**.
* [Cyanide implementation](https://github.com/kolbicz/Cyanide/blob/main/Cyanide/tweaks/powercuff.m): independently uses the old selector and distinguishes returned invocation from daemon survival/thermal observations. Its comments do not prove behavior on this target. No remote process calls or injection techniques from it were adopted.
* [Theos rootless documentation](https://theos.dev/docs/rootless): `/var/jb` packaging, rootless rpaths, `iphoneos-arm64`, and the modern arm64e ABI requirement motivate a macOS runner.
* [ElleKit upstream usage](https://github.com/tealbathingsuit/ellekit/blob/main/Usage.md): supports the Substrate hook API used by Logos. Target injection with the installed ElleKit 1.2 is confirmed by constructor, hook and daemon-reply evidence.
* [GitHub macOS 15 runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md): Xcode 16.4 and its SDK are available from Apple's preinstalled runner image. CI verifies the actual version.

## Implementation choice

The original API's existence and non-stub implementation on **iOS 16.1.1 are confirmed by target binary analysis**. Its hardware effects were not invoked or benchmarked; existence is not proof of effective throttling. The initial implementation had no target binary. The device subsequently became available; the exact 20B101 binary and thermal configuration were copied read-only and inspected, as recorded below. The original Nominal forced behavior also conflicts with the goal of only adding restrictions. Thus the alternative uses native component inputs with `min(native, cap)` and never enters simulation. The arithmetic policy is exhaustively tested for native indices 0–101 and caps 0–100, including the observed unrestricted 101 sentinel. Actual forwarding, readback and benchmark evidence are recorded separately in DEVICE-RESULTS.md.

Before hooks are installed, Objective-C argument counts, return types and parameter encodings must match. The product is weakly referenced; initialization work is deferred until the initializer has completed. Configuration is immutable after validation and selected caps are shared under a lock. There is no repeated private setter invocation from a new timer or foreign queue. Notification callbacks use the declared notify block API, with separate tokens and checked results. Startup requests a fresh SpringBoard publication instead of treating retained notifyd state as current.

Off removes added caps and forwards the native indices unchanged on subsequent calls. Nominal intentionally has the same cap behavior as Off and does not spoof a nominal temperature. Moderate/Heavy require the verified package-power class and ID. Light is unsupported on this device because its package entry is the unrestricted 101 sentinel. The selected map and live component coverage are logged; all non-package components are left native. Other devices/builds are rejected rather than borrowing this mapping. Subclasses can bypass the hooked setter, which is why actual forwarded calls and readback are required.

## Remaining evidence limits

* Hardware CPU/GPU frequency or CPMS/driver readback is not collected; loading-index getters and a local CPU workload supply distinct evidence.
* Metal is unavailable to this target's SSH CLI contexts. App-based GPU validation and calibrated power/energy measurement remain pending.
* Short-session daemon stability does not establish crash-free behavior over days. Other installed tweaks and uncontrolled ambient/display conditions limit generalization.
* Public thermal state is coarse, not a physical temperature or proof of a power limit. An additive cap can change CPU throughput while public thermal state stays nominal.
* Compatibility outside iPhone12,8 / 20B101 is intentionally disabled.

## Exact target binary evidence

The phone reported iPhone12,8, iOS 16.1.1 / 20B101, ElleKit 1.2 and PreferenceLoader 2.2.8 over SSH. `/usr/libexec/thermalmonitord` SHA-256: `098151865c156b1a669ccab5d28f90362f060276d0aa3ffc66f534a400e58ab7`. `/System/Library/ThermalMonitor/D79AP-Info.plist` SHA-256: `2526eb4478cc797c264db67d5d582a3806a1e684859a0379ca30933d1abc59f3`. System files were copied read-only; the originals were not changed.

Objective-C relative method metadata and arm64e disassembly locate:

| Method | Unslid address | Encoding |
| --- | --- | --- |
| `CommonProduct initProduct:` | `0x100052788` | `@24@0:8@16` |
| `CommonProduct putDeviceInThermalSimulationMode:` | `0x1000542e8` | `v24@0:8@16` |
| `ComponentControl setMaxLoadingIndex:releaseIndex:` | `0x10002987c` | `v24@0:8I16I20` |
| `ComponentControl getReleaseMaxLI` | `0x100029e08` | `i16@0:8` |
| `ComponentControl maxLoadingIndex` | `0x100029fd8` | `I16@0:8` |
| `PidComponent nameofComponent` | `0x10000d1dc` | `^{__CFString=}16@0:8` |
| `PackagePowerCC initWithParams:` | `0x1000255f0` | `@24@0:8^{__CFDictionary=}16` |

The simulation method has branches for Off/Nominal/Light/Moderate/Heavy. Nominal writes seventeen bytes of value 100 to the simulation table; other modes read the limit dictionary. Off clears overrides. The native two-argument setter returns early if the native LI-override flag is set; otherwise it stores its two unsigned inputs. The two getter implementations read those same fields. No target offsets are hardcoded in the tweak.

The package initializer passes `0x0d` (13) to its superclass, confirmed by the live component named `13 PackagePower`. The simulation table's `dtPackage` entry is at position 12, **not mitigation type 12**. An early diagnostic build caught this mismatch, was restored to Off, and was superseded before performance conclusions. The corrected port requires the actual `PackagePowerCC` class and ID 13. It applies no caps to Speaker (12), BackLight (0), or PwrSrc (1).

The target's package limits are Light=101 (unrestricted sentinel), Moderate=21, Heavy=1. Thus Light is explicitly unsupported as an additional package restriction. Nominal intentionally adds no cap. Only this model/build is enabled until other mappings are verified.
