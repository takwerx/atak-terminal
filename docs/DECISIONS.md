# Decisions and spike findings

Dated notes on what was decided and why, so nobody re-derives them. Newest first.

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
