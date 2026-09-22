# TAKWERX — Containerized ATAK Desktop Runtime

## Licensing and posture

Free and open source. Public GitHub repo, permissive license, no paid tier, no
telemetry, no account, no phone-home. Anyone can clone it and run it.

This constrains the design in ways that matter downstream:

- No Docker Desktop dependency — its license is a cost the user should never inherit
- No commercial emulator, no cloud device service, nothing with a metered backend
- Every component in the stack is open source except the ATAK APK itself, which the
  user supplies
- Runs entirely on the user's own hardware, disconnected-capable

## One-line goal

A user clones a public GitHub repo, runs one command in their terminal on macOS or
Windows, and ends up with a real ATAK instance running in a window on their desktop —
with working network connectivity to a TAK server.

No Android device. No Android Studio. No emulator. No DeX.

## Why this exists

Samsung DeX for PC/Mac is discontinued. There is no desktop ATAK client for macOS.
WinTAK exists but is a different application with a different plugin ecosystem.
People who need ATAK specifically — the actual app, with its actual plugins — currently
have no good way to run it on a laptop.

Android emulators are the usual answer and they are bad for this: they NAT the guest
behind 10.0.2.x, so multicast situational awareness never leaves the instance, and the
GUI is tuned for mobile gaming rather than sustained operational use.

Containerized Android (redroid) solves the networking problem and runs ARM code natively
on Apple Silicon. That is the core insight this project is built on.

## Architecture

Three layers. The user should only ever be aware of the CLI.

**Layer 1 — Android in a container (redroid)**

- Base image: `redroid/redroid` (arm64 and amd64 variants published)
- Runs Android directly on the host Linux kernel, no nested virtualization
- Requires the `binder_linux` kernel module present and loaded on the Linux host
- Configured via boot properties: `androidboot.redroid_width`, `redroid_height`,
  `redroid_dpi`, `redroid_gpu_mode`

**Layer 2 — a Linux host for it to run on**

macOS and Windows do not have binder in their kernels, so a Linux VM is required.
The user must never configure this by hand.

- macOS: `podman machine` (Fedora CoreOS under Virtualization.framework), with Lima +
  Ubuntu as the fallback if binder turns out to be unavailable there
- Windows: `podman machine` on the WSL2 backend, with a kernel that has
  `CONFIG_ANDROID_BINDER_IPC` enabled, referenced from `.wslconfig`. The Hyper-V provider
  is the fallback — see the decision below.
- Container runtime: Podman, not Docker. Docker Desktop requires a paid license for
  organizations above the small-business threshold, which disqualifies it for the target
  audience.

### Windows-specific design decisions

These are the parts with no Mac equivalent. Resolve them explicitly rather than
discovering them halfway through.

**Custom kernel vs Hyper-V.** `.wslconfig` is global — a custom kernel set there applies
to every WSL distro on the machine, including the user's dev environment. That is an
invasive side effect for a tool that should be uninstallable without a trace. Evaluate
`podman machine --provider hyperv` instead, which gets a self-contained VM whose kernel
we own outright. Slower to boot, no impact on the user's WSL setup. Lean toward Hyper-V
unless the WSL path proves clean; if WSL is used, `doctor` must warn before touching
`.wslconfig` and `reset` must restore it.

**Networking.** Windows 11 22H2+ supports `networkingMode=mirrored` in `.wslconfig`,
which mirrors host interfaces into the VM and is the path to working multicast. Under
Hyper-V, use an external virtual switch instead. Either way, requirement 2 (real LAN
identity, multicast crosses) applies to Windows exactly as it does to Mac.

**Architecture mismatch.** x86_64 host means the arm64 ATAK APK does not run natively.
Either use an amd64 redroid image with an ARM translation layer (libndk or libhoudini),
or use an x86 ATAK build if one is published. This is the biggest technical risk on the
Windows side and is spike 5 below. Do not assume translation will be transparent — ATAK
has native libraries in its map renderer.

**Firewall.** Windows Defender will prompt or silently block the bridged interface and
the ADB/scrcpy ports. `init` should create the firewall rules, and `doctor` should detect
when they are missing.

**Layer 3 — the window**

- `scrcpy` connected over ADB to the container, launched by the CLI, appearing as an
  ordinary resizable desktop window
- Optional `ws-scrcpy` mode serving the same session to a browser tab, for remote or
  multi-user hosting

## Hard requirements

1. **One command to install, one command to run.** `./takwerx init` then `./takwerx up`,
   or equivalent. Everything else — VM creation, kernel module loading, image pull,
   container start, ADB connect, window launch — happens inside those.
2. **Real network identity.** The Android instance must get its own address on the user's
   LAN (bridged / macvlan / WSL mirrored networking), not a NAT'd private address.
   Multicast on 239.2.3.1:6969 must actually leave the container. This is the feature
   that makes the project worth building; if it degrades to NAT, the project is just a
   worse emulator.
3. **Native architecture where possible.** On Apple Silicon: arm64 host → arm64 redroid
   image → arm64 ATAK APK, no translation anywhere in the stack. On x86_64 Windows,
   translation is unavoidable; keep it to one layer and verify the map renderer survives
   it.
4. **Persistent state.** Server connections, certs, map caches, plugin state and prefs
   survive restarts via a named volume.
5. **The user supplies their own ATAK APK.** Do not redistribute ATAK binaries in the
   repo or the image. The CLI takes a path to an APK the user already has, or reads one
   from a local directory. Same for plugins.

## Deliverables

- `Containerfile` layered on redroid, adding ATAK provisioning
- `compose.yaml` (podman-compose compatible)
- `takwerx` CLI — single shell script or a small Go binary, no runtime dependencies
  beyond podman and scrcpy
- Platform bootstrap scripts: `scripts/macos.sh`, `scripts/windows.ps1`
- `README.md` written for someone who has never heard of redroid or binder
- GitHub Actions workflow publishing multi-arch images to GHCR

## CLI surface (proposed — refine as you build)

```
takwerx doctor          # check host prerequisites, report exactly what's missing
takwerx init            # create/start the VM, load kernel modules, pull images
takwerx apk <path>      # install or replace the ATAK APK
takwerx plugin <path>   # install a plugin APK
takwerx datapackage <path.zip>   # seed /data/media/0/atak/ from a data package
takwerx up              # start the container and open the window
takwerx down            # stop, preserve state
takwerx shell           # adb shell into the instance
takwerx reset           # wipe the volume, start clean
```

## ATAK-specific provisioning the image must handle

- Seed `/data/media/0/atak/` before first launch: certs, `.pref` files, map sources
- Grant storage and location permissions non-interactively via `pm grant` so the user
  does not hit the permission wizard on first run
- Tablet geometry by default: 2560x1440 at ~200 dpi. Phone geometry makes the plugin
  trays unusable.
- A mock location provider so the self-marker has a position. Configurable by env var
  (static lat/lon), with a stretch goal of reading host GPS where available.
- Plugin loading requires the plugin's signature and API version to match the ATAK build
  exactly, same as on a device. Surface a clear error when they don't, rather than
  letting ATAK silently skip the plugin.

## Spikes to run BEFORE writing the installer

These decide the architecture. Do them first and report findings.

1. **Does `podman machine` on macOS Apple Silicon have `binder_linux` available?** Check
   whether Fedora CoreOS ships it, whether `modprobe binder_linux devices="binder,hwbinder,vndbinder"`
   succeeds inside `podman machine ssh`, and if not, whether layering
   `kernel-modules-extra` via rpm-ostree is viable. If this is ugly, pivot to Lima +
   Ubuntu, where `linux-modules-extra-$(uname -r)` provides it cleanly.
2. **binderfs vs `/dev/binder`.** Modern kernels expose binder through binderfs rather
   than the legacy character device, and published redroid images have historically
   expected the character device. Determine which the chosen VM kernels present and
   whether the images work against it.
3. **Bridged networking end to end.** Get a redroid container onto the LAN with its own
   DHCP lease on both platforms, then prove multicast actually crosses by receiving CoT
   from another node. Do this before anything else is polished — it is the load-bearing
   assumption. Mac and Windows both, since the mechanisms are completely different
   (vmnet vs mirrored/external switch).
4. **Does ATAK actually run well under redroid?** Install it, confirm the map renderer
   works with `redroid_gpu_mode=host`, check that it survives being left running for
   hours. If the map is unusable, everything above is moot.
5. **Windows kernel path.** Determine whether a WSL2 custom kernel or a Hyper-V VM gives
   a cleaner install. Build a kernel with `CONFIG_ANDROID_BINDER_IPC` and confirm redroid
   boots under it. Decide, then document the decision and why.
6. **ARM translation on x86.** Get the arm64 ATAK APK running on an amd64 redroid image
   with libndk. Check the map renderer specifically — translated native code is where
   this will fail if it fails. Also check whether an x86 ATAK build exists, which would
   make the whole problem disappear.

## Non-goals

- Google Play Services / GMS. ATAK does not need it.
- Supporting Intel Macs. Apple Silicon Macs and x86_64 Windows only.
- A GUI installer. CLI is the target audience's native habitat; a GUI can come later.
- Reimplementing WinTAK or WebTAK. This is ATAK itself, unmodified.

## Definition of done for v0.1

**Both platforms ship together.** Identical command surface, identical behavior. A user
on either OS follows the same README and hits the same result. Platform differences live
entirely inside `init` and are invisible from the outside.

On a clean Apple Silicon Mac with Homebrew:

```
git clone https://github.com/<user>/takwerx && cd takwerx
./takwerx doctor      # tells the user to `brew install podman scrcpy`, nothing else
./takwerx init        # 3-5 min, unattended
./takwerx apk ~/Downloads/ATAK-CIV-5.x.x.apk
./takwerx up          # ATAK window opens
```

On a clean Windows 11 machine with winget:

```
git clone https://github.com/<user>/takwerx; cd takwerx
.\takwerx.ps1 doctor  # tells the user what to winget install, nothing else
.\takwerx.ps1 init    # 5-10 min, unattended, including kernel setup
.\takwerx.ps1 apk $HOME\Downloads\ATAK-CIV-5.x.x.apk
.\takwerx.ps1 up      # ATAK window opens
```

...and on both, in that window, ATAK connects to a TAK server over TLS, shows the COP,
and another node on the same LAN sees its self-marker via multicast.

If one platform is going to slip, say so early and loudly rather than shipping a Mac
release with a Windows README that doesn't work. Half-working Windows support is worse
than none.
