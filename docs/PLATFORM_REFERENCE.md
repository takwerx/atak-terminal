# Platform reference: what takwerx depends on outside this repo

The outside contracts takwerx relies on. Each has an official source and a status:

- ✅ verified <date> on <box>: proven by running it; the evidence is in `docs/DECISIONS.md` (entry named).
- 🔗 link checked 2026-10-31: the URL answers (HTTP 200), nothing more.
- ❓ assumed: not proven here.

Platforms often fail vaguely on purpose. Read the spec before reasoning from the symptom.
Never put passwords, tokens or private box addresses in this file. Add a line when you learn a
contract the hard way; never delete an observation, note a disagreement next to it instead.

## Pins (`versions.env`)

Every download is checked against a SHA-256 in `versions.env` before it is unpacked or run
(DECISIONS 2026-10-19). Google publishes only SHA-1, so those SHA-256s are of files whose SHA-1
matched Google's repository XML at the time. Moving a pin means re-fetching the file, checking
it, and updating the hash together with the version.

| Dependency | Pinned | Official source | Status |
|---|---|---|---|
| Android Emulator | 37.1.11, build 15917651 | https://developer.android.com/studio/run/emulator and `dl.google.com/android/repository/emulator-<os>-<build>.zip` | 🔗 2026-10-31 (Mac zip). ✅ boots and runs ATAK, 2026-09-26 on the Studio (DECISIONS "the GPU emulator is a takwerx runtime"). The build is no longer listed in `repository2-3.xml` but the zip still downloads (DECISIONS 2026-10-19) |
| System image | Android 15, API 35, `google_apis`, r09 | `dl.google.com/android/repository/sys-img/google_apis/` | 🔗 2026-10-31 (arm64 zip). ✅ no fence leak, ATAK at 57 fps, 2026-09-27 on the Mac and the Dell (DECISIONS 2026-09-27 late night). Must be `google_apis`, not `google_apis_playstore`: the GPU runtime needs `adb root` |
| Platform-tools (Windows adb) | 37.0.1 | `dl.google.com/android/repository/platform-tools_r<ver>-win.zip` | 🔗 2026-10-31 |
| Android SDK licence | accepted once by the user | https://developer.android.com/studio/terms | 🔗 2026-10-31 |
| MoltenVK | 1.4.2 | https://github.com/KhronosGroup/MoltenVK/releases | 🔗 2026-10-31. ✅ 1.4.2 ran a 10-minute stress clean; the emulator's bundled 1.4.0 cannot build ANGLE's pipelines (DECISIONS 2026-09-26 night) |
| Lima | 2.2.1 | https://github.com/lima-vm/lima/releases (its `SHA256SUMS` asset) | 🔗 2026-10-31. ✅ VM built from the template and Android 14 booted, 2026-10-19 (DECISIONS 2026-10-19) |
| socket_vmnet | 1.2.2 | https://github.com/lima-vm/socket_vmnet/releases | 🔗 2026-10-31. Unpacked into `/` as root, so the SHA-256 check matters most here |
| scrcpy | 5.0.1 | https://github.com/Genymobile/scrcpy/releases (`SHA256SUMS.txt`) | 🔗 2026-10-31. ✅ hardware decoding, about a quarter of the earlier CPU, 2026-10-20 (DECISIONS 2026-10-20 scrcpy) |
| redroid image | `14.0.0_64only-240527@sha256:0a61...` | https://hub.docker.com/r/redroid/redroid | ✅ pulled by digest in a Lima 2.2.1 VM and booted, 2026-10-19 (DECISIONS 2026-10-19). A wrong digest is refused with "manifest unknown" |
| Ubuntu guest image (redroid runtime) | whatever Lima's `_images/ubuntu-24.04` template names | https://cloud-images.ubuntu.com | ❓ not pinned by us; falls back to an undated image without a digest if the dated one cannot be fetched (DECISIONS 2026-10-19) |

## ATAK and tak.gov

- **ATAK-CIV is never fetched or shipped by takwerx.** tak.gov requires a login, so the user
  downloads the APK themselves from https://tak.gov/products/atak-civ (🔗 2026-10-31). takwerx
  finds it in Downloads or opens a file picker. APKs are never committed (CLAUDE.md).
- **Supported ATAK: 5.7 and 5.8** (README). ✅ 5.8 official release APK on the Dell, 2026-09-27;
  5.7 to 5.8 update through the Market, 2026-09-27 (DECISIONS 2026-09-27 night).
- **Release and debug ATAK builds differ.** Official release APKs have scrambled resource file
  names, so ATAK's icon comes from `resources.arsc` (`lib/apk-icon.pl`, `Takwerx.Apk` in
  `native.cs`), not from a file name. ✅ 2026-09-27 (DECISIONS 2026-09-27 night). Signing and
  ATAK version targeting facts for plugins live in the `atak-plugins` repo's CLAUDE.md.
- **Mock location does not satisfy ATAK 5.8.** takwerx feeds position as NMEA on UDP 4349
  (CLAUDE.md). ✅ recorded in CLAUDE.md; ❓ not re-proven in this pass.
- **The TAKWERX Market plugin** is ours (`takwerx/takwerx-market`). `market_install` takes the
  latest release that matches the ATAK version at run time, so it is not pinned
  (`api.github.com/repos/takwerx/takwerx-market/releases/latest`). Plugins installed through the
  Market arrive with `shouldLoad=false` until ATAK is told to load them (DECISIONS 2026-09-27 afternoon).

## Android Emulator behaviour we depend on

Each is Google's code, observed in the pinned build. Re-check all of them when the emulator pin
moves.

- **Disk:** at first-time setup the emulator wants 1.2 times `disk.dataPartition.size` free in the
  device folder (12288 MB for our 10G), only while `userdata-qemu.img` does not exist.
  ✅ 2026-10-09 (DECISIONS 2026-10-09). takwerx checks first (`emu_data_disk_check`,
  `Test-AvdDiskSpace`).
- **Graphics on Windows:** Google forces SwiftShader (CPU drawing) for old GPUs by PCI id, from
  `emulator/lib/emu-original-feature-flags.protobuf` in the pinned build; no driver update lifts
  it. ✅ 2026-09-29 (DECISIONS 2026-09-29 first Windows PC). takwerx keeps a copy of the list in
  `lib/windows/emulator.ps1` to refresh when the pin moves.
- **Hypervisor:** `emulator -accel-check`; on Windows 11 with virtualization-based security,
  Windows' own hypervisor is enough, no WHPX switch needed. ✅ 2026-09-27 on the Dell (DECISIONS 2026-09-27 afternoon).
- **Image upgrade keeps data** only if `version_num.cache` is written with the new build number
  before the first start; otherwise the emulator silently recreates the data overlay.
  ✅ 2026-09-27 (DECISIONS 2026-09-27 late night; `emu_upgrade_image`, `Update-AvdImage`).
- **GPU path:** MoltenVK, with ANGLE's `warmUpPipelineCacheAtLink` feature disabled by
  `setprop debug.angle.feature_overrides_disabled` from a root shell after boot; the emulator's
  own `-feature`/`-prop` routes do not reach ANGLE. ✅ 2026-09-26 (DECISIONS 2026-09-26 night).
- **Android 14 guest graphics leaks one fence file descriptor per frame**; Android 15 does not.
  Do not go back to 14 on the emulator runtime. ✅ 2026-09-27 (DECISIONS 2026-09-27 late night).
- **Code signing:** re-signing Google's emulator binary strips the hypervisor entitlement and
  the emulator will not start; the patched copy is signed ad hoc with the entitlements it had
  (DECISIONS 2026-09-26 "how it installs" and "the GPU emulator is a takwerx runtime"). ✅ on the Studio and the MacBook.
- **Qt's compiled-in `qt.conf` and the window title format string** are patched in our private
  copy; the revision tag in `emu_prepare` must change whenever the patch does (CLAUDE.md,
  DECISIONS 2026-09-27).

## Host platforms

- **macOS:** Apple Silicon and macOS 13 or newer for the emulator runtime; Intel Macs use the
  slower redroid runtime and are untested. macOS Local Network privacy will eventually break adb
  to Android's LAN address, so adb always goes to `127.0.0.1:5555` through takwerx's own adb
  server on port 5038 (CLAUDE.md). ✅ recorded in CLAUDE.md.
- **Windows:** PowerShell 5.1 syntax, ASCII only (it reads a BOM-less file as the ANSI code page).
  Minimum 8 GB and 4 threads, warns below 16 GB (DECISIONS 2026-09-29). ✅ on the Dell.
- **Lima VM (redroid runtime):** provisioning runs only on a fresh VM (`/etc/takwerx-provisioned`);
  the VM's own kernel upgrade once lost binder (DECISIONS 2026-09-22 later). ✅ on the Studio.
  Validate the rendered instance file, not the template (`@CPUS@` placeholders make the
  template fail `limactl validate`).

## How users receive takwerx

- **Users receive tags, never the head of `main`.** `install.sh` and `takwerx update` read
  `VERSION` on `main` and fetch the tarball of tag `v<VERSION>`
  (`github.com/takwerx/atak-terminal/archive/refs/tags/v<VERSION>.tar.gz`); the daily notice fires
  when `VERSION` moves. So `VERSION` on `main` must always be a published tag, and the newest
  `CHANGELOG.md` section must be that version. ✅ 2026-09-27 (DECISIONS 2026-09-27 later);
  checked on every PR by `.github/ci/release_hygiene.sh`.
- On `dev` the version may carry a `-dev` suffix and be ahead of the newest tag.
- Release notes are written for the testers, in plain words (CLAUDE.md).
