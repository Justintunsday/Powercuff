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
* [ElleKit upstream usage](https://github.com/tealbathingsuit/ellekit/blob/main/Usage.md): supports the Substrate hook API used by Logos. Loader configuration, process exclusions and the exact installed 1.2 build still require target checks.
* [GitHub macOS 15 runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md): Xcode 16.4 and its SDK are available from Apple's preinstalled runner image. CI verifies the actual version.

## Implementation choice

The original API's existence/function on **iOS 16.1.1 is pending runtime inspection**. There is insufficient evidence to call it either proven functional or incompatible. No iOS 16 thermalmonitord binary or diagnostic log was available at implementation time. The original Nominal forced behavior also conflicts with the goal of only adding restrictions. Thus the safe alternative uses native component inputs with `min(native, cap)` and never enters simulation. That policy is exhaustively tested for all valid 0–100 index/cap pairs, but it is not a proof of the iOS 16 daemon's budget path.

Before hooks are installed, Objective-C argument counts, return types and parameter encodings must match. The product is weakly referenced; initialization work is deferred until the initializer has completed. Configuration is immutable after validation and selected caps are shared under a lock. There is no repeated private setter invocation from a new timer or foreign queue. Notification callbacks use the declared notify block API, with separate tokens and checked results. Startup requests a fresh SpringBoard publication instead of treating retained notifyd state as current.

Off removes added caps and forwards the native indices unchanged on subsequent calls. Nominal intentionally has the same cap behavior as Off and does not spoof a nominal temperature. Light/Moderate/Heavy require exact, restrictive matches. We do not infer missing names or silently substitute Heavy with a different mechanism. A partly matched map logs the exact component coverage; CPU/GPU coverage is pending validation. Readable names can differ across firmware, and subclasses can bypass the hooked setter.

## Unverified items

* Exact iOS 16.1.1 method implementations, configuration content and component mapping.
* Injection into both target processes under the user's Dopamine/ElleKit configuration.
* Low Power Mode toggle propagation on the device and settings reload timing.
* Whether normal CPU/GPU mitigation passes through this method, whether natural LI override flags permit updates, and whether limits differ between modes.
* Native index readback, actual driver/CPMS state, measurable CPU/GPU changes, energy savings, Off recovery time and sustained daemon stability.

Public thermal state is a coarse observation, not a physical temperature or proof of a power limit. An additive cap may change performance while the public thermal state remains nominal. The package must remain an experimental build until the validation protocol supplies actual evidence.
