# TAKwerx ATAK Terminal

**Beta.** Real ATAK, the Android app with its real plugins, running in a window on
your Mac or Windows PC, on its GPU. Two steps install it. After that there is a
**TAKwerx ATAK Terminal** icon (in Applications and the Dock on a Mac, in the Start
Menu and on the desktop on Windows), and you open it like any other app.

1. **Download ATAK-CIV first** from [tak.gov](https://tak.gov/products/atak-civ)
   (it needs a free login). Either build works, the regular one or the "small" one
   without the phone-only extras. Leave the file in Downloads; if several versions
   are there, the newest is used.
2. On a **Mac**, paste this line in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.sh | bash
```

   On **Windows**, paste this line in PowerShell (a normal window, not "as
   Administrator"):

```powershell
irm https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.ps1 | iex
```

That line downloads the tool and Google's Android emulator, starts Android 14 on
your computer's GPU, installs the ATAK APK from Downloads (or opens a file picker so you
can point at it), adds the TAKWERX Market plugin so your plugins install and update
from inside ATAK, creates the icon, and opens the window. First run takes a few
minutes and about 2 GB of downloads; it asks once to accept Google's Android SDK
terms. After that, opening ATAK takes about half a minute.

If you skipped step 1, the icon asks for the APK the first time you open it. On
Windows, right-click the window's taskbar button once and choose **Pin to taskbar**;
Windows lets no program pin itself.

**First run, in ATAK:**

1. Accept ATAK's EULA and go through its first-start questions.
2. Wait a moment: takwerx installs the TAKWERX Market plugin and ATAK asks to load
   it, or simply shows it. Say yes if asked.
3. Open the toolbar overflow (the ☰ button at the right end of the toolbar), tap
   **Market**, and install **Cursorwerx**. That is what makes the mouse and trackpad
   behave: wheel zoom at the cursor, scrolling in menus and panes, clicks in text
   fields. Install any other plugins you want the same way.

There is no account, no telemetry, no paid tier, and nothing is sent anywhere.
Everything runs on your own machine. The first thing you see in the window is
ATAK's EULA; that click is yours to make.

## What you need

- A Mac with Apple Silicon and macOS 13 or newer. 16 GB of memory is comfortable;
  8 GB is untested. Intel Macs use a different, slower path (see Runtimes) and are
  untested in this beta.
- Or a Windows 10 (2004 or newer) or Windows 11 PC with an Intel or AMD processor, a
  GPU with current drivers (NVIDIA, AMD, or Intel Arc or Iris Xe), and 16 GB of memory.
  Windows on ARM has no Android Emulator from Google. Android needs **Windows
  Hypervisor Platform**; it is already on where your IT department runs Windows'
  virtualization-based security, and then nothing needs an administrator. Where it is
  off, the installer says so and how to switch it on (an administrator, once, and a
  restart).
- Linux is next.
- The ATAK-CIV APK from [tak.gov](https://tak.gov/products/atak-civ). ATAK is not
  redistributed here and cannot be fetched for you; you download it once and takwerx
  installs it.
- About 12 GB of disk and an internet connection for the first run.

Nothing else. No Homebrew, no Docker, no Android Studio, no developer account, and
on Windows no installer package and nothing from the Microsoft Store.

## What works in the beta

- ATAK 5.7 and 5.8 with plugins, at the screen's full resolution, on the GPU: about
  58 fps on a Mac Studio, about 50 on a laptop's NVIDIA RTX 2000 and 41-44 on its
  Intel Arc.
- Mouse and trackpad: the TAKwerx **Cursorwerx** plugin makes ATAK behave for a mouse
  (wheel zooms at the cursor, wheel scrolls lists and panes, click and drag pans,
  clicks land in text fields, Escape is Back). Install it from the Market.
- Position: your computer's own location (the Mac's, or Windows' location service), an
  exact coordinate, or a rough fix from your IP.
- ATAK updates from inside ATAK: the Market offers the newest ATAK-CIV and moves your
  plugins over to it.
- TAK Portal "open in app": open the portal in Chrome inside Android, sign in, and
  ATAK enrols with the server. Chrome is the one Google app kept; the rest are off.
- On a Mac, drag any APK from Finder onto the window to install it; ATAK offers to
  load a plugin. Drag any other file and it lands in Android's Downloads folder. On
  Windows, `takwerx plugin FILE.apk` installs a plugin and switches it on.

Known issues, being worked on:

- Now and then, after half an hour or more, the emulator's display stalls for a few
  seconds. If ATAK stops responding, `takwerx atak` restarts it; `takwerx restart`
  restarts Android. Nothing is lost either way.
- No multicast: Android sits behind the emulator's NAT, so TAK servers over TLS work
  and situational awareness on 239.2.3.1 does not.
- Nothing is code-signed. That is why the install is a line you paste: a downloaded
  app would be blocked by Gatekeeper on a Mac and by SmartScreen on Windows.

## Daily use

Open **TAKwerx ATAK Terminal** from the Dock, Applications, Launchpad or Spotlight on a
Mac, or from the Start Menu, the desktop or your pinned taskbar button on Windows.
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

On Windows the same commands work in PowerShell. `takwerx gpu Intel` or `takwerx gpu
NVIDIA` picks the graphics on a laptop with two (then `takwerx restart`); `takwerx doctor`
and the Mac's VM commands do not exist there.

## Updating takwerx

One line, in Terminal on a Mac or PowerShell on Windows:

```bash
takwerx update
```

It fetches the newest takwerx release, fetches any tool whose pinned version moved (the
emulator, the Android image, the graphics driver), rebuilds the app icon, and
re-applies its Android settings to the running Android. Your Android data, ATAK,
plugins and settings stay. If Android was running, `takwerx restart` afterwards loads
the new emulator build; takwerx says so. Running the install line from the top of this
page again does the same thing.

You hear about a new release without looking: the app icon posts a notification within
a day of it, and `takwerx up` or `takwerx status` in a terminal prints a line until you
update. What changed is in [CHANGELOG.md](CHANGELOG.md) and on the
[releases page](https://github.com/takwerx/atak-terminal/releases).

ATAK itself updates with `takwerx apk` after you download a new APK, and plugins
update from the Market inside ATAK. When a newer takwerx is out, opening the app
mentions it once a day.

## Plugins

Three ways, all inside the window you already have:

- **The TAKWERX Market**, which `init` installs to match your ATAK version. Open it
  from ATAK's toolbar, pick a plugin, and it installs and updates from there.
- **Drag the APK onto the window.** Any plugin APK from anywhere: drop it on the
  ATAK window, Android installs it, and ATAK offers to load it. The same works for
  any file: a data package, a KML, imagery, all land in Android's Downloads folder
  for ATAK's Import Manager.
- **tak.gov in ATAK.** Link your EUD to your tak.gov account in ATAK's plugin
  manager and install from tak.gov's list, exactly as on a phone.

From Terminal, `takwerx plugin file.apk` does the same as the drag.

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

ATAK and Chrome sit in Android's dock at the bottom, with the app drawer. Everything
else Google ships in the image is switched off at install (Gmail, YouTube, Maps, Play
services and the rest). Take a package out of `EMU_TRIM_APPS` in `~/.takwerx/config`
to keep it.

**Tips for ATAK on a big screen**, in ATAK's Settings:

- **Use large icons** for the toolbar. The screen has the room, and the icons are
  easier to hit with a mouse.
- **Force extra icons in landscape.** The toolbar then shows up to ten tools before
  they go into the overflow menu.
- **DeX mode.** ATAK's desktop mode, meant for Samsung DeX, suits a windowed desktop
  the same way.
- Keep the toolbar to the tools you use. More tools than the bar has slots for
  overlap when a pane is open.

## Runtimes

On Windows there is one runtime, Google's Android Emulator on the PC's GPU. On a Mac
the default on Apple Silicon is the same emulator on the Mac's GPU
(`takwerx runtime emulator`): fast, full-size icons, no virtual machine, no admin
password. The other runtime (`takwerx runtime redroid`) runs Android in a small Linux
virtual machine with software rendering; it is slower and its map is choppy, but it
can sit on your LAN with its own address and multicast (`takwerx network bridged`),
and it is the path for Intel Macs. Both keep their own Android data.

## Where things live

| What | Mac | Windows |
|---|---|---|
| takwerx itself | `~/.takwerx/app` | `%LOCALAPPDATA%\takwerx\app` |
| The emulator, Android image, tools | `~/.takwerx/tools` | `%LOCALAPPDATA%\takwerx\tools` |
| Android's data; `takwerx reset` wipes it | `~/.takwerx/avd` | `%LOCALAPPDATA%\takwerx\avd` |
| Settings | `~/.takwerx/config` | `%LOCALAPPDATA%\takwerx\config` |
| Logs | `~/.takwerx/logs` | `%LOCALAPPDATA%\takwerx\logs` |
| The icon | `/Applications/TAKwerx ATAK Terminal.app` | Start Menu and desktop shortcuts |

`takwerx uninstall` removes all of it.

## Troubleshooting

- **The window never appears.** `takwerx status`, then `takwerx logs --container`
  is the emulator's own log. `takwerx logs --android` is logcat.
- **ATAK stops responding.** `takwerx atak` restarts ATAK; `takwerx restart` restarts
  Android. Data is kept.
- **The window vanished when you clicked "..." on its side toolbar.** Older installs did
  that (the emulator's Extended Controls); `takwerx update`, then `takwerx restart`.
- **ATAK asks for permissions anyway.** `takwerx apk` again re-grants everything.
- **A plugin is installed but ATAK does not show it.** `takwerx plugin` on its APK
  again; it switches the plugin on in ATAK and restarts ATAK.
- **Start over.** `takwerx reset` wipes Android; `takwerx uninstall` then the
  install line rebuilds everything.
- **macOS asks about Terminal and Downloads, or about location.** Allow it; the
  first is for reading the ATAK APK, the second for `takwerx location here`.
- **Windows: "takwerx is not recognized".** Open a new PowerShell window; the install
  adds the command for windows opened after it.
- **Windows: Windows Hypervisor Platform is off.** Settings, System, Optional
  features, More Windows features, tick Windows Hypervisor Platform, restart; or ask
  IT. Then `takwerx init` again.
- **Windows: the position is wrong or missing.** `takwerx location here` uses Windows'
  location service: Settings, Privacy & security, Location, with "Let desktop apps
  access your location" on. Or `takwerx location LAT,LON`.

## Security notes

- Android's debug bridge (adb) is reachable only from this Mac, on 127.0.0.1, through
  takwerx's own adb server. Nothing on your network can reach it.
- Android sees none of your Mac's files. Files reach it only through `takwerx apk`,
  `plugin`, `datapackage`, or a drag onto the window.
- All downloads are pinned to specific versions and checksums in `versions.env`; the
  emulator and Android image come from Google's own repository.
- The app in Applications is built on your Mac, not downloaded, and is not signed by
  Apple. The emulator inside it is Google's binary, re-signed locally because three
  strings in it are patched (the window title, its own Dock icon, and the name of the
  Qt path file it carries, which points at the wrong place from inside an app).
- On Windows nothing of Google's is modified. The window's title, icon and taskbar
  button are set while it runs. Everything lives in your own user folder, and nothing
  needs an administrator except switching on Windows Hypervisor Platform, once, where
  it is off.

## Status

Beta, on macOS with Apple Silicon and on Windows. Verified end to end on a Mac Studio
(M-series, macOS 26) and a 16 GB MacBook Pro (M2 Pro): install from scratch with the
line above, ATAK 5.8 and the Market plugin, TAK Portal enrolment, plugins by Market and
by drag. On Windows, on a company-managed Dell Precision 5490 (Windows 11, no
administrator rights, NVIDIA RTX 2000 Ada and Intel Arc): install from the line above,
ATAK 5.7, the Market, Cursorwerx, and ATAK's own update to 5.8 through the Market.
Intel Macs and Linux: not yet.

Every non-obvious finding, with the reasoning and the dead ends, is in
[docs/DECISIONS.md](docs/DECISIONS.md).

## License

AGPL-3.0-or-later, the same as the other TAKWERX projects. ATAK and the ATAK name
belong to the TAK Product Center and are not part of this repository; the ATAK icon
the app shows is read from the APK you downloaded.
