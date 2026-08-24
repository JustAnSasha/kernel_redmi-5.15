# Shining Kernel

GKI kernel builds for **Redmi Note 12 / Note 13 4G NFC** (topaz/tapas), based on `android13-5.15`.

## Variants

| Variant | Notes |
|---|---|
| Vanilla | No root, clean GKI |
| KernelSU | Upstream tiann/KernelSU, latest tag |
| KernelSU-Next | Upstream dev branch |
| ReSukiSU | LLVM=1 build, packs system_dlkm.img |
| SukiSU-Ultra | Upstream builtin branch, KPM supported |

All KSU forks are pulled stock from their official repos at the latest version — no custom patches, no branding hacks.

## Usage

Actions → **Build Kernel** → Run workflow.

Configurable from the dispatch menu: SUSFS, BBG, KPM, droidspaces, tick rate, LTO type, opt level, clang toolchain, optional kernel version spoof. The `systemDlkmErofs` toggle flips zram/zsmalloc to modules and packs them into an EROFS `system_dlkm.img` inside the AnyKernel3 zip.

Build takes roughly 30-60 min depending on LTO. The zip lands in artifacts and gets sent to Telegram if the secrets are set.

## Layout

```
.github/workflows/Build Kernel.yml   <- thin dispatcher, just inputs
configuration/build-config.json      <- URLs, variants, defconfig options
configuration/build.sh               <- does everything
configuration/notify.py              <- telegram upload/notification
```

The YAML contains no build logic. Patch URLs, KSU variants and defconfig options live in `build-config.json`. Build steps live in `build.sh`.

Clang (ZyCromerZ) and the KPM patcher are fetched from their latest GitHub releases at build time, with pinned fallbacks in the JSON. SuSFS is pulled from the official simonpunk repo. ccache is enabled and cached between runs.

## Telegram notifications

Set these repo secrets:

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_USER_ID`

Get a token from [@BotFather](https://t.me/BotFather), your chat id from [@userinfobot](https://t.me/userinfobot). Without secrets the notify step silently skips.

## Flashing

Flash the AnyKernel3 zip via TWRP / KernelFlasher / custom recovery. If the zip contains a `system_dlkm.img`, flash that too (EROFS format).

Not responsible for bricked devices, lost data, exploded phones, etc.

## Credits

- [KernelSU](https://github.com/tiann/KernelSU) / [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) / [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) / [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU)
- [SuSFS](https://gitlab.com/simonpunk/susfs4ksu) by simonpunk
- [Baseband-guard](https://github.com/vc-teahouse/Baseband-guard)
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3)
