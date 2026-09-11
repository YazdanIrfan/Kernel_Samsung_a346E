#!/bin/bash
# ==============================================================================
# Build script for Samsung A346E kernel (MediaTek mt6877, kernel-6.6)
# Updated to support KernelSU-Next & SUSFS v2.2.0
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"
export PATH="${ROOT_DIR}/bin:${PATH}"
export TMPDIR=/tmp

RED='\033[1;31m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; GREEN='\033[1;32m'; NC='\033[0m'

log()  { echo -e "\n${BLUE}[$(date +%H:%M:%S)] $*${NC}"; }
ok()   { echo -e "${GREEN}[OK] $*${NC}"; }
warn() { echo -e "\n${YELLOW}[WARN] $*${NC}" >&2; }
die()  { echo -e "\n${RED}[ERROR] $*${NC}" >&2; exit 1; }

ensure_dir() { mkdir -p "$1"; }

detect_kernel_dir() {
  if [ -d "${ROOT_DIR}/Kernel-6.6" ] && [ -f "${ROOT_DIR}/Kernel-6.6/Makefile" ]; then
    echo "${ROOT_DIR}/Kernel-6.6"
  elif [ -d "${ROOT_DIR}/kernel-6.6" ] && [ -f "${ROOT_DIR}/kernel-6.6/Makefile" ]; then
    echo "${ROOT_DIR}/kernel-6.6"
  else
    die "Could not find kernel-6.6 or Kernel-6.6 with Makefile in ${ROOT_DIR}"
  fi
}

setup_system() {
  log "ROOT_DIR=${ROOT_DIR}"
  log "SCRIPT_DIR=${SCRIPT_DIR}"
  ensure_dir "${ROOT_DIR}/bin"
  ulimit -n 4096 2>/dev/null || warn "ulimit -n 4096 failed"

  if [ -z "${GITHUB_ACTIONS:-}" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      log "Installing host dependencies (local build)"
      sudo apt-get update -y || warn "apt-get update failed"
      sudo apt-get install -y curl wget unzip python3 python3-pip git rsync \
        bc bison flex build-essential libssl-dev libelf-dev libncurses-dev \
        dwarves lz4 zstd cpio libxml2-utils xsltproc || warn "apt install partial fail"
    fi
  else
    log "Running in GitHub Actions - skipping apt install (handled by workflow)"
  fi

  git config --global user.email "builder@example.com" || true
  git config --global user.name "Builder" || true
  git config --global --add safe.directory "*" || true

  df -h || true
  nproc || true
  free -h || true
}

download_repo_tool() {
  local dest="${ROOT_DIR}/bin/repo"
  if [ -f "$dest" ] && [ -s "$dest" ] && head -n 5 "$dest" | grep -q "repo"; then
    log "repo tool already present at $dest"
    chmod a+x "$dest"
    return 0
  fi

  log "Downloading repo tool to $dest"
  local urls=(
    "https://storage.googleapis.com/git-repo-downloads/repo"
    "https://raw.githubusercontent.com/GerritCodeReview/git-repo/main/repo"
  )
  for url in "${urls[@]}"; do
    if command -v curl >/dev/null 2>&1; then
      curl -L --retry 3 --retry-delay 5 -fsSL -o "$dest" "$url" && [ -s "$dest" ] && chmod a+x "$dest" && return 0 || rm -f "$dest"
    fi
    if command -v wget >/dev/null 2>&1; then
      wget -q -O "$dest" "$url" && [ -s "$dest" ] && chmod a+x "$dest" && return 0 || rm -f "$dest"
    fi
  done

  warn "Failed to download repo from mirrors, trying apt"
  sudo apt-get install -y repo || true
  if command -v repo >/dev/null 2>&1; then
    cp "$(command -v repo)" "$dest" || true
    chmod a+x "$dest" || true
  fi

  [ -f "$dest" ] && [ -s "$dest" ] || die "repo tool not available at $dest"
  chmod a+x "$dest"
  "$dest" --version || true
}

sync_aosp_kernel() {
  log "Syncing aosp-kernel (common-android15-6.6)"
  local aosp_dir="${ROOT_DIR}/aosp-kernel"
  ensure_dir "$aosp_dir"
  pushd "$aosp_dir" >/dev/null

  if [ ! -d .repo ]; then
    log "repo init"
    if ! repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6 --depth=1 --no-clone-bundle --repo-url=https://gerrit.googlesource.com/git-repo; then
      repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6 --depth=1 --no-clone-bundle || warn "repo init failed"
    fi
  fi

  log "repo sync (up to 3 attempts, -j2)"
  local attempt
  for attempt in 1 2 3; do
    if repo sync -c -j2 --force-sync --no-clone-bundle --no-tags; then
      ok "repo sync succeeded on attempt $attempt"
      break
    fi
    warn "repo sync failed attempt $attempt"
    if [ "$attempt" -eq 3 ]; then
      die "repo sync failed after 3 attempts"
    fi
    sleep 10
  done

  popd >/dev/null
}

link_prebuilts() {
  log "Linking prebuilts"
  local aosp_prebuilts="${ROOT_DIR}/aosp-kernel/prebuilts"
  local kernel_prebuilts="${ROOT_DIR}/kernel/prebuilts"

  if [ ! -d "$aosp_prebuilts" ]; then
    die "aosp-kernel/prebuilts not found at $aosp_prebuilts"
  fi

  rm -rf "$kernel_prebuilts" || true
  ln -sfn "$aosp_prebuilts" "$kernel_prebuilts"
  ok "Linked $kernel_prebuilts -> $aosp_prebuilts"

  for ext in zopfli pigz; do
    local src="${ROOT_DIR}/aosp-kernel/external/${ext}"
    local dst="${ROOT_DIR}/kernel/external/${ext}"
    if [ -d "$src" ] && [ ! -e "$dst" ]; then
      ln -sfn "$src" "$dst" || warn "Failed to link $ext"
      ok "Linked $dst -> $src"
    fi
  done
}

apply_optional_patches() {
  local kdir
  kdir="$(detect_kernel_dir)"

  if [ "${PERMISSIVE:-false}" = "true" ]; then
    local pp="${ROOT_DIR}/Permissive/selinux-make-permissive.patch"
    [ -f "$pp" ] || die "PERMISSIVE=true but $pp not found"
    log "PERMISSIVE=true -> applying $(basename "$pp") to $kdir"
    if patch -p1 -d "$kdir" --forward --batch < "$pp" >/tmp/permissive.log 2>&1; then
      ok "SELinux permissive patch applied"
    elif grep -q "Reversed (or previously applied)" /tmp/permissive.log; then
      ok "SELinux permissive patch already applied"
    else
      cat /tmp/permissive.log >&2
      die "PERMISSIVE=true but the permissive patch failed to apply"
    fi
  else
    log "PERMISSIVE=false -> SELinux stays enforcing"
  fi

  if [ "${CUSTOM_PATCH:-false}" = "true" ]; then
    shopt -s nullglob
    local extra=("${ROOT_DIR}/patch"/*.patch)
    shopt -u nullglob
    if [ ${#extra[@]} -gt 0 ]; then
      log "CUSTOM_PATCH=true -> applying ${#extra[@]} extra patch(es) to $kdir"
      local p
      for p in "${extra[@]}"; do
        patch -p1 -d "$kdir" --forward --batch < "$p" || warn "$(basename "$p") failed or already applied"
      done
    fi
  fi
}

apply_kernel66_patches() {
  local kdir applier
  kdir="$(detect_kernel_dir)"
  applier="${ROOT_DIR}/kernel/patches-kernel-6.6/apply.sh"

  if [ ! -f "$applier" ]; then
    warn "kernel/patches-kernel-6.6/apply.sh not found - kernel-6.6 stays unpatched"
    return 0
  fi

  log "Applying kernel-6.6 patches from kernel/patches-kernel-6.6/ to $kdir"
  chmod +x "$applier" 2>/dev/null || true
  if bash "$applier" "$kdir"; then
    ok "kernel-6.6 patches applied"
  else
    die "kernel-6.6 patches failed to apply to $kdir"
  fi
}

apply_compat_fixes() {
  log "Applying compatibility fixes for kernel-6.6 vs device_modules-6.6"

  # Restore include/linux/loop.h if missing
  local target_loop="kernel-6.6/include/linux/loop.h"
  if [ ! -f "$target_loop" ]; then
    ensure_dir "$(dirname "$target_loop")"
    cat > "$target_loop" <<'LOOP_EOF'
/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_LOOP_H
#define _LINUX_LOOP_H

#include <linux/blkdev.h>
#include <linux/blk-mq.h>
#include <linux/bio.h>
#include <linux/mutex.h>
#include <linux/workqueue.h>
#include <uapi/linux/loop.h>

struct loop_func_table;

struct loop_device {
    int         lo_number;
    loff_t      lo_offset;
    loff_t      lo_sizelimit;
    int         lo_flags;
    char        lo_file_name[LO_NAME_SIZE];
    char        lo_crypt_name[LO_NAME_SIZE];
    char        lo_encrypt_key[LO_KEY_SIZE];
    int         lo_encrypt_key_size;
    struct loop_func_table *lo_encryption;
    __u32       lo_init[2];
    uid_t       lo_key_owner;
    int         (*ioctl)(struct loop_device *, int cmd, unsigned long arg);
    struct file *lo_backing_file;
    struct block_device *lo_device;
    void        *key_data;
    gfp_t       old_gfp_mask;
    spinlock_t  lo_lock;
    int         lo_state;
    struct kthread_worker queue_worker;
    struct kthread_work rootcg_work;
    struct kthread_work free_work;
    struct task_struct *worker_task;
    bool        use_dio;
    bool        sysfs_inited;
    struct request_queue *lo_queue;
    struct blk_mq_tag_set tag_set;
    struct gendisk *lo_disk;
    struct mutex lo_mutex;
    bool        idr_visible;
};

static inline bool is_loop_device(struct file *file) {
    struct inode *i = file->f_mapping->host;
    return S_ISBLK(i->i_mode) && MAJOR(i->i_rdev) == LOOP_MAJOR;
}
#endif /* _LINUX_LOOP_H */
LOOP_EOF
    ok "Created $target_loop"
  fi

  # Remove MIN/MAX collisions in drivers
  find "kernel_device_modules-6.6/drivers" \( -name "*.c" -o -name "*.h" \) -type f | while read -r f; do
    if grep -q "^#define[[:space:]]*MAX[[:space:]]*(" "$f" 2>/dev/null || grep -q "^#define[[:space:]]*MIN[[:space:]]*(" "$f" 2>/dev/null; then
      if grep -q "^#define[[:space:]]*MAX[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)" "$f" || \
         grep -q "^#define[[:space:]]*MIN[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)" "$f"; then
        sed -i '/^#define[[:space:]]*MAX[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)/d' "$f" || true
        sed -i '/^#define[[:space:]]*MIN[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)/d' "$f" || true
        if ! grep -q "linux/minmax.h" "$f"; then
          sed -i '1i #include <linux/minmax.h>' "$f" || true
        fi
      fi
    fi
  done

  # Fix Samsung PM core
  local pm_kconfig="kernel_device_modules-6.6/drivers/samsung/pm/Kconfig"
  if [ -f "$pm_kconfig" ] && ! grep -q "^config SEC_PM$" "$pm_kconfig"; then
    tmp_kc=$(mktemp)
    {
      head -n 7 "$pm_kconfig"
      cat <<'KCEOF'
config SEC_PM
    tristate "Samsung PM core"
    default y
    help
      Samsung Power Management core. Required for sec_pm_debug.
KCEOF
      tail -n +8 "$pm_kconfig"
    } > "$tmp_kc"
    mv "$tmp_kc" "$pm_kconfig"
  fi
}

stamp_ksu_version() {
  local ws_kbuild="kernel/kernel-6.6/drivers/kernelsu/Kbuild"
  [ -f "$ws_kbuild" ] || return 0
  grep -q "KSU_VERSION_FALLBACK" "$ws_kbuild" || return 0

  local code="" tag="" src_ksu=""
  for d in "${ROOT_DIR}/kernel-6.6/KernelSU-Next" \
           "${ROOT_DIR}/Kernel-6.6/KernelSU-Next" \
           "${ROOT_DIR}/aosp-kernel/common/KernelSU-Next"; do
    if [ -d "$d/.git" ]; then
      src_ksu="$d"
      break
    fi
  done

  if [ -n "$src_ksu" ]; then
    local count
    count=$(git -C "$src_ksu" rev-list --count HEAD 2>/dev/null || echo 0)
    code=$((30000 + count))
    tag=$(git -C "$src_ksu" describe --tags --abbrev=0 2>/dev/null || echo "dev")
  elif [ -n "${KSU_VERSION:-}" ] && [ -n "${KSU_GIT_TAG:-}" ]; then
    code="${KSU_VERSION}"
    tag="${KSU_GIT_TAG}"
  fi

  if [ -n "$code" ] && [ -n "$tag" ]; then
    sed -i "s|^KSU_VERSION_FALLBACK := .*|KSU_VERSION_FALLBACK := ${code}|" "$ws_kbuild"
    sed -i "s|^KSU_VERSION_TAG_FALLBACK := .*|KSU_VERSION_TAG_FALLBACK := ${tag}|" "$ws_kbuild"
    ok "KernelSU-Next version stamped: ${tag} (${code})"
  fi
}

prepare_workspace() {
  log "Preparing kernel/ workspace"
  apply_kernel66_patches
  apply_optional_patches

  local real_kernel_dir
  real_kernel_dir="$(detect_kernel_dir)"
  local real_kernel_basename
  real_kernel_basename="$(basename "$real_kernel_dir")"

  pushd "${ROOT_DIR}/kernel" >/dev/null

  if [ -L "kernel-6.6" ] || [ ! -d "kernel-6.6" ]; then
    rm -rf "kernel-6.6" || true
    rsync -a --copy-links "${real_kernel_dir}/" "kernel-6.6/"
  else
    rsync -a --copy-links --delete "${real_kernel_dir}/" "kernel-6.6/"
  fi

  if [ "$real_kernel_basename" = "Kernel-6.6" ] && [ ! -d "${ROOT_DIR}/kernel-6.6" ]; then
    rsync -a --copy-links "${real_kernel_dir}/" "${ROOT_DIR}/kernel-6.6/" || true
  fi

  stamp_ksu_version

  if [ -L "build/bazel_common_rules" ] || [ ! -d "build/bazel_common_rules" ]; then
    rm -rf "build/bazel_common_rules" || true
    if [ -d "${ROOT_DIR}/build/bazel_common_rules" ]; then
      rsync -a --copy-links "${ROOT_DIR}/build/bazel_common_rules/" "build/bazel_common_rules/"
    fi
  fi

  local fdo_src=""
  [ -d "${ROOT_DIR}/Google-FDO" ] && fdo_src="${ROOT_DIR}/Google-FDO"
  [ -d "${ROOT_DIR}/google-FDO" ] && fdo_src="${ROOT_DIR}/google-FDO"
  if [ -n "$fdo_src" ]; then
    rm -rf "Google-FDO" || true
    rsync -a --copy-links "${fdo_src}/" "Google-FDO/"
  fi

  ln -sfn "build/bazel_mgk_rules/kleaf/bazel.WORKSPACE" "WORKSPACE"
  ln -sfn "../build/kernel/kleaf/bazel.sh" "tools/bazel"
  chmod +x "build/kernel/kleaf/bazel.sh" "tools/bazel" || true

  # Disable module signature checks for sandbox build
  local disable_sig_fragment="kernel_device_modules-6.6/kernel/configs/disable_module_sig.config"
  ensure_dir "$(dirname "$disable_sig_fragment")"
  cat > "$disable_sig_fragment" <<'EOF'
CONFIG_MODULE_SIG=n
# CONFIG_MODULE_SIG_FORCE is not set
# CONFIG_MODULE_SIG_ALL is not set
# CONFIG_MODULE_SIG_SHA512 is not set
CONFIG_MODULE_SIG_HASH=""
CONFIG_MODULE_SIG_KEY=""
CONFIG_SYSTEM_TRUSTED_KEYRING=n
EOF

  apply_compat_fixes
  popd >/dev/null
  ok "Workspace prepared"
}

patch_stamp() {
  log "Patching stamp.bzl & scripts"
  local stamp_files=(
    "${ROOT_DIR}/kernel/build/kernel/kleaf/impl/stamp.bzl"
    "${ROOT_DIR}/aosp-kernel/build/kernel/kleaf/impl/stamp.bzl"
  )
  for stamp in "${stamp_files[@]}"; do
    if [ -f "$stamp" ]; then
      sed -i "s/stable_scmversion_cmd = _get_status_at_path.*/stable_scmversion_cmd = \"echo ''\"/g" "$stamp" || true
      sed -i 's/-maybe-dirty//g' "$stamp" || true
    fi
  done

  # Fix Samsung shebang bug where SPDX appears before #!/bin/bash
  local build_scripts=(
    "${ROOT_DIR}/kernel/kernel_device_modules-6.6/build.sh"
    "${ROOT_DIR}/kernel/kernel_device_modules-6.6/build_abi.sh"
  )
  for bs in "${build_scripts[@]}"; do
    if [ -f "$bs" ] && head -n1 "$bs" | grep -q "SPDX"; then
      local tmp
      tmp=$(mktemp)
      { echo "#!/bin/bash"; grep -v "^#!/bin/bash" "$bs" || true; } > "$tmp"
      mv "$tmp" "$bs"
      chmod +x "$bs"
    fi
  done
}

generate_build_config() {
  log "Generating build.config"
  pushd "${ROOT_DIR}/kernel" >/dev/null

  local out_base="${ROOT_DIR}/out/target/product/a34x/obj"
  ensure_dir "${out_base}/KERNEL_OBJ"
  ensure_dir "${out_base}/KLEAF_OBJ"

  local gen_script="kernel_device_modules-6.6/scripts/gen_build_config.py"
  [ -f "$gen_script" ] || die "gen_build_config.py not found at $gen_script"

  local overlays="mt6877_overlay.config mt6877_teegris_5_overlay.config"
  if [ -f "kernel_device_modules-6.6/kernel/configs/disable_module_sig.config" ]; then
    overlays="$overlays disable_module_sig.config"
  fi

  python3 "$gen_script" \
    --kernel-defconfig mediatek-bazel_defconfig \
    --kernel-defconfig-overlays "$overlays" \
    --kernel-build-config-overlays "" \
    -m user \
    -o "../out/target/product/a34x/obj/KERNEL_OBJ/build.config"

  popd >/dev/null
  ok "Generated build.config"
}

run_kernel_build() {
  log "Starting kernel compilation"
  pushd "${ROOT_DIR}/kernel" >/dev/null

  export DEVICE_MODULES_DIR="kernel_device_modules-6.6"
  export BUILD_CONFIG="../out/target/product/a34x/obj/KERNEL_OBJ/build.config"
  export OUT_DIR="../out/target/product/a34x/obj/KLEAF_OBJ"
  export DIST_DIR="../out/target/product/a34x/obj/KLEAF_OBJ/dist"
  local defconfig_overlays="mt6877_overlay.config mt6877_teegris_5_overlay.config"
  if [ -f "kernel_device_modules-6.6/kernel/configs/disable_module_sig.config" ]; then
    defconfig_overlays="$defconfig_overlays disable_module_sig.config"
  fi
  export DEFCONFIG_OVERLAYS="$defconfig_overlays"
  export PROJECT="mgk_64_k66"
  export MODE="user"
  export KERNEL_VERSION="kernel-6.6"
  export SOURCE_DATE_EPOCH="$(date +%s)"
  export KBUILD_BUILD_USER="builder"
  export KBUILD_BUILD_HOST="github"
  export BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1
  export SANDBOX=0
  export BUILD_CONFIG_FRAGMENTS=""

  local build_sh="./kernel_device_modules-6.6/build.sh"
  chmod +x "$build_sh"

  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL bash "$build_sh"
  else
    bash "$build_sh"
  fi

  popd >/dev/null
  ok "Kernel build finished"
}

collect_image() {
  log "Collecting Image"
  pushd "${ROOT_DIR}" >/dev/null

  local primary_src="out/target/product/a34x/obj/KLEAF_OBJ/dist/kernel_device_modules-6.6/mgk_64_k66_kernel_aarch64.user/Image"
  local dest="${ROOT_DIR}/Image"

  if [ -f "$primary_src" ]; then
    cp -v "$primary_src" "$dest"
  else
    local found
    found=$(find out -name "Image" -type f 2>/dev/null | grep -v ".*\.d$" | head -n 1 || true)
    if [ -n "$found" ] && [ -f "$found" ]; then
      cp -v "$found" "$dest"
    else
      die "Image not found in out/! Build failed."
    fi
  fi

  ls -lh "$dest"
  sha256sum "$dest" || true
  ok "Done! Image is ready at $dest."
  popd >/dev/null
}

main() {
  log "=== A346E Kernel Build Started ==="
  setup_system
  download_repo_tool
  sync_aosp_kernel
  link_prebuilts
  prepare_workspace
  patch_stamp
  generate_build_config
  run_kernel_build
  collect_image
  log "=== Build Completed Successfully ==="
}

trap 'die "Build failed at line $LINENO (exit code $?)"' ERR

main "$@"
