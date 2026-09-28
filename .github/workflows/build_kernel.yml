name: Build A346E Kernel

on:
  workflow_dispatch:
    inputs:
      ksu_variant:
        description: "Choose KernelSU variant"
        required: true
        type: choice
        options:
          - NO-ROOT
          - KSUN
          - KSUN-SUSFS
        default: KSUN
      permissive:
        description: "Make SELinux permissive?"
        type: boolean
        required: true
        default: false
      custom_patches:
        description: "Also apply extra patches from patch/*.patch?"
        type: boolean
        required: true
        default: false
  push:
    branches:
      - A346E
      - Game
  pull_request:
    branches:
      - A346E
      - Game

permissions:
  contents: read
  issues: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

env:
  G_EXT: ${{ github.workspace }}/external_deps
  KSU_VAR: ${{ github.event.inputs.ksu_variant || (github.event_name == 'push' && 'KSUN') || 'NO-ROOT' }}
  PERMISSIVE: ${{ github.event.inputs.permissive || 'false' }}
  CUSTOM_PATCH: ${{ github.event.inputs.custom_patches || 'false' }}

jobs:
  detect:
    name: "#1 Checkout & Detect"
    runs-on: ubuntu-22.04
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v6
        with:
          submodules: recursive
          fetch-depth: 1

      - name: Detect kernel tree & build options
        id: detect
        run: |
          set -eu
          if [ -f "Kernel-6.6/Makefile" ]; then
            REAL_DIR="Kernel-6.6"
          elif [ -f "kernel-6.6/Makefile" ]; then
            REAL_DIR="kernel-6.6"
          else
            echo "::error::No kernel tree found"; exit 1
          fi
          [ -f "$REAL_DIR/arch/arm64/configs/gki_defconfig" ] || exit 1

          SEL=$([ "$PERMISSIVE" = "true" ] && echo permissive || echo enforcing)
          echo "kernel tree : $REAL_DIR"
          echo "KSU variant : $KSU_VAR"
          
          {
            echo "## Build A346E Kernel"
            echo "| option | value |"
            echo "|---|---|"
            echo "| KSU variant | \`${KSU_VAR}\` |"
            echo "| SELinux | \`${SEL}\` |"
            echo "### #1 Checkout & Detect - OK"
          } >> "$GITHUB_STEP_SUMMARY"

  system-prep:
    name: "#2 System Prep"
    needs: detect
    runs-on: ubuntu-22.04
    timeout-minutes: 15
    steps:
      - name: Check runner resources & toolchain
        run: |
          set -eu
          AVAIL=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
          if [ "$AVAIL" -lt 10 ]; then exit 1; fi
          for t in git curl python3 tar xz; do command -v "$t" >/dev/null || exit 1; done

  external-deps:
    name: "#3 External Deps (KSU/SUSFS)"
    needs: system-prep
    runs-on: ubuntu-22.04
    timeout-minutes: 15
    steps:
      - name: Fetch & verify SUSFS repos
        if: env.KSU_VAR == 'KSUN-SUSFS'
        run: |
          set -eu
          mkdir -p "$G_EXT" && cd "$G_EXT"
          # Clone latest without pinning to a hardcoded commit
          git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android15-6.6 --depth 1
          
          for repo in https://github.com/xnnnsets/kernel_patches.git \
                      https://github.com/xnnnsets/patch.git \
                      https://github.com/SukiSU-Ultra/SukiSU_patch.git; do
            git clone "$repo" --depth 1
          done
          
          # Dynamically target the newest wild patch version dir
          LATEST_SUS_DIR=$(ls -d kernel_patches/wild/susfs_fix_patches/v* | sort -V | tail -n 1)
          
          MISSING=0
          for f in "susfs4ksu/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch" \
                   "susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" \
                   "patch/6.6/Dont_reduce_TTL.patch" \
                   "kernel_patches/wild/hooks/scope_min_manual_hooks_v1.4.patch" \
                   "$LATEST_SUS_DIR/1_fix_base.c.patch"; do
            if [ -f "$f" ]; then echo "OK      $f"; else echo "::error::MISSING $f"; MISSING=1; fi
          done
          [ "$MISSING" = "0" ] || exit 1

  patches:
    name: "#4 Patches"
    needs: external-deps
    runs-on: ubuntu-22.04
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v6
        with:
          submodules: recursive
          fetch-depth: 1

      - name: Detect kernel dir
        run: |
          set -eu
          if [ -f "Kernel-6.6/Makefile" ]; then echo "KDIR=Kernel-6.6" >> "$GITHUB_ENV"
          else echo "KDIR=kernel-6.6" >> "$GITHUB_ENV"; fi

      - name: kernel-6.6 patches (always applied)
        run: |
          set -eu
          bash "kernel/patches-kernel-6.6/apply.sh" --check "$KDIR"

      - name: Extra patches from patch/*.patch (CUSTOM_PATCH=true)
        if: env.CUSTOM_PATCH == 'true'
        run: |
          set -eu
          shopt -s nullglob
          EXTRA=(patch/*.patch)
          for p in "${EXTRA[@]}"; do
            patch -p1 -d "$KDIR" --dry-run --forward --batch < "$p" > /dev/null || exit 1
          done

  kernelsu:
    name: "#5 KernelSU"
    needs: patches
    runs-on: ubuntu-22.04
    timeout-minutes: 15
    steps:
      - name: Resolve KernelSU-Next version
        id: resolve
        if: env.KSU_VAR != 'NO-ROOT'
        run: |
          set -eu
          if [ "$KSU_VAR" = "KSUN" ]; then
            REPO=https://github.com/KernelSU-Next/KernelSU-Next.git; BRANCH=dev
          else
            REPO=https://github.com/xnnnsets/KernelSU-Next.git; BRANCH=next-1
          fi
          git clone --branch "$BRANCH" "$REPO" /tmp/ksun >/dev/null 2>&1
          cd /tmp/ksun
          TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo dev)
          CODE=$((30000 +$(git rev-list --count HEAD)))
          SHA=$(git rev-parse --short HEAD)
          { echo "ksu_tag=$TAG"; echo "ksu_code=$CODE"; echo "ksu_sha=$SHA"; } >> "$GITHUB_OUTPUT"

  build:
    name: "#6 Build"
    needs: kernelsu
    runs-on: ubuntu-22.04
    timeout-minutes: 330
    outputs:
      image_size: ${{ steps.build.outputs.image_size }}
      image_sha: ${{ steps.build.outputs.image_sha }}
      artifact: ${{ steps.meta.outputs.artifact }}
      selinux: ${{ steps.meta.outputs.selinux }}
    steps:
      - uses: actions/checkout@v6
        with:
          submodules: recursive
          fetch-depth: 1

      - name: Free disk space & install deps
        run: |
          set -eu
          sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/share/boost || true
          sudo apt-get update -y
          sudo apt-get install -y --no-install-recommends \
            curl wget unzip git rsync ca-certificates bc bison flex build-essential \
            libssl-dev libelf-dev libncurses-dev dwarves lz4 zstd cpio libxml2-utils xsltproc \
            python3 python3-pip python3-setuptools python3-dev zlib1g-dev libbz2-dev liblz4-dev libzstd-dev
          git config --global --add safe.directory "*"

      - name: Set kernel dir & artifact name
        id: meta
        run: |
          set -eu
          REAL_DIR=$([ -f "Kernel-6.6/Makefile" ] && echo Kernel-6.6 || echo kernel-6.6)
          echo "REAL_DIR=$REAL_DIR" >> "$GITHUB_ENV"
          echo "G_KERNEL=$GITHUB_WORKSPACE/$REAL_DIR" >> "$GITHUB_ENV"
          SEL=$([ "$PERMISSIVE" = "true" ] && echo permissive || echo enforcing)
          CUS=$([ "$CUSTOM_PATCH" = "true" ] && echo custom || echo nocustom)
          echo "selinux=$SEL" >> "$GITHUB_OUTPUT"
          echo "artifact=kernel-image-${KSU_VAR}-${SEL}-${CUS}" >> "$GITHUB_OUTPUT"

      - name: External deps (SUSFS only)
        if: env.KSU_VAR == 'KSUN-SUSFS'
        run: |
          set -eu
          mkdir -p "$G_EXT" && cd "$G_EXT"
          git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android15-6.6 --depth 1
          for repo in https://github.com/xnnnsets/kernel_patches.git https://github.com/xnnnsets/patch.git https://github.com/SukiSU-Ultra/SukiSU_patch.git; do
            git clone "$repo" --depth 1
          done

      - name: SUSFS kernel patches
        if: env.KSU_VAR == 'KSUN-SUSFS'
        run: |
          set -eu
          SUSFS_DIR="$G_EXT/susfs4ksu"
          cp -v "$SUSFS_DIR"/kernel_patches/include/linux/* "$G_KERNEL/include/linux/" || true
          cp -v "$SUSFS_DIR"/kernel_patches/fs/* "$G_KERNEL/fs/" || true
          
          LATEST_SUS_DIR=$(ls -d "$G_EXT"/kernel_patches/wild/susfs_fix_patches/v* | sort -V | tail -n 1)
          
          cd "$G_KERNEL"
          for p in "$G_EXT/patch/6.6/Dont_reduce_TTL.patch" \
                   "$G_EXT/kernel_patches/wild/hooks/scope_min_manual_hooks_v1.4.patch" \
                   "$SUSFS_DIR/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch" \
                   "$LATEST_SUS_DIR/1_fix_base.c.patch"; do
            patch -p1 --forward --batch < "$p" || true
          done
          
          find "$GITHUB_WORKSPACE/$REAL_DIR" -iname "abi_gki_protected_exports*" -type f -delete 2>/dev/null || true

      - name: Add KernelSU-Next
        id: ksu
        if: env.KSU_VAR != 'NO-ROOT'
        run: |
          set -eu
          cd "$G_KERNEL"
          rm -rf KernelSU-Next
          case "$KSU_VAR" in
            KSUN)
              curl -LSs --retry 3 https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/refs/heads/dev/kernel/setup.sh -o /tmp/ksun_setup.sh
              sh /tmp/ksun_setup.sh dev
              ;;
            KSUN-SUSFS)
              curl -LSs --retry 3 https://raw.githubusercontent.com/xnnnsets/KernelSU-Next/refs/heads/next-1/kernel/setup.sh -o /tmp/ksun_setup.sh
              sh /tmp/ksun_setup.sh next-1
              LATEST_SUS_DIR=$(ls -d "$G_EXT"/kernel_patches/wild/susfs_fix_patches/v* | sort -V | tail -n 1)
              for p in "$G_EXT/susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" \
                       "$LATEST_SUS_DIR/fix_core_hook.c.patch" \
                       "$LATEST_SUS_DIR/fix_sucompat.c.patch" \
                       "$LATEST_SUS_DIR/fix_kernel_compat.c.patch"; do
                patch -p1 -d ./KernelSU-Next --forward --batch < "$p" || true
              done
              ;;
          esac
          cd KernelSU-Next
          KSU_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo dev)
          KSU_CODE=$((30000 +$(git rev-list --count HEAD 2>/dev/null || echo 0)))
          if [ -f kernel/Kbuild ] && grep -q KSU_VERSION_FALLBACK kernel/Kbuild; then
            sed -i "s|^KSU_VERSION_FALLBACK := .*|KSU_VERSION_FALLBACK := ${KSU_CODE}|" kernel/Kbuild
            sed -i "s|^KSU_VERSION_TAG_FALLBACK := .*|KSU_VERSION_TAG_FALLBACK := ${KSU_TAG}|" kernel/Kbuild
          fi
          { echo "KSU_GIT_TAG=$KSU_TAG"; echo "KSU_VERSION=$KSU_CODE"; } >> "$GITHUB_ENV"

      - name: Defconfig (KSU + IPSet)
        run: |
          set -eu
          DEFCONFIG="$G_KERNEL/arch/arm64/configs/gki_defconfig"
          sed -i '/^# >>> a346e-ci$/,/^# <<< a346e-ci$/d' "$DEFCONFIG"
          echo "# >>> a346e-ci" >> "$DEFCONFIG"
          case "$KSU_VAR" in
            KSUN)
              cat >> "$DEFCONFIG" <<'EOF'
          CONFIG_KSU=y
          CONFIG_KPROBES=y
          CONFIG_KPROBE_EVENTS=y
          CONFIG_MODULES=y
          EOF
              ;;
            KSUN-SUSFS)
              cat >> "$DEFCONFIG" <<'EOF'
          CONFIG_KSU=y
          CONFIG_KSU_KPROBES_HOOK=n
          CONFIG_MODULES=y
          CONFIG_KSU_SUSFS=y
          CONFIG_KSU_SUSFS_SUS_PATH=y
          CONFIG_KSU_SUSFS_SUS_MOUNT=y
          CONFIG_KSU_SUSFS_TRY_UMOUNT=y
          CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
          CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
          CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
          CONFIG_KSU_SUSFS_SUS_KSTAT=y
          CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n
          CONFIG_KSU_SUSFS_SPOOF_UNAME=y
          CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
          CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
          CONFIG_KSU_SUSFS_ENABLE_LOG=y
          CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
          CONFIG_KSU_SUSFS_SUS_SU=n
          EOF
              ;;
          esac
          cat >> "$DEFCONFIG" <<'EOF'
          CONFIG_IP_SET=y
          CONFIG_IP_SET_MAX=65534
          CONFIG_IP_SET_BITMAP_IP=y
          CONFIG_IP_SET_BITMAP_IPMAC=y
          CONFIG_IP_SET_BITMAP_PORT=y
          CONFIG_IP_SET_HASH_IP=y
          CONFIG_IP_SET_HASH_IPMARK=y
          CONFIG_IP_SET_HASH_IPPORT=y
          CONFIG_IP_SET_HASH_IPPORTIP=y
          CONFIG_IP_SET_HASH_IPPORTNET=y
          CONFIG_IP_SET_HASH_IPMAC=y
          CONFIG_IP_SET_HASH_MAC=y
          CONFIG_IP_SET_HASH_NETPORTNET=y
          CONFIG_IP_SET_HASH_NET=y
          CONFIG_IP_SET_HASH_NETNET=y
          CONFIG_IP_SET_HASH_NETPORT=y
          CONFIG_IP_SET_HASH_NETIFACE=y
          CONFIG_IP_SET_LIST_SET=y
          EOF
          echo "# <<< a346e-ci" >> "$DEFCONFIG"

      - name: Build kernel
        id: build
        run: |
          set -eu
          chmod +x ./build_kernel.sh
          if ! bash ./build_kernel.sh 2>&1 | tee build.log; then exit 1; fi
          echo "image_size=$(du -h Image | awk '{print $1}')" >> "$GITHUB_OUTPUT"
          echo "image_sha=$(sha256sum Image \vert{} cut -c1-16)" >> "$GITHUB_OUTPUT"

      - name: Upload Image
        uses: actions/upload-artifact@v6
        with:
          name: ${{ steps.meta.outputs.artifact }}
          path: Image

  upload-summary:
    name: "#7 Upload & Summary"
    needs: build
    if: always()
    runs-on: ubuntu-22.04
    timeout-minutes: 10
    steps:
      - name: Report
        run: |
          {
            echo "### #7 Result: \`${{ needs.build.result }}\`"
            echo "| KSU variant | \`${KSU_VAR}\` |"
          } >> "$GITHUB_STEP_SUMMARY"
