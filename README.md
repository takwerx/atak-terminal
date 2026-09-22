# takwerx: ATAK on your desktop

Real ATAK, the Android app with its real plugins, running in a window on your Mac.
One command installs it. After that there is an **ATAK** icon in Applications and
you open it like any other app.

```bash
curl -fsSL https://raw.githubusercontent.com/takwerx/takwerx-desktop/main/install.sh | bash
```

That line downloads the tool, builds a small Linux virtual machine, starts Android
inside it, installs the ATAK APK you already have in Downloads, adds the TAKWERX
Market plugin so your plugins update from inside ATAK, creates the icon, and opens
the window. First run takes a few minutes and about 2 GB of downloads. After that,
opening ATAK takes about half a minute.

There is no account, no telemetry, no paid tier, and nothing is sent anywhere.
Everything runs on your own machine.

## What you need

- A Mac with Apple Silicon or Intel, macOS 13 or newer. Windows and Linux are next.
- The ATAK-CIV APK from [tak.gov](https://tak.gov/products/atak-civ). ATAK is not
  redistributed here; you download it once and takwerx installs it.
- About 10 GB of disk and an internet connection for the first run.

Nothing else. No Homebrew, no Docker, no Android Studio, no developer account.

## How it works

ATAK is an Android app, and Android needs a Linux kernel with a feature called
binder that macOS does not have. So takwerx creates a small Ubuntu virtual machine
using Apple's own virtualization, loads binder there, and runs Android in a
container inside it, using a project called redroid. The picture and your mouse and
keyboard travel over adb to a window on your desktop, using scrcpy. You never see
any of this. You see an ATAK window.

## Daily use

Open **ATAK** from Applications, Launchpad or Spotlight. Close the window when you
are done. Android keeps running in the background so the next open is fast;
`takwerx down` stops it completely and frees the memory.

Everything ATAK stores, server connections, certificates, map caches, plugin
settings, survives restarts and takwerx updates.

The `takwerx` command is available in any new terminal:

```
takwerx up                  start Android and open the ATAK window
takwerx down                stop Android and the VM, keep all data
takwerx status              what is running

takwerx apk [FILE]          install or replace ATAK (newest in ~/Downloads by default)
takwerx plugin FILE.apk     install a plugin
takwerx market              install the TAKWERX Market plugin for your ATAK version
takwerx datapackage FILE    import a data package zip

takwerx display PRESET      ultra | tablet | desktop | phone | WIDTHxHEIGHT@DPI
takwerx location WHERE      LAT,LON [ACCURACY_M] | here | ip | off
takwerx keyboard MODE       auto | uhid | sdk
takwerx network MODE        nat | bridged
takwerx screenshot          save a PNG of the screen to the Desktop
takwerx shell               adb shell into Android
takwerx logs                takwerx log; --android for logcat, --container for Android boot
takwerx doctor              check the host and report what is missing
takwerx reset               wipe Android and start clean
takwerx update              update takwerx and its pinned tools
takwerx uninstall           remove everything
```

## Updating ATAK and plugins

Plugins from TAKWERX update from inside ATAK through the Market plugin, which
`init` installs to match your ATAK version. Any other plugin: `takwerx plugin file.apk`.

ATAK itself cannot be fetched automatically, because tak.gov requires a login.
Download the new APK, then `takwerx apk` picks up the newest one in Downloads.
Your settings and plugins stay.

## Position

There is no GPS in the container, so ATAK reports no location until you give it
one. takwerx streams the position to ATAK as NMEA, the same input a Bluetooth or
USB GPS uses, once a second, so ATAK shows a normal GPS fix, its self marker sits
where you say, and situational awareness beacons carry a position.

```
takwerx location here            this Mac's location, the way a browser gets it
takwerx location 33.55,-117.21   an exact position, optional accuracy in metres
takwerx location ip              a rough fix from your public IP, a few km at best
takwerx location off
```

`init` sets the rough IP fix so the map opens near you. The first `here` makes
macOS ask whether the terminal, or ATAK, may use your location; allow it. The
position survives restarts; change it whenever you move.

## Keyboard and mouse

Your Mac keyboard reaches ATAK as a hardware keyboard, so typing, shortcuts and
arrow keys work without touching anything inside Android, and Android keeps its
on-screen keyboard hidden. No plugin is involved.

Over a remote desktop such as AnyDesk or Screen Sharing, keystrokes arrive as
injected events and the hardware-keyboard path forwards nothing. Switch to typed
text, which works everywhere at the cost of Android showing its on-screen keyboard:

```
takwerx keyboard sdk     typed text, works over remote desktop
takwerx keyboard uhid    hardware keyboard, best when you are at the Mac
takwerx keyboard auto    the default: uhid when available
```

Close and reopen the ATAK window after changing it.

## Screen size

ATAK lays out its toolbar from the screen size it is given, so the instance
claims a tablet. Presets switch live, without a restart:

| Preset | Pixels | dpi | Layout room |
|---|---|---|---|
| `ultra` | 2960x1848 | 240 | Galaxy Tab S11 Ultra |
| `tablet` | 2560x1440 | 200 | default: the Ultra's toolbar at fewer pixels |
| `desktop` | 2560x1440 | 160 | the most toolbar room, small touch targets |
| `phone` | 1440x3120 | 450 | to check phone layouts |

Right-click goes to Android as a normal secondary click. Shift with right, middle,
4th and 5th mouse buttons give Back, Home, App switch and Notifications. The keyboard
is a real HID keyboard, so ATAK's hardware shortcuts work. Android runs with gesture
navigation so its tablet taskbar stays hidden and ATAK gets the whole screen; swipe
up from the bottom edge, or press Shift and middle-click, to get Home.

## Networking: NAT or bridged

Out of the box Android sits behind the VM's NAT. Everything outbound works, so
TAK servers over TLS connect fine, but multicast situational awareness on
239.2.3.1:6969 does not leave the machine.

`takwerx network bridged` puts Android on your LAN as its own device: its own
MAC address, a DHCP lease from your router, the hostname ATAK, and multicast in
and out. It uses Apple's vmnet on your Wi-Fi or Ethernet interface and asks for
your Mac password once, to install a small helper under `/opt` that Apple
requires to be root-owned. `init` offers this automatically when run from a
terminal. `takwerx status` shows the address.

The ATAK window itself never depends on the LAN: it reaches Android through the
VM, so no macOS network permission is involved. Inside Android, a firewall rule
lets only the VM reach adb; nothing else on your network can.

## Where things live

| What | Where |
|---|---|
| takwerx itself | `~/.takwerx/app` |
| Downloaded tools (Lima, scrcpy) | `~/.takwerx/tools` |
| The VM | `~/.takwerx/lima` |
| Android data | a volume inside the VM; `takwerx reset` wipes it |
| Settings | `~/.takwerx/config` |
| Logs | `~/.takwerx/logs` |
| The icon | `/Applications/ATAK.app` |

`takwerx uninstall` removes all of it.

## Troubleshooting

- **The window never appears.** `takwerx status`, then `takwerx logs --container`
  shows Android's boot log. `takwerx logs --android` is logcat.
- **"binder is missing inside the VM".** `takwerx vm-shell` then
  `cat /var/log/cloud-init-output.log` shows what the VM setup did.
- **Slow or choppy map.** There is no GPU inside the VM; the map renders in
  software. Try `takwerx display desktop` or a smaller custom size such as
  `takwerx display 1920x1200@160`.
- **ATAK asks for permissions anyway.** `takwerx apk` again re-grants everything.
- **The window dropped after the Mac slept.** Open ATAK again; it reconnects, and
  starts the VM and Android first if the sleep stopped them.
- **Start over.** `takwerx reset` wipes Android; `takwerx uninstall` then the
  install line rebuilds everything.

## Security notes

- adb inside the instance has no password. It is only ever reachable through
  127.0.0.1 on your Mac, via the VM. On the LAN, a firewall rule inside Android
  drops adb from every address except the VM's.
- The VM mounts nothing from your Mac. Files reach Android only through
  `takwerx apk`, `plugin` and `datapackage`.
- All downloads are pinned to specific versions in `versions.env`.

## Status

- macOS, Apple Silicon: working end to end with NAT networking. Verified on an M-series
  Mac with macOS 26: install from scratch, ATAK 5.8 and the Market plugin installed,
  window open, about five minutes on a fast connection.
- macOS, bridged networking: working. Android gets its own address from your router by
  DHCP, shows up as ATAK in the router's client list, and multicast from the LAN reaches
  it, verified over Wi-Fi on Apple Silicon.
- macOS, Intel: same code path, untested.
- Windows and Linux: next.

The first thing you see in the window is ATAK's EULA. That click is yours to make;
takwerx does not accept it for you.

Findings from the first build, with the reasoning, are in [docs/DECISIONS.md](docs/DECISIONS.md).

## License

AGPL-3.0-or-later, the same as the other TAKWERX projects. ATAK and the ATAK
name belong to the TAK Product Center and are not part of this repository.
