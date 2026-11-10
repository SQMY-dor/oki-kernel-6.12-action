# OKI Kernel 6.12 · GitHub Actions 编译仓库

一加 OKI 内核（OnePlus Kernel Initiative）云编译，**SUSFS 来源可选**，默认使用
[`simonpunk/susfs4ksu`](https://gitlab.com/simonpunk/susfs4ksu) 并按**内核版本号**自动选择分支树。

## 快速开始

Actions → **Build OKI Kernel (6.12 / SUSFS)** → Run workflow：

| 输入 | 默认 | 说明 |
|---|---|---|
| `manifest_branch` | `oneplus/sm8750` | OnePlusOSS/kernel_manifest 平台分支 |
| `manifest_file` | `oneplus_13t` | 设备 manifest（不带 `.xml`） |
| `cpud` | `sun` | 平台 build target |
| `kernel_version` | `6.12` | 决定 SUSFS 分支树 |
| `susfs_repo` | `https://gitlab.com/simonpunk/susfs4ksu` | 可换成任意镜像/fork |
| `susfs_branch` | `auto` | `auto` = 按内核版本自动匹配；也可手填 |
| `ksu_variant` | `KernelSU-Next` | KernelSU / KernelSU-Next / SukiSU-Ultra |
| `enable_lto` / `enable_polly` / `enable_o3` | 关 | 编译优化（失败时先关掉） |
| `validate_only` | 关 | 只解析参数、不编译（验证配置用） |
| `make_release` | 关 | 成功后发布 Release |

产物：`OKI-<device>-<ksu>-SUSFS-<time>.zip`（AnyKernel3 卡刷包），同时上传为 workflow artifact。

## SUSFS 分支如何按内核版本选

`scripts/build.sh` 内置映射，按「新 → 旧」顺序探测远端分支，存在即用：

| 内核版本 | 候选分支（第一个存在的生效） |
|---|---|
| 6.12 | `gki-android16-6.12` → `gki-android15-6.12` → `kernel-6.12` |
| 6.6 | `gki-android15-6.6` → `gki-android14-6.6` → `kernel-6.6` |
| 6.1 | `gki-android14-6.1` → `gki-android13-6.1` → `kernel-6.1` |
| 5.15 | `gki-android14-5.15` → `gki-android13-5.15` → `kernel-5.15` |
| 5.10 | `gki-android13-5.10` → `gki-android12-5.10` → `kernel-5.10` |
| 5.4 / 4.19 / 4.14 / 4.9 | `kernel-<ver>` |

补丁路径随分支走：`kernel_patches/50_add_susfs_in_<branch>.patch`，
外加 `kernel_patches/fs/*`、`kernel_patches/include/linux/*` 与
`kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch`。

想换 SUSFS 来源（自建镜像、fork、内网 GitLab）只需改 `susfs_repo` 输入；
只要仓库保持同样的目录结构与分支命名即可。

## sm8750 可用设备 manifest

`oneplus_13t` · `oneplus_13t_b` · `oneplus_13` · `oneplus_13_b` · `oneplus_13_global`
· `oneplus_13s` · `oneplus_13s_b` · `oneplus_ace5_pro` · `oneplus_ace5_pro_b`
· `oneplus_ace_6` · `oneplus_pad_3` · `oneplus_pad_3_b`

其它平台把 `manifest_branch` 改成对应分支（`oneplus/sm8650`、`oneplus/sm7675` …），
并把 `cpud` 换成平台代号（sm8650 = `pineapple`，sm8750 = `sun`）。

## 本地复现

```bash
# 1) 解析参数（不需要源码树）
KERNEL_VERSION=6.12 SUSFS_REPO=https://gitlab.com/simonpunk/susfs4ksu \
  bash scripts/build.sh --resolve

# 2) 同步源码
mkdir -p kernel_workspace && cd kernel_workspace
repo init -u https://github.com/OnePlusOSS/kernel_manifest.git \
  -b refs/heads/oneplus/sm8750 -m oneplus_13t.xml --depth=1 --repo-rev=v2.16
repo sync -c -j"$(nproc)" --no-tags --fail-fast

# 3) 编译 + 打包
cd .. && bash scripts/build.sh --build && bash scripts/build.sh --package
```

## 注意事项

- 内核源码来自 `OnePlusOSS/kernel_manifest`（`repo` 多仓同步，约 10–20GB，Actions 上约 30–60 分钟）。
- 编译用 manifest 同步下来的 prebuilt clang；找不到才回落系统 clang。
- AnyKernel3 默认 **关闭 devicecheck**（`do.devicecheck=0`），刷前请确认机型与内核匹配。
- 打不开机 / 卡 logo 时，先关掉 LTO/Polly/O3 重编；SUSFS 与 KSU 的补丁版本差异也可能导致编译失败，可把 `susfs_branch` 手填为更贴近源码的 dev 分支试。
- 本仓库只做"编译 + 打包"，不提供内核源码本身，也不对刷机后果负责。

## 许可

MIT（脚本与 workflow）；内核源码、SUSFS、KernelSU 各自遵循其原始许可。