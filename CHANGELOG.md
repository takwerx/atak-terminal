# Changelog

Newest first. `takwerx update` brings an installed Mac to the newest release; the app
icon mentions a new release within a day of it, and so do `takwerx up` and
`takwerx status` in a terminal.

## 0.2.0 — 2026-09-27

- **Windows.** One line in PowerShell installs TAKwerx ATAK Terminal on a Windows 10 or 11
  PC with an Intel or AMD processor:
  `irm https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.ps1 | iex`.
  The same commands as on the Mac, ATAK on the PC's GPU, a Start Menu and desktop icon,
  one taskbar button with ATAK's icon. No administrator needed where Windows Hypervisor
  Platform is already on; the installer says how to switch it on where it is not.
- Map tiles load several times faster. Android's Wi-Fi no longer detours through the
  emulator's network simulator: a small request inside Android went from about 800 ms to
  about 45 ms, downloads from 3-4 MB/s to your connection's own speed.
- The app's icon is ATAK's own. With a release ATAK it never was: those APKs rename their
  image files, and takwerx fell back to its own icon.
- After ATAK's first start, ATAK asks to load the Market once you have accepted its EULA;
  before, it could be asked too early and then not ask at all.
- `takwerx plugin` restarts ATAK for real, so a plugin it installs is loaded right away.
  ATAK never received the quit takwerx sent it; `takwerx down` and `takwerx atak` now stop
  it properly too.

On a Mac: `takwerx update`, then `takwerx restart`.

## 0.1.1 — 2026-09-27

- The window no longer quits when you click "..." on its side toolbar (the emulator's
  Extended Controls). The emulator ran from inside the app since 0.1.0 and looked for
  its built-in browser in the wrong place; its Location page, with the Google map,
  works now.
- After `takwerx update`, `takwerx restart` loads the new emulator build. takwerx tells
  you when Android is still running the previous one.
- `takwerx update` and the install line fetch the newest release, not whatever is on
  the development branch, and you are told about new releases: a notification from the
  app icon within a day, a line in the terminal until you update.

## 0.1.0 — 2026-09-26

Public beta. Google's Android Emulator on the Mac's GPU as the default runtime, ATAK
from your own APK, the TAKwerx Market plugin, the app icon in Applications and the
Dock, redroid in a VM as the LAN runtime.
