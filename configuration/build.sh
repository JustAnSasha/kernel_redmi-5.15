#!/usr/bin/env bash
set -euo pipefail

CFG="$(cd "$(dirname "$0")" && pwd)/build-config.json"
WORK_DIR="$(pwd)"

VARIANT="${VARIANT:-SukiSU-Ultra}"
KERNEL_DEVICE="${KERNEL_DEVICE:-gki}"
CLANG_VERSION="${CLANG_VERSION:-ZyCromerZ}"
OPT_LEVEL="${OPT_LEVEL:-O3}"
TICK_RATE="${TICK_RATE:-250}"
LTO_TYPE="${LTO_TYPE:-thin}"
BBG="${BBG:-on}"
SPOOF_INTEGRITY="${SPOOF_INTEGRITY:-off}"
KPM="${KPM:-off}"
DROIDSPACES="${DROIDSPACES:-off}"
ENABLE_SUSFS="${ENABLE_SUSFS:-true}"
SYSTEM_DLKM="${SYSTEM_DLKM:-false}"

KERNEL_BRANCH="${KERNEL_BRANCH:-$(jq -r '.repo.kernelBranch' "$CFG") }"
KERNEL_SOURCE_URL="${KERNEL_SOURCE_URL:-$(jq -r '.repo.kernelSourceURL' "$CFG") }"
KERNEL_SPOOF_VERSION="${KERNEL_SPOOF_VERSION:-}"
LOCAL_VERSION="${LOCAL_VERSION:-}"

kernelDir="common_${KERNEL_DEVICE}"
kernelName="common"
DEFCONFIG_NAME="${KERNEL_DEVICE}_defconfig"
SRC="$WORK_DIR/$kernelDir/$kernelName"
DIST_DIR="$WORK_DIR/out/dist"

log() { echo -e "\033[1;35m==> $1\033[0m"; }
die() { echo "::error::$1"; exit 1; }
json() { jq -r "$1" "$CFG"; }
is_on() { [[ "$1" == "on" || "$1" == "true" ]]; }

apply_patch() {
  local url="$1" file
  file="$(basename "$url")"
  curl -L -s -f -o "$file" "$url" || return 1
  if patch -p1 --forward --dry-run < "$file" >/dev/null 2>&1; then
    patch -p1 --forward < "$file"
  fi
  rm -f "$file"
}

prepare_env() {
  log "Preparing environment"
  mkdir -p "$kernelDir"
  sudo apt-get update -qq
  sudo apt-get install -y repo rsync aria2 jq zip ccache binutils lld gcc-aarch64-linux-gnu
}

free_space() {
  log "Freeing disk space"
  sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/share/boost "${AGENT_TOOLSDIRECTORY:-}"
  sudo docker image prune --all --force 2>/dev/null || true
  sudo docker builder prune -a -f 2>/dev/null || true
}

add_swap() {
  log "Adding swap"
  if [ -f /swapfile ]; then
    sudo swapoff /swapfile 2>/dev/null || true
    sudo rm -f /swapfile
  fi
  sudo dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
}

clone_kernel() {
  log "Cloning kernel source ($KERNEL_BRANCH)"
  git clone --recursive --branch "$KERNEL_BRANCH" "$KERNEL_SOURCE_URL" "$SRC" --depth=1
  log "Reading kernel version from Makefile"
  local ver
  ver="$(sed -n 's/^VERSION *= *//p' "$SRC/Makefile").$(sed -n 's/^PATCHLEVEL *= *//p' "$SRC/Makefile")"
  local sub
  sub="$(sed -n 's/^SUBLEVEL *= *//p' "$SRC/Makefile")"
  [ -n "$sub" ] && [ "$sub" != "0" ] && ver="$ver.$sub"
  echo "KERNEL_MAKE_VERSION=$ver" >> "${GITHUB_ENV:-/dev/null}"
  log "Kernel version: $ver"
}

spoof_version() {
  [ -z "$KERNEL_SPOOF_VERSION" ] && return 0
  log "Spoofing kernel version to ${KERNEL_SPOOF_VERSION}${LOCAL_VERSION}"
  cd "$SRC"
  sed -i "s/^KERNELVERSION =.*/KERNELVERSION = ${KERNEL_SPOOF_VERSION}${LOCAL_VERSION}/" Makefile
  echo "" > .scmversion
  sed -i 's/echo "\$res"/#echo "\$res"/g' scripts/setlocalversion
  local cfg="arch/arm64/configs/$DEFCONFIG_NAME"
  sed -i '/CONFIG_LOCALVERSION/d; /CONFIG_LOCALVERSION_AUTO/d' "$cfg"
  echo "CONFIG_LOCALVERSION=\"$LOCAL_VERSION\"" >> "$cfg"
  echo "CONFIG_LOCALVERSION_AUTO=n" >> "$cfg"
  [ -f build.config.constants ] && \
    sed -i "s/^KERNEL_VERSION=.*/KERNEL_VERSION=${KERNEL_SPOOF_VERSION}${LOCAL_VERSION}/" build.config.constants
}

spoof_integrity() {
  is_on "$SPOOF_INTEGRITY" || return 0
  log "Applying integrity spoof patch"
  cd "$SRC"
  apply_patch "$(json '.patches.spoofIntegrity')"
}

setup_toolchain() {
  log "Syncing build tools"
  cd "$WORK_DIR"
  repo init -u https://android.googlesource.com/kernel/manifest -b "$(json '.device.androidBranch')" --depth=1
  repo sync -c --optimized-fetch --prune --no-clone-bundle --no-tags --force-sync --fail-fast -j"$(nproc)"

  local kd="$SRC"
  if [ "$CLANG_VERSION" = "AOSP" ]; then
    log "Fetching latest AOSP clang"
    rm -rf .repo common
    local clang_ver
    clang_ver="$(curl -s "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/refs/heads/main/?format=JSON" | sed '1d' | jq -r '.entries[].name' | grep -E '^clang-r[0-9]+' | head -n1 || true)"
    [ -z "$clang_ver" ] && clang_ver="$(json '.toolchain.aosp.version')"
    log "Using $clang_ver"
    local clang_dir="prebuilts/clang/host/linux-x86/$clang_ver"
    mkdir -p "$clang_dir"
    aria2c -x16 -s16 -j16 -o clang.tar.gz "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/${clang_ver}.tar.gz"
    tar -xzf clang.tar.gz -C "$clang_dir" --strip-components=1 2>/dev/null || tar -xzf clang.tar.gz -C "$clang_dir"
    rm -f clang.tar.gz
    find prebuilts/clang/host/linux-x86 -maxdepth 1 -type d ! -name host ! -name "$clang_ver" -exec rm -rf {} +
    sed -i -e 's/^BRANCH=.*/BRANCH=android13-5.15/' \
      -e "s/^CLANG_VERSION=.*/CLANG_VERSION=$clang_ver/" \
      "$kd/build.config.constants"
  else
    log "Fetching latest ZyCromerZ clang"
    local url
    url="$(curl -sL "$(json '.toolchain.zycromerz.releaseApi')" | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url' | head -n1 || true)"
    [ -z "$url" ] && url="$(json '.toolchain.zycromerz.fallbackUrl')"
    log "Using $(basename "$url")"
    mkdir -p clang
    aria2c -x16 -s16 -j16 -o clang.tar.gz "$url"
    tar -C clang -zxf clang.tar.gz && rm clang.tar.gz
    export CLANG_PATH="$WORK_DIR/clang"
  fi

  sed -i '/^DEFCONFIG=gki_defconfig/d' "$kd/build.config.gki"
  sed -i '$a\DEFCONFIG='"$DEFCONFIG_NAME" "${kd}/build.config.gki"
  sed -i '/^POST_DEFCONFIG_CMDS="check_defconfig"/d' "$kd/build.config.gki"
  sed -i \
    -e '/^KMI_SYMBOL_LIST_STRICT_MODE=/d' -e '/^TRIM_NONLISTED_KMI=/d' -e '/^KMI_ENFORCED=/d' \
    -e '$a\KMI_SYMBOL_LIST_STRICT_MODE=0' -e '$a\TRIM_NONLISTED_KMI=0' -e '$a\KMI_ENFORCED=0' \
    -e '/^MODULES_ORDER=/d' -e '/^MODULES_LIST=/d' \
    "$kd/build.config.gki.aarch64"
}

configure_defconfig() {
  log "Configuring defconfig"
  cd "$SRC"
  local cfg="arch/arm64/configs/$DEFCONFIG_NAME"

  sed -i '/CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE\b/d; /CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3/d; /CONFIG_CC_OPTIMIZE_FOR_SIZE/d' "$cfg"
  case "$OPT_LEVEL" in
    O2) echo "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y"    >> "$cfg" ;;
    O3) echo "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=y" >> "$cfg" ;;
    Os) echo "CONFIG_CC_OPTIMIZE_FOR_SIZE=y"           >> "$cfg" ;;
  esac

  if [ "$TICK_RATE" != "default" ]; then
    sed -i '/^CONFIG_HZ_/d; /^CONFIG_HZ=/d' "$cfg"
    printf 'CONFIG_NO_HZ_IDLE=y\nCONFIG_HZ=%s\nCONFIG_HZ_%s=y\n' "$TICK_RATE" "$TICK_RATE" >> "$cfg"
  fi

  sed -i '/^CONFIG_LTO_CLANG/d; /^CONFIG_THINLTO/d' "$cfg"
  if [ "$LTO_TYPE" = "thin" ]; then
    printf 'CONFIG_LTO_CLANG=y\nCONFIG_LTO_CLANG_THIN=y\nCONFIG_THINLTO=y\n' >> "$cfg"
  else
    printf 'CONFIG_LTO_CLANG=y\nCONFIG_LTO_CLANG_FULL=y\n' >> "$cfg"
  fi

  if is_on "$SYSTEM_DLKM"; then
    log "system_dlkm enabled, switching zram/zsmalloc to modules"
    sed -i '/^CONFIG_ZRAM=/d; /^CONFIG_ZSMALLOC=/d; /^# CONFIG_ZRAM is not set/d; /^# CONFIG_ZSMALLOC is not set/d' "$cfg"
    printf 'CONFIG_ZRAM=m\nCONFIG_ZSMALLOC=m\nCONFIG_MODULE_UNLOAD=y\nCONFIG_MODULES=y\n' >> "$cfg"
  fi

  json '.defconfigExtras[]' >> "$cfg"
}

patch_extras() {
  cd "$SRC"
  if is_on "$BBG"; then
    log "Applying Baseband Guard"
    wget -qO- "$(json '.patches.basebandGuard')" | bash
    echo "CONFIG_BBG=y" >> "arch/arm64/configs/$DEFCONFIG_NAME"
    sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/{ /baseband_guard/! s/selinux/selinux,baseband_guard/; }; }' security/Kconfig
  fi
  if is_on "$DROIDSPACES"; then
    log "Applying Droidspaces"
    curl -sL "$(json '.patches.droidspaces')" | git apply -v --ignore-whitespace
  fi
}

setup_ksu() {
  [ "$VARIANT" = "Vanilla" ] && { log "Vanilla build, skipping KSU"; return 0; }
  log "Setting up $VARIANT"

  cd "$SRC"
  rm -rf KernelSU KernelSU-Next drivers/kernelsu KernelSU-Workspace
  local setup_url setup_arg dir ksurepo ksu_ref
  setup_url="$(json ".variants.\"$VARIANT\".ksu.setupUrl")"
  setup_arg="$(json ".variants.\"$VARIANT\".ksu.setupArg")"
  dir="$(json ".variants.\"$VARIANT\".ksu.dir")"
  ksurepo="$(echo "$setup_url" | sed -E 's|.*github.com[:/]+([^/]+/[^/]+)(\.git)?$|\1|')"
  ksu_ref="${setup_arg:-main}"

  log "Cloning $ksurepo @ $ksu_ref"
  if git ls-remote --heads "https://github.com/$ksurepo.git" "$ksu_ref" | grep -q .; then
    git clone --depth=64 --single-branch --branch "$ksu_ref" "https://github.com/$ksurepo.git" /tmp/ksu-src
  else
    git clone --depth=64 "https://github.com/$ksurepo.git" /tmp/ksu-src
    git -C /tmp/ksu-src fetch --depth=64 origin "$ksu_ref"
    git -C /tmp/ksu-src checkout --detach FETCH_HEAD
  fi
  log "Linking KSU into kernel tree via setup script"
  bash /tmp/ksu-src/kernel/setup.sh "$ksu_ref" || bash /tmp/ksu-src/setup.sh "$ksu_ref"

  local commits ksu_version ksu_commit ksu_tag
  commits=$(git -C /tmp/ksu-src rev-list --count HEAD)
  ksu_version=$((30000 + commits))
  ksu_commit=$(git -C /tmp/ksu-src rev-parse --short HEAD)
  ksu_tag=$(git -C /tmp/ksu-src describe --tags --abbrev=0 2>/dev/null || echo "unknown")

  if [ -f "$SRC/$dir/Kbuild" ]; then
    sed -i "s/^KSU_VERSION_FALLBACK := .*/KSU_VERSION_FALLBACK := ${ksu_version}/" "$SRC/$dir/Kbuild" || true
    if [ -n "$LOCAL_VERSION" ]; then
      sed -i "s|\(-DKSU_VERSION_FULL=[^\"]*\)\"|\1${LOCAL_VERSION}\"|" "$SRC/$dir/Kbuild" || true
      log "KSU version name suffix: ${LOCAL_VERSION}"
    fi
  fi
  {
    echo "KSUVER=${ksu_tag}-${ksu_commit}"
    echo "KSU_COMMIT=$ksu_commit"
    echo "KSU_VERSION=$ksu_version"
    echo "KSU_GIT_TAG=$ksu_tag"
  } >> "${GITHUB_ENV:-/dev/null}"

  rm -rf /tmp/ksu-src
  log "KSU ready: $VARIANT ($ksu_tag @ $ksu_commit, version $ksu_version)"
}

setup_susfs() {
  is_on "$ENABLE_SUSFS" || return 0
  [ "$VARIANT" = "Vanilla" ] && return 0
  log "Setting up SuSFS"
  cd "$SRC"
  git clone --depth=1 "$(json '.patches.susfsRepo')" -b "$(json '.patches.susfsBranch')" susfs

  mkdir -p include/linux fs
  cp -f susfs/kernel_patches/include/linux/susfs.h include/linux/
  cp -f susfs/kernel_patches/include/linux/susfs_def.h include/linux/
  cp -f susfs/kernel_patches/fs/susfs.c fs/

  curl -Lso susfs_kernel.patch "$(json '.patches.susfsKernel')"
  patch -p1 --forward < susfs_kernel.patch || true
  rm -f susfs_kernel.patch

  case "$VARIANT" in
    KernelSU)
      cd KernelSU
      if [ -f kernel/Kbuild ]; then
        sed -i 's|kernel/Makefile|kernel/Kbuild|g' ../susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch
      fi
      patch -p1 --forward --fuzz=3 < ../susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch || true
      cd ..
      ;;
    KernelSU-Next)
      patch -p2 --forward --fuzz=3 -d drivers/kernelsu < susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch || true
      ;;
  esac
  rm -rf susfs
}

configure_ksu_defconfig() {
  cd "$SRC"
  local cfg="arch/arm64/configs/$DEFCONFIG_NAME"
  sed -i '/^CONFIG_KSU=/d; /^CONFIG_KSU_TRACEPOINT_HOOK=/d; /^CONFIG_KSU_MANUAL_HOOK=/d; /^CONFIG_KSU_SUSFS/d' "$cfg"

  [ "$VARIANT" = "Vanilla" ] && return 0

  json '.ksuBaseConfig[]' >> "$cfg"

  if is_on "$ENABLE_SUSFS"; then
    if [ "$VARIANT" = "ReSukiSU" ]; then
      printf '# CONFIG_KSU_TRACEPOINT_HOOK is not set\n# CONFIG_KSU_MANUAL_HOOK is not set\n' >> "$cfg"
    fi
    json '.susfsConfig[]' >> "$cfg"
  fi
}

compile() {
  log "Compiling kernel"
  cd "$WORK_DIR"
  export CCACHE=1
  export CCACHE_DIR="$WORK_DIR/.ccache"
  local extra=""
  [ "$VARIANT" = "ReSukiSU" ] && extra="LLVM=1 LLVM_IAS=1"
  if [ "$CLANG_VERSION" = "AOSP" ]; then
    LTO="$LTO_TYPE" \
      BUILD_CONFIG="$kernelDir/$kernelName/build.config.gki.aarch64" \
      build/build.sh -j"$(nproc --all)" $extra
  else
    export PATH="$CLANG_PATH/bin:$PATH"
    LTO="$LTO_TYPE" \
      BUILD_CONFIG="$kernelDir/$kernelName/build.config.gki.aarch64" \
      build/build.sh -j"$(nproc --all)" CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- $extra
  fi
}

find_dist() {
  DIST_DIR="$(find "$WORK_DIR/out" -maxdepth 3 -type d -name dist 2>/dev/null | head -n1)"
  [ -z "$DIST_DIR" ] && DIST_DIR="$WORK_DIR/out/dist"
  log "Dist dir: $DIST_DIR"
}

apply_kpm() {
  is_on "$KPM" || return 0
  log "Applying KPM patch"
  cd "$DIST_DIR"
  local url
  url="$(curl -sL "$(json '.patches.kpmApi')" | jq -r '.assets[] | select(.name == "patch_linux") | .browser_download_url' | head -n1 || true)"
  [ -z "$url" ] && url="$(json '.patches.kpmFallback')"
  log "Using $(basename "$url")"
  curl -fL -s -o patch_linux "$url"
  chmod +x patch_linux && ./patch_linux
  [ -f oImage ] && mv -f oImage Image
}

pack_system_dlkm() {
  is_on "$SYSTEM_DLKM" || return 0
  log "Collecting system_dlkm"
  local img
  img="$(find "$WORK_DIR/out" -maxdepth 4 -name "system_dlkm.img" -type f 2>/dev/null | head -n1)"
  if [ -z "$img" ]; then
    echo "::warning::system_dlkm.img not found in build output, it will not be included"
    return 0
  fi
  mkdir -p "$WORK_DIR/dlkm_out"
  cp -f "$img" "$WORK_DIR/dlkm_out/system_dlkm.img"
  ls -la "$WORK_DIR/dlkm_out/system_dlkm.img"
}

package_ak3() {
  log "Packaging AnyKernel3"
  cd "$DIST_DIR"
  [ -f Image ] || die "Kernel image missing"

  cd "$WORK_DIR"
  git clone --depth=1 "$(json '.repo.anyKernel3')" AK3_Workspace
  rm -rf AK3_Workspace/.git

  cp "$DIST_DIR/Image" "AK3_Workspace/Image.${VARIANT}"

  if is_on "$SYSTEM_DLKM" && [ -f "$WORK_DIR/dlkm_out/system_dlkm.img" ]; then
    cp "$WORK_DIR/dlkm_out/system_dlkm.img" AK3_Workspace/system_dlkm.img
    log "Including system_dlkm.img in zip"
  else
    log "system_dlkm disabled or missing, not included in zip"
  fi

  local build_time zip_name
  build_time="$(date +'%Y-%m-%d')"
  zip_name="${VARIANT}_AK3_${KERNEL_BRANCH}_${build_time}"
  echo "ZIP_NAME=$zip_name" >> "${GITHUB_ENV:-/dev/null}"
  echo "AK3_DIR=$WORK_DIR/AK3_Workspace" >> "${GITHUB_ENV:-/dev/null}"
  echo "ZIP_PATH=$WORK_DIR/AK3_Workspace" >> "${GITHUB_ENV:-/dev/null}"
  echo "SYSTEM_DLKM_PACKED=$(is_on "$SYSTEM_DLKM" && echo true || echo false)" >> "${GITHUB_ENV:-/dev/null}"
  log "Done: $zip_name"
}

prepare_env
free_space
add_swap
clone_kernel
spoof_version
spoof_integrity
setup_toolchain
configure_defconfig
patch_extras
setup_ksu
setup_susfs
configure_ksu_defconfig
compile
find_dist
apply_kpm
pack_system_dlkm
package_ak3
