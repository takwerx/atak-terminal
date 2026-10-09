# Changelog

Newest first. `takwerx update` brings an installed Mac to the newest release; the app
icon mentions a new release within a day of it, and so do `takwerx up` and
`takwerx status` in a terminal.

## 0.2.8 — 2026-10-09

- **Too little free disk space is now said plainly.** Google's emulator wants 12 GB free
  before it creates Android's data the first time, and with less it quit, leaving only
  "Android did not come up". takwerx now checks for that before it downloads anything and
  again before Android's first start, and says how much space is free, how much is
  needed, and where. A new install needs about 23 GB free.

**How to get it**

- **Already installed:** open Terminal on a Mac, or PowerShell on Windows, and run
  `takwerx update`. If Android is running, it restarts by itself (about a minute) and
  ATAK comes back with its data.
- **New install on a Mac** (Terminal):
  `curl -fsSL https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.sh | bash`
- **New install on Windows** (PowerShell):
  `irm https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.ps1 | iex`

## 0.2.7 — 2026-10-09

- **Mac: full screen on an external monitor is centred.** On a monitor shaped
  differently from your Mac's screen, ATAK keeps its proportions in full screen, and the
  spare width showed as one black strip on the right. The map now sits in the middle,
  with an even strip on each side. On the Mac's own screen nothing changes.

**How to get it**

- **Already installed:** open Terminal on a Mac, or PowerShell on Windows, and run
  `takwerx update`. If Android is running, it restarts by itself (about a minute) and
  ATAK comes back with its data.
- **New install on a Mac** (Terminal):
  `curl -fsSL https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.sh | bash`
- **New install on Windows** (PowerShell):
  `irm https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.ps1 | iex`

## 0.2.6 — 2026-10-09

- **Mac: the window has its title-bar buttons again.** The red, yellow and green buttons
  at the top left of the ATAK window are always there now, including after you move the
  window to another display. The green one takes ATAK full screen.

**How to get it**

- **Already installed:** open Terminal on a Mac, or PowerShell on Windows, and run
  `takwerx update`. If Android is running, it restarts by itself (about a minute) and
  ATAK comes back with its data.
- **New install on a Mac** (Terminal):
  `curl -fsSL https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.sh | bash`
- **New install on Windows** (PowerShell):
  `irm https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.ps1 | iex`

## 0.2.5 — 2026-09-30

- **Chrome no longer gets stuck on its welcome screen.** Opened for the first time,
  Chrome showed "Welcome to Chrome" and never let you continue, because that screen
  waits for Google Play services, which takwerx switches off. Chrome now skips it and
  opens straight to a tab, so TAK Portal links and anything else you open in Chrome work
  from the first time. If Chrome is stuck on that screen for you now, the update fixes
  it: after the restart, open Chrome again.

**How to get it**

- **Already installed:** open Terminal on a Mac, or PowerShell on Windows, and run
  `takwerx update`. If Android is running, it restarts by itself (about a minute) and
  ATAK comes back with its data.
- **New install on a Mac** (Terminal):
  `curl -fsSL https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.sh | bash`
- **New install on Windows** (PowerShell):
  `irm https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.ps1 | iex`

## 0.2.4 — 2026-09-29

- **ATAK opens once.** At every start, takwerx sent ATAK to Android's home screen and
  back again, so it looked as if ATAK opened, closed and opened again. That worked around
  text fields not taking typing after a start on Android 14. Android 15, which everyone
  has had since 0.2.1, does not need it, so ATAK now simply opens. If a text field ever
  ignores your typing right after a start, tell us.
- When ATAK stops responding and takwerx restarts it, it no longer does the same
  home-and-back either.

**How to get it**

- **Already installed:** open Terminal on a Mac, or PowerShell on Windows, and run
  `takwerx update`. If Android is running, it restarts by itself (about a minute) and
  ATAK comes back with its data.
- **New install on a Mac** (Terminal):
  `curl -fsSL https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.sh | bash`
- **New install on Windows** (PowerShell):
  `irm https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.ps1 | iex`

## 0.2.3 — 2026-09-29

- **Full screen.** `takwerx fullscreen on` gives ATAK the whole screen. Android restarts
  once to take the new size, and from then on ATAK opens full screen.
  - **Windows:** no title bar, side toolbar or taskbar. **F11** switches between full
    screen and a normal window. On laptops where F11 is a media key, **Ctrl+Alt+F** does
    the same.
  - **Mac:** the usual macOS full screen, with the menu bar and Dock hidden and the map
    below the notch. **Ctrl+Cmd+F** or the green button switches. The green button now
    works even with full screen off.
  - `takwerx fullscreen off` goes back to a normal window.
- **ATAK is no longer restarted over and over when a plugin makes it pause at start.**
  When Android reported ATAK as not responding, takwerx restarted it straight away. A
  plugin that holds ATAK up for a few seconds while it loads then did the same after
  every restart, so ATAK restarted every two minutes. takwerx now waits up to 30 seconds
  and leaves ATAK alone if it recovers by itself. (Seen with an older build of the
  Atmosphere plugin.)
- **Windows:** `takwerx anr` shows why ATAK last stopped responding. If ATAK freezes on
  you, send us what it prints.

**How to get it**

- **Already installed:** open Terminal on a Mac, or PowerShell on Windows, and run
  `takwerx update`. If Android is running, it restarts by itself (about a minute) and
  ATAK comes back with its data. If you skipped 0.2.1, this update also downloads
  Android 15 once (about 1.8 GB), so give it a few minutes.
- **Then, to try full screen:** `takwerx fullscreen on`
- **New install on a Mac** (Terminal):
  `curl -fsSL https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.sh | bash`
- **New install on Windows** (PowerShell):
  `irm https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.ps1 | iex`

## 0.2.2 — 2026-09-29

- **The installer checks the computer first.** Before downloading anything it checks the
  free disk space and, on Windows, the memory, the processor and the graphics chip. If
  one falls short, it says which and stops, instead of leaving you with a blank window.
  The minimums are in the README under "What you need".
- Windows: Google's Android Emulator refuses some older graphics chips, such as the
  Intel HD Graphics 520 and 620 in many 2015 to 2017 laptops, and draws Android on the
  processor instead, which is far too slow for ATAK. takwerx now says so at install,
  and stops the emulator with the same message if it happens anyway.
- Windows: when Windows Hypervisor Platform is off, the installer now says so after
  0.44 GB of downloads instead of 2.2 GB.
- Windows: pinning the window to the taskbar while Android was still starting could
  leave a pin that shows "libandroid-emu-agents.dll was not found". The window now
  takes TAKwerx ATAK Terminal's name within seconds of appearing. If you have such a pin,
  unpin it and pin the window again.
- Windows: opening the icon while ATAK was already running added one more copy of a
  background helper each time, and each copy restarted ATAK when it stopped responding.
  Now there is only ever one.

On a Mac or Windows: `takwerx update`. On Windows it restarts Android by itself (about a
minute); ATAK and its data come back.

## 0.2.1 — 2026-09-27

- **ATAK no longer freezes after 10 to 30 minutes.** Android 14's graphics in the emulator
  leaked one file handle per frame the map draws. ATAK reaches Android's limit of 32,768
  in about ten minutes, its network connections start failing well before that, and then
  it stops responding. takwerx now runs Android 15, which does not leak. Your device moves
  to Android 15 by itself at the next start after `takwerx update`, with ATAK, plugins,
  servers, certificates and maps kept. It downloads Android 15 once (about 1.7 GB), and
  that first start takes a little longer.
- `takwerx update` finishes by itself: if Android is running on what the update
  replaced, it is restarted onto the new version (a clean power-off, about a minute) and
  ATAK reopens with its data. No `takwerx restart` afterwards.
- ATAK's permissions are re-applied at every start, so ATAK does not ask for file access
  again after a restart.
- Windows: when Windows Hypervisor Platform is off, the installer explains step by step
  how to switch it on.

On a Mac or Windows: `takwerx update`. That is all; it restarts Android by itself.

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
