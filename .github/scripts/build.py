#!/usr/bin/env python3
import os
import subprocess as sp
import sys
import time
from contextlib import contextmanager
from datetime import datetime

# ANSI colors
C_CYAN = "\033[96m"
C_GREEN = "\033[92m"
C_YELLOW = "\033[93m"
C_RED = "\033[91m"
C_MAGENTA = "\033[95m"
C_BOLD = "\033[1m"
C_DIM = "\033[2m"
C_RESET = "\033[0m"

# make sure the runner doesn't strip our colors
env = os.environ
if env.get("CI"):
    env["FORCE_COLOR"] = "1"
    if not env.get("TERM"):
        env["TERM"] = "xterm-256color"


def say(msg, color=C_RESET, step=""):
    tag = f"{C_BOLD}[{step}]{C_RESET}" if step else ""
    print(f"{color}{tag} {msg}{C_RESET}", flush=True)


def run(cmd, cwd=None, step="", check=True):
    """Run a shell command, echoing it first like a human would."""
    say(f"$ {' '.join(cmd) if isinstance(cmd, list) else cmd}", color=C_CYAN, step=step)
    proc = sp.run(cmd, shell=isinstance(cmd, str), cwd=cwd)
    if check and proc.returncode != 0:
        say(f"command failed with exit code {proc.returncode}", C_RED, step)
        sys.exit(proc.returncode)
    return proc.returncode


def header(variant, clang):
    print()
    info = [
        ("target", "Redmi Note 12/13 4G · android13-5.15"),
        ("variant", variant),
        ("toolchain", clang),
        ("kicked off", datetime.now().strftime("%Y-%m-%d %H:%M UTC")),
    ]
    for key, val in info:
        print(f"  {C_DIM}{key:>10}{C_RESET} · {C_BOLD}{val}{C_RESET}")
    print()


# ---------------------------------------------------------------- inputs ----

env = os.environ
INPUT = {
    "ksuVariant": env.get("INPUT_KSUVARIANT", env.get("KSUVARIANT", "Vanilla")),
    "kernelSourceURL": env.get("INPUT_KERNELSOURCEURL", "https://github.com/JustAnSasha/kernel_redmi-5.15"),
    "kernelBranch": env.get("INPUT_KERNELBRANCH", "shining"),
    "kernelDevice": env.get("INPUT_KERNELDEVICE", "gki"),
    "kernelSpoofVersion": env.get("INPUT_KERNELSPOOFVERSION", ""),
    "localVersion": env.get("INPUT_LOCALVERSION", ""),
    "SUSFS": env.get("INPUT_SUSFS", "true"),
    "optimizationLevel": env.get("INPUT_OPTIMIZATIONLEVEL", "O3"),
    "clangVersion": env.get("INPUT_CLANGVERSION", "ZyCromerZ"),
    "LtoOptimizations": env.get("INPUT_LTOOPTIMIZATIONS", "thin"),
    "bbg": env.get("INPUT_BBG", "on"),
    "KPM": env.get("INPUT_KPM", "off"),
    "droidspaces": env.get("INPUT_DROIDSPACES", "off"),
    "spoofIntegrity": env.get("INPUT_SPOOFINTEGRITY", "on"),
}

WORK_DIR = env.get("GITHUB_WORKSPACE", os.getcwd())
KERNEL_DIR = f"common_{INPUT['kernelDevice']}"
KERNEL_NAME = "common"
KERNEL = os.path.join(KERNEL_DIR, KERNEL_NAME)
DEFCONFIG = f"{INPUT['kernelDevice']}_defconfig"
CONFIG_FILE = os.path.join(KERNEL_DIR, KERNEL_NAME, "arch/arm64/configs", DEFCONFIG)
VARIANT = INPUT["ksuVariant"]
CLANG_19 = os.path.join(WORK_DIR, "clang-19")


def on(v):
    return str(v).lower() in ("on", "true", "yes", "1")


# ----------------------------------------------------------------- steps ----

def clone_source():
    run(
        f"git clone --recursive --branch {INPUT['kernelBranch']} "
        f"{INPUT['kernelSourceURL']} {KERNEL_NAME} --depth=1",
        cwd=KERNEL_DIR, step="clone",
    )


def set_kernel_version():
    spoof = INPUT["kernelSpoofVersion"]
    local = INPUT["localVersion"]
    if not spoof:
        say("no spoof version given, keeping the original", C_YELLOW, "version")
        return
    full = f"{spoof}{local}"
    kd = os.path.join(WORK_DIR, KERNEL)

    sp.run(
        f'sed -i "s/^KERNELVERSION =.*/KERNELVERSION = {full}/" Makefile && '
        'echo "" > .scmversion && '
        'sed -i \'s/echo "$res"/#echo "$res"/g\' scripts/setlocalversion',
        shell=True, cwd=kd, check=True,
    )
    with open(CONFIG_FILE, "a") as f:
        f.write(f'CONFIG_LOCALVERSION="{local}"\nCONFIG_LOCALVERSION_AUTO=n\n')
    constants = os.path.join(kd, "build.config.constants")
    if os.path.isfile(constants):
        sp.run(f'sed -i "s/^KERNEL_VERSION=.*/KERNEL_VERSION={full}/" build.config.constants',
               shell=True, cwd=kd, check=True)
    say(f"kernel version -> {full}", C_GREEN, "version")


def sync_tools():
    run(
        "repo init -u https://android.googlesource.com/kernel/manifest "
        "-b common-android13-5.15-lts --depth=1 && "
        "repo sync -c --optimized-fetch --prune --no-clone-bundle --no-tags --force-sync --fail-fast "
        f"-j{os.cpu_count()}",
        cwd=WORK_DIR, step="repo",
    )


def install_clang():
    kd = os.path.join(WORK_DIR, KERNEL)
    if INPUT["clangVersion"] == "AOSP":
        run(
            "rm -rf .repo common && "
            "aria2c -x16 -s16 -j16 -o clang-r596125.tar.gz "
            '"https://github.com/yougotme101/clang/releases/download/v1.0.1/clang-r596125.tar.gz" && '
            "mkdir -p prebuilts/clang/host/linux-x86/clang-r596125 && "
            "tar -xzf clang-r596125.tar.gz -C prebuilts/clang/host/linux-x86/clang-r596125 && "
            "rm -f clang-r596125.tar.gz && "
            "rm -rf prebuilts/clang/host/linux-x86/clang-3289846 "
            "prebuilts/clang/host/linux-x86/clang-r450784e "
            "prebuilts/clang/host/linux-x86/clang-r547379 "
            "prebuilts/clang/host/linux-x86/clang-stable",
            cwd=WORK_DIR, step="clang",
        )
        sp.run(
            "sed -i -e 's/^BRANCH=.*/BRANCH=android13-5.15/' "
            "-e 's/^CLANG_VERSION=.*/CLANG_VERSION=r596125/' build.config.constants",
            shell=True, cwd=kd, check=True,
        )
    else:
        run(
            "mkdir -p clang-19 && "
            "aria2c -x16 -s16 -j16 -o clang.tar.gz "
            '"https://github.com/ZyCromerZ/Clang/releases/download/19.0.0git-20240723-release/Clang-19.0.0git-20240723.tar.gz" && '
            "tar -C clang-19 -zxf clang.tar.gz && rm clang.tar.gz",
            cwd=WORK_DIR, step="clang",
        )
        env["CLANG_PATH"] = CLANG_19

    # let the kernel build our defconfig, drop KMI enforcement
    sp.run(
        f"sed -i '/^DEFCONFIG=gki_defconfig/d' build.config.gki && "
        f"echo 'DEFCONFIG={DEFCONFIG}' >> build.config.gki && "
        f"sed -i '/^POST_DEFCONFIG_CMDS=\"check_defconfig\"/d' build.config.gki && "
        f"sed -i "
        f"-e '/^KMI_SYMBOL_LIST_STRICT_MODE=/d' -e '/^TRIM_NONLISTED_KMI=/d' -e '/^KMI_ENFORCED=/d' "
        f"-e '$a\\KMI_SYMBOL_LIST_STRICT_MODE=0' -e '$a\\TRIM_NONLISTED_KMI=0' -e '$a\\KMI_ENFORCED=0' "
        f"-e '/^MODULES_ORDER=/d' -e '/^MODULES_LIST=/d' "
        f"build.config.gki.aarch64",
        shell=True, cwd=kd, check=True,
    )


def tune_defconfig():
    opt = INPUT["optimizationLevel"]
    with open(CONFIG_FILE) as f:
        lines = [l for l in f if not any(
            k in l for k in (
                "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE",
                "CONFIG_CC_OPTIMIZE_FOR_SIZE",
                "CONFIG_LTO_CLANG",
                "CONFIG_THINLTO",
            )
        )]
    lines.append({"O2": "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y\n",
                  "O3": "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=y\n",
                  "Os": "CONFIG_CC_OPTIMIZE_FOR_SIZE=y\n"}[opt])
    if INPUT["LtoOptimizations"] == "thin":
        lines += ["CONFIG_LTO_CLANG=y\n", "CONFIG_LTO_CLANG_THIN=y\n", "CONFIG_THINLTO=y\n"]
    else:
        lines += ["CONFIG_LTO_CLANG=y\n", "CONFIG_LTO_CLANG_FULL=y\n"]
    lines += ["CONFIG_STRIP_ASM_SYMS=y\n", "CONFIG_LD_DEAD_CODE_DATA_ELIMINATION=y\n"]
    with open(CONFIG_FILE, "w") as f:
        f.writelines(lines)
    say(f"optimization -{opt}, LTO {INPUT['LtoOptimizations']}", C_GREEN, "defconfig")

def patch_applicator(kd):
    """Apply a patch if it hasn't been applied yet - be forgiving about it."""
    def apply(url, patch_args=("-p1", "--forward")):
        name = os.path.basename(url)
        path = os.path.join(kd, name)
        sp.run(f"curl -Lso {name} {url}", shell=True, cwd=kd, check=True)
        if sp.run(f"patch {' '.join(patch_args)} --dry-run < {name}",
                  shell=True, cwd=kd).returncode == 0:
            sp.run(f"patch {' '.join(patch_args)} < {name}", shell=True, cwd=kd, check=True)
        os.remove(path)
    return apply


def add_optional_features():
    kd = os.path.join(WORK_DIR, KERNEL)
    if on(INPUT["bbg"]):
        run(
            'wget -qO- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash && '
            f'echo "CONFIG_BBG=y" >> {CONFIG_FILE}',
            cwd=kd, step="bbg",
        )
        sp.run(
            "sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ "
            "{ /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig",
            shell=True, cwd=kd, check=True,
        )
    if on(INPUT["droidspaces"]):
        run(
            "curl -sL 'https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/"
            "Documentation/resources/kernel-patches/GKI/below-kernel-6.12/"
            "001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch' | git apply -v --ignore-whitespace",
            cwd=kd, step="droidspaces",
        )
    if on(INPUT["spoofIntegrity"]):
        patch_applicator(kd)(
            "https://raw.githubusercontent.com/JustAnSasha/extra_kernel_stuff/main/patches/spoof-kernel-integrity.patch"
        )


KSU_SETUP = {
    "KernelSU": ("https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh", "main", "KernelSU"),
    "KernelSU-Next": ("https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/refs/heads/dev/kernel/setup.sh", "dev", "KernelSU-Next"),
    "SukiSU-Ultra": ("https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/builtin/kernel/setup.sh", "susfs_new", "KernelSU"),
    "ReSukiSU": ("https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh", "main", "KernelSU"),
}


def setup_ksu():
    kd = os.path.join(WORK_DIR, KERNEL)
    url, branch, _ = KSU_SETUP[VARIANT]
    run(
        f"rm -rf KernelSU KernelSU-Next drivers/kernelsu && "
        f"curl -LSs {url} | bash -s {branch}",
        cwd=kd, step=f"setup {VARIANT}",
    )


def setup_susfs():
    if not on(INPUT["SUSFS"]):
        say("disabled, skipping", C_YELLOW, "susfs")
        return
    kd = os.path.join(WORK_DIR, KERNEL)
    run(
        "git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android13-5.15 susfs",
        cwd=kd, step="susfs",
    )
    sp.run(
        "mkdir -p include/linux fs && "
        "cp -f susfs/kernel_patches/include/linux/susfs.h include/linux/ && "
        "cp -f susfs/kernel_patches/include/linux/susfs_def.h include/linux/ && "
        "cp -f susfs/kernel_patches/fs/susfs.c fs/",
        shell=True, cwd=kd, check=True,
    )
    patch_applicator(kd)(
        "https://raw.githubusercontent.com/JustAnSasha/extra_kernel_stuff/main/patches/"
        "50_add_susfs_in_gki-android13-5.15.patch"
    )
    if VARIANT == "KernelSU":
        patch_file = os.path.join(kd, "susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch")
        if os.path.isfile(os.path.join(kd, "KernelSU/kernel/Kbuild")):
            sp.run(f"sed -i 's|kernel/Makefile|kernel/Kbuild|g' {patch_file}", shell=True, cwd=kd, check=True)
        sp.run(f"patch -p1 --forward --fuzz=3 < {patch_file} || true", shell=True, cwd=kd)
    elif VARIANT == "KernelSU-Next":
        run("git clone --depth=1 https://github.com/WildKernels/kernel_patches.git wild_susfs_fix",
            cwd=kd, step="susfs")
        patch_file = os.path.join(kd, "susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch")
        sp.run(f"patch -p2 --forward --fuzz=3 -d drivers/kernelsu < {patch_file} || true", shell=True, cwd=kd)
        fix_dir = os.path.join(kd, "wild_susfs_fix/next/susfs_fix_patches/stable/v2.2.0")
        for p in ("fix_Kbuild.patch", "fix_init.c.patch", "fix_kernel_umount.c.patch",
                  "fix_setuid_hook.c.patch", "fix_sucompat.c.patch", "fix_supercall.c.patch",
                  "ksu_toolkit.patch", "overwrite_hook_mode.patch"):
            fix = os.path.join(fix_dir, p)
            if os.path.isfile(fix):
                ok = sp.run(f"patch -p2 --forward -d drivers/kernelsu < {fix}",
                            shell=True, cwd=kd).returncode == 0
                say(f"{p} {'applied' if ok else 'skipped (conflict)'}",
                    C_GREEN if ok else C_YELLOW, "susfs")
    run("rm -rf susfs wild_susfs_fix", cwd=kd, step="susfs")


KSU_CONFIGS = [
    "CONFIG_KSU=y",
    "CONFIG_OVERLAY_FS=y",
    "CONFIG_TMPFS_XATTR=y",
    "CONFIG_TMPFS_POSIX_ACL=y",
    "CONFIG_KALLSYMS=y",
]

SUSFS_CONFIGS = [
    "CONFIG_KSU_SUSFS=y",
    "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y",
    "CONFIG_KSU_SUSFS_SUS_PATH=y",
    "CONFIG_KSU_SUSFS_SUS_MOUNT=y",
    "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y",
    "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y",
    "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y",
    "CONFIG_KSU_SUSFS_SUS_KSTAT=y",
    "CONFIG_KSU_SUSFS_TRY_UMOUNT=y",
    "CONFIG_KSU_SUSFS_SPOOF_UNAME=y",
    "CONFIG_KSU_SUSFS_ENABLE_LOG=y",
    "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y",
    "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y",
    "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y",
    "CONFIG_KSU_SUSFS_SUS_MAP=y",
]


def configure_ksu():
    if VARIANT == "Vanilla":
        return
    with open(CONFIG_FILE) as f:
        lines = [l for l in f if "CONFIG_KSU" not in l]
    lines += [c + "\n" for c in KSU_CONFIGS]
    if VARIANT == "ReSukiSU":
        lines += ["# CONFIG_KSU_TRACEPOINT_HOOK is not set\n",
                  "# CONFIG_KSU_MANUAL_HOOK is not set\n"]
    if on(INPUT["SUSFS"]):
        lines += [c + "\n" for c in SUSFS_CONFIGS]
        if VARIANT != "ReSukiSU":
            lines.append("CONFIG_KSU_SUSFS_SUS_SU=y\n")
    with open(CONFIG_FILE, "w") as f:
        f.writelines(lines)
    say(f"KSU + SuSFS config written ({VARIANT})", C_GREEN, "config")


def compile_kernel():
    if not on(env.get("INPUT_SAVECACHE", "true")):
        env["CCACHE_MAXSIZE"] = "0"
    jobs = os.cpu_count()
    build_config = f"{KERNEL}/build.config.gki.aarch64"
    env["PATH"] = "/usr/lib/ccache:" + env.get("CLANG_PATH", "") + "/bin:" + env["PATH"]

    if INPUT["clangVersion"] == "AOSP":
        cmd = (
            f"LTO={INPUT['LtoOptimizations']} BUILD_CONFIG={build_config} "
            f"LLVM=1 LLVM_IAS=1 CC='ccache clang' build/build.sh -j{jobs}"
        )
    else:
        cmd = (
            f"LTO={INPUT['LtoOptimizations']} BUILD_CONFIG={build_config} "
            f"build/build.sh -j{jobs} "
            "LLVM=1 LLVM_IAS=1 CC='ccache clang' CLANG_TRIPLE=aarch64-linux-gnu- "
            "CROSS_COMPILE=aarch64-linux-gnu-"
        )
    run(cmd, cwd=WORK_DIR, step="build")
    sp.run("ccache -s", shell=True)


def apply_kpm():
    dist = os.path.join(WORK_DIR, "out/dist")
    run(
        "curl -fL -s -o patch_linux "
        "https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.13.0/patch_linux && "
        "chmod +x patch_linux && ./patch_linux && "
        "[ -f oImage ] && mv -f oImage Image",
        cwd=dist, step="kpm",
    )


def package_ak3():
    dist_image = os.path.join(WORK_DIR, "out/dist/Image")
    if not os.path.isfile(dist_image):
        say("kernel image missing, nothing to package", C_RED, "package")
        sys.exit(1)

    ak3 = os.path.join(WORK_DIR, "AK3_Workspace")
    run(
        "git clone --depth=1 https://github.com/JustAnSasha/AnyKernel3 -b master AK3_Workspace && "
        "rm -rf AK3_Workspace/.git",
        cwd=WORK_DIR, step="package",
    )
    image_name = "Image.Vanilla" if VARIANT == "Vanilla" else f"Image.{VARIANT}"
    with open(dist_image, "rb") as src, open(os.path.join(ak3, image_name), "wb") as dst:
        dst.write(src.read())

    date = datetime.now().strftime("%Y-%m-%d")
    zip_name = f"{VARIANT}_AK3_{INPUT['kernelBranch']}_{date}"
    with open(os.path.join(WORK_DIR, "ak3_env.txt"), "w") as f:
        f.write(f"ZIP_NAME={zip_name}\nAK3_DIR={ak3}\n")
    env["ZIP_NAME"] = zip_name
    env["AK3_DIR"] = ak3
    say(f"packed {zip_name}", C_GREEN, "package")


@contextmanager
def phase(name):
    """Narrate a chunk of work like a person would: announce, do, report time."""
    started = time.time()
    print(f"\n{C_BOLD}{C_MAGENTA}▶ {name}{C_RESET}", flush=True)
    try:
        yield
    except SystemExit:
        print(f"{C_RED}✖ {name} failed after {_fmt_secs(time.time() - started)}{C_RESET}", flush=True)
        raise
    print(f"{C_GREEN}✔ {name} — {_fmt_secs(time.time() - started)}{C_RESET}", flush=True)


def _fmt_secs(secs):
    if secs < 60:
        return f"{secs:.1f}s"
    return f"{int(secs // 60)}m {int(secs % 60)}s"


def main():
    header(VARIANT, INPUT["clangVersion"])
    print(f"{C_DIM}right, let's build a kernel. grabbing coffee... ☕{C_RESET}")

    if os.path.isdir(os.path.join(WORK_DIR, KERNEL_DIR)):
        with phase("kernel source"):
            say("already here from a previous run, skipping clone", C_YELLOW, "clone")
    else:
        with phase("cloning kernel source"):
            clone_source()

    with phase("setting kernel version"):
        set_kernel_version()
    with phase("syncing build tools (this one takes a while)"):
        sync_tools()
    with phase("installing clang"):
        install_clang()
    with phase("tuning defconfig"):
        tune_defconfig()
    with phase("optional features"):
        add_optional_features()
    if VARIANT != "Vanilla":
        with phase(f"setting up {VARIANT}"):
            setup_ksu()
        if on(INPUT["SUSFS"]):
            with phase("applying SuSFS"):
                setup_susfs()
    with phase("writing kernel config"):
        configure_ksu()
    with phase("compiling kernel (grab a snack, this is the long one)"):
        compile_kernel()
    if VARIANT != "Vanilla" and on(INPUT["KPM"]):
        with phase("patching image with KPM"):
            apply_kpm()
    with phase("packaging AnyKernel3 zip"):
        package_ak3()

    print()
    say("all done, kernel image is ready 🎉", C_GREEN, "main")


if __name__ == "__main__":
    main()
