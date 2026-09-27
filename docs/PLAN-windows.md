# Windows: the plan and the brief for the session that builds it

Read `CLAUDE.md`, `README.md` and the 2026-09-26 and 2026-09-27 entries of
`docs/DECISIONS.md` first. They are the spec. Nothing in them is re-derived; the
Windows work reuses every Android-side decision and ports the host side.

## Goal

The same product on Windows 10 and 11, Intel or AMD, with a GPU:

- One line in PowerShell installs it: `irm https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.ps1 | iex`
- Google's Android Emulator on the host GPU, an x86-64 Android 14 google_apis image
  (ATAK-CIV ships x86-64 native libraries; no translation).
- A Start Menu and taskbar shortcut named **TAKwerx ATAK Terminal** with ATAK's icon,
  taken from the user's APK. The emulator window carries the same title and icon.
- The ATAK APK found in Downloads by version, or a native file picker.
- The Market installed and registered after ATAK's first run; Cursorwerx from the Market.
- Position from Windows' own location service (`here`), an exact coordinate, or IP.
- No code signing, no Authenticode, no installer package. `irm | iex` and
  `Unblock-File` are the answer to Mark-of-the-Web, as curl is to quarantine.

## What carries over unchanged

Everything sent into Android: the trimmed Google apps (`EMU_TRIM_APPS`), dark mode and
the SystemUI restart, the ANGLE override, Chrome's `--disable-features=AndroidSurfaceControl`,
guest RAM a third of the host, the plugin registration after first run, the splash, the
dock pin, the window geometry rule, adb on a private server port. The AVD written by
hand. The pinned versions and checksums in `versions.env` (add the Windows emulator
and the x86-64 image there, from the same Google repository XML).

## What is ported

- The engine. `takwerx` and `lib/*.sh` are bash; Windows gets `takwerx.ps1` and a
  `lib/*.ps1` with the same commands, the same config file under `%LOCALAPPDATA%\takwerx`
  (the `~/.takwerx` of Windows), the same log lines. Emulator runtime only; no redroid, no VM.
- `lib/host-macos.sh` becomes `lib/host-windows.ps1`: tools download, shortcut instead of
  app bundle, icon from the APK (a `.ico` built from the launcher PNG), the title and icon
  patch on `qemu-system-x86_64.exe` (the strings are the same; the icon lives in the PE
  resources, so it is a resource replacement, not a PNG signature patch).
- `helpers/maclocation` becomes a PowerShell call into `Windows.Devices.Geolocation`.
- `install.ps1` beside `install.sh`. README gets a Windows section; the Mac text stays.

## Genuinely new, and measured first

Status 2026-09-27, night: built and verified on the Dell end to end, from `takwerx uninstall`
through the one line to ATAK, the Market's own load question, the icon, the taskbar button
and the splash (DECISIONS 2026-09-27, all four entries). Open: a PC without Windows
Hypervisor Platform (the installer's instructions are written, never shown to a person),
and the range-and-bearing endpoint drag under Cursorwerx. Released as 0.2.0 the same
night; `takwerx update` then verified on the Dell against that release.
`tools/windows-measure.ps1` does the measuring.

Before porting anything, on the Windows machine, by hand, in this order:

1. The hypervisor. WHPX (Windows Hypervisor Platform, an optional feature) or Google's
   AEHD driver. Both need admin once. Record which one the emulator picks, what it costs
   the user to enable, and whether the install line can enable it or must say "do this
   first". This is the one place the experience cannot match the Mac.
2. Boot the stock x86-64 image with `-gpu host` and put ATAK on it. Measure the map
   frame rate and, above all, **the label and icon size**: the 64 px point-sprite cap was
   Apple's OpenGL. Try guest ANGLE (`-feature Vulkan,GuestAngle`) on the host's own
   Vulkan driver; there is no MoltenVK here. Record the driver (NVIDIA, AMD, Intel),
   the numbers, and whether the ANGLE override is still needed.
3. VirtioTablet and the mouse. Cursorwerx was written against the emulator's tablet
   input; confirm the same sources arrive on Windows.
4. Only then port, in the order the Mac was built: install and boot, provisioning,
   ATAK and Market, the shortcut and icon, position, the update path.

## How the session works

The operator's Windows machine is reached over SSH through NetBird, PowerShell as the
SSH shell, key auth. The session runs on the Mac Studio and drives Windows over SSH,
the way the MacBook was driven. Screenshots of the guest come over adb; screenshots of
the Windows desktop need a helper (PowerShell `System.Drawing` on the console session).

Every non-obvious finding goes into `docs/DECISIONS.md` the day it is found, with the
measurement. The bash engine stays the reference; when a rule changes on one side, it
changes on both.

## Done means

A fresh Windows machine, the one line, ATAK open on the GPU at the screen's size with
readable labels, Cursorwerx from the Market, the shortcut in the taskbar, position set,
`takwerx update` working, and the README saying so. Then the beta says "Mac and Windows".
