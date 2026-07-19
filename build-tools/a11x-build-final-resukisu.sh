#!/usr/bin/env bash
set -Eeuo pipefail

# Build the final OPPO A11x ReSukiSU kernel:
#   * the running stock kernel's /proc/config.gz
#   * Snapdragon LLVM 10.0.7 (the compiler shown by the stock kernel)
#   * GNU binutils 2.27, not LLVM binutils/lld
#   * pinned ReSukiSU with the Linux 4.14 manual hook path
#   * SUSFS/tracepoint disabled; Qualcomm audio/data remain stock vendor DLKMs
#   * module-signature enforcement disabled (the public tree lacks OPPO's key)
#   * the stock boot image's original ramdisk, header and single DTB/RTIC tail

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
  ./a11x-build-final-resukisu.sh \
    工作区或内核根目录 原厂boot.img 原厂stock-running.config

你的目录示例：
  ./a11x-build-final-resukisu.sh \
    /root/kernel/source/oppo-a11x-resukisu-work \
    /root/kernel/source/a11x-resukisu-boot-repack/boot-stock.img \
    /root/kernel/source/oppo-a11x-resukisu-work/a11x-stock-vs-built-report-20260719-000324/phone/stock-running.config

第三个参数必须是从这台 PCHM30/19021 当前原厂内核提取的 config，
不要传 vendor/trinket-perf_defconfig，也不要传上次编译生成的 .config。
通常直接运行同目录的 a11x-final-clean-resukisu.sh，不要单独调用本脚本。
EOF
}

[[ "${1:-}" != -h && "${1:-}" != --help ]] || { usage; exit 0; }
(($# == 3)) || { usage >&2; exit 2; }

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
	KERNEL="$INPUT_ROOT/source/android/kernel/msm-4.14"
elif [[ -f "$INPUT_ROOT/Makefile" && -f "$INPUT_ROOT/Kconfig" ]]; then
	KERNEL="$INPUT_ROOT"
	WORKSPACE="$(cd -- "$KERNEL/../../../.." 2>/dev/null && pwd -P || printf '%s' "$KERNEL")"
else
	die "找不到内核根目录；应当存在 source/android/kernel/msm-4.14/Makefile"
fi

for tool in make gcc g++ bc bison flex cpio perl python python3 gzip sha256sum strings stat git; do
	command -v "$tool" >/dev/null 2>&1 || die "缺少主机工具：$tool"
done

: "${SDCLANG_DIR:?请设置 SDCLANG_DIR，必须指向 Snapdragon LLVM 10.0.7 根目录}"
: "${GCC64_DIR:?请设置 GCC64_DIR，必须指向 aarch64 GCC 4.9 根目录}"
: "${GCC32_DIR:?请设置 GCC32_DIR，必须指向 arm GCC 4.9 根目录}"
: "${MAGISKBOOT:?请设置 MAGISKBOOT=/绝对路径/magiskboot}"

SDCLANG_DIR="$(cd -- "$SDCLANG_DIR" 2>/dev/null && pwd -P)" || die "SDCLANG_DIR 不存在"
GCC64_DIR="$(cd -- "$GCC64_DIR" 2>/dev/null && pwd -P)" || die "GCC64_DIR 不存在"
GCC32_DIR="$(cd -- "$GCC32_DIR" 2>/dev/null && pwd -P)" || die "GCC32_DIR 不存在"
MAGISKBOOT="$(abs_existing_file "$MAGISKBOOT")" || die "MAGISKBOOT 路径无效"
[[ -x "$MAGISKBOOT" ]] || die "magiskboot 没有执行权限：$MAGISKBOOT"

SDCLANG="$SDCLANG_DIR/bin/clang"
[[ -x "$SDCLANG" ]] || die "SDCLANG_DIR 下没有可执行的 bin/clang"

pick_prefix() {
	local dir="$1"
	shift
	local prefix
	for prefix in "$@"; do
		if [[ -x "$dir/bin/${prefix}gcc" && -x "$dir/bin/${prefix}ld" ]]; then
			printf '%s/bin/%s' "$dir" "$prefix"
			return 0
		fi
	done
	return 1
}

CROSS64="$(pick_prefix "$GCC64_DIR" \
	aarch64-linux-android- aarch64-linux-androidkernel- aarch64-linux-androideabi-)" ||
	die "GCC64_DIR 中找不到 aarch64 GCC/ld"
CROSS32="$(pick_prefix "$GCC32_DIR" arm-linux-androideabi- arm-eabi-)" ||
	die "GCC32_DIR 中找不到 arm GCC/ld"
[[ -x "${CROSS64}elfedit" ]] ||
	die "GCC64 工具链缺少 ${CROSS64}elfedit，Kbuild 无法定位 GNU toolchain"

CLANG_VERSION="$($SDCLANG --version 2>&1 | head -n 1)"
LD_VERSION="$(${CROSS64}ld --version 2>&1 | head -n 1)"
[[ "$CLANG_VERSION" == *"clang version 10.0.7 for Android NDK"* ]] ||
	die "编译器不是原厂同款 Snapdragon LLVM 10.0.7：$CLANG_VERSION"
[[ "$LD_VERSION" == *"2.27"* ]] ||
	die "链接器不是原厂同代 GNU ld 2.27：$LD_VERSION"

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
OUT="$WORKSPACE/out-final-resukisu-$RUN_ID"
DIST="$WORKSPACE/dist-final-resukisu-$RUN_ID"
LOG="$WORKSPACE/build-final-resukisu-$RUN_ID.log"
[[ ! -e "$OUT" && ! -e "$DIST" ]] || die "时间戳输出目录已存在，请重新运行"
mkdir -p "$OUT" "$DIST"

export PATH="$SDCLANG_DIR/bin:$GCC64_DIR/bin:$GCC32_DIR/bin:$PATH"
export ARCH=arm64
export TARGET_PRODUCT=trinket
export KCONFIG_NOTIMESTAMP=true
export KBUILD_BUILD_USER=root
export KBUILD_BUILD_HOST=ubuntu-8-196
export KBUILD_BUILD_VERSION=2
export KBUILD_BUILD_TIMESTAMP='Mon May 16 17:39:41 CST 2022'
unset LLVM LLVM_IAS KBUILD_COMPILER_STRING

JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '8')}"
MAKE_ARGS=(
	O="$OUT"
	ARCH=arm64
	# The OPPO tree's default CC goes through scripts/gcc-wrapper.py, which is
	# Python-2-only.  On current Debian, "python" is Python 3, so that wrapper
	# dies silently during Kbuild's compiler probes and clang is misdetected as
	# gcc.  Override CC with the real compiler, as modern standalone builds do.
	CC="$SDCLANG"
	CROSS_COMPILE="$CROSS64"
	CROSS_COMPILE_ARM32="$CROSS32"
	REAL_CC="$SDCLANG"
	CLANG_TRIPLE=aarch64-linux-gnu-
	LOCALVERSION=+
)

exec > >(tee "$LOG") 2>&1

printf '==================================================\n'
printf ' OPPO A11x 最终 ReSukiSU + Snapdragon LLVM 10.0.7\n'
printf ' 外置 audio/data DLKM；SUSFS 关闭；只保留一份原厂 DTB\n'
printf '==================================================\n'
printf '内核根目录：%s\n' "$KERNEL"
printf '原厂 boot：%s\n' "$STOCK_BOOT"
printf '原厂 config：%s\n' "$STOCK_CONFIG"
printf '编译器：%s\n' "$CLANG_VERSION"
printf '链接器：%s\n' "$LD_VERSION"
printf '输出目录：%s\n' "$OUT"
printf '日志：%s\n' "$LOG"

# Test the exact compiler path and flags Kbuild will use.  This catches a
# missing GNU assembler or an incompatible SDClang package before a long build.
if ! "$SDCLANG" \
	--target=aarch64-linux-gnu \
	--prefix="$GCC64_DIR/bin/" \
	--gcc-toolchain="$GCC64_DIR" \
	-no-integrated-as \
	-fstack-protector-strong \
	-c -x c /dev/null -o "$OUT/.sdclang-probe.o"; then
	die "Snapdragon clang 的 ARM64/栈保护预检失败"
fi
printf '[确认] Snapdragon clang ARM64 + GNU assembler + stack protector 预检通过。\n'

case "$STOCK_CONFIG" in
	*.gz) gzip -cd -- "$STOCK_CONFIG" > "$OUT/.config.stock" ;;
	*) cp -- "$STOCK_CONFIG" "$OUT/.config.stock" ;;
esac
cp -- "$OUT/.config.stock" "$OUT/.config"

grep -qx 'CONFIG_LOCALVERSION="-perf"' "$OUT/.config" ||
	die "传入的 config 不是报告中的 A11x 原厂运行配置（LOCALVERSION 不符）"
grep -qx 'CONFIG_IKCONFIG_PROC=y' "$OUT/.config" ||
	die "传入的 config 缺少 CONFIG_IKCONFIG_PROC=y"

# Reject the two failed approaches before touching Kconfig.
for forbidden in techpack/audio techpack/data; do
	[[ ! -e "$KERNEL/$forbidden" ]] ||
		die "检测到 $forbidden；A11x 原厂是外置 DLKM，拒绝继续"
done
[[ -L "$KERNEL/drivers/kernelsu" && -f "$KERNEL/KernelSU/kernel/Kconfig" ]] ||
	die "ReSukiSU 没有按预期接入 drivers/kernelsu"
: "${EXPECTED_RESUKISU_COMMIT:?缺少 EXPECTED_RESUKISU_COMMIT，请运行总脚本}"
[[ "$(git -C "$KERNEL/KernelSU" rev-parse HEAD)" == "$EXPECTED_RESUKISU_COMMIT" ]] ||
	die "ReSukiSU 源码不是固定提交"

for source_file in fs/exec.c fs/open.c fs/stat.c kernel/reboot.c; do
	grep -q 'ksu_handle_' "$KERNEL/$source_file" || die "$source_file 缺少手动 Hook"
done

# Start from the phone's running config.  The public source lacks OPPO's
# private signing key, so stock vendor DLKMs can only load when enforcement is
# disabled. CONFIG_MODVERSIONS remains enabled for ABI version checks.
for symbol in \
	KSU KSU_DEBUG KSU_TOOLKIT_SUPPORT KSU_TRACEPOINT_HOOK KSU_MANUAL_HOOK \
	KSU_SUSFS KSU_DISABLE_MANAGER KSU_DISABLE_POLICY \
	MODULE_SIG MODULE_SIG_FORCE MODULE_SIG_ALL MODULE_SIG_SHA512 SUSFS; do
	"$KERNEL/scripts/config" --file "$OUT/.config" --disable "$symbol"
done
for symbol in \
	KSU KSU_MANUAL_HOOK KSU_MANUAL_HOOK_AUTO_SETUID_HOOK \
	KSU_MANUAL_HOOK_AUTO_INITRC_HOOK KSU_MANUAL_HOOK_AUTO_INPUT_HOOK; do
	"$KERNEL/scripts/config" --file "$OUT/.config" --enable "$symbol"
done

make -C "$KERNEL" "${MAKE_ARGS[@]}" olddefconfig

for required in \
	CONFIG_KSU=y CONFIG_KSU_MANUAL_HOOK=y \
	CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y \
	CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y \
	CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y \
	CONFIG_KALLSYMS_ALL=y CONFIG_MODVERSIONS=y; do
	grep -qx "$required" "$OUT/.config" || die "最终配置缺少：$required"
done
for forbidden in KSU_TRACEPOINT_HOOK KSU_SUSFS KSU_DEBUG KSU_TOOLKIT_SUPPORT MODULE_SIG; do
	grep -qx "# CONFIG_${forbidden} is not set" "$OUT/.config" ||
		die "最终配置没有关闭：CONFIG_$forbidden"
done
if grep -Eq '^CONFIG_KSU_SUSFS[A-Za-z0-9_]*=(y|m)$' "$OUT/.config"; then
	grep -E '^CONFIG_KSU_SUSFS[A-Za-z0-9_]*=(y|m)$' "$OUT/.config" >&2
	die "仍有 SUSFS 选项启用"
fi

python3 - "$OUT/.config.stock" "$OUT/.config" "$DIST/config-semantic-diff.txt" <<'PY'
from pathlib import Path
import re, sys

stock_path, final_path, report_path = map(Path, sys.argv[1:])

def parse(path):
    values = {}
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
            continue
        match = re.fullmatch(r"# (CONFIG_[A-Za-z0-9_]+) is not set", line)
        if match:
            values[match.group(1)] = "n"
    return values

stock = parse(stock_path)
final = parse(final_path)
keys = sorted(set(stock) | set(final))
changes = [(k, stock.get(k, "<missing>"), final.get(k, "<missing>"))
           for k in keys if stock.get(k) != final.get(k)]
report_path.write_text("".join(f"{k}\tstock={a}\tfinal={b}\n" for k, a, b in changes))

critical = {
    "CONFIG_LOCALVERSION",
    "CONFIG_LOCALVERSION_AUTO",
    "CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE",
    "CONFIG_BUILD_ARM64_DT_OVERLAY",
    "CONFIG_DEBUG_FS",
    "CONFIG_MODULES",
    "CONFIG_MODVERSIONS",
    "CONFIG_MODULE_SIG",
    "CONFIG_MODULE_SIG_FORCE",
    "CONFIG_LTO_NONE",
    "CONFIG_TOUCHPANEL_OPPO",
    "CONFIG_TOUCHPANEL_NEW_SET_IRQ_WAKE",
    "CONFIG_TOUCHPANEL_NOVA_NT36525B_NOFLASH",
    "CONFIG_TOUCHPANEL_ILITEK",
    "CONFIG_TOUCHPANEL_ILITEK_ILITEK9881H_V3",
}
allowed = {
    "CONFIG_MODULE_SIG",
    "CONFIG_MODULE_SIG_FORCE",
    "CONFIG_MODULE_SIG_ALL",
    "CONFIG_MODULE_SIG_SHA512",
    "CONFIG_MODULE_SIG_HASH",
    "CONFIG_MODULE_SIG_KEY",
}
bad = [(k, a, b) for k, a, b in changes if k in critical and k not in allowed]
print(f"[配置比较] olddefconfig 后共 {len(changes)} 项语义差异。")
print(f"[配置比较] 详情：{report_path}")
if bad:
    for k, a, b in bad:
        print(f"[关键差异] {k}: stock={a}, final={b}")
    raise SystemExit("[错误] 当前公开源码无法保留原厂关键配置，停止生成测试镜像")
PY

cp -- "$OUT/.config" "$DIST/config-final"
printf '\n[开始编译] 只生成纯 Image.gz 和模块；不编译/替换设备树。\n'
make -C "$KERNEL" -j"$JOBS" "${MAKE_ARGS[@]}" Image.gz modules

IMAGE_GZ="$OUT/arch/arm64/boot/Image.gz"
VMLINUX="$OUT/vmlinux"
[[ -s "$IMAGE_GZ" ]] || die "没有生成 Image.gz"
[[ -s "$VMLINUX" ]] || die "没有生成 vmlinux"
cp -- "$IMAGE_GZ" "$DIST/Image.gz"

python3 - "$VMLINUX" "$DIST/kernel-version.txt" <<'PY'
from pathlib import Path
import sys

source, output = map(Path, sys.argv[1:])
data = source.read_bytes()
start = data.find(b"Linux version ")
if start < 0:
    raise SystemExit("[错误] 无法从 vmlinux 读取 Linux version")
end = data.find(b"\x00", start)
if end < 0:
    raise SystemExit("[错误] vmlinux 中的 Linux version 字符串不完整")
version = data[start:end].decode("ascii", "replace")
output.write_text(version + "\n")
print(version)
PY
grep -q 'clang version 10.0.7 for Android NDK' "$DIST/kernel-version.txt" ||
	die "vmlinux 编译器标识不是原厂 Snapdragon LLVM 10.0.7"
grep -q 'GNU ld .*2.27' "$DIST/kernel-version.txt" ||
	die "vmlinux 链接器标识不是原厂 GNU ld 2.27"
grep -q '4.14.180-perf+' "$DIST/kernel-version.txt" ||
	die "内核 release 不是原厂的 4.14.180-perf+，模块 ABI 会不一致"

OUTPUT="$DIST/a11x-final-resukisu-boot.img"
TMP="$(mktemp -d /tmp/a11x-final-resukisu-repack.XXXXXX)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

(
	cd "$TMP"
	"$MAGISKBOOT" unpack "$STOCK_BOOT"
	[[ -s kernel ]] || die "magiskboot 没有解出 kernel"
	[[ -s kernel_dtb || -s dtb ]] || die "没有独立 kernel_dtb/dtb；拒绝猜测打包结构"
	cp -- "$IMAGE_GZ" kernel
	"$MAGISKBOOT" repack "$STOCK_BOOT" "$OUTPUT"
)
[[ -s "$OUTPUT" ]] || die "magiskboot 没有生成 boot"

python3 - "$STOCK_BOOT" "$OUTPUT" "$IMAGE_GZ" <<'PY'
from pathlib import Path
import hashlib, struct, sys, zlib

stock_path, output_path, image_path = map(Path, sys.argv[1:])

def boot_kernel(path):
    data = path.read_bytes()
    if data[:8] != b"ANDROID!":
        raise SystemExit(f"[错误] {path} 不是 Android boot image")
    size = struct.unpack_from("<I", data, 8)[0]
    page = struct.unpack_from("<I", data, 36)[0]
    return data, data[page:page + size]

def split_gzip(data, label):
    if not data.startswith(b"\x1f\x8b"):
        raise SystemExit(f"[错误] {label} kernel 不是 gzip")
    stream = zlib.decompressobj(16 + zlib.MAX_WBITS)
    raw = stream.decompress(data) + stream.flush()
    if not stream.eof:
        raise SystemExit(f"[错误] {label} gzip 不完整")
    used = len(data) - len(stream.unused_data)
    return data[:used], stream.unused_data, raw

stock_data, stock_kernel = boot_kernel(stock_path)
out_data, out_kernel = boot_kernel(output_path)
stock_gzip, stock_tail, stock_raw = split_gzip(stock_kernel, "原厂")
out_gzip, out_tail, out_raw = split_gzip(out_kernel, "新 boot")
input_gzip = image_path.read_bytes()

print(f"原厂 kernel: {len(stock_kernel)} bytes")
print(f"新 kernel: {len(out_kernel)} bytes")
print(f"原厂 DTB/RTIC: {len(stock_tail)} bytes, FDT={stock_tail.count(bytes.fromhex('d00dfeed'))}")
print(f"新 DTB/RTIC: {len(out_tail)} bytes, FDT={out_tail.count(bytes.fromhex('d00dfeed'))}")
if out_gzip != input_gzip:
    raise SystemExit("[错误] boot 中 gzip 与本次编译 Image.gz 不一致")
if out_tail != stock_tail:
    raise SystemExit("[错误] 新 boot 的 DTB/RTIC 不是逐字节原厂数据")
if len(out_tail) != len(stock_tail):
    raise SystemExit("[错误] DTB 尾部数量异常")
print("[通过] 纯内核已替换；原厂 DTB/RTIC 逐字节一致且只有一份。")
print(f"新 boot SHA256: {hashlib.sha256(out_data).hexdigest()}")
PY

sha256sum "$OUTPUT" > "$OUTPUT.sha256"
sha256sum "$IMAGE_GZ" > "$DIST/Image.gz.sha256"

printf '\n==================================================\n'
printf '最终 ReSukiSU boot 已生成：\n%s\n' "$OUTPUT"
printf '校验：%s\n' "$OUTPUT.sha256"
printf '临时启动命令：\nfastboot boot %q\n' "$OUTPUT"
printf '不要执行 fastboot flash boot。\n'
printf '==================================================\n'
