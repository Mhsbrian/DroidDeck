# DroidDeck for Googlebook x86_64

This fork runs DroidDeck natively on x86_64 Googlebook laptops: Android-based laptops with an AMD Ryzen CPU,
Radeon graphics and, on some models, an NVIDIA GPU. Upstream DroidDeck targets Adreno phones and handhelds
and is arm64-only. This page records the design, the milestones and what has been measured.

Status: 2026-10-28, milestone 0 (feasibility) done. **The app does not build for x86_64 yet.**

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
| 1 | x86_64 APK | `assembleRelease` makes an x86_64 APK; it installs and its front end opens | next |
| 2 | x86_64 runtime | a pinned Arch x86_64 runtime image with gamescope, its WSI layer, the preloads, mangoapp and pipewire, all x86_64 | |
| 3 | Steam on the Radeon | Steam Big Picture appears through the app's compositor on the Radeon | |
| 4 | Controllers | an Xbox-style and a DualSense controller work in Steam Input, including rumble; keyboard, mouse and touch work | |
| 5 | Games on the Radeon | a Proton game and a native Linux game run; fps recorded | |
| 6 | Games on the NVIDIA GPU | the same games render on NVIDIA's driver and appear on screen; fps compared with the Radeon; the NVIDIA GPU powers down after the game exits | |
| 7 | Speed and polish | x86_64 proot fast path; driver choice per game; first-run setup without developer options | |

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
