# Shining Kernel

GKI kernel for **Redmi Note 12 4G** (`topaz`/`tapas`) and **Redmi Note 13 4G** (`sapphire`/`sapphiren`), based on `android13-5.15`.

Built entirely from a single GitHub Actions workflow — no helper scripts, no local setup.

## Features

- Latest ZyCromerZ or AOSP clang, fetched at build time
- SuSFS + KernelSU / KernelSU-Next / ReSukiSU / SukiSU-Ultra or vanilla
- KPM patching for SukiSU variants
- Baseband-guard, integrity spoof, droidspaces fixes — all toggleable
- Full ccache integration (5 GB, auto-pruned) for fast rebuilds

## Branches

| Branch | Target |
|---|---|
| `shining` | All four devices, stock HyperOS/MIUI ROMs |
| `google` | Just stock google android 5.15-lts |

## Variants

| Variant | Notes |
|---|---|
| Vanilla | No root, clean GKI |
| KernelSU | Upstream tiann/KernelSU |
| KernelSU-Next | Upstream dev branch |
| ReSukiSU | LLVM=1 build, KPM |
| SukiSU-Ultra | Upstream builtin branch, KPM supported |

All KSU forks are pulled fresh from their official repos at build time.

## Usage

Actions → **Build Kernel** → Run workflow.

Everything is configurable from the dispatch menu: variant, branch, SUSFS, KPM, BBG, integrity spoof, droidspaces, tick rate, LTO type, opt level, toolchain, kernel version spoof.

### Builds and caching

The first build of a branch/variant combo is a full build (~30-60 min with LTO). Every following build restores a 5 GB ccache and reuses it, and stale caches are deleted automatically so only the newest cache per branch+variant is kept.

### Artifacts

The flashable AnyKernel3 zip lands in run artifacts.

## Flashing

Grab the zip from artifacts and flash in recovery. The installer auto-detects the variant and handles `init_boot` and `boot` partitions.
