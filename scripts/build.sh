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

# 从已同步的源码树读取真实内核版本（common/Makefile 的 VERSION.PATCHLEVEL）。
# 注意：Android16 manifest（*_b）不等于 6.12 内核，例如 sm8750（一加 13/13T）
# 的 _b 分支仍是 6.6；只有 sm8850 等新平台才是 6.12。
detect_kernel_version() {
  local mk="${KP}/common/Makefile"
  [ -f "$mk" ] || return 1
  awk '/^VERSION *=/ { v=$3 } /^PATCHLEVEL *=/ { p=$3 } END { if (v != "" && p != "") print v"."p }' "$mk"
}

KERNEL_VERSION="${KERNEL_VERSION:-auto}"
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

# auto 模式下参与试补丁的分支清单（主分支 + dev 变体）
susfs_branch_candidates() {
  if [ "$SUSFS_BRANCH_INPUT" != "auto" ] && [ -n "$SUSFS_BRANCH_INPUT" ]; then
    echo "$SUSFS_BRANCH_INPUT"; return
  fi
  local base
  base="$(susfs_candidates "$KERNEL_VERSION" | awk '{print $1}')"
  [ -n "$base" ] || die "不支持的内核版本 $KERNEL_VERSION"
  echo "$base ${base}-dev"
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

# 在 SUSFS 分支里定位主补丁：dev 分支的补丁文件名不带 -dev 后缀，
# 因此按「全名 → 去 -dev → 任意 50_*.patch」三级回退。
find_susfs_patch() {
  local dir="$1" br="$2"
  local cands=("50_add_susfs_in_${br}.patch" "50_add_susfs_in_${br%-dev}.patch")
  local c
  for c in "${cands[@]}"; do
    [ -f "${dir}/${c}" ] && { echo "$c"; return 0; }
  done
  c="$(ls "${dir}"/50_*.patch 2>/dev/null | head -1 || true)"
  [ -n "$c" ] && { basename "$c"; return 0; }
  return 1
}

cmd_resolve() {
  local br patch url
  if [ "$KERNEL_VERSION" = "auto" ] && [ "$SUSFS_BRANCH_INPUT" = "auto" ]; then
    cat <<EOT
MANIFEST_BRANCH=${MANIFEST_BRANCH:-}
MANIFEST_FILE=${MANIFEST_FILE}
CPUD=${CPUD}
KERNEL_VERSION=auto（同步源码后从 common/Makefile 读取）
SUSFS_REPO=${SUSFS_REPO}
SUSFS_BRANCH=auto
KSU_VARIANT=${KSU_VARIANT}
KSU_SETUP_URL=$(ksu_setup_url)
LTO=${ENABLE_LTO} POLLY=${ENABLE_POLLY} O3=${ENABLE_O3}
EOT
    return
  fi
  br="$(resolve_susfs_branch)"
  url="$(ksu_setup_url)"
  tmp_dir="$(mktemp -d)"
  git clone --depth 1 -b "$br" "$SUSFS_REPO" "${tmp_dir}/s" >/dev/null 2>&1 \
    || die "克隆 SUSFS 失败：$SUSFS_REPO @ $br"
  patch="kernel_patches/$(find_susfs_patch "${tmp_dir}/s/kernel_patches" "$br")" \
    || die "SUSFS 分支 $br 里找不到 50_*.patch"
  rm -rf "$tmp_dir"
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
  setup_url="$(ksu_setup_url)"
  log "内核源码：$KP"
  log "KernelSU：$KSU_VARIANT"

  # 0) 以源码树里的真实版本为准，避免把 6.12 的 SUSFS 补丁打进 6.6 源码
  local real_kv
  real_kv="$(detect_kernel_version)" || die "无法从 ${KP}/common/Makefile 读取内核版本"
  [ -n "$real_kv" ] || die "无法从 ${KP}/common/Makefile 读取内核版本"
  log "源码树内核版本：${real_kv}"
  if [ "$KERNEL_VERSION" = "auto" ]; then
    KERNEL_VERSION="$real_kv"
  elif [ "$KERNEL_VERSION" != "$real_kv" ]; then
    if [ "$SUSFS_BRANCH_INPUT" = "auto" ] || [ -z "$SUSFS_BRANCH_INPUT" ]; then
      echo "::warning::输入 kernel_version=${KERNEL_VERSION}，但 manifest 同步下来的是 ${real_kv}；按 ${real_kv} 选择 SUSFS 分支" >&2
      KERNEL_VERSION="$real_kv"
    else
      die "输入 kernel_version=${KERNEL_VERSION} 与源码树 ${real_kv} 不符，且手动指定了 susfs_branch=${SUSFS_BRANCH_INPUT}；请改用匹配 ${real_kv} 的分支或换 manifest"
    fi
  fi
  [ -n "$(susfs_candidates "$KERNEL_VERSION")" ] || die "不支持的内核版本 $KERNEL_VERSION"
  echo "KERNEL_VERSION=${KERNEL_VERSION}" >> "${GITHUB_ENV:-/dev/null}"

  # 2a) 用 patch --dry-run 在候选分支里挑补丁最干净的一个
  local best_br="" best_fail=999 tmp_root br cand fails
  tmp_root="$(mktemp -d)"
  for cand in $(susfs_branch_candidates); do
    if ! git clone --depth 1 -b "$cand" "$SUSFS_REPO" "${tmp_root}/${cand}" >/dev/null 2>&1; then
      log "候选 $cand：分支不可用，跳过"; continue
    fi
    local pn
    pn="$(find_susfs_patch "${tmp_root}/${cand}/kernel_patches" "$cand")" || { log "候选 $cand：没有 50_*.patch，跳过"; continue; }
    fails="$( cd "$KP/common" && patch -p1 --dry-run -F3 --forward < "${tmp_root}/${cand}/kernel_patches/${pn}" 2>&1 | grep -cE "FAILED|find file" || true )"
    log "候选 $cand：$pn → 失败块 $fails"
    if [ "$fails" -lt "$best_fail" ]; then best_fail="$fails"; best_br="$cand"; fi
    if [ "$fails" = "0" ]; then break; fi
  done
  [ -n "$best_br" ] || die "没有可用的 SUSFS 分支（候选：$(susfs_branch_candidates)）"
  br="$best_br"
  log "SUSFS：$SUSFS_REPO @ $br（试补丁后选择，失败块=$best_fail）"
  if [ "$best_fail" != "0" ] && [ "${SUSFS_STRICT:-false}" = "true" ]; then
    die "所有候选分支都有 reject（最少 $best_fail 块），SUSFS_STRICT=true 终止"
  fi

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
  cp -r "${tmp_root}/${br}" "$susfs_dir" || die "准备 SUSFS 源码失败"
  rm -rf "$tmp_root"
  patch_dir="${susfs_dir}/kernel_patches"
  patch_name="$(find_susfs_patch "$patch_dir" "$br")" \
    || die "SUSFS 分支 $br 里找不到 50_*.patch"
  log "SUSFS 补丁：$patch_name"

  cp "${patch_dir}/${patch_name}" "${KP}/common/"
  cp -r "${patch_dir}/fs/." "${KP}/common/fs/" 2>/dev/null || true
  cp -r "${patch_dir}/include/linux/." "${KP}/common/include/linux/" 2>/dev/null || true

  local patch_ok=true
  ( cd "${KP}/common" && git apply --3way --whitespace=nowarn "${patch_name}" ) >"${ROOT}/susfs-patch.log" 2>&1 \
    || ( cd "${KP}/common" && patch -p1 --forward -F3 < "${patch_name}" >>"${ROOT}/susfs-patch.log" 2>&1 ) \
    || patch_ok=false
  local rejects
  rejects="$(find "${KP}/common" -name '*.rej' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$patch_ok" = true ] && [ "$rejects" = "0" ]; then
    log "SUSFS 主补丁干净应用"
  else
    log "SUSFS 主补丁有 ${rejects} 处 reject（补丁与 OnePlus 源码存在版本差异）"
    tail -20 "${ROOT}/susfs-patch.log" | sed 's/^/[oki]   /' >&2 || true
    if [ "${SUSFS_STRICT:-false}" = "true" ]; then
      die "SUSFS_STRICT=true：存在 reject，终止（可改用 -dev 分支或放宽）"
    fi
    log "宽松模式继续：reject 已记录，编译可能失败，失败时请换 susfs_branch"
  fi

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

  # 6) 编译：优先用厂商封装脚本（manifest README 指定入口），失败再回落 build_with_bazel.py
  export OPLUS_FEATURES="${OPLUS_FEATURES:-OPLUS_FEATURE_BSP_DRV_INJECT_TEST=1}"
  local entry="${BUILD_ENTRY:-oplus}"
  local oplus_script="${KP}/oplus/build/oplus_build_kernel.sh"
  if [ "$entry" = "oplus" ] && [ -x "$oplus_script" ]; then
    log "编译入口：oplus_build_kernel.sh ${CPUD} perf"
    ( cd "$WS" && ./kernel_platform/oplus/build/oplus_build_kernel.sh "$CPUD" perf ) \
      || { log "oplus 入口失败，回落 build_with_bazel.py"; \
           ( cd "$KP" && ./build_with_bazel.py -t "$CPUD" gki --config=stamp --linkopt="-fuse-ld=lld" $bazel_args ); }
  else
    log "编译入口：build_with_bazel.py -t ${CPUD} gki"
    ( cd "$KP" && ./build_with_bazel.py -t "$CPUD" gki --config=stamp --linkopt="-fuse-ld=lld" $bazel_args )
  fi

  local dist
  dist="$(find "$WS/out" -maxdepth 3 -type d -name dist 2>/dev/null | grep -E "msm-kernel-${CPUD}" | head -1 || true)"
  [ -n "$dist" ] || dist="${WS}/out/msm-kernel-${CPUD}-gki/dist"
  [ -d "$dist" ] || die "编译产物目录不存在：$dist"
  log "编译完成：$dist"
  ls -lh "$dist" | sed 's/^/[oki]   /'
}

# ── 打包 AnyKernel3 ───────────────────────────────────────────────────────
cmd_package() {
  local dist
  dist="$(find "$WS/out" -maxdepth 3 -type d -name dist 2>/dev/null | grep -E "msm-kernel-${CPUD}" | head -1 || true)"
  [ -n "$dist" ] || dist="${WS}/out/msm-kernel-${CPUD}-gki/dist"
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
