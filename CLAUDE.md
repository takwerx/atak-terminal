# atak-terminal (TAKwerx ATAK Terminal)

Real ATAK in a desktop window, a bash engine (`takwerx`) driving it all. Two runtimes:
the default on Apple Silicon is Google's Android Emulator on the Mac's GPU (`lib/emulator.sh`,
no VM); the other is redroid (Android in a container) inside a Lima VM with scrcpy as the
window, for LAN multicast and Intel Macs. Public beta since 2026-09-26, Mac only. Read
`README.md` for what it does and `docs/DECISIONS.md` for every non-obvious finding and
why; do not re-derive those. Windows is next: `docs/PLAN-windows.md` is the brief.

## Layout

- `takwerx`: the CLI. `lib/common.sh` (paths, config, logging, the APK lookup and picker),
  `lib/host-macos.sh` (tools, bridged networking, the app bundle and Dock), `lib/emulator.sh`
  (the emulator runtime: SDK download, AVD, the patched and bundled emulator binary,
  provisioning, plugins), `lib/vm.sh` (Lima), `lib/android.sh` (container, adb, ATAK,
  window, position).
- `lima/takwerx.yaml.tmpl`: the VM. Its provisioning script installs podman, binder via
  binderfs, uhid, and three systemd services: `dev-binderfs.mount`, `takwerx-location`
  (NMEA feeder) and `takwerx-adb-relay`. Placeholders `@CPUS@` etc. make the template itself
  fail `limactl validate`; validate the rendered instance file instead.
- `helpers/maclocation`: Swift CoreLocation CLI, universal binary committed because users
  have no compiler. `helpers/maclocation/build.sh` rebuilds it.
- `install.sh`: the `curl | bash` bootstrap. `versions.env`: pinned versions.
- Runtime state lives in `~/.takwerx` (tools, Lima home, config, logs), never in the repo.

## Working on it

- Run the engine in place: `./takwerx <cmd>`. `takwerx vm-shell` for the VM, `takwerx shell`
  for Android. `takwerx logs --container` and `--android` for boot and logcat.
- Provisioning only runs on a fresh VM (`/etc/takwerx-provisioned` marker). When changing
  it, apply the same change to the live VM by hand or recreate the VM; a full clean run is
  `limactl delete -f takwerx` then `./takwerx init`.
- Bridged mode recreates the Android container on every start (fresh DHCP lease before
  Android boots); data lives in the `takwerx-data` volume, so that is safe.
- adb always goes to `127.0.0.1:5555` on the Mac through takwerx's private adb server on
  port 5038. Never connect adb to Android's LAN address from the Mac: macOS Local Network
  privacy will eventually break it.
- Position for ATAK is NMEA on UDP 4349, streamed by the VM service from
  `/etc/takwerx/location`. Mock location providers do not satisfy ATAK 5.8.
- No code signing anywhere, by decision. The app bundle is generated on the user's Mac.
- License AGPL-3.0-or-later. ATAK APKs are never committed or redistributed.

- On the emulator runtime, provisioning runs on every boot (`emu_provision`), and the
  emulator copy under `~/.takwerx/tools/emulator` is rebuilt whenever the revision tag in
  `emu_prepare` changes. The emulator binary runs from inside the app in Applications,
  which is why the copy has Qt's compiled-in qt.conf patched out and the wrapper script
  sets Qt WebEngine's paths (DECISIONS 2026-09-27). To drive the emulator's own UI in a
  test, `EMU_ARGS=-grpc 8554` in the config and curl to its UiController; keystrokes by
  osascript are refused here.
- Every mouse and trackpad fix is in the Cursorwerx plugin (takwerx/cursorwerx, in the
  Market), never in the runtime.

## Not done

Windows (see `docs/PLAN-windows.md`) and Linux hosts. A scrcpy patch to turn trackpad
scrolling into touch drags, for the redroid runtime.
