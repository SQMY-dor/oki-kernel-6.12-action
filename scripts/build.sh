#!/usr/bin/env bash
# OKI Kernel 6.12+ 构建脚本（GitHub Actions 与本地通用）
#
#   bash scripts/build.sh --resolve   只解析参数（输出 SUSFS 分支/补丁路径，供 workflow 校验）
#   bash scripts/build.sh --build     同步好的源码树里安装 KSU + 打 SUSFS 补丁并编译
#   bash scripts/build.sh --package   把产物打成 AnyKernel3 卡刷包到 dist/
#
# 关键环境变量（workflow 已注入）：MANIFEST_FILE CPUD KERNEL_VERSION
#   SUSFS_REPO SUSFS_BRANCH_INPUT KSU_VARIANT ENABLE_LTO ENABLE_POLLY ENABLE_O3
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="${ROOT}/kernel_workspace"
KP="${WS}/kernel_platform"
LOG_PREFIX="[oki]"

log()  { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }
die()  { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

KERNEL_VERSION="${KERNEL_VERSION:-6.12}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu}"
SUSFS_BRANCH_INPUT="${SUSFS_BRANCH_INPUT:-auto}"
KSU_VARIANT="${KSU_VARIANT:-KernelSU-Next}"
CPUD="${CPUD:-sun}"
MANIFEST_FILE="${MANIFEST_FILE:-oneplus_13t}"
ENABLE_LTO="${ENABLE_LTO:-false}"
ENABLE_POLLY="${ENABLE_POLLY:-false}"
ENABLE_O3="${ENABLE_O3:-false}"

# ── SUSFS 分支树映射 ───────────────────────────────────────────────────────
# 规则：按内核版本号选分支（同版本可能有多个 Android 标签，按"新→旧"顺序试，
# 远程存在即用；全部不存在再退回 kernel-<ver> 系分支）。
susfs_candidates() {
  case "$1" in
    6.12) echo "gki-android16-6.12 gki-android15-6.12 kernel-6.12" ;;
    6.6)  echo "gki-android15-6.6 gki-android14-6.6 kernel-6.6" ;;
    6.1)  echo "gki-android14-6.1 gki-android13-6.1 kernel-6.1" ;;
    5.15) echo "gki-android14-5.15 gki-android13-5.15 kernel-5.15" ;;
    5.10) echo "gki-android13-5.10 gki-android12-5.10 kernel-5.10" ;;
    5.4)  echo "kernel-5.4" ;;
    4.19) echo "kernel-4.19" ;;
    4.14) echo "kernel-4.14" ;;
    4.9)  echo "kernel-4.9" ;;
    *)    echo "" ;;
  esac
}

remote_branch_exists() {
  local repo="$1" branch="$2"
  GIT_TERMINAL_PROMPT=0 timeout 60 git ls-remote --heads "$repo" "$branch" 2>/dev/null | grep -q "refs/heads/${branch}$"
}

resolve_susfs_branch() {
  if [ "$SUSFS_BRANCH_INPUT" != "auto" ] && [ -n "$SUSFS_BRANCH_INPUT" ]; then
    log "SUSFS 分支：使用手动指定值 $SUSFS_BRANCH_INPUT"
    echo "$SUSFS_BRANCH_INPUT"
    return
  fi
  local cand
  cand="$(susfs_candidates "$KERNEL_VERSION")"
  [ -n "$cand" ] || die "不支持的内核版本 $KERNEL_VERSION（可选 6.12/6.6/6.1/5.15/5.10/5.4/4.19/4.14/4.9）"
  for b in $cand; do
    if remote_branch_exists "$SUSFS_REPO" "$b"; then
      log "SUSFS 分支：内核 $KERNEL_VERSION → $b（远程存在）"
      echo "$b"
      return
    fi
    log "SUSFS 分支：$b 不存在，继续尝试下一个"
  done
  die "在 $SUSFS_REPO 找不到适配内核 $KERNEL_VERSION 的分支（试过：$cand）"
}

ksu_setup_url() {
  case "$KSU_VARIANT" in
    KernelSU)       echo "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" ;;
    KernelSU-Next)  echo "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" ;;
    SukiSU-Ultra)   echo "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" ;;
    *) die "未知 KSU_VARIANT: $KSU_VARIANT" ;;
  esac
}

cmd_resolve() {
  local br patch url
  br="$(resolve_susfs_branch)"
  patch="kernel_patches/50_add_susfs_in_${br}.patch"
  url="$(ksu_setup_url)"
  cat <<EOF
MANIFEST_BRANCH=${MANIFEST_BRANCH:-}
MANIFEST_FILE=${MANIFEST_FILE}
CPUD=${CPUD}
KERNEL_VERSION=${KERNEL_VERSION}
SUSFS_REPO=${SUSFS_REPO}
SUSFS_BRANCH=${br}
SUSFS_PATCH=${patch}
KSU_VARIANT=${KSU_VARIANT}
KSU_SETUP_URL=${url}
LTO=${ENABLE_LTO} POLLY=${ENABLE_POLLY} O3=${ENABLE_O3}
EOF
}

# ── 打 KSU + SUSFS ────────────────────────────────────────────────────────
cmd_build() {
  [ -d "$KP" ] || die "找不到内核工作区 $KP（先 repo init/sync）"

  local br patch_dir setup_url
  br="$(resolve_susfs_branch)"
  setup_url="$(ksu_setup_url)"
  log "内核源码：$KP"
  log "KernelSU：$KSU_VARIANT"
  log "SUSFS：$SUSFS_REPO @ $br"

  # 1) KernelSU 接入（不同分支克隆出的目录名不同：KernelSU / KernelSU-Next / SukiSU-Ultra）
  ( cd "$KP" && curl -LSs "$setup_url" | bash - )
  local ksu_dir=""
  for cand in KernelSU KernelSU-Next SukiSU-Ultra; do
    if [ -d "${KP}/${cand}" ]; then ksu_dir="${KP}/${cand}"; break; fi
  done
  if [ -z "$ksu_dir" ]; then
    ksu_dir="$(find "$KP" -maxdepth 2 -type d -name 'KernelSU*' -o -maxdepth 2 -type d -name 'SukiSU*' 2>/dev/null | head -1 || true)"
  fi
  [ -n "$ksu_dir" ] || die "KernelSU 接入失败（$KP 下找不到 KernelSU*/SukiSU* 目录）"
  log "KernelSU 目录：$ksu_dir"

  # 2) SUSFS 源码与补丁
  local susfs_dir="${ROOT}/susfs4ksu"
  rm -rf "$susfs_dir"
  git clone --depth 1 -b "$br" "$SUSFS_REPO" "$susfs_dir" \
    || die "克隆 SUSFS 失败：$SUSFS_REPO @ $br"
  patch_dir="${susfs_dir}/kernel_patches"
  [ -f "${patch_dir}/50_add_susfs_in_${br}.patch" ] \
    || die "SUSFS 分支 $br 缺少 50_add_susfs_in_${br}.patch"

  cp "${patch_dir}/50_add_susfs_in_${br}.patch" "${KP}/common/"
  cp -r "${patch_dir}/fs/." "${KP}/common/fs/" 2>/dev/null || true
  cp -r "${patch_dir}/include/linux/." "${KP}/common/include/linux/" 2>/dev/null || true

  ( cd "${KP}/common" && patch -p1 --forward < "50_add_susfs_in_${br}.patch" ) \
    || die "SUSFS 主补丁应用失败"

  # 3) 让 KernelSU 支持 SUSFS（补丁随分支提供，缺失则跳过并告警）
  local ksu_patch="${patch_dir}/KernelSU/10_enable_susfs_for_ksu.patch"
  if [ -f "$ksu_patch" ]; then
    cp "$ksu_patch" "${ksu_dir}/"
    ( cd "${ksu_dir}" && patch -p1 --forward < 10_enable_susfs_for_ksu.patch ) \
      || log "警告：KernelSU 侧 SUSFS 补丁未完全应用（版本差异，可能仍可用）"
  else
    log "提示：该 SUSFS 分支没有 KernelSU 侧补丁，跳过"
  fi

  # 4) 编译必需的小修：清理保护导出 + 打开 xattr
  rm -f "${KP}/common/android/abi_gki_protected_exports_"* 2>/dev/null || true
  rm -f "${KP}/msm-kernel/android/abi_gki_protected_exports_"* 2>/dev/null || true
  grep -q '^CONFIG_TMPFS_XATTR=y' "${KP}/common/arch/arm64/configs/gki_defconfig" 2>/dev/null \
    || echo 'CONFIG_TMPFS_XATTR=y' >> "${KP}/common/arch/arm64/configs/gki_defconfig"
  sed -i 's/check_defconfig//' "${KP}/common/build.config.gki" 2>/dev/null || true

  # 5) 编译器：优先用 manifest 里同步下来的 prebuilt clang
  local prebuilt
  prebuilt="$(ls -d "${KP}"/prebuilts/clang/host/linux-x86/clang-* 2>/dev/null | sort -V | tail -1 || true)"
  if [ -n "$prebuilt" ]; then
    export PATH="${prebuilt}/bin:${PATH}"
    log "使用镜像内 prebuilt clang：$prebuilt"
  else
    log "未发现 prebuilt clang，使用系统 clang：$(command -v clang || echo 缺失)"
  fi

  local bazel_args=""
  [ "$ENABLE_O3" = "true" ]    && bazel_args="${bazel_args} --copt=-O3 --copt=-Wno-error"
  [ "$ENABLE_LTO" = "true" ]   && bazel_args="${bazel_args} --copt=-flto --linkopt=-flto"
  [ "$ENABLE_POLLY" = "true" ] && bazel_args="${bazel_args} --copt=-mllvm --copt=-polly --copt=-mllvm --copt=-polly-vectorizer=stripmine"

  # 6) 编译
  ( cd "$KP" && ./build_with_bazel.py -t "$CPUD" gki --config=stamp --linkopt="-fuse-ld=lld" $bazel_args )

  local dist="${WS}/out/msm-kernel-${CPUD}-gki/dist"
  [ -d "$dist" ] || die "编译产物目录不存在：$dist"
  log "编译完成：$dist"
  ls -lh "$dist" | sed 's/^/[oki]   /'
}

# ── 打包 AnyKernel3 ───────────────────────────────────────────────────────
cmd_package() {
  local dist="${WS}/out/msm-kernel-${CPUD}-gki/dist"
  [ -d "$dist" ] || die "找不到产物目录 $dist"

  local ak="${ROOT}/AnyKernel3"
  rm -rf "$ak"
  git clone --depth 1 https://github.com/osm0sis/AnyKernel3.git "$ak" || die "克隆 AnyKernel3 失败"
  rm -rf "${ak}/.git"

  [ -f "${dist}/Image" ] || die "产物里没有 Image"
  cp "${dist}/Image" "${ak}/Image"
  for extra in Image.gz dtbo.img dtb.img; do
    [ -f "${dist}/${extra}" ] && cp "${dist}/${extra}" "${ak}/" || true
  done

  # 设备代号：oneplus_13t → 13t（仅展示用；关掉 devicecheck 避免刷机校验失败）
  local code="${MANIFEST_FILE#oneplus_}"
  code="${code%_b}"
  cat > "${ak}/anykernel.sh" <<EOF
kernel.string=OKI ${MANIFEST_FILE} (${KSU_VARIANT} + SUSFS)
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanup=1
device.name1=${code}
supported.versions=
supported.patchlevels=
EOF

  mkdir -p "${ROOT}/dist"
  local stamp out
  stamp="$(date +%Y%m%d-%H%M)"
  out="${ROOT}/dist/OKI-${MANIFEST_FILE}-${KSU_VARIANT}-SUSFS-${stamp}.zip"
  ( cd "$ak" && zip -r9 "$out" . -x '.git/*' '*.zip' >/dev/null )
  log "已打包：$out"
  ls -lh "${ROOT}/dist" | sed 's/^/[oki]   /'
}

case "${1:-}" in
  --resolve) cmd_resolve ;;
  --build)   cmd_build ;;
  --package) cmd_package ;;
  *) die "用法: bash scripts/build.sh --resolve|--build|--package" ;;
esac
