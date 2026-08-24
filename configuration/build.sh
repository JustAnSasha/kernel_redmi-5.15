#!/usr/bin/env bash
set -e

CFG="$(cd "$(dirname "$0")" && pwd)/build-config.json"
WORK_DIR="$(pwd)"
KERNEL_VERSION="5.15"
ANDROID_VERSION="13"
ANDROID_BRANCH="common-android13-5.15-lts"

VARIANT="${VARIANT:-SukiSU-Ultra}"
KERNEL_DEVICE="${KERNEL_DEVICE:-gki}"
CLANG_VERSION="${CLANG_VERSION:-ZyCromerZ}"
OPT_LEVEL="${OPT_LEVEL:-O3}"
TICK_RATE="${TICK_RATE:-250}"
LTO_TYPE="${LTO_TYPE:-thin}"
BBG="${BBG:-on}"
KPM="${KPM:-off}"
DROIDSPACES="${DROIDSPACES:-off}"
SPOOF_INTEGRITY="${SPOOF_INTEGRITY:-on}"
ENABLE_SUSFS="${ENABLE_SUSFS:-true}"
SYSTEM_DLKM_EROFS="${SYSTEM_DLKM_EROFS:-false}"

kernelDir="common_${KERNEL_DEVICE}"
kernelName="common"
DEFCONFIG_NAME="${KERNEL_DEVICE}_defconfig"
SRC="$WORK_DIR/$kernelDir/$kernelName"

log() { echo -e "\033[1;36m==> $1\033[0m"; }
die() { echo "::error::$1"; exit 1; }

json_get() { jq -r "$1" "$CFG"; }

is_on() { [[ "$1" == "on" || "$1" == "true" ]]; }

apply_patch() {
  local url="$1" file
  file=$(basename "$url")
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
  sudo apt-get install -y repo rsync aria2 jq erofs-utils zip
}

free_space() {
  log "Freeing disk space"
  sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc "/usr/local/share/boost" "$AGENT_TOOLSDIRECTORY"
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
  log "Cloning kernel source"
  git clone --recursive --branch "$KERNEL_BRANCH" \
    "${KERNEL_SOURCE_URL:-$(json_get '.repo.kernelSourceURL')}" \
    "$SRC" --depth=1
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

setup_toolchain() {
  log "Syncing build tools"
  cd "$WORK_DIR"
  repo init -u https://android.googlesource.com/kernel/manifest -b $ANDROID_BRANCH --depth=1
  repo sync -c --optimized-fetch --prune --no-clone-bundle --no-tags --force-sync --fail-fast -j$(nproc)

  local kd="$SRC"
  if [ "$CLANG_VERSION" = "AOSP" ]; then
    log "Fetching AOSP clang r596125"
    rm -rf .repo common
    aria2c -x16 -s16 -j16 -o clang-r596125.tar.gz "$(json_get '.toolchain.aosp.url')"
    mkdir -p prebuilts/clang/host/linux-x86/clang-r596125
    tar -xzf clang-r596125.tar.gz -C prebuilts/clang/host/linux-x86/clang-r596125
    rm -f clang-r596125.tar.gz
    rm -rf prebuilts/clang/host/linux-x86/clang-3289846 \
           prebuilts/clang/host/linux-x86/clang-r450784e \
           prebuilts/clang/host/linux-x86/clang-r547379 \
           prebuilts/clang/host/linux-x86/clang-stable
    sed -i -e 's/^BRANCH=.*/BRANCH=android13-5.15/' \
      -e 's/^CLANG_VERSION=.*/CLANG_VERSION=r596125/' \
      "$kd/build.config.constants"
  else
    log "Fetching latest ZyCromerZ clang"
    local url
    url=$(curl -sL "$(json_get '.toolchain.zycromerz.releaseApi')" | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url' | head -n1)
    [ -z "$url" ] && url=$(json_get '.toolchain.zycromerz.fallbackUrl')
    echo "Using: $url"
    mkdir -p clang-19
    aria2c -x16 -s16 -j16 -o clang.tar.gz "$url"
    tar -C clang-19 -zxf clang.tar.gz && rm clang.tar.gz
    export CLANG_PATH="$WORK_DIR/clang-19"
  fi

  sed -i '/^DEFCONFIG=gki_defconfig/d' "$kd/build.config.gki"
  sed -i '$a\DEFCONFIG='"$DEFCONFIG_NAME" "$kd/build.config.gki"
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

  apply_patch "$(json_get '.repo.extraStuff')/patches/custom-tickrate-options.patch"
  find . -name "*.rej" -delete

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

  json_get '.defconfigExtras[]' >> "$cfg"

  if [ "$SYSTEM_DLKM_EROFS" = "true" ]; then
    log "zram/zsmalloc as modules for system_dlkm EROFS"
    sed -i '/^CONFIG_ZRAM=/d; /^CONFIG_ZSMALLOC=/d; /^CONFIG_ZRAM_DEF_COMP/d; /^CONFIG_MODULE_COMPRESS/d' "$cfg"
    cat >> "$cfg" << 'EOF'
    CONFIG_MODULE_UNLOAD=y
    CONFIG_MODULE_COMPRESS_GZIP=y
    CONFIG_ZRAM=m
    CONFIG_ZRAM_WRITEBACK=y
EOF
  fi
}

patch_extras() {
  cd "$SRC"
  if is_on "$BBG"; then
    log "Baseband-guard"
    wget -qO- "$(json_get '.patches.basebandGuard')" | bash
    echo "CONFIG_BBG=y" >> "arch/arm64/configs/$DEFCONFIG_NAME"
    sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
  fi
  if is_on "$DROIDSPACES"; then
    log "Droidspaces"
    curl -sL "$(json_get '.patches.droidspaces')" | git apply -v --ignore-whitespace
  fi
  if is_on "$SPOOF_INTEGRITY"; then
    log "Integrity spoof"
    curl -Lso spoof-integrity.patch "$(json_get '.repo.extraStuff')/patches/spoof-kernel-integrity.patch"
    patch -p1 --forward < spoof-integrity.patch || true
    rm -f spoof-integrity.patch
  fi
}

setup_ksu() {
  [ "$VARIANT" = "Vanilla" ] && { log "Vanilla build, skipping KSU"; return 0; }
  log "Setting up $VARIANT"
  cd "$SRC"
  rm -rf KernelSU KernelSU-Next drivers/kernelsu

  local setup_url setup_arg dir offset
  setup_url=$(json_get ".variants.\"$VARIANT\".ksu.setupUrl")
  setup_arg=$(json_get ".variants.\"$VARIANT\".ksu.setupArg")
  dir=$(json_get ".variants.\"$VARIANT\".ksu.dir")
  offset=$(json_get ".variants.\"$VARIANT\".ksu.versionOffset // 0")

  curl -LSs "$setup_url" | bash -s "$setup_arg"

  if [ "$VARIANT" = "ReSukiSU" ]; then
    cd KernelSU
    sed -i '/ccflags-y.*KSU_VERSION_FULL/d' kernel/Kbuild kernel/Makefile 2>/dev/null || true
    echo 'ccflags-y += -DKSU_VERSION_FULL=\"@ReSukiSU'"${LOCAL_VERSION}"'\"' >> kernel/Kbuild
    echo "KSUVER=ReSukiSU${LOCAL_VERSION}" >> "$GITHUB_ENV"
    cd ..
    return 0
  fi

  local ksu_dir="$SRC/$dir"
  KSUVER=$(( $(git -C "$ksu_dir" rev-list --count HEAD) + offset ))
  echo "KSUVER=$KSUVER" >> "$GITHUB_ENV"

  local api_ver commit kbuild
  api_ver=$(grep -E "^KSU_VERSION[[:space:]]*=" "$ksu_dir/Makefile" | cut -d'=' -f2 | tr -d '[:space:]')
  [ -z "$api_ver" ] && api_ver=$(json_get ".variants.\"$VARIANT\".ksu.apiFallback")
  commit=$(git -C "$ksu_dir" rev-parse --short=8 HEAD)
  kbuild="$ksu_dir/kernel/Makefile"
  [ -f "$ksu_dir/kernel/Kbuild" ] && kbuild="$ksu_dir/kernel/Kbuild"
  sed -i 's/-DKSU_VERSION_FULL=[^ ]*//g' "$kbuild"
  sed -i '/KSU_VERSION_FULL/d' "$kbuild"
  echo "ccflags-y += -DKSU_VERSION_FULL=\"v${api_ver}-${commit}@shiney\"" >> "$kbuild"
}

setup_susfs() {
  is_on "$ENABLE_SUSFS" || return 0
  [ "$VARIANT" = "Vanilla" ] && return 0
  log "Setting up SuSFS"
  cd "$SRC"
  git clone --depth=1 "$(json_get '.patches.susfsRepo')" -b "$(json_get '.patches.susfsBranch')" susfs

  mkdir -p include/linux fs
  cp -f susfs/kernel_patches/include/linux/susfs.h include/linux/
  cp -f susfs/kernel_patches/include/linux/susfs_def.h include/linux/
  cp -f susfs/kernel_patches/fs/susfs.c fs/

  curl -Lso susfs_kernel.patch "$(json_get '.repo.extraStuff')/patches/50_add_susfs_in_gki-android13-5.15.patch"
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
      git clone --depth=1 "$(json_get '.patches.wildSusfsFix')" wild_susfs_fix
      patch -p2 --forward --fuzz=3 -d drivers/kernelsu < susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch || true
      local fix_dir="wild_susfs_fix/$(json_get ".variants.\"$VARIANT\".ksu.wildFixDir")"
      for p in $(json_get ".variants.\"$VARIANT\".ksu.wildFixPatches[]"); do
        if [ -f "$fix_dir/$p" ]; then
          patch -p2 --forward -d drivers/kernelsu < "$fix_dir/$p" && echo "applied $p" || echo "skipped $p"
        fi
      done
      rm -rf wild_susfs_fix
      ;;
  esac
  rm -rf susfs
}
configure_ksu_defconfig() {
  cd "$SRC"
  local cfg="arch/arm64/configs/$DEFCONFIG_NAME"
  sed -i '/^CONFIG_KSU=/d; /^CONFIG_KSU_TRACEPOINT_HOOK=/d; /^CONFIG_KSU_MANUAL_HOOK=/d; /^CONFIG_KSU_SUSFS/d' "$cfg"

  [ "$VARIANT" = "Vanilla" ] && return 0

  json_get '.ksuBaseConfig[]' >> "$cfg"

  if is_on "$ENABLE_SUSFS"; then
    if [ "$VARIANT" = "ReSukiSU" ]; then
      printf '# CONFIG_KSU_TRACEPOINT_HOOK is not set\n# CONFIG_KSU_MANUAL_HOOK is not set\n' >> "$cfg"
    fi
    json_get '.susfsConfig[]' >> "$cfg"
  fi
}

compile() {
  log "Compiling kernel"
  cd "$WORK_DIR"
  local extra=""
  [ "$VARIANT" = "ReSukiSU" ] && extra="LLVM=1 LLVM_IAS=1"
  if [ "$CLANG_VERSION" = "AOSP" ]; then
    LTO="$LTO_TYPE" \
      BUILD_CONFIG="$kernelDir/$kernelName/build.config.gki.aarch64" \
      build/build.sh -j$(nproc --all) $extra
  else
    export PATH="$CLANG_PATH/bin:$PATH"
    LTO="$LTO_TYPE" \
      BUILD_CONFIG="$kernelDir/$kernelName/build.config.gki.aarch64" \
      build/build.sh -j$(nproc --all) CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- $extra
  fi
}

apply_kpm() {
  is_on "$KPM" || return 0
  log "Applying KPM patch"
  cd "$WORK_DIR/out/dist"
  local url
  url=$(curl -sL "$(json_get '.patches.kpmApi')" | jq -r '.assets[] | select(.name == "patch_linux") | .browser_download_url' | head -n1)
  [ -z "$url" ] && url=$(json_get '.patches.kpmFallback')
  echo "Using: $url"
  curl -fL -s -o patch_linux "$url"
  chmod +x patch_linux && ./patch_linux
  [ -f oImage ] && mv -f oImage Image
}

pack_erofs() {
  [ "$SYSTEM_DLKM_EROFS" = "true" ] || return 0
  log "Packing system_dlkm as EROFS"
  cd "$WORK_DIR/out/dist"
  [ -f Image ] || die "Kernel image missing"

  local staging="system_dlkm_staging"
  rm -rf "$staging" system_dlkm.img
  mkdir -p "$staging/lib/modules"
  find . -maxdepth 1 \( -name "*.ko" -o -name "*.ko.gz" \) -exec cp -f {} "$staging/lib/modules/" \;

  for req in zram zsmalloc lz4 lz4hc zstd zcomp; do
    ls "$staging/lib/modules/" | grep -q "^${req}" && echo "packed ${req}.ko" || echo "::warning::${req}.ko not found in build output"
  done

  mkfs.erofs -z lz4hc,9 -T 1230768000 system_dlkm.img "$staging" 2>/dev/null || \
    mkfs.erofs -z lz4hc system_dlkm.img "$staging"
  rm -rf "$staging"
  ls -la system_dlkm.img
}

package_ak3() {
  log "Packaging AnyKernel3"
  cd "$WORK_DIR"
  [ -f out/dist/Image ] || die "Kernel image missing"

  git clone --depth=1 "$(json_get '.repo.anyKernel3')" -b master AK3_Workspace
  rm -rf AK3_Workspace/.git

  local img_name
  img_name=$(json_get ".variants.\"$VARIANT\".image")
  cp out/dist/Image "AK3_Workspace/$img_name"

  [ -f out/dist/system_dlkm.img ] && cp out/dist/system_dlkm.img AK3_Workspace/system_dlkm.img

  local build_time zip_name
  build_time=$(date +'%Y-%m-%d')
  zip_name="${VARIANT}_AK3_${KERNEL_BRANCH}_${build_time}"
  echo "ZIP_NAME=$zip_name" >> "$GITHUB_ENV"
  echo "AK3_DIR=$WORK_DIR/AK3_Workspace" >> "$GITHUB_ENV"
  echo "ZIP_PATH=$WORK_DIR/AK3_Workspace" >> "$GITHUB_ENV"
  echo "Done: $zip_name"
}

prepare_env
free_space
add_swap
clone_kernel
spoof_version
setup_toolchain
configure_defconfig
patch_extras
setup_ksu
setup_susfs
configure_ksu_defconfig
compile
apply_kpm
pack_erofs
package_ak3
