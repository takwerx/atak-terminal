# Changelog

Newest first. `takwerx update` brings an installed Mac to the newest release; the app
icon mentions a new release within a day of it, and so do `takwerx up` and
`takwerx status` in a terminal.

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
