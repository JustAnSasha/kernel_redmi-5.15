# Shining Kernel

GKI kernel builds for **Redmi Note 12 / Note 13 4G NFC** (topaz/tapas), based on `android13-5.15`.

One workflow, one config file, one build script. Pick a variant, hit run, get a flashable zip.

## Variants

| Variant | Notes |
|---|---|
| Vanilla | No root, clean GKI |
| KernelSU | Upstream tiann/KernelSU |
| KernelSU-Next | dev branch + WildKernels susfs fix patches |
| ReSukiSU | LLVM=1 build, packs system_dlkm.img |
| SukiSU-Ultra | builtin branch, KPM supported |

## Usage

Actions → **Build Kernel** → Run workflow.

Everything is configurable from the dispatch menu: SUSFS, BBG, KPM, droidspaces, integrity spoof, tick rate, LTO type, opt level, clang toolchain, spoofed kernel version. There's also a `systemDlkmErofs` toggle that flips zram/zsmalloc to modules and packs them into an EROFS `system_dlkm.img` inside the AnyKernel3 zip.

Build takes roughly 30-60 min depending on LTO. The zip lands in artifacts and gets sent to Telegram if you've set the secrets.

## How it's wired

```
.github/workflows/Build Kernel.yml   <- thin dispatcher, just inputs
configuration/build-config.json      <- all URLs, variants, defconfig opts
configuration/build.sh               <- does everything
configuration/notify.py              <- telegram upload/notification
```

The YAML doesn't contain any build logic. If you want to change a patch URL, add a KSU variant or tweak defconfig options, edit `build-config.json`. Build steps themselves live in `build.sh`.

Clang (ZyCromerZ) and the KPM patcher are fetched from their latest GitHub releases at build time, with pinned fallbacks in the JSON.

## Telegram notifications

Set these repo secrets:

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_USER_ID`

Get a token from [@BotFather](https://t.me/BotFather), your chat id from [@userinfobot](https://t.me/userinfobot). Without secrets the notify step silently skips.

Optional: `TELEGRAPH_TOKEN` is no longer used.

## Flashing

Flash the AnyKernel3 zip via TWRP / KernelFlasher / custom recovery. If the zip contains a `system_dlkm.img`, flash that too (EROFS format).

Not responsible for bricked devices, lost data, exploded phones, etc.

## Credits

- [KernelSU](https://github.com/tiann/KernelSU) / [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) / [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) / [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU)
- [SuSFS](https://gitlab.com/simonpunk/susfs4ksu) by simonpunk
- [Baseband-guard](https://github.com/vc-teahouse/Baseband-guard)
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3)
