# TAKwerx ATAK Terminal

**Beta.** Real ATAK, the Android app with its real plugins, running in a window on
your Mac, on the Mac's GPU. Two steps install it. After that there is a
**TAKwerx ATAK Terminal** icon in Applications and the Dock, and you open it like
any other app.

1. **Download ATAK-CIV first** from [tak.gov](https://tak.gov/products/atak-civ)
   (it needs a free login). Leave the file in Downloads.
2. Paste this line in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/takwerx/takwerx-desktop/main/install.sh | bash
```

That line downloads the tool and Google's Android emulator, starts Android 14 on
your Mac's GPU, installs the ATAK APK from Downloads (or opens a file picker so you
can point at it), adds the TAKWERX Market plugin so your plugins install and update
from inside ATAK, creates the icon, and opens the window. First run takes a few
minutes and about 2 GB of downloads; it asks once to accept Google's Android SDK
terms. After that, opening ATAK takes about half a minute.

If you skipped step 1, the icon asks for the APK the first time you open it.

There is no account, no telemetry, no paid tier, and nothing is sent anywhere.
Everything runs on your own machine. The first thing you see in the window is
ATAK's EULA; that click is yours to make.

## What you need

- A Mac with Apple Silicon and macOS 13 or newer. 16 GB of memory is comfortable;
  8 GB is untested. Intel Macs use a different, slower path (see Runtimes) and are
  untested in this beta. Windows and Linux are next.
- The ATAK-CIV APK from [tak.gov](https://tak.gov/products/atak-civ). ATAK is not
  redistributed here and cannot be fetched for you; you download it once and takwerx
  installs it.
- About 12 GB of disk and an internet connection for the first run.

Nothing else. No Homebrew, no Docker, no Android Studio, no developer account.

## What works in the beta

- ATAK 5.8 with plugins, at the Mac screen's full resolution, on the GPU.
- Mouse and trackpad: the TAKwerx **Cursorwerx** plugin makes ATAK behave for a mouse
  (wheel zooms at the cursor, wheel scrolls lists and panes, click and drag pans,
  clicks land in text fields, Escape is Back). Install it from the Market.
- Position: your Mac's location, an exact coordinate, or a rough fix from your IP.
- TAK Portal "open in app": open the portal in Chrome inside Android, sign in, and
  ATAK enrols with the server. Chrome is the one Google app kept; the rest are off.
- Drag any APK from Finder onto the window to install it; ATAK offers to load a
  plugin. Drag any other file and it lands in Android's Downloads folder.

Known issues, being worked on:

- Now and then, after half an hour or more, the emulator's display stalls for a few
  seconds. If ATAK stops responding, `takwerx atak` restarts it; `takwerx restart`
  restarts Android. Nothing is lost either way.
- No multicast: Android sits behind the emulator's NAT, so TAK servers over TLS work
  and situational awareness on 239.2.3.1 does not.
- The Mac app is not code-signed. That is why the install is a Terminal line: a
  downloaded app would be blocked by Gatekeeper.

## Daily use

Open **TAKwerx ATAK Terminal** from the Dock, Applications, Launchpad or Spotlight.
Close the window when you are done; `takwerx down` stops Android completely and frees
the memory. Everything ATAK stores, server connections, certificates, map caches,
plugin settings, survives restarts and takwerx updates.

The `takwerx` command is available in any new terminal:

```
takwerx up                  start Android and open the ATAK window
takwerx down                stop Android, keep all data
takwerx restart             restart Android (keeps data)
takwerx atak                restart ATAK only
takwerx status              what is running

takwerx apk [FILE]          install or replace ATAK (newest in ~/Downloads, else a file picker)
takwerx plugin FILE.apk     install a plugin (or drag the APK onto the window)
takwerx market              install the TAKWERX Market plugin for your ATAK version
takwerx datapackage FILE    import a data package zip
takwerx app                 rebuild the app icon in Applications

takwerx display screen      Android's screen follows this Mac's display (the default)
takwerx display WxH@DPI     or a fixed size, for example 2560x1440@200
takwerx location WHERE      LAT,LON [ACCURACY_M] | here | ip | off
takwerx screenshot          save a PNG of the screen to the Desktop
takwerx shell               adb shell into Android
takwerx logs                takwerx log; --android for logcat, --container for Android's boot log
takwerx doctor              check the host and report what is missing
takwerx reset               wipe Android and start clean
takwerx update              update takwerx and its pinned tools
takwerx uninstall           remove everything
```

## Plugins

Plugins install and update from inside ATAK through the TAKWERX Market plugin, which
`init` installs to match your ATAK version. Any plugin from elsewhere: drag its APK
onto the window, or `takwerx plugin file.apk`. tak.gov's own plugin loading through
ATAK works as on a phone.

ATAK itself cannot be fetched automatically, because tak.gov requires a login.
Download the new APK, then `takwerx apk` picks up the newest one in Downloads, or
opens a file picker if there is none. Your settings and plugins stay.

## Position

There is no GPS in a Mac, so ATAK shows no location until you give it one. takwerx
feeds the position to Android's GPS, so ATAK shows a normal fix, its self marker
sits where you say, and situational awareness beacons carry a position.

```
takwerx location here            this Mac's location, the way a browser gets it
takwerx location 33.55,-117.21   an exact position, optional accuracy in metres
takwerx location ip              a rough fix from your public IP, a few km at best
takwerx location off
```

`init` sets the rough IP fix so the map opens near you. The first `here` makes macOS
ask whether the app may use your location; allow it. The position survives restarts;
change it whenever you move. On a laptop in a vehicle, `here` follows the Mac's own
location service.

## Screen and window

Android's screen is sized to your display at the start, so a maximized window is
pixel for pixel and a smaller one scales down. Dragging the window to another size
scales the same picture; `takwerx display` changes the size Android is given, which
restarts Android. ATAK lays out its toolbar from the screen size, so a bigger or
denser screen means more toolbar slots.

Chrome, and the Android app drawer, stay in Android's dock at the bottom. Everything
else Google ships in the image is switched off at install (Gmail, YouTube, Maps, Play
services and the rest). Take a package out of `EMU_TRIM_APPS` in `~/.takwerx/config`
to keep it.

## Runtimes

The default on Apple Silicon is Google's Android Emulator on the Mac's GPU
(`takwerx runtime emulator`): fast, full-size icons, no virtual machine, no admin
password. The other runtime (`takwerx runtime redroid`) runs Android in a small Linux
virtual machine with software rendering; it is slower and its map is choppy, but it
can sit on your LAN with its own address and multicast (`takwerx network bridged`),
and it is the path for Intel Macs. Both keep their own Android data.

## Where things live

| What | Where |
|---|---|
| takwerx itself | `~/.takwerx/app` |
| The emulator, Android image, tools | `~/.takwerx/tools` |
| Android's data (the AVD) | `~/.takwerx/avd`; `takwerx reset` wipes it |
| Settings | `~/.takwerx/config` |
| Logs | `~/.takwerx/logs` |
| The icon | `/Applications/TAKwerx ATAK Terminal.app` |

`takwerx uninstall` removes all of it.

## Troubleshooting

- **The window never appears.** `takwerx status`, then `takwerx logs --container`
  is the emulator's own log. `takwerx logs --android` is logcat.
- **ATAK stops responding.** `takwerx atak` restarts ATAK; `takwerx restart` restarts
  Android. Data is kept.
- **ATAK asks for permissions anyway.** `takwerx apk` again re-grants everything.
- **A plugin is installed but ATAK does not show it.** `takwerx plugin` on its APK
  again; it switches the plugin on in ATAK and restarts ATAK.
- **Start over.** `takwerx reset` wipes Android; `takwerx uninstall` then the
  install line rebuilds everything.
- **macOS asks about Terminal and Downloads, or about location.** Allow it; the
  first is for reading the ATAK APK, the second for `takwerx location here`.

## Security notes

- Android's debug bridge (adb) is reachable only from this Mac, on 127.0.0.1, through
  takwerx's own adb server. Nothing on your network can reach it.
- Android sees none of your Mac's files. Files reach it only through `takwerx apk`,
  `plugin`, `datapackage`, or a drag onto the window.
- All downloads are pinned to specific versions and checksums in `versions.env`; the
  emulator and Android image come from Google's own repository.
- The app in Applications is built on your Mac, not downloaded, and is not signed by
  Apple. The emulator inside it is Google's binary, re-signed locally because two
  strings in it are patched (the window title, and its own Dock icon).

## Status

Beta, macOS on Apple Silicon. Verified end to end on a Mac Studio (M-series, macOS 26)
and a 16 GB MacBook Pro (M2 Pro): install from scratch with the line above, ATAK 5.8
and the Market plugin, TAK Portal enrolment, plugins by Market and by drag. Intel
Macs, Windows and Linux: not yet.

Every non-obvious finding, with the reasoning and the dead ends, is in
[docs/DECISIONS.md](docs/DECISIONS.md).

## License

AGPL-3.0-or-later, the same as the other TAKWERX projects. ATAK and the ATAK name
belong to the TAK Product Center and are not part of this repository; the ATAK icon
shown on the Mac app is read from the APK you downloaded.
