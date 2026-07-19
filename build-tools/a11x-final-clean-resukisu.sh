#!/usr/bin/env bash
set -Eeuo pipefail

# Final OPPO A11x/PCHM30 kernel preparation:
#   - exact OPPO release commits
#   - only restore released external symlink targets
#   - keep Qualcomm audio/data as stock vendor DLKMs (never in-tree)
#   - pin ReSukiSU and apply its documented Linux 4.14 manual hooks
#   - build with the stock runtime config/toolchain and preserve stock DTB tail

OFFICIAL_KERNEL_COMMIT="47e5e4fb39f820a2648c998959b9def509bdb8a3"
OFFICIAL_MODULES_COMMIT="5e7bee452c72c948427b9131bec8cd5d92934f83"
RESUKISU_COMMIT="930f61a654f35b98577e5da781fb30f9a1bc678b"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUILDER="$SCRIPT_DIR/a11x-build-final-resukisu.sh"
HOOK_PATCHER="$SCRIPT_DIR/apply-resukisu-hooks.py"

die() {
	printf '[错误] %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
用法：
  SDCLANG_DIR=/path/Snapdragon-LLVM-10.0.7 \
  GCC64_DIR=/path/aarch64-linux-android-4.9 \
  GCC32_DIR=/path/arm-linux-androideabi-4.9 \
  MAGISKBOOT=/path/magiskboot \
  ./a11x-final-clean-resukisu.sh \
    工作区或内核根目录 原厂boot.img 原厂stock-running.config

你的目录示例：
  ./a11x-final-clean-resukisu.sh \
    /root/kernel/source/oppo-a11x-resukisu-work \
    /root/kernel/source/a11x-resukisu-boot-repack/boot-stock.img \
    /root/kernel/source/oppo-a11x-resukisu-work/a11x-stock-vs-built-report-20260719-000324/phone/stock-running.config

可选：若服务器已克隆 ReSukiSU，可设置 RESUKISU_REPO=/绝对路径/ReSukiSU。
脚本只会新建 a11x-final-clean-resukisu-时间戳，不清理或覆盖现有源码。
EOF
}

[[ "${1:-}" != -h && "${1:-}" != --help ]] || { usage; exit 0; }
(($# == 3)) || { usage >&2; exit 2; }
[[ -x "$BUILDER" ]] || die "同目录缺少可执行脚本：$BUILDER"
[[ -f "$HOOK_PATCHER" ]] || die "同目录缺少：$HOOK_PATCHER"

abs_existing_file() {
	local parent name
	parent="$(cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P)" || return 1
	name="$(basename -- "$1")"
	[[ -f "$parent/$name" ]] || return 1
	printf '%s/%s\n' "$parent" "$name"
}

INPUT_ROOT="$(cd -- "$1" 2>/dev/null && pwd -P)" || die "目录不存在：$1"
STOCK_BOOT="$(abs_existing_file "$2")" || die "找不到原厂 boot：$2"
STOCK_CONFIG="$(abs_existing_file "$3")" || die "找不到原厂 config：$3"

if [[ -f "$INPUT_ROOT/source/android/kernel/msm-4.14/Makefile" ]]; then
	WORKSPACE="$INPUT_ROOT"
	SOURCE_KERNEL="$INPUT_ROOT/source/android/kernel/msm-4.14"
elif [[ -f "$INPUT_ROOT/Makefile" && -f "$INPUT_ROOT/Kconfig" ]]; then
	SOURCE_KERNEL="$INPUT_ROOT"
	WORKSPACE="$(cd -- "$SOURCE_KERNEL/../../../.." 2>/dev/null && pwd -P)" ||
		die "无法从内核根目录定位工作区"
else
	die "找不到内核根目录；应存在 source/android/kernel/msm-4.14/Makefile"
fi

for tool in git tar python3 find grep sort sed wc; do
	command -v "$tool" >/dev/null 2>&1 || die "缺少主机工具：$tool"
done

git -C "$SOURCE_KERNEL" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
	die "内核目录不是 git 仓库"
git -C "$SOURCE_KERNEL" cat-file -e "$OFFICIAL_KERNEL_COMMIT^{commit}" 2>/dev/null ||
	die "本地内核仓库缺少 OPPO 官方提交 $OFFICIAL_KERNEL_COMMIT"

modules_repo_ok() {
	local repo="$1"
	[[ -d "$repo" ]] || return 1
	git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
	git -C "$repo" cat-file -e "$OFFICIAL_MODULES_COMMIT^{commit}" 2>/dev/null || return 1
}

MODULES_REPO="${MODULES_REPO:-}"
if [[ -n "$MODULES_REPO" ]]; then
	modules_repo_ok "$MODULES_REPO" ||
		die "MODULES_REPO 不是固定提交对应的 OPPO modules 仓库"
else
	for candidate in \
		/root/kernel/source/android_kernel_modules_and_devicetree_oppo_sm6125 \
		/root/kernel/source/oppo_modules_and_devicetree_sm6125; do
		if modules_repo_ok "$candidate"; then
			MODULES_REPO="$(cd -- "$candidate" && pwd -P)"
			break
		fi
	done
fi

if [[ -z "$MODULES_REPO" && -d /root/kernel/source ]]; then
	while IFS= read -r candidate; do
		if modules_repo_ok "$candidate"; then
			MODULES_REPO="$(cd -- "$candidate" && pwd -P)"
			break
		fi
	done < <(find /root/kernel/source -maxdepth 3 -type d \
		-name '*modules*devicetree*sm6125*' 2>/dev/null | sort)
fi
[[ -n "$MODULES_REPO" ]] ||
	die "找不到 OPPO modules_and_devicetree 固定提交；可设置 MODULES_REPO=/绝对路径"

RUN_STAMP="${RUN_STAMP:-$(date +%Y%m%d-%H%M%S)}"
SANDBOX="$WORKSPACE/a11x-final-clean-resukisu-$RUN_STAMP"
CLEAN_KERNEL="$SANDBOX/source/android/kernel/msm-4.14"
[[ ! -e "$SANDBOX" ]] || die "输出目录已存在：$SANDBOX"
mkdir -p "$(dirname -- "$CLEAN_KERNEL")"

printf '[1/6] 创建 OPPO 官方固定提交的干净 worktree……\n'
git -C "$SOURCE_KERNEL" worktree add --detach "$CLEAN_KERNEL" "$OFFICIAL_KERNEL_COMMIT"
[[ -z "$(git -C "$CLEAN_KERNEL" status --porcelain)" ]] ||
	die "官方 worktree 意外不干净"

printf '[2/6] 仅恢复 OPPO 官方仓库中的断链目标……\n'
EXTERNAL_PATHS="$SANDBOX/official-external-link-targets.txt"
: > "$EXTERNAL_PATHS"
for pass in 1 2 3 4 5; do
	BROKEN_TARGETS="$(
		python3 - "$CLEAN_KERNEL" "$SANDBOX" <<'PY'
from pathlib import Path
import os, sys

kernel = Path(sys.argv[1])
sandbox = Path(sys.argv[2]).resolve()
targets = set()
for base, dirs, files in os.walk(kernel, followlinks=False):
    for name in dirs + files:
        link = Path(base) / name
        if not link.is_symlink() or link.exists():
            continue
        target = (link.parent / os.readlink(link)).resolve(strict=False)
        try:
            targets.add(target.relative_to(sandbox).as_posix())
        except ValueError:
            raise SystemExit(f"[错误] 软链接逃出沙箱：{link} -> {target}")
print("\n".join(sorted(targets)))
PY
	)"
	[[ -n "$BROKEN_TARGETS" ]] || break
	while IFS= read -r rel; do
		[[ -n "$rel" ]] || continue
		git -C "$MODULES_REPO" cat-file -e \
			"$OFFICIAL_MODULES_COMMIT:$rel" 2>/dev/null ||
			die "OPPO modules 固定提交中缺少断链目标：$rel"
		if ! grep -Fxq "$rel" "$EXTERNAL_PATHS"; then
			printf '[恢复] %s\n' "$rel"
			git -C "$MODULES_REPO" archive "$OFFICIAL_MODULES_COMMIT" "$rel" |
				tar -x -C "$SANDBOX"
			printf '%s\n' "$rel" >> "$EXTERNAL_PATHS"
		fi
	done <<< "$BROKEN_TARGETS"
done

if find "$CLEAN_KERNEL" -xtype l -print -quit | grep -q .; then
	find "$CLEAN_KERNEL" -xtype l -printf '%p -> %l\n' >&2 || true
	die "恢复后仍有断开的官方软链接"
fi

printf '[3/6] 固定 ReSukiSU 提交，不跟随 main 更新……\n'
if [[ -n "${RESUKISU_REPO:-}" ]]; then
	RESUKISU_REPO="$(cd -- "$RESUKISU_REPO" 2>/dev/null && pwd -P)" ||
		die "RESUKISU_REPO 不存在"
	git -C "$RESUKISU_REPO" cat-file -e "$RESUKISU_COMMIT^{commit}" 2>/dev/null ||
		die "RESUKISU_REPO 缺少固定提交 $RESUKISU_COMMIT"
	git clone --no-hardlinks --no-checkout "$RESUKISU_REPO" "$CLEAN_KERNEL/KernelSU"
else
	git clone --filter=blob:none --no-checkout \
		https://github.com/ReSukiSU/ReSukiSU.git "$CLEAN_KERNEL/KernelSU"
fi
git -C "$CLEAN_KERNEL/KernelSU" checkout --detach "$RESUKISU_COMMIT"
[[ "$(git -C "$CLEAN_KERNEL/KernelSU" rev-parse HEAD)" == "$RESUKISU_COMMIT" ]] ||
	die "ReSukiSU 提交校验失败"

[[ ! -e "$CLEAN_KERNEL/drivers/kernelsu" ]] || die "官方干净树意外已有 drivers/kernelsu"
ln -s ../KernelSU/kernel "$CLEAN_KERNEL/drivers/kernelsu"
grep -q 'kernelsu' "$CLEAN_KERNEL/drivers/Makefile" &&
	die "官方 drivers/Makefile 意外已有 kernelsu"
printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$CLEAN_KERNEL/drivers/Makefile"
grep -q 'drivers/kernelsu/Kconfig' "$CLEAN_KERNEL/drivers/Kconfig" &&
	die "官方 drivers/Kconfig 意外已有 kernelsu"
[[ "$(grep -c '^endmenu$' "$CLEAN_KERNEL/drivers/Kconfig")" == 1 ]] ||
	die "drivers/Kconfig 的 endmenu 结构与固定源码不符"
sed -i '/^endmenu$/i source "drivers/kernelsu/Kconfig"' "$CLEAN_KERNEL/drivers/Kconfig"

printf '[4/6] 应用 ReSukiSU 文档规定的 Linux 4.14 手动 Hook……\n'
python3 "$HOOK_PATCHER" "$CLEAN_KERNEL"

printf '[5/6] 执行启动结构硬保护……\n'
for forbidden in techpack/audio techpack/data; do
	[[ ! -e "$CLEAN_KERNEL/$forbidden" ]] ||
		die "检测到 $forbidden；A11x 原厂使用外置 DLKM，本方案拒绝内建"
done
grep -q 'CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y' "$STOCK_CONFIG" &&
	die "传入 config 启用了 appended DTB，不是本机原厂运行配置"
printf '[确认] 未内建 audio/data；将只生成纯 Image.gz 并保留原厂唯一 DTB 尾部。\n'

printf '[6/6] 使用原厂配置/SDClang 生成最终 ReSukiSU boot……\n'
export EXPECTED_RESUKISU_COMMIT="$RESUKISU_COMMIT"
"$BUILDER" "$SANDBOX" "$STOCK_BOOT" "$STOCK_CONFIG"

printf '\n最终工作目录：%s\n' "$SANDBOX"
