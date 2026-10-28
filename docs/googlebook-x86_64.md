# DroidDeck for Googlebook x86_64

This fork runs DroidDeck natively on x86_64 Googlebook laptops: Android-based laptops with an AMD Ryzen CPU,
Radeon graphics and, on some models, an NVIDIA GPU. Upstream DroidDeck targets Adreno phones and handhelds
and is arm64-only. This page records the design, the milestones and what has been measured.

Status: 2026-10-28. Milestones 0 to 2 are done. Milestone 3 is in progress: in DroidDeck's real session on an x86_64 host, Steam's UI starts and reaches "Before Login", then its web helper asserts and Steam exits. The APK goes to the reference laptop once Steam's sign-in screen shows.

Labels: **CONFIRMED** = measured on the reference laptop; **HYPOTHESIS** = not tested yet.

## Reference machine

- An x86_64 Googlebook-style laptop with:
  - a Ryzen AI 9 HX 370 and Radeon 890M (`gfx1150`);
  - a GeForce RTX 5070 Ti Laptop GPU (`10de:2f58`), driven by NVIDIA's open kernel modules 615.78.08.
- Android exposes these GPU nodes to apps:
  - `/dev/dri/renderD128` (amdgpu);
  - `/dev/dri/renderD129`, `/dev/nvidiactl`, `/dev/nvidia0` and `/dev/nvidia-modeset` (NVIDIA).
- The device reports the ABIs `x86_64,arm64-v8a`. arm64 apps run through an ARM translator.

## Why upstream does not work there

- Upstream's APK, proot, Linux runtime (Arch Linux ARM), Steam client and Proton are all arm64.
- On an x86_64 device the APK runs through the ARM translator.
- **"Play Steam" stops at "Starting display and audio".** proot's first child stays in `t (tracing stop)`:
  - proot traces it with ptrace and seccomp written for AArch64;
  - the translated processes are really x86_64, so proot never sees the stop it waits for.
- **No GPU driver.** Upstream ships only Turnip, which needs `/dev/kgsl-3d0` (Adreno).
- **Double translation.** Even with both fixed, x86 games would be translated twice: x86 to arm64 by FEX, then arm64 back to x86 by the device's ARM translator.

## Design

| Part | Upstream | This fork |
| --- | --- | --- |
| APK ABI | `arm64-v8a` | `x86_64` |
| proot | termux/proot plus 18 patches, arm64 | the same patches built for x86_64, plus proot's 32-bit loader for i386 programs |
| proot fast path | patches arm64 `svc #0` sites | off at first; an x86_64 `syscall` port later |
| Linux runtime | Arch Linux ARM | Arch Linux x86_64 with multilib (proposed; it keeps upstream's pacman-based scripts) |
| Steam client | Valve's arm64 client; an x86_64 client under FEX as an option | Valve's x86_64 `steamrt64` client, started directly (upstream's `droiddeck-steam-x64` flow, without FEX) |
| Proton | Valve's ARM64 Proton without the Steam Linux Runtime container | Valve's Proton and GE-Proton x86_64 without the container. Android apps cannot create user namespaces (HYPOTHESIS: it works the way upstream's ARM64 tool does) |
| Linux-side Vulkan | Turnip (Adreno) | Mesa RADV on the Radeon; NVIDIA's own Linux driver on the NVIDIA GPU, the exact version of the kernel module |
| OpenGL | Zink over Turnip | radeonsi on the Radeon; NVIDIA's GL on the NVIDIA GPU |
| App-side compositor | Turnip loaded through adrenotools | the system Vulkan driver, with dma-buf import; adrenotools only in arm64 builds |
| Frames from the NVIDIA GPU | n/a | linear dma-buf shared with the Radeon, which drives the panel (HYPOTHESIS); a copy through system memory as the fallback |
| Controllers | Android `InputDevice` to shared rings, then a fake evdev and uinput (`libfakeinput`) for Steam Input | the same; upstream already builds an x86_64 `libfakeinput` |
| Audio | PulseAudio and the AAudio/DirectAudio sinks, built for arm64 | the same, rebuilt for x86_64 |
| App updates | upstream's catalog (arm64 APKs) | off, or pointed at this fork's releases |

NVIDIA's Linux driver is not part of this repository. It must match the device's kernel module exactly. Two ways to provide it:
- the device image ships the matching userspace and the app binds it into the runtime;
- the app downloads NVIDIA's installer for that version from `download.nvidia.com` and checks its SHA-256.

## Milestones

| # | Milestone | Done when | State |
| --- | --- | --- | --- |
| 0 | Feasibility on the device | native proot runs an x86_64 glibc system; both GPUs render inside it | **done** (below) |
| 1 | x86_64 APK | `assembleRelease` makes an x86_64 APK; it installs and its front end opens | **done** (below), apart from seeing it on screen |
| 2 | x86_64 runtime | a pinned Arch x86_64 runtime image with gamescope, its WSI layer, the preloads, mangoapp and pipewire, all x86_64; the app installs it and uses its proot instead of upstream's arm64 ones | **done**, apart from hosting the runtime (below) |
| 3 | Steam on the Radeon | Steam Big Picture appears through the app's compositor on the Radeon | |
| 4 | Controllers | Steam Input sees the controllers Steam supports as Steam sees them on SteamOS: buttons, rumble, and gyro and touchpad where the controller has them. Xbox, DualSense and 8BitDo controllers also work in emulators and other non-Steam apps. Keyboard, mouse and touch work | |
| 5 | Games on the Radeon | a Proton game and a native Linux game run; fps recorded | |
| 6 | Games on the NVIDIA GPU | the same games render on NVIDIA's driver and appear on screen; fps compared with the Radeon; the NVIDIA GPU powers down after the game exits | |
| 7 | Speed and polish | x86_64 proot fast path; driver choice per game; first-run setup without developer options | |

## Milestone 1: building the x86_64 APK

```sh
# once per ABI: libffi and libwayland-server for the compositor (Docker, NDK)
NDK=... DROIDDECK_ABI=x86_64 tools/googlebook/build-wayland-server.sh app/src/main/jniLibs/x86_64
# the APK (JDK 17)
./gradlew -PdroiddeckAbi=x86_64 -PskipRust=true -PndkVersion=<installed NDK> :app:assembleDebug
# sign with your own key; Play Protect rejects the AOSP testkey
GOOGLEBOOK_KEYSTORE=... GOOGLEBOOK_KEYSTORE_PASS_FILE=... tools/googlebook/sign-apk.sh \
  app/build/outputs/apk/debug/app-debug.apk droiddeck-googlebook-x86_64.apk
```

- **`droiddeckAbi`** (Gradle property, or `droiddeck.abi` in `local.properties`):
  - `arm64-v8a` (the default) builds exactly what upstream builds.
  - `x86_64` builds the Googlebook app, `com.droiddeck.launcher.googlebook`, which installs beside upstream's app.
- **adrenotools** (Turnip loading) is built and linked only for arm64. On x86_64 the compositor uses the system Vulkan driver.
- **`verifyRuntimeInputs`** still runs for arm64. It is skipped for x86_64 until milestone 2 records x86_64 runtime inputs.
- **Results (2026-10-28, reference laptop):**
  - The APK holds only `lib/x86_64` and is 61 MB.
  - With the AOSP testkey, Play Protect refused the install ("Install not allowed", verdict 3).
  - Re-signed with our key, it installed. The process started, the front-end activity was created, and every native library loaded except the store engines (left out with `-PskipRust`). There were no crashes.
  - The laptop's screen was off, so no frame was drawn. Seeing it on screen is still open.
- **Still missing for x86_64:**
  - PulseAudio and its modules (needed for sound, milestone 3);
  - the DirectAudio relay;
  - the Rust store engines (`cargo-ndk` target `x86_64-linux-android`);
  - an x86_64 proot pack and runtime catalog. The app still asks upstream's catalogs for the arm64 runtime, FEX and arm64 Proton (milestone 2).
- **Labels.** The app is still called "DroidDeck", the same as upstream's. A distinct label comes with packaging (milestone 7).

## Milestone 1, second part: sound and the rest of the Android side

- **PulseAudio.** `tools/googlebook/build-pulseaudio.sh` builds the Android-side PulseAudio 13.0 that upstream ships for arm64: daemon, `libpulse`, `pactl` and the modules. It also builds `libltdl` 2.4.7 and `libsndfile` 1.2.2, all from pinned sources for API 33.
  - Changes for bionic:
    - no privilege or capability dropping (Android's app seccomp filter kills `set*id`, and bionic has no libcap);
    - no gettext;
    - a higher open-file limit, as Termux uses.
  - The AAudio and DirectAudio sinks and the DirectAudio relay build for x86_64 with `DROIDDECK_ABI=x86_64`.
- **Build.** `tools/googlebook/build-apk.sh` builds and signs the whole x86_64 APK (release: 54 MB, x86_64 code only). Generated libraries are not in Git.
- **Reference laptop, over adb:**
  - The x86_64 PulseAudio daemon starts and answers `pactl` (server 13.0).
  - Its AAudio sink opens an Android output stream: 48 kHz, stereo, low-latency mode.

## Milestone 2 so far: the x86_64 runtime

- **Runtime.** `tools/googlebook/build-runtime.sh` builds `linuxfs-x86_64.tar.zst` from the `archlinux:base` image and a dated Arch archive snapshot (`runtime.env`, 2026-10-27), with multilib. 391 MB compressed, 1.6 GB unpacked, 401 packages (`runtime-packages-x86_64.txt`):
  - Mesa 26.2.5 (RADV), Xwayland 24.1, PipeWire 1.6, MangoHud (mangoapp), Python 3.14, glibc 2.44, 32-bit Mesa and Vulkan;
  - the x86_64 proot at `opt/android-host`, as in upstream's runtime;
  - no NVIDIA files: the build refuses to package any.
- **gamescope.** `tools/googlebook/build-gamescope.sh` builds gamescope 3.16.29 for x86_64 the way upstream does for arm64: Arch's packaging plus upstream's patches.
  - The two patches for the arm64 Steam client (0009, 0019) are left out.
  - `gamescope-patches/0200` is added: Android apps may open render nodes only, so a missing primary node must not stop the nested (Wayland) and headless backends.
  - Upstream's gamescope tests pass.
- **How it was tested.** adb's `shell` SELinux domain cannot create Unix sockets in `/data/local/tmp`, so Wayland and PulseAudio sockets fail there. The tests therefore ran in the app's own domain: a debuggable build, `run-as`, and the runtime unpacked in the app's files directory, without starting the app.
- **Results (reference laptop, app domain, headless):**
  - Patched gamescope on the Radeon runs vkcube through Xwayland and gamescope's WSI layer: 900 frames, clean exit, three runs out of three. One crash (SIGBUS) happened on the first run after the binary was replaced; it did not come back.
  - Unpatched gamescope stops with "physical device has no primary node".
  - NVIDIA's own driver (615.78.08, its files added to the test copy only) passes the probe in the app domain.
  - **Cross-GPU.** gamescope composites on the Radeon while vkcube renders on the RTX through NVIDIA's driver: about 600 frames per 10 s were handed over and composited. This is the milestone 6 path, still without a screen.
- **Not done yet:**
  - hosting the runtime, the x86_64 proot pack and catalogs, and pointing the app at them;
  - the x86_64 Steam client and Proton in the session scripts;
  - presenting on screen through the app's compositor (milestone 3).

## Milestone 2, second part: the app and Steam

- **App, x86_64 builds only** (arm64 unchanged; `DeviceSupport.nativeX86()`):
  - The patched proot (and its i386 loader) comes from the runtime's `opt/android-host`. No add-on pack is pinned, so nothing ARM is fetched.
  - The runtime catalog is a local file: `droiddeck-runtime-x86_64.json` in the app's external files directory (`Android/data/<package>/files/`). Its `url` may name an archive beside it, and the archive is still checked against the catalog's SHA-256.
  - No ARM64 Proton seed (Steam installs Valve's Proton), no FEX catalog, no non-Adreno warning.
  - RADV is the default Linux driver instead of the first ICD the runtime lists.
  - The APK carries x86_64 builds of the session preloads: System V IPC for the client's tier0, and the controller reader for Steam Input.
- **Steam.** `droiddeck-steam-native` installs, updates and starts Valve's steamrt64 client in the session's runtime. It is `droiddeck-steam-x64`'s flow without FEX: delta updates, scout runtime, `~/.steam` links, the steamrt shim, and Valve's platform libraries. `droiddeck-session` uses it when the runtime is x86_64 and skips the ARM64 Proton steps.
- **Runtime gb2** (sha256 `93e894b7…`): `/tmp` at 1777, a localhost `/etc/hosts`, and `diffutils`.
- **Checked (2026-10-28):**
  - On the build host, in the runtime image: the client (`1793056502`, `steamdeck_publicbeta`, 28 parts SHA-256-checked) installs in 30 s.
  - On the reference laptop, in the app's SELinux domain under gamescope (headless): **the client starts natively**, its GPU query finds RADV, and it reports correctly that it is offline. The laptop was asleep, so Android's Doze blocked the app's network.
  - Its web helper (CEF) starts but restarts about every 10 s. In this bare test there is no system D-Bus, no network and none of upstream's web helper flags, all of which the real session provides. Milestone 3 continues there.
  - Fixed on the way:
    - Valve's update parts carry no execute bits, which FEX never needed, so `droiddeck-steam-native` now sets them.
    - CEF lives in `ubuntu12_64`, which is now on the library path.
- **Not done:**
  - hosting the runtime: a decision for the owner;
  - Valve's Proton without the Steam Linux Runtime container;
  - NVIDIA's driver as a session choice (it needs gamescope kept on the Radeon while games use the RTX);
  - 32-bit preloads;
  - 32-bit SDL2, which is missing from the Arch snapshot and is used only by Steam's 32-bit GL query.

## Owner decision (2026-10-28): keep the Linux side like upstream

- The runtime is downloaded at first start, exactly as upstream's is, from this fork's releases:
  - catalog at `googlebook-runtime/linuxfs-x86_64.json`;
  - the archive in a release per version.
- It is the same kind of Arch Linux system upstream uses, built for x86_64 because upstream's is ARM-only.
- The app is the rebuilt Googlebook app. It is pushed to the laptop when it works and preinstalled in the Googlebook image later.

## Milestone 3 so far: the Steam session on an x86_64 host

`tools/googlebook/session-host-test.sh` runs the real `droiddeck-session steam` in the x86_64 runtime on an x86_64 Linux host. It runs headless, with one AMD render node and no display node, as an Android app sees the GPU. Results, 2026-10-28, on a Radeon 610M (RADV):
- **Session:** gamescope, Xwayland, the system D-Bus with the login1 and NetworkManager stand-ins, and the agent all start.
- **Steam:** the native client installs and starts with DroidDeck's arguments (`-gamepadui -steamdeck -steamos3`, CEF on ANGLE Vulkan). It is online and logged off.
- **Hostname:** Steam's UI reaches the client through the machine's hostname, and Android's is `localhost`. The harness sets it; under Docker's default name the UI's WebSocket failed.
- **lsof:** Steam calls it. The runtime now has it, so the session shim can answer.
- **With the session preload** (`libblsession`), on the host: the UI's JavaScript chunks fail to load (`ChunkLoadError`). Without the preload the UI initializes ("SteamApp Init - Before Login", 0.2 s). Whether the preload does the same on Android is not known yet.
- **Then** the web helper hits a tier0 assert as its Vulkan starts (`vulkandriverquery` too), and Steam shuts down about 10 s later. The same happens with gamescope's WSI layer off. Starting the helper through upstream's `droiddeck-x64-webhelper` wrapper was worse, so it is not used.
- Steam uploads an anonymous minidump to Valve on each assert. That is the client's own behaviour, and no account is involved.

## Milestone 0: what was measured

Run on 2026-10-28 on the reference laptop, from `adb shell` (not yet inside the app):
- an x86_64 proot built from `tools/proot` (`DROIDDECK_ABI=x86_64`);
- a Debian 13 x86_64 test system with Mesa 25.0.7 and NVIDIA's 615.78.08 userspace.

`tools/googlebook/m0-smoke.sh` repeats the whole check. It builds both, pushes them over adb, runs the probes below and removes its files from the device.

- **proot (CONFIRMED).**
  - The x86_64 build applies all 18 patches and keeps seccomp acceleration.
  - It ran Debian 13 (glibc 2.41) to a shell, plus a 2,000-iteration file-test loop, in 0.1 to 0.3 s.
  - No tracing-stop deadlock.
- **Radeon, Mesa RADV (CONFIRMED).** `AMD Radeon Graphics (RADV GFX1150)`.
  - Offscreen clear at 1920×1080 and readback: correct.
  - Fill: 120 to 122 GB/s.
  - vkmark (headless, 1920×1080): score 7546 and 7647 in two runs.
- **NVIDIA, NVIDIA's own driver (CONFIRMED).** `NVIDIA GeForce RTX 5070 Ti Laptop GPU`, `DRIVER_ID_NVIDIA_PROPRIETARY`, `615.78.08`, conformance 1.4.3.3.
  - Offscreen clear at 1920×1080 and readback: correct.
  - Fill: 403 to 408 GB/s.
- **What NVIDIA's userspace needs inside proot (CONFIRMED):**
  - glvnd's EGL vendor file `10_nvidia.json`. Without it the Vulkan driver refuses `vkCreateInstance`, because it initializes through EGL.
  - The rootfs bound at its own host path. The driver re-opens its libraries by the host paths in `/proc/self/maps`. Whether it fails without that bind was not tested.
  - It cannot read `/proc/driver/nvidia/params` (EACCES). It carries on without it.
- **Not working yet:** vkmark's headless mode crashes on the NVIDIA device (NULL+0x18 at its first frame). The minimal probe (`tools/googlebook/vkprobe.c`) passes on the same device, so the suspect is vkmark's headless window-system path, not rendering (HYPOTHESIS).

## Keeping up with upstream

- Upstream changes daily. This fork merges upstream `main` regularly.
- Changes are kept ABI-conditional where possible, so the arm64 build keeps working and parts can be offered upstream.

## Licence

GPL-3.0, as upstream. NVIDIA's driver binaries are not in this repository.
