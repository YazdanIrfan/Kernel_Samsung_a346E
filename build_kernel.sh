#!/bin/bash
# ==============================================================================
# Build script for Samsung A346E kernel (MediaTek mt6877, kernel-6.6)
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
  ensure_dir "${ROOT_DIR}/bin"
  ulimit -n 4096 2>/dev/null || warn "ulimit -n 4096 failed"
  if [ -z "${GITHUB_ACTIONS:-}" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y || true
      sudo apt-get install -y curl wget unzip python3 python3-pip git rsync \
        bc bison flex build-essential libssl-dev libelf-dev libncurses-dev \
        dwarves lz4 zstd cpio libxml2-utils xsltproc || true
    fi
  fi
  git config --global user.email "builder@example.com" || true
  git config --global user.name "Builder" || true
  git config --global --add safe.directory "*" || true
}

download_repo_tool() {
  local dest="${ROOT_DIR}/bin/repo"
  if [ -f "$dest" ] && [ -s "$dest" ] && head -n 5 "$dest" | grep -q "repo"; then return 0; fi
  local urls=("https://storage.googleapis.com/git-repo-downloads/repo" "https://raw.githubusercontent.com/GerritCodeReview/git-repo/main/repo")
  for url in "${urls[@]}"; do
    if command -v curl >/dev/null 2>&1; then
      curl -L -fsSL -o "$dest" "$url" && chmod a+x "$dest" && return 0 || rm -f "$dest"
    fi
  done
  die "repo tool not available"
}

sync_aosp_kernel() {
  local aosp_dir="${ROOT_DIR}/aosp-kernel"
  ensure_dir "$aosp_dir"
  pushd "$aosp_dir" >/dev/null
  if [ ! -d .repo ]; then
    repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6 --depth=1 --no-clone-bundle || true
  fi
  for attempt in 1 2 3; do
    if repo sync -c -j2 --force-sync --no-clone-bundle --no-tags; then break; fi
    if [ "$attempt" -eq 3 ]; then die "repo sync failed"; fi
    sleep 10
  done
  popd >/dev/null
}

link_prebuilts() {
  local aosp_prebuilts="${ROOT_DIR}/aosp-kernel/prebuilts"
  local kernel_prebuilts="${ROOT_DIR}/kernel/prebuilts"
  [ ! -d "$aosp_prebuilts" ] && die "aosp-kernel/prebuilts not found"
  rm -rf "$kernel_prebuilts" || true
  ln -sfn "$aosp_prebuilts" "$kernel_prebuilts"
  for ext in zopfli pigz; do
    local src="${ROOT_DIR}/aosp-kernel/external/${ext}"
    local dst="${ROOT_DIR}/kernel/external/${ext}"
    if [ -d "$src" ] && [ ! -e "$dst" ]; then ln -sfn "$src" "$dst" || true; fi
  done
}

apply_optional_patches() {
  local kdir
  kdir="$(detect_kernel_dir)"
  if [ "${PERMISSIVE:-false}" = "true" ]; then
    local pp="${ROOT_DIR}/Permissive/selinux-make-permissive.patch"
    patch -p1 -d "$kdir" --forward --batch < "$pp" >/dev/null 2>&1 || true
  fi
  if [ "${CUSTOM_PATCH:-false}" = "true" ]; then
    shopt -s nullglob
    local extra=("${ROOT_DIR}/patch"/*.patch)
    shopt -u nullglob
    for p in "${extra[@]}"; do patch -p1 -d "$kdir" --forward --batch < "$p" || true; done
  fi
}

apply_kernel66_patches() {
  local kdir applier
  kdir="$(detect_kernel_dir)"
  applier="${ROOT_DIR}/kernel/patches-kernel-6.6/apply.sh"
  if [ ! -f "$applier" ]; then return 0; fi
  chmod +x "$applier" 2>/dev/null || true
  bash "$applier" "$kdir" || die "kernel-6.6 patches failed"
}

apply_compat_fixes() {
  log "Applying compatibility fixes"
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
	int lo_number; loff_t lo_offset; loff_t lo_sizelimit; int lo_flags;
	char lo_file_name[LO_NAME_SIZE]; char lo_crypt_name[LO_NAME_SIZE];
	char lo_encrypt_key[LO_KEY_SIZE]; int lo_encrypt_key_size;
	struct loop_func_table *lo_encryption; __u32 lo_init[2]; uid_t lo_key_owner;
	int (*ioctl)(struct loop_device *, int cmd, unsigned long arg);
	struct file *lo_backing_file; struct block_device *lo_device; void *key_data;
	gfp_t old_gfp_mask; spinlock_t lo_lock; int lo_state;
	struct kthread_worker queue_worker; struct kthread_work rootcg_work;
	struct kthread_work free_work; struct task_struct *worker_task;
	bool use_dio; bool sysfs_inited; struct request_queue *lo_queue;
	struct blk_mq_tag_set tag_set; struct gendisk *lo_disk;
	struct mutex lo_mutex; bool idr_visible;
};
static inline bool is_loop_device(struct file *file) {
	struct inode *i = file->f_mapping->host;
	return S_ISBLK(i->i_mode) && MAJOR(i->i_rdev) == LOOP_MAJOR;
}
#endif
LOOP_EOF
  fi

  find "kernel_device_modules-6.6/drivers" \( -name "*.c" -o -name "*.h" \) -type f | while read -r f; do
    if grep -q "^#define[[:space:]]*MAX[[:space:]]*(" "$f" 2>/dev/null; then
      sed -i '/^#define[[:space:]]*MAX[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)/d' "$f" || true
      sed -i '/^#define[[:space:]]*MIN[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)/d' "$f" || true
      if ! grep -q "linux/minmax.h" "$f"; then sed -i '1i #include <linux/minmax.h>' "$f" || true; fi
    fi
  done
}

stamp_ksu_version() {
  local ws_kbuild="kernel/kernel-6.6/drivers/kernelsu/Kbuild"
  if [ ! -f "$ws_kbuild" ] || ! grep -q "KSU_VERSION_FALLBACK" "$ws_kbuild"; then return 0; fi
  local code="${KSU_VERSION:-}" tag="${KSU_GIT_TAG:-}"
  if [ -n "$code" ]; then sed -i "s|^KSU_VERSION_FALLBACK := .*|KSU_VERSION_FALLBACK := ${code}|" "$ws_kbuild"; fi
  if [ -n "$tag" ]; then sed -i "s|^KSU_VERSION_TAG_FALLBACK := .*|KSU_VERSION_TAG_FALLBACK := ${tag}|" "$ws_kbuild"; fi
}

prepare_workspace() {
  apply_kernel66_patches
  apply_optional_patches
  local real_kernel_dir="$(detect_kernel_dir)"
  pushd "${ROOT_DIR}/kernel" >/dev/null
  rm -rf "kernel-6.6" || true
  rsync -a --copy-links "${real_kernel_dir}/" "kernel-6.6/" || cp -r "${real_kernel_dir}" "kernel-6.6"
  stamp_ksu_version
  
  if [ -L "build/bazel_common_rules" ] || [ ! -d "build/bazel_common_rules" ]; then
    rm -rf "build/bazel_common_rules" || true
    rsync -a --copy-links "${ROOT_DIR}/build/bazel_common_rules/" "build/bazel_common_rules/" || cp -r "${ROOT_DIR}/build/bazel_common_rules" "build/bazel_common_rules"
  fi
  
  local fdo_src="${ROOT_DIR}/Google-FDO"
  if [ -d "$fdo_src" ]; then
    rm -rf "Google-FDO" || true
    rsync -a --copy-links "${fdo_src}/" "Google-FDO/" || cp -r "${fdo_src}" "Google-FDO"
  fi

  ln -sfn "build/bazel_mgk_rules/kleaf/bazel.WORKSPACE" "WORKSPACE"
  ln -sfn "../build/kernel/kleaf/bazel.sh" "tools/bazel"
  
  local disable_sig_fragment="kernel_device_modules-6.6/kernel/configs/disable_module_sig.config"
  ensure_dir "$(dirname "$disable_sig_fragment")"
  cat > "$disable_sig_fragment" <<'EOF'
CONFIG_MODULE_SIG=n
# CONFIG_MODULE_SIG_FORCE is not set
# CONFIG_MODULE_SIG_ALL is not set
CONFIG_MODULE_SIG_HASH=""
CONFIG_MODULE_SIG_KEY=""
CONFIG_SYSTEM_TRUSTED_KEYRING=n
EOF
  
  apply_compat_fixes
  popd >/dev/null
}

patch_stamp() {
  local stamp="${ROOT_DIR}/kernel/build/kernel/kleaf/impl/stamp.bzl"
  if [ -f "$stamp" ]; then
    sed -i "s/stable_scmversion_cmd = _get_status_at_path.*/stable_scmversion_cmd = \"echo ''\"/g" "$stamp" || true
  fi
}

generate_build_config() {
  pushd "${ROOT_DIR}/kernel" >/dev/null
  local out_base="${ROOT_DIR}/out/target/product/a34x/obj"
  ensure_dir "${out_base}/KERNEL_OBJ"
  local gen_script="kernel_device_modules-6.6/scripts/gen_build_config.py"
  local overlays="mt6877_overlay.config mt6877_teegris_5_overlay.config disable_module_sig.config"
  python3 "$gen_script" --kernel-defconfig mediatek-bazel_defconfig --kernel-defconfig-overlays "$overlays" \
    --kernel-build-config-overlays "" -m user -o "../out/target/product/a34x/obj/KERNEL_OBJ/build.config"
  popd >/dev/null
}

run_kernel_build() {
  pushd "${ROOT_DIR}/kernel" >/dev/null
  export DEVICE_MODULES_DIR="kernel_device_modules-6.6"
  export BUILD_CONFIG="../out/target/product/a34x/obj/KERNEL_OBJ/build.config"
  export OUT_DIR="../out/target/product/a34x/obj/KLEAF_OBJ"
  export DIST_DIR="../out/target/product/a34x/obj/KLEAF_OBJ/dist"
  export DEFCONFIG_OVERLAYS="mt6877_overlay.config mt6877_teegris_5_overlay.config disable_module_sig.config"
  export PROJECT="mgk_64_k66"
  export MODE="user"
  export KERNEL_VERSION="kernel-6.6"
  export KBUILD_BUILD_USER="builder"
  export BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1
  export SANDBOX=0
  bash "./kernel_device_modules-6.6/build.sh"
  popd >/dev/null
}

collect_image() {
  local primary_src="out/target/product/a34x/obj/KLEAF_OBJ/dist/kernel_device_modules-6.6/mgk_64_k66_kernel_aarch64.user/Image"
  local dest="${ROOT_DIR}/Image"
  if [ -f "$primary_src" ]; then cp -v "$primary_src" "$dest"
  else find out -name "Image" -type f | grep -v ".*\.d$" | head -n 1 | xargs -I {} cp -v {} "$dest"; fi
}

main() {
  setup_system
  download_repo_tool
  sync_aosp_kernel
  link_prebuilts
  prepare_workspace
  patch_stamp
  generate_build_config
  run_kernel_build
  collect_image
}

trap 'die "Build failed at line $LINENO"' ERR
main "$@"
