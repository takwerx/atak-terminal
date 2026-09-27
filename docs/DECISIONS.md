# Decisions and spike findings

Dated notes on what was decided and why, so nobody re-derives them. Newest first.

## 2026-09-27, late afternoon: slow tiles were the emulator's netsim Wi-Fi, on both platforms. And the Intel GPU

The operator saw map tiles arrive more slowly on the Dell than on the Mac. Timed with the
same plain-HTTP requests on the host and from inside Android (`tools/windows-measure.ps1
-NetTest`, toybox `nc` in Android, dl.google.com for throughput, 20 sequential requests to
www.google.com/generate_204 for the round trip):

| | Mac host | Dell host | Mac Android | Dell Android |
|---|---|---|---|---|
| download | 6-12 MB/s | 18-22 MB/s | 3.4-4.2 MB/s | 3.0-3.4 MB/s |
| one small request | 40 ms | 113 ms | about 800 ms | about 1,070 ms |

- **The Dell's own share**: three times the Mac's round trip on the host, on Wi-Fi with
  CrowdStrike Falcon running (no proxy, no PAC, Tailscale up but not the default route).
  That explains why its Android was somewhat worse than the Mac's, not the size of the gap.
- **The emulator's share, on both machines**: twenty times the host's round trip. Since
  emulator 33 Android's virtio Wi-Fi streams every packet over gRPC to the separate `netsimd`
  process (`WiFiPacketStream`, "Successfully initialized netsim WiFi" in the log), which runs
  its own NAT. With `-feature -WiFiPacketStream` the emulator keeps Wi-Fi on its built-in
  stack: **41-47 ms a request and 8.5-9.7 MB/s inside Android on the Mac**, against 9-11.5 on
  the host at the same moment. Android still reports a connected, VALIDATED Wi-Fi network
  ("AndroidWifi", 10.0.2.16), ATAK held 8 live TCP connections, adb and the GPS fix were
  unaffected. What is given up is netsim's simulation between emulators, unused here. Now the
  default in `emu_start` and in the Windows measuring script. **On the Dell with it: 46 ms a
  request and 8-13 MB/s inside Android** (from 1,070 ms and 3.0-3.4), faster per request than
  curl.exe on the Dell's own Windows (128 ms, with Falcon inspecting it), and the NVIDIA on
  ANGLE held 48-50 fps over zoomed-in imagery, tiles sharp in every screenshot. Of the time a request took before, about 45% was the name lookup (by IP:
  422 ms, by name: 768 ms).
- **The Intel Arc on ANGLE: 41-44 fps** zoomed into imagery (first window 27, while tiles
  were still arriving), renderer `ANGLE (Intel, Vulkan 1.3.0 (Intel(R) Arc(TM) Pro Graphics),
  Intel-0.406.668)`. So a laptop's integrated Intel graphics carries ATAK on Windows. Getting
  there took the emulator's own switch: Windows' per-app GPU preference
  (`HKCU\Software\Microsoft\DirectX\UserGpuPreferences`) steers OpenGL and DirectX only,
  and the emulator picks its Vulkan device itself, the discrete one by default. It reads
  `ANDROID_EMU_VK_SELECT_GPU` at start and matches it against the device names
  ("Selecting GPU (Intel(R) Arc(TM) Pro Graphics) at index 0").
- **For the record, the scenes**: the Mac's 57-58 fps and the Dell NVIDIA's 48-51 were both
  on the zoomed-out globe (the Mac at 3360x1380, the Dell at 1820x1050). The NVIDIA with
  imagery and a live Cam Depot video in the side pane held 31-38.

## 2026-09-27, afternoon: Windows measured first. WHPX without admin, ANGLE at 50 fps, the stock path at 16

The measure-first phase of `docs/PLAN-windows.md`, on the operator's work laptop: Dell
Precision 5490, Core Ultra 7 165H, 32 GB, NVIDIA RTX 2000 Ada (driver 596.71) beside Intel
Arc Pro, Windows 11 Pro 26200, 1920x1200 at 125%. A managed machine: the operator is not a
local administrator, so no SSH server could be installed, and the work ran as
`tools/windows-measure.ps1`, typed by hand, fetching itself and ATAK from the Mac over a
switch and posting its results back to `tools/measure-server.py`. What it found:

- **The hypervisor needs nothing on a machine like this.** Virtualization-based security was
  running, so Windows' own hypervisor was up, and `emulator -accel-check` said `WHPX(10.0.26200)
  is installed and usable` as a plain user. The emulator runs without admin. A machine without
  WHPX needs it switched on once, by an admin; not met yet.
- **The stock path (`-gpu host`, the emulator's GLES translator on NVIDIA OpenGL 4.5)** draws
  ATAK's icons and labels at full size, so the 64 px cap was Apple's OpenGL, not the emulator.
  But it ran at 16 fps under the scripted drags below. ATAK did not stay up on it without
  `opengl.broken` (splash, then black; not running 20 s after launch), the same as the Mac's
  first GPU run; with the file it started.
- **Guest ANGLE (`-feature Vulkan,GuestAngle`) on NVIDIA's Vulkan: 48-51 fps** in the measured
  windows, SurfaceFlinger's own average 55-57, renderer `ANGLE (NVIDIA, Vulkan 1.3.0 ...
  NVIDIA-596.71.0.0), OpenGL ES 3.2.0`. The Mac under the identical test: 57.4-57.6 (average
  59.3) on ANGLE over MoltenVK. ATAK started on ANGLE without the Mac's
  `warmUpPipelineCacheAtLink` override: that one was MoltenVK's. `opengl.broken` was in place;
  ANGLE without it is untested. Boot to Android 32 s on ANGLE, 43-50 s on the stock path.
  So Windows takes the Mac's recipe minus the override: `-gpu host -feature
  Vulkan,GuestAngle,VirtioTablet`.
- **How the frame rate is measured**, the same on both machines: SurfaceFlinger timestats
  (`dumpsys SurfaceFlinger --timestats -enable`, `-clear`, `-dump`), `totalFrames` of ATAK's
  map layer, `SurfaceView[...ATAKActivityCiv](BLAST)`, over three windows of three 3-second
  `input swipe` drags each. `dumpsys SurfaceFlinger --latency` returned nothing on this
  Android 14 image for any layer, and short swipes left the map idle between them (15 fps on
  the stock path by that method, 16 with long drags).
- **Windows traps for the port**, each hit today: `Expand-Archive` fails on the 1.5 GB image
  zip ("A local file header is corrupt"), `tar.exe` unpacks it; `Invoke-WebRequest` on the
  420 MB emulator zip crawls with its progress bar (use `curl.exe`); the emulator's `*.lock`
  entries are directories on Windows; a PowerShell function with a `param()` block binds
  `-W`, `-d` and `-c` meant for adb as its own switches; the emulator starts at its factory
  position (San Francisco) until `adb emu geo fix`, as on the Mac.
- **Plugins**: installed through the Market inside ATAK they get `shouldLoad=false` and
  wait in the Plugins screen, as on the Mac; switching all nine on and restarting ATAK loaded
  them. Map Depot's entry then came and went from the Tools list while ATAK's registry kept
  it loaded (`Already loaded, skipping plugin extension ... MapDepot`), and ATAK never
  restarted: a Map Depot bug, seen on the Mac too, not the runtime's.
- **Open:** the operator finds the dynamic range-and-bearing endpoint drag worse than on the
  Mac, a Cursorwerx question for the tablet input on Windows. (The Intel Arc: measured, see
  the late-afternoon entry.)

## 2026-09-27, later: releases. Users receive tags, not the head of main

Until now the install line and `takwerx update` fetched the main branch tarball, and the
daily notice compared VERSION files that had never moved, so a fix reached people only
if they happened to run `update`, and any push reached them the same way. Now a release
is `./release.sh X.Y.Z` after a CHANGELOG section: it bumps VERSION, tags vX.Y.Z, pushes
commit and tag in one atomic push, and creates the GitHub release with that section as
its notes. VERSION on main names the newest release and the tag holds it; `install.sh`
and `update` read VERSION from main and fetch the tag's tarball (`TAKWERX_BRANCH`
still takes a branch, for development). So main can move between releases without
reaching anyone, the notice fires exactly when VERSION moves, and a tester can read
what changed before typing `update`. The notice also prints in a terminal now (`up`,
`status`), since not everyone starts from the icon, and `emu_up` says when Android is
still running the previous emulator build after an update (the copy is rebuilt at the
next start, not during `update`). First release 0.1.1, the Extended Controls fix.

## 2026-09-27: the first crash from the field is the "..." button. Qt's path file, the app bundle, and Chromium's sandbox

A tester's Mac mini M4 Pro (24 GB), fresh install, 76 seconds after start: the whole
emulator went down when they clicked "..." (Extended Controls) on the side toolbar. The
crash report's main thread: `ToolWindow::on_more_button_clicked -> ExtendedWindow::show ->
QWebEngineView::showEvent -> WebEngineContext::WebEngineContext ->
WebEngineLibraryInfo::getPath -> QMessageLogger::fatal -> abort`. The Location page of that
window is a Chromium view (Google Maps), created the first time the window shows.

- **Reproduced here without a click.** macOS Accessibility blocks keystrokes from this
  session (`osascript is not allowed to send keystrokes`), so the emulator was started with
  `-grpc 8554` (now `EMU_ARGS` in the config, for trials only: that port is on every
  interface, unauthenticated) and asked over its gRPC bridge,
  `android.emulation.control.UiController/showExtendedControls`, with curl
  (`--http2-prior-knowledge`, `content-type: application/grpc`, a 5-byte empty frame, or
  `00 00 00 00 02 08 01` for the Location pane). The emulator routes Qt's messages through
  its own handler into `emulator.log`, so the fatal text is there:
  `The following paths were searched for Qt WebEngine Process:
  /Applications/lib64/qt/libexec/QtWebEngineProcess, /Applications/lib64/qt/bin/...,
  /Applications/TAKwerx ATAK Terminal.app/Contents/MacOS/QtWebEngineProcess`.
- **Cause: Qt's path file, compiled into the binary, and where the binary runs from.**
  qemu-system-aarch64 carries `:/qt/etc/qt.conf` as a Qt resource, 33 bytes,
  `[Paths] Prefix = ../../lib64/qt`. Qt reads a compiled-in qt.conf before any other (one
  in the app's Resources cannot override it, checked in Qt 6.5.3's qlibraryinfo.cpp) and
  resolves a relative Prefix against the executable's directory, or, for an executable
  inside an app bundle, against the bundle's `Contents/`. From `qemu/darwin-aarch64/`
  that is the emulator's `lib64/qt`; from `TAKwerx ATAK Terminal.app/Contents/MacOS/` (the
  Dock decision below, 2026-09-26) it is `/Applications/lib64/qt`. Nothing else the
  emulator draws noticed: the launcher passes the plugin directory in
  `QT_QPA_PLATFORM_PLUGIN_PATH`, which Qt also adds to its library paths, and the emulator
  ships no Qt translations or QML imports. Only Qt WebEngine reads the prefix, for its
  helper (`lib64/qt/libexec/QtWebEngineProcess`), its resources (`resources/*.pak`,
  `icudtl.dat`) and locales. The tester's own Claude read of the crash had the symptom
  right and the cause wrong: Qt's libraries loading from under the home folder is the
  design; the executable's location is what moved.
- **Qt's three environment overrides are not enough on their own.**
  `QTWEBENGINEPROCESS_PATH`, `QTWEBENGINE_RESOURCES_PATH` and `QTWEBENGINE_LOCALES_PATH` in
  the wrapper script stopped the abort, but the helper died the moment it started
  (`icu_util.cc: Invalid file descriptor to ICU data received`,
  `ContentMainDelegate::TerminateForFatalInitializationError`, two crash reports per
  opening, a blank page). Chromium sandboxes the helper before it reads anything, and the
  seatbelt profile in Qt's build allows reads under the app bundle, the helper's own
  executable and `(subpath (param qt-prefix-path))`: Qt's prefix as the browser process
  sees it, still `/Applications/lib64/qt`. So the prefix itself has to be right.
- **The fix: the retitle pass takes the path file out of the copy.** One letter of the
  resource's name in the resource table changes, `qt.conf` to `qt.conx` (UTF-16, the
  stored hash stays and the lookup compares names, so `:/qt/etc/qt.conf` no longer
  exists). Qt then looks in the app's Resources and next to the executable, finds nothing,
  and uses its relocatable prefix, the directory QtCore was loaded from: `lib64/qt` of the
  copy, the same answer the stock layout gives. Measured first with a 30-line C probe that
  dlopens the emulator's QtCore and calls `QLibraryInfo::path` (LibraryExecutables,
  Data, Translations all under `~/.takwerx/tools/emulator/lib64/qt`). Verified on the
  built app: Extended Controls opens on the Location pane, two renderers stay up, Google
  Maps' JavaScript loads (its own deprecation warnings arrive in `emulator.log`), no crash
  report. The three variables stay in the wrapper as the second line for an emulator build
  where the byte pattern does not match: no abort, a blank map, and `emu_prepare` warns.
  Copy revision r12; `takwerx update` then a restart brings an installed Mac up to it.
- **Not chosen.** `-no-location-ui` drops the pane (a real feature: a map to set a
  position from). `QTWEBENGINE_DISABLE_SANDBOX=1` works by removing the sandbox. A qt.conf
  in the app is read after the compiled-in one. Qt expands `$(VAR)` in qt.conf values, so
  rewriting the 33-byte payload to `Prefix=$(X)` would also work, but only with the
  variable set. `Prefix = Resources/qt` with a symlink out of the bundle keeps Qt happy
  and the sandbox not: seatbelt matches real paths, and the files stay outside the bundle.

## 2026-09-26, late night: how it installs, decided

The operator's call: no Apple Developer ID ("not paying Apple"), so no notarized
disk image; the install stays the one Terminal line, and everything after it is
clicks. The one thing takwerx cannot do is fetch ATAK: tak.gov is behind a login,
and the official GitHub releases of ATAK-CIV carry SDK zips only, no APK (checked
2026-09-26, 4.6.0.5 is the newest there). So the instructions say "download ATAK
first", and every path that needs the APK and cannot find one in Downloads opens a
native file picker (`atak_pick`, `choose file` via osascript; zenity on Linux):
`takwerx init`, `takwerx apk`, and the app icon, which shows a dialog with "Open
tak.gov" and "Choose the APK" first (`atak_ask_pick`) and then installs and launches
ATAK in one go. Cancel is handled: the picker returns nothing and the message says
what to do. Anything that downloads by click (an app, a dmg, a "web installer") gets
quarantined, and macOS 15 dropped right-click-open, so curl is the clean path, not
the compromise.

- **Public, as a beta** (operator, 2026-09-26 night, minutes after asking for a team
  zip: "lets just make this an open github public project its beta for now"). So the
  README's curl line is the install, the repository carries every instruction, and
  the zip is gone. Before the flip the tracked files were scanned: no APK was ever
  committed, no private addresses or account names. The README was rewritten for the
  emulator runtime it had grown past (it still described the VM, NMEA and keyboard
  modes of redroid), and `reset`, `uninstall`, `keyboard`, `network` and `logs
  --container` were given emulator behaviour so the command list is true. Mac only
  for now; Windows is next ("we will work on windows tomorrow"). Plugins come through
  the Market inside ATAK ("it only needs one plugin, the Market"), or by dragging an
  APK onto the window, which the emulator installs and ATAK offers to load ("dragging
  is so clutch"). Cursorwerx, which carries the mouse fixes, is not in the Market
  yet. Prompts read /dev/tty, so `curl | bash` can ask for the SDK licence.
- **First fresh install from the public line, MacBook, 23:18 to 23:22.** Uninstall, ATAK
  5.8.0.5 "civSmall" in Downloads, the curl line: tools, emulator, image and MoltenVK
  down in a minute, Android up 31 s after start, the small build found by version and
  installed (same package as the full one, so everything applies), Market 1.7, the
  icon rebuilt with ATAK's art, position from the Mac, ATAK open. Two things learned:
  (1) the Market, installed before ATAK's first run, was not registered by ATAK (no
  `shouldLoad` entry, as found earlier for other plugins); installing it again over
  itself while ATAK ran made ATAK load it on the spot, no restart, no question
  (`AtakPluginRegistry: Loaded plugin ... takwerxmarket`, `shouldLoad` written true).
  So a first install now arms a background waiter that does exactly that once ATAK is
  past its first run (`market_register_after_first_run`). (2) Without Cursorwerx the
  trackpad zooms the map when scrolling over the toolbar overflow, the operator's first
  remark on the fresh install; every mouse and trackpad fix is in that plugin, and it
  is not in the Market yet, so until it is, the APK is dragged onto the window.
- **The app is "TAKwerx ATAK Terminal"** (was ATAK.app; an old bundle with our
  identifier is removed by `app_build`; `takwerx app` rebuilds the icon on demand).
- **Its icon is ATAK's own**, taken from the APK on the user's disk at build time, the
  largest `ic_atak_launcher.png` in it (96 px in 5.8; the Dock draws 64 to 128 px, so it
  is sharp there and soft in Launchpad). Nothing of ATAK's is shipped. Before ATAK is
  installed the takwerx icon is used; `takwerx app` after `takwerx apk` swaps it.
- **Pinned to the Dock once** at build (`persistent-apps`, then the Dock restarts).
- **The running emulator is the app itself: one Dock tile, "TAKwerx ATAK Terminal",
  the ATAK icon**, where it said qemu-system-aarch64 and sat next to the pinned app as a
  second tile. macOS names a process after its bundle, or after the executable file
  when there is none, and merges it with a Dock tile only when it is the same app; the
  binary had no bundle and no embedded Info.plist. So the retitled, signed binary is
  copied into the app in Applications (`Contents/MacOS/qemu-system-aarch64`, APFS
  clone), and the file the launcher execs at its fixed path in the emulator copy
  becomes a two-line shell script that execs that copy (`emu_bundle`); the original
  stays beside it as `qemu-system-aarch64.bin`, and `emu_start` restores the app copy
  if the app was deleted. Measured on the Studio on the way there: a symlink into a
  bundle is not enough (macOS goes by the path exec'd: still qemu-system-aarch64,
  though the emulator ran); a bundle inside the emulator directory did rename the
  process but left two tiles; the script first failed with `dyld: Library not loaded:
  @rpath/libandroid-emu-tracing` because macOS strips `DYLD_*` from the environment
  when it runs a system binary such as /bin/sh, and the launcher passes its libraries
  in `DYLD_LIBRARY_PATH`; the script sets that path again from
  `ANDROID_EMULATOR_LAUNCHER_DIR` (`lib64/qt/lib`, `lib64/vulkan`, `lib64/gles_angle`,
  `lib64`). Signing: the app is signed ad hoc without `--deep`, each helper on its own
  and the emulator copy with its original entitlements (`app_sign`), because a deep
  signature would strip the hypervisor entitlement and the emulator would not start.
  Two more things measured on the way: (1) with all that in place the Dock tile still
  showed the emulator's own picture, Android on a device, because the emulator hands
  Qt a window icon at start (`skin_winsys_set_window_icon`), which on macOS sets the
  Dock tile at run time over the bundle's icon. The picture is three PNGs compiled
  into the binary, `emulator_icon_32/128/256.png`, found by name in a table; the slots
  are too small for ATAK's art (7.5 KB for 256 px), so the retitle pass zeroes the
  first signature byte of each (each is the only PNG of its size in the binary): the
  pixmap fails to load, the QIcon is null, Qt sets nothing, and the Dock keeps the
  app's icon. Misspelling the Qt resource name `:/all/android_studio_icon`, the first
  guess, changed nothing on the MacBook: that is a different picture, so it is patched
  no more. (2) `app_dock_add` pinned the app again on every build, four
  tiles on the MacBook, because the Dock stores the path URL-encoded (`%20`) and the
  check looked for the plain path; it now walks the tiles by index through
  `defaults export`, PlistBuddy and `defaults import`, removes every TAKwerx tile and
  appends one, with `tile-type = file-tile` so it recognises its own tile next time.

## 2026-09-26, laptop night: what the MacBook found that the Studio had not

First full run on a 16 GiB M2 Pro MacBook Pro (2864x1838 at 400 dpi). Everything below
was measured there over SSH while the operator used it.

- **A 4 GiB guest is starved.** At a quarter of host memory the MacBook's Android had
  4096 MiB: 526 MiB free and swap in use with ATAK and the stock Google apps up, then
  `am_low_memory`, and at 21:40 the display stack restarted (init sent SIGTERM to the
  gralloc, camera and GNSS HALs and killed surfaceflinger, taking zygote and ATAK with
  it), a few seconds after SystemUI's ANGLE logged `createPipeline` failing with
  `VK_ERROR_INITIALIZATION_FAILED` (-3). Guest RAM is now a third of the host, 4 to
  8 GiB, and takwerx re-applies the sizing to an existing AVD on every start.
- **Google tiles slow to fill on the MacBook: not the network.** Measured from inside
  the guest against the host clock: ten TCP connects to Google's tile host in 0.11 s,
  ten to the host loopback in the same, and the host itself fetches a tile in 0.13 s.
  `time nc` inside the guest reads ~0.9 s per fetch only because nc waits for the
  server's close; ignore it. The guest clock is fine (`sleep 1` measures 1.03 s), but
  ping's rtt prints garbage through slirp (every reply arrives as seq 0) and a `ping -c3`
  never ends: never wait on it. IPv6 in the guest is dead (100% loss to 2001:4860::8888
  though the host has IPv6), but netstat showed only IPv4 sockets to Google, so nothing
  waits on it. The tile stalls line up with the memory starvation above (`Long monitor
  contention` of 100 to 460 ms on the tile cache while the guest swapped); verify after
  the RAM change before looking further.
- **Toasts as an empty pill: SystemUI's theme, not ATAK's.** ATAK targets API 35, so
  its toasts are text toasts drawn by SystemUI. SystemUI keeps the theme it started
  with: `cmd uimode night yes` applied after boot left the toast pill and text in
  mismatched modes until SystemUI restarted (after the display-stack restart the same
  toast, "Auto Map Select On", drew correctly: dark pill, white text, ATAK icon).
  Provisioning now restarts SystemUI when it switches the mode; later boots start dark.
- **Esri's sign-in page in a WebView ignored every click.** Cursorwerx re-issues the
  emulator's tablet presses as touchscreen-sourced events with the mouse tool type, which
  is what an EditText needs to focus; a WebView (Chromium) drops that combination
  (`handled=false`). Cursorwerx now hit-tests on DOWN, looking through its own pointer
  shroud, and sends a press over a WebView as a finger. Sign-in and "Show password" work.
- **Play services floods the system log; it is off now.** `AppOps: Could not forward
  noteOp of 108 (FINE_LOCATION_SOURCE) to com.google.android.gms/fused_location_provider`
  and the same for `network_location_provider`, a 15-line stack trace each, on both
  Macs. GMS's two location providers hold PASSIVE listeners with no minimum interval, so
  every GNSS fix (ATAK asks for one a second; the HAL emits three) is noted against GMS,
  and the async-noted callback of a GMS process that has since restarted fails with
  `DeadObjectException`. `am force-stop com.google.android.gms` silences it for minutes;
  `appops set ... FINE_LOCATION_SOURCE ignore` does not take. `pm disable-user` on
  `com.google.android.gms` ends it: the MacBook's log went from 3060 lines per 10 s to
  66, the flood to zero, 140 MiB freed, ATAK's GPS fix time still advancing (the GNSS
  service is Android's, not GMS's), Chrome still opening pages with no dialog, one
  `GoogleApiAvailability: ConnectionResult=3` warning at Chrome start. Lost: signing
  into a Google account inside Chrome. GMS is first in `EMU_TRIM_APPS`; take it out of
  the list in the config to keep it. One follow-on: "Enable Google Play services.
  Settings Services won't work unless you enable Google Play services", a notification
  from `com.google.android.settings.intelligence` (Google's Settings suggestions), so
  that package is trimmed too.
- **SystemUI must restart after provisioning, every boot.** It starts before takwerx
  can set ANGLE's `warmUpPipelineCacheAtLink` override (a debug property, gone at each
  boot), and without it HWUI's shaders fail to compile on MoltenVK: `skia: Shader
  compilation error` plus libEGL, 70 lines a second, and the same `createPipeline`
  failure preceded the MacBook's display-stack restart. Restarting SystemUI after the
  override took it to zero on the Studio. The restart also settles the toast theme
  (above), so provisioning now always kills SystemUI after the override and the
  dark-mode switch: two seconds of status bar at boot, before ATAK is launched. What is
  left in a quiet log: ATAK's own `MapGroupHierarchyListItem` (26 lines a second while
  the overlay list is open) and the GNSS HAL's debug lines (4 a second).
- **The stock Google apps are off; Chrome stays.** The operator wants only Chrome in
  the dock. Provisioning now `pm disable-user`s Gmail, YouTube, YouTube Music, Photos,
  Messages, Phone, the Google app, Wellbeing, Maps, Docs, Calendar, Contacts, Clock,
  System Intelligence (both packages) and Android Auto (`EMU_TRIM_APPS`, overridable),
  then restarts the launcher, without which the taskbar keeps showing the old dock.
  After the guest RAM change and the trim the MacBook reports 1.2 GiB free instead of
  0.5; the operator: "much faster on the tiles". With System Intelligence off the taskbar
  shows only the pinned Chrome and the app in use. Files (documentsui), TTS and Play
  services stay: ATAK's import picker, its speech, and Chrome sign-in use them. Chrome
  is there for one job, the operator says: TAK Portal's "open in app", which hands the
  server enrolment to ATAK over its `tak:` scheme. Checked after the trim: Chrome is
  still the default browser and ATAK still claims `tak` and `content` links.
- **Chrome flashed black on the guest-ANGLE emulator: its GPU process in a crash loop.**
  Opening TAK Portal, Chrome's content area stayed black and flickered. Its GPU process
  logged `Failed to create android native fence sync object`, `Unable to initialize
  SkSurface`, then `context is marked as lost` and exited (exit code 0): 47 restarts in
  100 s on the MacBook, 6 in 20 s on the Studio. The guest ANGLE on gfxstream has no
  working `EGL_ANDROID_native_fence_sync` for Chrome's SurfaceControl path (the GPU
  process also logs `Failed to open rendernode`). Fixed by
  `chrome --disable-features=AndroidSurfaceControl` in
  `/data/local/tmp/chrome-command-line`, which Chrome honours on this debuggable image:
  zero crashes, pages render, and the portal's sign-in page came up on the MacBook.
  Provisioning writes the file on every boot. `--disable-gpu-compositing` and
  `--disable-gpu` were the fallbacks and were not needed. ATAK's WebView (Esri sign-in)
  never had the problem: in-process, no SurfaceControl. With the flag, the whole TAK
  Portal flow ran on the MacBook at 22:11: Chrome's "open in app" fired
  `tak://com.atakmap.app/...` into ATAK (BROWSABLE VIEW intent), ATAK enrolled, connected
  to the server on 8089 over SSL, negotiated protocol, and pulled version (5.8.84),
  groups and contacts over 8443 within a second.
- **A crash-restart of ATAK does not ask "load plugins?" here**: after the display stack
  restart, `am start` brought ATAK back with every plugin loaded and no dialog.

## 2026-09-26, late: the runtime installs itself. Proven in an empty root on this Mac

`takwerx init` now fetches Google's emulator (37.1.11, build 15917651) and the Android 14
google_apis arm64 image (r14) from `dl.google.com/android/repository` at the sha1s the
repository XML publishes, and MoltenVK 1.4.2 from its GitHub release, writes the AVD by
hand (no Java, no avdmanager), and asks once for Google's SDK licence. Tested with
`TAKWERX_ROOT=~/takwerx-fresh`: 37 s from cached archives to a booted Android 14 on the
GPU, ATAK installed, every provisioning step applied, first-run EULA over the TAKwerx
splash. Found only on a fresh device:

- **The emulator refuses an SDK root with no `platform-tools` directory** ("Broken AVD
  system path"). It wants adb there; a symlink to scrcpy's adb satisfies it.
- **`have=$(adb_sh md5sum missing-file | cut ...)` ends `takwerx up` under `set -e`**: a
  failing command substitution in an assignment is fatal, and the splash file does not
  exist yet on a fresh device. `|| true`.
- **First boot of the image takes ~25 s**, not minutes; the encrypted userdata is created
  from the image's on the fly.
- **The emulator is the default runtime on Apple Silicon** (`RUNTIME_DEFAULT`): no VM, no
  admin password, no Homebrew. redroid remains for other hosts and multicast.
- Not exercised end to end here: `takwerx init` itself with `app_build` and `path_setup`,
  because on this Mac they would repoint the bench's app icon and PATH. The MacBook is the
  first full run.

## 2026-09-26, night: the GPU emulator is a takwerx runtime. Every setting below was measured

The product is **TAKwerx ATAK Terminal**. `takwerx runtime emulator`, then `takwerx up|down|restart` and the ATAK icon work as before;
`lib/emulator.sh`. The operator's verdict at the machine, on the final build: "fucking
nailed it". What it does and why, each one a separate hour:

- **A private copy of the SDK's emulator** in `~/.takwerx/tools/emulator` (APFS clone),
  with Homebrew's Vulkan drivers dropped over the bundled ones, because the emulator loads
  `lib64/vulkan/<driver>.dylib` by file name and ignores the ICD json. Rebuilt when the
  emulator, molten-vk or mesa version changes (`.version`).
- **MoltenVK 1.4.2 by default, not KosmicKrisp.** KosmicKrisp 26.2.3 is faster (41-53 fps
  busy view) but lost its GPU fences under a few minutes of heavy zooming, every time:
  gfxstream logs `pending waitables ... taking more than 1000 milliseconds` then aborts on
  `vkQueueWaitIdle ... VK_TIMEOUT`. Reproduced without the operator (wheel bursts over gRPC,
  `-grpc 8554`), in 3-10 minutes, across every feature-flag combination tried
  (`-VulkanVirtualQueue`, `ANDROID_EMU_VK_DISABLE_DEFERRED_COMMANDS`,
  `-VulkanNativeSwapchain`). MoltenVK 1.4.2 (Homebrew) ran the same stress 10 minutes clean
  at 25-44 fps. The bundled MoltenVK 1.4.0 cannot build ANGLE's pipelines at all.
- **One ANGLE feature must be off for ATAK to start on MoltenVK:** its pipeline warm-up at
  link builds placeholder pipelines with float attributes for ATAK's integer ones, Metal
  refuses (`uint2 cannot be read using MTLAttributeFormatFloat4`), the link fails and ATAK
  aborts in `AntiAliasedLinesShader`. `setprop debug.angle.feature_overrides_disabled
  warmUpPipelineCacheAtLink` from a root shell after boot, before ATAK starts. The boot
  property the emulator offers for this (`-feature`/`androidboot.hardware.angle_*`) does not
  reach ANGLE; `-prop` does not either. So the image must allow `adb root` (google_apis).
- **`-feature VirtioTablet` makes the Mac pointer a real mouse in Android**: hover, the
  wheel as ACTION_SCROLL, buttons. Without it every mouse action is a synthetic finger and
  the wheel pans. Android classes the tablet as MOUSE|STYLUS, tool type STYLUS, and three
  things follow, each fixed where it can be:
  - a press from it never focuses a text field (Cursorwerx re-issues every tablet press as
    touchscreen-sourced, see its `ClickRepair`; measured, not reasoned);
  - Android 14 offers stylus handwriting over every text field, a floating icon under the
    cursor (`settings put secure stylus_handwriting_enabled 0`, in provisioning);
  - Android draws its own cursor under the Mac's, plus a hand over ATAK's toolbar buttons
    (Cursorwerx hides it: window icon none, and a transparent shroud over the content).
- **ATAK's main window has no text input after a fresh start** until it is sent home and
  back once: the hand-over from its "ATAK Loading" window drops the focus report ("Unknown
  focus tokens, dropping reportFocusChanged"). `takwerx up` does that bounce after launch.
- **Android's screen is sized to the main display's usable area** less the title bar and
  side toolbar (3360x1380 here), 200 dpi over a physical 150: a maximized window is 1:1 and
  a smaller one scales down, since the emulator cannot follow a free resize (presets only).
  At the old 2560x1440 a window dragged to 1656x932 showed ATAK at 65%.
- **The window title** is one format string in the qemu binary, `%s Emulator - %s:%d`,
  overwritten in the copy with `TAKwerx ATAK Terminal`. That is two characters longer than
  the slot, so it runs into the next string, `%s: %dx%d\n`, a debug-only log format that
  becomes `l`; printf ignores arguments a format does not use. The binary is then re-signed
  ad hoc with the entitlements it had: never Google's signed binary again, and macOS may
  ask once. The name went Viewer -> Terminal the same evening.
- **Resizing the window while ATAK runs can freeze it.** ATAK "isn't responding" at 16:59:
  its GL thread stuck in `BufferQueueProducer::dequeueBuffer` under
  `vkAcquireNextImageKHR`, the UI thread waiting on it in `GLThread.onWindowResize`, after
  the emulator had rebuilt its window swapchain 113 times at sizes down to 1251x514 as the
  window was dragged about. The two KosmicKrisp aborts earlier also came right after
  swapchain rebuilds. A second stall at 17:34, same stacks, came with **no** rebuild since
  the first, so resizing is not the trigger; the presentation path stalls on its own after
  30-40 minutes of use, on MoltenVK as this stall and on KosmicKrisp as the fence abort.
  `-feature -VulkanNativeSwapchain` was tried the same evening: stalled again after 28
  minutes, this time with ATAK's UI thread in `ThreadedRenderer_syncAndDrawFrame`, so the
  host swapchain is not it either. The display-sleep case (18:55) was separate and is
  handled by keeping the display awake. Recovery is a restart of ATAK only; `takwerx atak`
  does it, and `takwerx up` runs a watchdog that does it on ATAK's ANR.
- **The likely root: a flood of failed Metal pipeline compiles.** MoltenVK logs
  `Vertex attribute m_14(2) of type uint2 cannot be read using MTLAttributeFormatFloat4`
  at 4-13 a second while the map sits idle (0 while panning, 0 with ATAK hidden), 22,756
  in the 30 minutes before one stall. The only integer vertex input in ATAK's shaders is
  `in int a_pattern` in `BatchGeometryAntiAliasedLines.vert`; when a batch draws with
  that attribute array disabled, ANGLE feeds its float default, Metal rejects the
  pipeline, the failure is not cached, and ATAK's idle re-batching retries it every
  frame. ANGLE overrides tried, failures per 30 s idle on DOME: baseline 231,
  `supportsVertexInputDynamicState` 114, `-supportsGraphicsPipelineLibrary` 38,
  `preferMonolithicPipelinesOverLibraries` 163 -- single samples, none near zero, so no
  knob. KosmicKrisp does not log these but has its own fence aborts. Lead left: the
  Android 15 image ships a newer ANGLE, which may convert a mismatched default attribute
  instead of failing; the operator's `atakgpu` AVD (android-35) can test it.
- **A clean stop is ATAK's QUITAPP, `sync`, then `reboot -p`**; the emulator exits by
  itself in ~4 s. `adb emu kill` is a pulled plug and cost Feature Layer its layer list.
- **The splash is ATAK's own supported one:** `atak/support/atak_splash.png` (under
  4096 px a side, full-screen centre-crop), pushed by provisioning from
  `assets/atak_splash.png` when its md5 differs. Nothing in ATAK is modified. The SDK docs
  say nothing about the size; ATAK's own art is 1280x720.
- **The position** is `adb emu geo fix` from the Mac's location at every start. A moving
  host (a vehicle) needs the GPS's NMEA forwarded live (`emu geo nmea`, at the module's
  rate, 1-10 Hz); not built, and Windows, where such a host would be, is not built either.
- **scrcpy can mirror the emulator** (40 fps in the busy view, 20-28 fps encode) but is not
  needed: the emulator's own window is the product now, with the Mac keyboard and mouse.
- **Not done:** takwerx does not install the SDK, the system image or the AVD yet (the
  operator's `atak34` is used); the Feature Layer save fix is parked in its repo's stash.

## 2026-09-26, evening: the speed cost was the emulator's KosmicKrisp. Mesa 26.2.3's runs at 41 fps

The entry below measured the label fix at 11 fps in a busy view. The cause was the
KosmicKrisp build the emulator bundles (`Apple-26.1.99`, a Mesa 26.1 development
snapshot): each frame took 116-132 ms from queueBuffer to its GPU fence. Homebrew's
`mesa` 26.2.3 ships KosmicKrisp too, and with it the same view runs at **41 fps**, queued
-> GPU done 8 ms. Same flags, same ATAK, same view:

| KosmicKrisp | busy DOME view | empty globe | frame latency |
|---|---|---|---|
| emulator's bundled 26.1.99 | 11 fps | 24 | 120 ms |
| Homebrew mesa 26.2.3 | **41 fps** | ~50 | 8 ms |
| (`-gpu host`, squashed labels) | 43 fps | 46 | -- |
| (redroid, same view, measured today) | ~2 fps | -- | -- |

- **How it is wired, for now:** the emulator ignores `library_path` in
  `lib64/vulkan/libkosmickrisp_icd.json` and loads `lib64/vulkan/libvulkan_kosmickrisp.dylib`
  by name. So that file is moved aside to `.takwerx-orig` and replaced by a symlink to
  `/opt/homebrew/opt/mesa/lib/libvulkan_kosmickrisp.dylib` (`brew install mesa`). Verified
  with `lsof` on the qemu process and the guest's GLES string (`Apple-26.2.3`).
- **That is a hand edit inside a Homebrew-managed SDK**, undone by any emulator update.
  It belongs in takwerx: its GPU-emulator launcher should own a private copy or re-link
  on every start, and check the driver version it got.
- **redroid is not the fallback it was assumed to be.** In this busy view it is ~2 fps
  (SwiftShader), 2.4 with the PBO-cull option; the "~22 fps" figure was from a light map.
- **Stopping the emulator for a restart truncates Feature Layer's `layers.json`** even
  after `adb shell sync`: the stop makes ATAK save, and the power cut lands mid-write.
  `am force-stop com.atakmap.app.civ` first avoids it. The fix is Feature Layer's.

## 2026-09-26, later: labels fixed on the GPU, via guest ANGLE on KosmicKrisp -- at a speed cost

The 64 px cap below is gone, for every plugin at once, with no plugin changed. Operator,
at the machine, with Feature Layer's labels up: "fuck yeah you did it". Step 5 of the
recipe (next entry down) becomes:

    ANDROID_EMU_VK_SELECT_ICD=kosmickrisp \
      emulator -avd atak34 -port 5574 -gpu host -feature Vulkan,GuestAngle -no-snapshot

    GLES: Google Inc. (Apple), ANGLE (Apple, Vulkan 1.3.0 (Apple M2 Max (0x00000064)),
          Apple-26.1.99), OpenGL ES 3.1.0 (ANGLE 2.1.24303 git hash: 54447ed6f702)

- **What it is.** Android's GLES is ANGLE inside the guest; its Vulkan crosses to the
  host through gfxstream; the host runs that Vulkan on **KosmicKrisp**, Mesa's
  Vulkan-on-Metal driver, which emulator 37.1.11 ships in `lib64/vulkan/` beside
  MoltenVK. No Apple OpenGL anywhere in the path, so no 64 px point sprites.
- **Why the same flags failed before:** the default Vulkan driver is MoltenVK, and on it
  ANGLE fails to build pipelines (`createPipeline: Internal Vulkan error (-3)`) and ATAK
  aborts in `AntiAliasedLinesShader`. On KosmicKrisp: no Vulkan errors, ATAK up.
- **The env var only works in host mode.** The emulator logs
  `Setting ICD from envvar ANDROID_EMU_VK_SELECT_ICD, to 'kosmickrisp'`. Accepted values,
  from the binary: `swiftshader`, `lavapipe`, `moltenvk`, `kosmickrisp`; anything else
  falls back to MoltenVK. It must be in the emulator's own environment, so it goes in
  the script Terminal.app runs.
- **Dead ends tried the same day:** `-feature ForceANGLE` makes the emulator pick
  `vulkan_mode_selected:swiftshader gles_mode_selected:swangle` and ignores both
  `ANGLE_DEFAULT_PLATFORM=metal` and the ICD variable: always software.
- **Cost: speed, measured.** Same view (Feature Layer "Go to" on a 1,027-feature NIFS
  layer, 20 km scale), same pan benchmark, emulator restarted between runs:

  | Setup | Labels | DOME view | Empty globe |
  |---|---|---|---|
  | `-gpu host` (Apple GL) | squashed to 64 px | **43 fps** | 46 |
  | guest ANGLE on KosmicKrisp | full size | **11 fps** | 24 |
  | redroid (SwiftShader), earlier | full size | ~22 fps | -- |

  So the fix is slower than redroid in a busy view. Boot is also slower, 20-76 s.
- **Where the time goes.** Not the Mac: gfxstream's render threads sit waiting for the
  guest, KosmicKrisp's own work is a few percent. Not pixels: 1920x1080 instead of
  2560x1440 gains 10%. From queueBuffer to the GPU fence signalling takes 116-132 ms a
  frame, i.e. per-draw-call cost through guest ANGLE -> gfxstream Vulkan -> KosmicKrisp.
  ATAK is draw-call heavy.
- **One real gain: `mapengine.glmapview.use-pbo-cull=0`** in
  `/sdcard/atak/devopts.properties`. ATAK culls terrain tiles on the GPU and maps a PBO
  to read the result back every frame; under ANGLE that `glMapBufferRange` is a full
  `vkWaitForFences` round trip (seen in `debuggerd -b` stacks,
  `GLGlobe::cullTerrainTiles_pbo`). The option selects `cullTerrainTiles_cpu`, which
  ATAK's own Apple build always uses (`#ifndef __APPLE__` in `GLGlobe.cpp`). Globe 16 ->
  21-24 fps; the busy view barely moves.
- **Tried, no gain:** `-VulkanNativeSwapchain`; `VulkanBatchedDescriptorSetUpdate` +
  `VirtioGpuNativeSync` (+1-2 fps).
- **Tried, dead:** host-side ANGLE on a real GPU. `ForceANGLE` loads ANGLE's bundled
  SwiftShader through `lib64/gles_angle/vk_swiftshader_icd.json`; pointing that file at
  KosmicKrisp works (`ANGLE (Apple, Vulkan 1.3.348 (Apple M2 Max), KosmicKrisp)`) but is
  no faster (DOME 9 fps, globe 12). Pointing it at MoltenVK crashes the emulator at
  start, with or without the portability flag. Stock file restored.
- **ATAK draws feature icons only as point sprites** (`batchDrawPoints` in
  `GLBatchGeometryRenderer4.cpp`, `GL_PROGRAM_POINT_SIZE`, no quad path or option), so
  on `-gpu host` the 64 px cap cannot be configured away.
- **Not re-tested:** whether `/sdcard/atak/opengl.broken` is still needed. It was for
  the Metal translator's missing stencil config; ANGLE publishes one. Left in place.
- **Hard-killing the emulator (`adb emu kill`) is a power pull.** Feature Layer's
  `layers.json` was left 0 bytes mid-write and it started with no layers, logging
  "state restore failed" without trying `layers.json.bak` (which was intact). `adb shell
  sync` before a kill. The non-atomic write is a Feature Layer bug, same family as the
  0-byte icon PNGs.

## 2026-09-26: why labels are tiny on the GPU emulator -- a 64 px cap, measured

The AVD recipe below is fast but labelled markers render at about 0.6x and feature labels
become specks. Settings are not the cause; the migration of redroid's prefs proved that.

- **Apple's OpenGL caps point sprites at 64 px.** Queried on this Mac with a CGL 3.2 core
  context: `renderer: Apple M2 Max / GL_POINT_SIZE_RANGE: 1..64`. The AVD's `-gpu host`
  path translates GLES to that driver.
- **ATAK draws every map icon as a point sprite.** The live 5.8 renderer is native:
  `renderer/feature/BatchGeometryPoints.vert` sets
  `gl_PointSize = (pointSize*rotPad) + hitTestRadius` with no query of the maximum and no
  fallback. Plain icons (~26 px) fit; Feature Layer's labelled composites (a DART callsign
  bakes to 178x65) are clamped to 64 and the text inside shrinks with them. ATAK's own text
  labels are drawn as quads and are unaffected -- "DIV A", "Hazard Tree" read fine.
  redroid is SwiftShader, which has no such cap. That is the whole difference.
- **Dead end: `mapengine.glbatchgeometryrenderer.force-points-render-batch=1`** in
  `/sdcard/atak/devopts.properties` (ATAK copies `mapengine.*` keys into ConfigOptions).
  No effect: it is read by the Java `GLBatchPoint` path, deprecated since 5.3.
- **Dead end, for now: `-feature Vulkan,GuestAngle`.** Gives `ANGLE (Apple, Vulkan 1.3.0
  (Apple M2 Max)), OpenGL ES 3.1` -- real GPU through MoltenVK, where Metal's limit is 511 --
  but ANGLE fails to build some Vulkan pipelines (`vk_cache_utils.cpp createPipeline:
  Internal Vulkan error (-3)`, seen from skia too) and ATAK aborts at
  `GLBatchGeometryShaders.cpp:228 AntiAliasedLinesShader ... code == TE_Ok`. Re-test when
  the emulator moves past 37.1.11.
- **Also found: physical DPI.** ATAK's engine DPI is
  `min(sqrt(xdpi*ydpi), densityDpi)` (`AtakMapView`). redroid was booted at 150 and
  overridden to 200, so its map ran at 150. The AVD now matches: `hw.lcd.density=150`,
  then `adb shell wm density 200` after boot. Basemap text grew; the 64 px cap is separate.
- **The fix belongs in the runtime, not in plugins.** Baking labels into icons is how
  every TAKWERX plugin labels (Atmosphere's station pills are two lines in several colors,
  which an ATAK text label cannot draw at all), and phones and redroid have no cap. Next
  lead: the emulator's bundled ANGLE has a Metal backend and reads
  `ANGLE_DEFAULT_PLATFORM`; Metal's point limit is 511. Handoff in the notes repo,
  `HANDOFF-2026-09-26-featurelayer-gpu-labels.md`.

## 2026-09-22, night: the recipe. ATAK on the Apple GPU, measured at 2x redroid

Working end to end, operator's words "working very well". The full recipe, because every
one of these five lines was a separate hour:

    # 1. an arm64 AVD -- android-34 google_apis (35 also works)
    avdmanager create avd -n atak34 -k "system-images;android-34;google_apis;arm64-v8a"

    # 2. config.ini -- all three matter
    hw.gpu.mode=host     # NOT swiftshader_indirect, which is the default and is software
    hw.keyboard=yes      # default 'no' silently ignores the physical keyboard
    hw.mainKeys=no       # 'yes' means "device has hardware Back/Home", so no nav bar is drawn

    # 3. the one that unlocks it
    adb shell touch /sdcard/atak/opengl.broken

    # 4. Android's own suppression of the on-screen keyboard
    adb shell settings put secure show_ime_with_hard_keyboard 0

    # 4b. layout room. dp = px * 160 / dpi, and dp is what ATAK's toolbar counts in.
    #     A stock phone profile at 1920x1200 @ 200 dpi is 1536x960 dp and drops toolbar
    #     slots; at 150 dpi the same pixels give 2048x1280 dp, matching the redroid
    #     tablet preset. `wm density 150` applies live; pin hw.lcd.density=150 to keep it.
    #     Watch for duplicate hw.lcd.* keys -- appending to config.ini does not replace
    #     the device profile's lines, and the last one wins.

    # 5. run it
    emulator -avd atak34 -port 5574 -gpu host

- **Measured: 45.8 fps** on an empty map against redroid's 22-25 at best, and 2.9 with
  feature labels. `GLES: Google (Apple), Android Emulator OpenGL ES Translator
  (Apple M2 Max), OpenGL ES 3.0 (4.1 Metal - 90.5)`.
- **Dev ATAK plus debug plugins load normally.** `atak.apk` from the SDK, then the debug
  APKs, then `shouldLoad-<pkg>=true` in ATAK's prefs. TAKwerx Market and Feature Layer
  both LOADED on the first try.
- **What the AVD gives for free that redroid needed work for:** a real hardware keyboard,
  a working nav bar with Back (ATAK's own faux nav bar is broken on Android 14 and
  irrelevant here), and pointer input straight from the host.
- **What it gives up:** the scrcpy bindings (`Shift+right-click` for Back and friends) are
  gone with scrcpy, and the emulator is behind user-mode NAT -- no LAN address, no
  multicast. TAK Server over TLS is unaffected. So this is a **second mode**, not a
  replacement: AVD when the map matters, redroid when LAN presence does.
- Open: whether Cursorwerx is still needed here. Much of what it fixes was 3 fps rather
  than gesture logic, and the AVD may not need it. Test before installing.

## 2026-09-22, night: the native Android Emulator has the GPU, and ATAK will not run on it

A proposal arrived to drop redroid and run Google's Android Emulator natively on macOS,
on the grounds that it reaches the Apple GPU without a VM in the way. The first half is
true. The second half is where it dies.

- **The AVD really does get the Apple GPU.** `-gpu host` on an arm64 image reports, from
  inside Android: `GLES: Google (Apple), Android Emulator OpenGL ES Translator (Apple
  M2 Max), OpenGL ES 3.0 (4.1 Metal - 90.5)`. Boot is about 14 seconds and ATAK installs
  in 10. Against redroid's `ANGLE (SwiftShader Device)` this is the real thing.
- **ATAK crashes on it before drawing a frame.** `FATAL EXCEPTION: GLThread /
  java.lang.IllegalArgumentException: No config chosen`, from
  `GLSurfaceView$BaseConfigChooser.chooseConfig`. Reproduced on android-34 and android-35,
  `google_apis`, `-gpu host` and `-gpu guest`.
- **The reason is one attribute.** `GLMapSurface.setConfigChooser` asks for
  `EGL_BUFFER_SIZE 16, EGL_DEPTH_SIZE 8, EGL_STENCIL_SIZE 1`. The Metal GL translator
  offers no config with a stencil buffer, so `eglChooseConfig` returns nothing and ATAK
  dies. It also caps at OpenGL ES 3.0.
- **ATAK runs fine under ANGLE**, which publishes a full config set and ES 3.1:
  `-gpu swangle` boots ATAK with no crash. That isolates it -- the problem is the
  translator's config list, not ATAK, not the image, not the emulator.
- **But ANGLE on this emulator is always backed by SwiftShader.** `-gpu swangle` says so
  outright, and `-gpu host -feature ForceANGLE` still comes up
  `ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device))`. There is no ANGLE-on-Metal mode:
  `-help-gpu` lists only `auto`, `host`, `swiftshader`, `swangle`.
- **Solved. ATAK ships the switch, and it is a touch file.** `MapView.initGLSurface`:

      if (IOProviderFactory.exists(FileSystemUtils.getItem("opengl.broken")))
          System.setProperty("USE_GENERIC_EGL_CONFIG", "true");

  and `GLMapSurface` then asks for `setEGLConfigChooser(8, 8, 8, 8, 16, 0)` -- **stencil
  zero** -- which the Metal translator does provide. So:

      adb shell touch /sdcard/atak/opengl.broken

  **Verified 2026-09-22:** with that file present and `-gpu host`, ATAK 5.8.0.3 runs on
  `Apple M2 Max / 4.1 Metal` with zero `No config chosen` crashes -- full UI, toolbar,
  globe rendering, GPS fix. The comment beside the fallback path reads "Required for EGL
  compatibility with the emulator", so TAK anticipated exactly this. No code change, no
  rebuild, nothing to ask the TAK Product Center for.
- The name is misleading and cost an hour: nothing is broken about the GPU. The file only
  selects a less demanding EGL config. Do not read `opengl.broken` as a diagnosis.
- Incidental: the `google_apis` images ship Chrome, and the emulator's own `-gpu` default
  on a stock AVD is `swiftshader_indirect` -- the existing `atak58` AVD on this machine
  had been measured on software rendering without anyone noticing.

## 2026-09-22, evening: the GPU spike, run properly. It gets further than the notes say, and still fails

Panning ATAK at the operator's working view measured **2.9 fps**. Labels off took it to
22.6; resolution, the frame cap and core count then changed nothing (22.5 to 22.8 fps
across a 2.6x change in pixel count, 3.8 of 7 cores busy). The per-object cost of ~600
features sets the frame rate, and SwiftShader is why. So the GPU question stopped being a
second spike and became the only remaining lever.

- **The recorded blocker is wrong and should not stop anyone again.** This file said the
  krunkit path "needs zink in redroid's Mesa build". redroid 14.0.0_64only already ships
  the whole stack: `/vendor/lib64/dri/zink_dri.so`, `virtio_gpu_dri.so`,
  `/vendor/lib64/hw/vulkan.virtio.so` (venus), `libEGL_mesa.so`, `gralloc.gbm.so`,
  `libgbm.so.1`. Nothing needs rebuilding on the Android side.
- **krunkit does give a Linux guest a GPU, which `vz` cannot.** `brew tap slp/krun`,
  Lima 2.2 has the driver. The guest gets `/dev/dri/card0` and `renderD128`, virtio_gpu
  loads with `+virgl +resource_blob +host_visible +context_init`.
- **Lima never asks for one.** Its krunkit driver passes virtio-serial, virtio-blk,
  virtio-vsock and virtio-net, and no virtio-gpu, so the guest gets a stub. krunkit does
  accept `--device virtio-gpu,width=,height=` -- width and height are its only arguments
  -- and a shim on `PATH` that appends it is enough to get a real device attached.
- **It still does not work, and this is where it dies.** With a real virtio-gpu attached,
  every 3D context creation is refused: `[drm:virtio_gpu_dequeue_ctrl_func] *ERROR*
  response 0x1200 (command 0x200)`, i.e. CTX_CREATE rejected, plus `[drm] *ERROR* Failed
  to register client: -95` (EOPNOTSUPP). The venus capset is advertised but empty
  (`cap set 2: id 4, max-version 0, max-size 0`); only the virgl capsets are populated.
  Guest Mesa falls back to llvmpipe.
- **redroid does the right thing and then cannot start.** With `redroid_gpu_mode=host` and
  `/dev/dri` passed in, it flips to `ro.hardware.egl=mesa` and `ro.hardware.gralloc=gbm`
  instead of `angle`/`redroid`. zygote comes up, **SurfaceFlinger never does**, because
  there is no 3D context for it to use. Boot never completes.
- **Settled: the macOS GPU is compute-only, and this is documented, not inferred.** Podman
  Desktop's own GPU page states it outright: "the virtualized GPU (Virtio-GPU Venus) only
  supports vulkan compute shaders, **not rendering / draw**"
  (<https://podman-desktop.io/docs/podman/gpu>). That is the whole answer. The libkrun GPU
  path exists and is real -- llama.cpp reports a 40x speedup on it -- because inference is
  compute. A map is draw. ATAK gets nothing from it, and no amount of configuration
  changes that. Do not spend another evening here.
- Two dead ends found on the way, recorded so nobody repeats them: Lima's krunkit docs say
  Fedora is required rather than Ubuntu (it makes no difference -- the venus capset is
  empty on both); and the guest needs patched Mesa from `dnf copr enable slp/mesa-libkrun-vulkan`
  for venus at all, which was never worth chasing once compute-only was established.
- Homebrew's QEMU on macOS is also out: `qemu-system-aarch64 -device help` offers only
  `virtio-gpu-pci`/`virtio-gpu-device`, no `virtio-gpu-gl`, and no GL display backend.
  UTM ships its own patched build; stock brew does not.
- **So the blocker has moved, from redroid's Mesa to libkrun's virtio-gpu on macOS.**
  Measured with krunkit 1.3.2, libkrun 1.19.4, libkrunfw 5.5.0, virglrenderer 1.3.0 on
  macOS 26.5 arm64. libkrun drives the device through `rutabaga_gfx::virgl_renderer`,
  which wants a host GL context; macOS has no usable one. Re-test when krunkit or
  virglrenderer moves, and check venus rather than virgl -- an empty venus capset with a
  populated virgl one suggests venus is the path being built out.
- The test instance was a throwaway Lima VM alongside `takwerx`, deleted afterwards. The
  working VM was never touched. One driver per VM still holds: a stale `takwerx up`
  process recreated the Android container from its own in-memory copy of the engine
  mid-experiment, which is how a 60 fps change silently came back as 30.

## 2026-09-22, later still: TAK portal enrols ATAK in the container, from the container

- **The whole onboarding works inside the window, with no file ever touching the Mac.** Log
  into TAK portal in the container's own browser, click **Open in app**, and ATAK comes to
  the foreground already enrolled: certs in, `enable-channels.pref` written to
  `/sdcard/atak/config/prefs/`, Channels populated, and an SSL connection up to
  `takserver...:8089`. No data package to download, no `takwerx datapackage`, no certs
  shuttled across the host boundary.
- **The stock `org.chromium.webview_shell` is enough, and that was not obvious.** It is the
  WebView Browser Tester that ships in the redroid image, it is already the default https
  handler, and it is Chromium 125. It runs CloudTAK fine including `wss://`, and -- the part
  worth recording -- it **does** follow `intent://` links, which is what portal's "Open in
  app" fires. WebView normally ignores unknown schemes unless the host app implements
  `shouldOverrideUrlLoading`, so the expectation was that this would fail and that Firefox or
  Cromite would have to be sideloaded. It does not fail. Do not add a browser.
- **There is already a landing page.** `com.android.launcher3` (QuickstepLauncher) is
  installed and handles HOME, with a near-black wallpaper. From the window it is
  **Shift+middle-click** (scrcpy's `--mouse-bind=++++:bhsn` puts HOME on shifted middle,
  Back on shifted right, Recents on shifted 4th). Its Google search bar is dead weight --
  there are no Play Services in redroid.

## 2026-09-22, later: the VM upgraded its own kernel and lost binder

- Ubuntu's unattended-upgrades installed kernel 6.8.0-139 during the day. The next reboot
  booted it, `linux-modules-extra` existed only for 6.8.0-134, so binder and uhid could not
  load, `dev-binderfs.mount` failed with "unknown filesystem type 'binder'", and Android
  could not start. Every user would meet this after their first kernel update. Fixes:
  provisioning disables unattended-upgrades and holds the kernel metapackages (the VM is an
  appliance; `takwerx update` is the upgrade path), and `binder_ready` installs modules-extra
  for the running kernel and restarts the mount units when the module directory is missing.
- The reboot itself was forced because the VM wedged: all six vCPUs pegged, SSH login
  starving while ping and the adb relay still answered, right after Map Depot had pulled 15
  DTED cells and ATAK began rendering terrain on software GL. Android is privileged and uses
  real-time priorities, so it can starve the VM's own services. The container is now pinned
  with `--cpuset-cpus` to all cores but one. A parallel session capped the container's
  memory 1.5 GiB under the VM and raised the VM to 10 GiB for the same incident, from the
  memory side.
- Two Claude sessions drove the same VM at once for a while. Do not. One session per VM.

## 2026-09-22: Android on the LAN, verified (spike 3 closed on the Mac)

- **vmnet bridged passes a second MAC, and multicast, over Wi-Fi.** A macvlan container behind
  the VM got its own address, reached the router and the internet, was pingable from the Mac,
  and received multicast sent to 239.2.3.1:6969 from the Mac. The VM's own interface receives
  it too. This is the load-bearing assumption of the project and it holds on Apple Silicon
  over Wi-Fi (en1 on this Mac).
- **Android does no DHCP.** redroid snapshots eth0 as a static configuration at boot
  (`/vendor/bin/ipconfigstore` in `redroid.common.rc`), so the address has to exist before
  Android starts. takwerx therefore does `podman create`, `podman init`, then runs busybox
  `udhcpc` inside the container's network namespace with `nsenter`, and only then `podman start`.
  udhcpc stays resident in the VM to renew the lease. The container gets one locally
  administered MAC per install so the router keeps handing out the same address, and the DHCP
  hostname is ATAK so it is recognizable in the router's client list.
- **No netavark DHCP proxy on Ubuntu 24.04** (netavark 1.4), which is why the lease is obtained
  by hand rather than with `--ipam-driver dhcp`.
- **A bridged container is recreated on every start.** The network namespace is new each time,
  so the lease has to be redone before boot. The container is disposable; state is the volume.
- **adb never crosses the LAN from the Mac.** The first version connected adb straight to
  Android's LAN address, and macOS's Local Network privacy took it down twice: once because
  an adb server started by another app lacked the permission, then for good when a prompt was
  dismissed mid-session and every process in the tree, including Python, got `No route to
  host` while Apple's own `nc` and `ping` kept working. A remote user on AnyDesk cannot be
  expected to manage that. Now adb always uses Lima's loopback forward: in NAT mode podman
  publishes 5555 there; in bridged mode `adb-relay.py`, a systemd service in the VM, listens on
  127.0.0.1:5555 while a lease exists and pipes to the container's LAN address over
  `takwerx-shim`, a macvlan sibling interface, because a macvlan parent cannot talk to its own
  children. The shim borrows the VM's address as a /32 with a host route to the container.
  redroid's adbd has no authentication, so the iptables chain inside Android now admits only
  the VM's address. The chain must only be applied to a container that is actually on the
  LAN: on a NAT container it drops adb's own traffic, which arrives from podman's gateway.
- **8 GiB was not enough.** After about an hour of ATAK on screen, the VM logged 59 OOM
  kills in one storm, invoked by Android's software H.264 encoder (the window's video), and
  the victims included Lima's guest agent and the journal. The VM had no swap and the
  container no memory cap, so the VM's own services were fair game. Three changes: the VM
  default is now a third of the host's RAM, 4 to 12 GiB (10 GiB on this 32 GB Mac); the
  container is capped 1.5 GiB below the VM so Android's own low-memory killer trims apps
  before the VM's OOM killer reaches anything that matters; and zram swap at half of RAM
  is a pressure valve. Watch `free -m` in the VM with ATAK running; the encoder at
  2560x1440 is the biggest consumer, and a smaller display preset is the cheapest relief.
- **The VM can be found stopped after the Mac sleeps.** The window then drops with scrcpy
  exit code 2. The window's reconnect now goes through the full `android_up` path, which
  starts the VM and recreates the container if needed. Note that `limactl shell` auto-starts
  a stopped instance, so every read-only path in the engine checks `vm_running` first.
- **Every adb shell call now has a hard timeout** (perl `alarm`, since macOS has no `timeout`).
  A blackholed adb connection hung the engine once; it cannot again.
- **Sudo without a terminal.** The engine's bridged setup now also proceeds when sudo already
  holds credentials, and the sudoers file is installed 0644 so `limactl sudoers --check` can
  read it.

## 2026-09-22: first boot on Apple Silicon, what actually broke

Everything below was found by running `takwerx init` on an M-series Mac with Lima 2.2.0,
Ubuntu 24.04 (kernel 6.8.0-134-generic) and redroid 14. Each one is now handled in
`lima/takwerx.yaml.tmpl` or `lib/android.sh`.

- **Ubuntu's binder is binderfs-only.** `CONFIG_ANDROID_BINDERFS=m`, and on such kernels the
  module's `devices=` parameter creates nodes only inside a binderfs mount, never the legacy
  `/dev/binder`. Fix: a systemd mount unit for `/dev/binderfs`, and the three nodes bind-mounted
  into the container with `-v /dev/binderfs/binder:/dev/binder` and so on. Symlinks do not
  survive into podman's tmpfs `/dev`; file bind-mounts keep the binderfs inode, which the
  driver requires. Spike 2 is closed.
- **binderfs nodes are created 0600 root, and nothing inside Android can widen that.** They have
  no sysfs entries, so ueventd never touches them, and servicemanager (uid system) died with
  `Permission denied`, taking zygote and surfaceflinger into a restart loop. Fix: a oneshot
  service that chmods them 666 after the mount, plus the same chmod before every container start.
- **The regular redroid image crash-loops on Apple Silicon.** M-series CPUs cannot execute
  32-bit ARM code, so the 32-bit zygote in `14.0.0-latest` restarts forever and pinned all six
  vCPUs hard enough to kill SSH into the VM. redroid's own docs call for the `_64only` image on
  such platforms. `versions.env` now pins `14.0.0_64only-latest`.
- **ashmem is gone from kernels after 5.18.** redroid defaults to ashmem; the container runs with
  `androidboot.use_memfd=true`.
- **ATAK-CIV's package id is `com.atakmap.app.civ`**, not `com.atakmap.app`. Its launcher
  activity is `com.atakmap.app.ATAKActivityCiv`; launch it with `am start`, since `monkey`
  did nothing here.
- **scrcpy's HID keyboard needs `/dev/uhid`.** The VM must load the `uhid` module and the node
  inside the container must be chmod'ed from the VM side with `podman exec`, because adb runs
  as the shell user. scrcpy 4.1 drops the whole session when uhid fails, so the engine checks
  and falls back to the sdk keyboard.
- **First-boot numbers on this Mac:** Ubuntu image download and VM creation about 1 minute,
  provisioning about 1 minute, redroid pull about 1 minute, Android boot 30 to 60 seconds,
  ATAK 5.8 install over adb about 1 minute. Idle VM CPU with ATAK on screen: about 1 percent.
- **Bridged networking is written but not yet run.** socket_vmnet needs an admin password and
  this build was done in a session without one. `takwerx network bridged` is the command.

## 2026-09-21: platform stack

- **Podman machine rejected on every platform.** Its networking is user-mode NAT through
  gvproxy on both macOS and Windows, with no bridged option. Requirement 2 fails before
  binder comes up. Podman stays as the container runtime inside the VM.
- **Mac: Lima with the vz driver, Ubuntu 24.04 guest, socket_vmnet for bridged.** Apple's
  own hypervisor, and vmnet bridges over Wi-Fi, which Linux bridges cannot.
- **Windows: Multipass on Hyper-V for Pro and Enterprise, VirtualBox backend for Home.**
  WSL2 rejected for the product: Microsoft has not shipped binder in the stock kernel
  (microsoft/WSL#12692, open since March 2025), a custom kernel in `.wslconfig` replaces
  the kernel for every distro on the machine, and mirrored mode sends multicast but does
  not reliably receive it (microsoft/WSL discussions 10614 and 14357).
- **Linux: native podman, no VM.** The only platform with a real GPU today.
- **Ubuntu as the guest everywhere.** binder ships as a module in `linux-modules-extra`;
  `modprobe binder_linux devices=binder,hwbinder,vndbinder` creates the legacy `/dev/binder`
  nodes the stock redroid images still require (remote-android/redroid-doc#859, open).
  Kernels that build binder in, such as Fedora's, expose only binderfs.
- **Spike 6 is moot.** ATAK-CIV 5.4 and 5.8 ship x86_64 native libraries including
  `libtakengine`, `libgdal` and `libspatialite`. Only `libgnustl_shared` and `libltidsdk`
  (MrSID imagery) are arm-only. Windows and Intel Macs run the x86_64 ATAK with no
  translation layer; MrSID imagery will not load there.
- **No GPU in any VM path.** Virtualization.framework gives Linux guests 2D only; Hyper-V
  has no 3D for Linux guests. SwiftShader is the baseline. Lima's krunkit driver (Vulkan
  through venus and MoltenVK, Apple Silicon only, experimental) is the one lead, and it
  needs zink in redroid's Mesa build. Second spike, not the plan.
- **No code signing.** The one-line installer downloads with curl, which sets no
  quarantine flag, so Gatekeeper never runs. The app bundle is generated on the user's
  machine. Windows will use `irm | iex` and `Unblock-File` the same way.
- **License: AGPL-3.0-or-later**, matching infra-TAK and the TAKWERX plugins. The brief
  said "permissive"; change `LICENSE` if that was meant literally.
- **Market plugin.** Installs plugins via ACTION_VIEW on a content URI through ATAK's
  FileProvider, so ATAK's package gets the `REQUEST_INSTALL_PACKAGES` appop at
  provisioning. Market does not update ATAK itself; tak.gov requires a login.
- **Display presets.** Layout room in dp is pixels * 160 / dpi. The default `tablet`
  preset (2560x1440 at 200) gives the same toolbar width as a Galaxy Tab S11 Ultra
  (2960x1848 at 240) at two thirds of the pixels. Presets switch live via `wm size`
  and `wm density`.
- **adb exposure.** redroid's adbd has no authentication. The container publishes 5555
  on the VM's loopback only and Lima forwards only that port to 127.0.0.1 on the host.
  Bridged mode with ipvlan or macvlan will expose adbd on the LAN and needs a fix
  (iptables inside Android or `ro.adb.secure=1` with a vendored key) before it ships.
