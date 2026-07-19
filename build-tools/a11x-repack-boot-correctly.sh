#!/usr/bin/env bash
set -Eeuo pipefail

# Correctly repack an OPPO A11x Android 11 boot image with a plain Image.gz.
# magiskboot already preserves/re-appends kernel_dtb; do not feed it an
# Image.gz-stock-dtb payload or the DTB tail will be duplicated.

die() {
	printf '[错误] %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
用法：
  MAGISKBOOT=/绝对路径/magiskboot \
  ./a11x-repack-boot-correctly.sh \
    原厂boot.img \
    编译输出的纯Image.gz \
    新boot.img

示例（无 KSU 对照内核）：
  ./a11x-repack-boot-correctly.sh \
    /root/kernel/source/a11x-resukisu-boot-repack/boot-stock.img \
    /root/kernel/source/oppo-a11x-resukisu-work/out-noksu-control/arch/arm64/boot/Image.gz \
    /root/kernel/source/oppo-a11x-resukisu-work/dist-noksu-control/a11x-noksu-control-fixed.img

注意：第二个参数只能是纯 Image.gz，不能是 Image.gz-stock-dtb。
EOF
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }
(($# == 3)) || { usage >&2; exit 2; }

abs_file() {
	local input="$1"
	local parent name
	parent="$(cd -- "$(dirname -- "$input")" 2>/dev/null && pwd -P)" || return 1
	name="$(basename -- "$input")"
	printf '%s/%s\n' "$parent" "$name"
}

STOCK_BOOT="$(abs_file "$1")" || die "原厂 boot 路径无效：$1"
IMAGE_GZ="$(abs_file "$2")" || die "Image.gz 路径无效：$2"
OUTPUT_PARENT="$(cd -- "$(dirname -- "$3")" 2>/dev/null && pwd -P)" ||
	die "输出目录不存在：$(dirname -- "$3")"
OUTPUT="$OUTPUT_PARENT/$(basename -- "$3")"

[[ -f "$STOCK_BOOT" ]] || die "找不到原厂 boot：$STOCK_BOOT"
[[ -f "$IMAGE_GZ" ]] || die "找不到 Image.gz：$IMAGE_GZ"
[[ ! -e "$OUTPUT" ]] || die "输出文件已经存在，为避免覆盖请换一个名字：$OUTPUT"
[[ "$OUTPUT" != "$STOCK_BOOT" && "$OUTPUT" != "$IMAGE_GZ" ]] || die "输出不能覆盖输入文件"

for tool in python3 sha256sum stat; do
	command -v "$tool" >/dev/null 2>&1 || die "缺少工具：$tool"
done

MAGISKBOOT="${MAGISKBOOT:-$(command -v magiskboot 2>/dev/null || true)}"
[[ -n "$MAGISKBOOT" && -x "$MAGISKBOOT" ]] ||
	die "找不到 magiskboot；请设置 MAGISKBOOT=/绝对路径/magiskboot"

# Reject Image.gz-stock-dtb or any other gzip with trailing data.
python3 - "$IMAGE_GZ" <<'PY'
from pathlib import Path
import sys, zlib

path = Path(sys.argv[1])
data = path.read_bytes()
if not data.startswith(b"\x1f\x8b"):
    raise SystemExit("[错误] 第二个参数不是 gzip 格式的 Image.gz")
stream = zlib.decompressobj(16 + zlib.MAX_WBITS)
try:
    stream.decompress(data)
    stream.flush()
except zlib.error as error:
    raise SystemExit(f"[错误] Image.gz 损坏：{error}")
if not stream.eof:
    raise SystemExit("[错误] Image.gz 数据不完整")
if stream.unused_data:
    raise SystemExit(
        f"[错误] 第二个参数带有 {len(stream.unused_data)} bytes 尾部数据。\n"
        "不要使用 Image.gz-stock-dtb；必须传入编译目录中的纯 Image.gz。"
    )
print(f"[确认] 输入是纯 Image.gz：{len(data)} bytes")
PY

TMP="$(mktemp -d /tmp/a11x-correct-repack.XXXXXX)"
cleanup() {
	rm -rf -- "$TMP"
}
trap cleanup EXIT

LOG="$OUTPUT.repack.log"
exec > >(tee "$LOG") 2>&1

printf '==================================================\n'
printf ' OPPO A11x 正确重打包 boot\n'
printf ' 不刷写任何分区\n'
printf '==================================================\n'
printf '原厂 boot：%s\n' "$STOCK_BOOT"
printf '纯 Image.gz：%s\n' "$IMAGE_GZ"
printf '输出：%s\n' "$OUTPUT"

cd "$TMP"
"$MAGISKBOOT" unpack "$STOCK_BOOT"
[[ -s kernel ]] || die "magiskboot 没有解出 kernel"

printf '\n[magiskboot 解包文件]\n'
find . -maxdepth 1 -type f -printf '%f %s bytes\n' | sort

if [[ -s kernel_dtb ]]; then
	printf '\n[确认] magiskboot 已单独解出 kernel_dtb：%s bytes。\n' "$(stat -c %s kernel_dtb)"
	printf '[操作] 只用纯 Image.gz 替换 kernel，保留 kernel_dtb，避免重复追加。\n'
	cp "$IMAGE_GZ" kernel
elif [[ -s dtb ]]; then
	printf '\n[确认] magiskboot 已单独解出 dtb：%s bytes。\n' "$(stat -c %s dtb)"
	printf '[操作] 只用纯 Image.gz 替换 kernel，保留 dtb。\n'
	cp "$IMAGE_GZ" kernel
else
	printf '\n[提示] 没有独立 kernel_dtb；检查解出的 kernel 是否自带原厂尾部。\n'
	python3 - "$STOCK_BOOT" "$IMAGE_GZ" kernel <<'PY'
from pathlib import Path
import struct, sys, zlib

stock_path, image_path, output_path = map(Path, sys.argv[1:])
boot = stock_path.read_bytes()
if boot[:8] != b"ANDROID!":
    raise SystemExit("[错误] 原厂文件不是 Android boot image")
size = struct.unpack_from("<I", boot, 8)[0]
page = struct.unpack_from("<I", boot, 36)[0]
stock_kernel = boot[page:page + size]
stream = zlib.decompressobj(16 + zlib.MAX_WBITS)
stream.decompress(stock_kernel)
stream.flush()
tail = stream.unused_data
if not tail.startswith(b"\xd0\x0d\xfe\xed"):
    raise SystemExit("[错误] 无法确定原厂 DTB 尾部，停止打包")
output_path.write_bytes(image_path.read_bytes() + tail)
print(f"[操作] magiskboot 未分离 DTB，因此仅在此模式下手工保留 {len(tail)} bytes 原厂尾部。")
PY
fi

"$MAGISKBOOT" repack "$STOCK_BOOT" "$OUTPUT"
[[ -s "$OUTPUT" ]] || die "magiskboot 没有生成输出 boot"

printf '\n[最终结构校验]\n'
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

def split_gzip(kernel, label):
    if not kernel.startswith(b"\x1f\x8b"):
        raise SystemExit(f"[错误] {label} kernel 不是 gzip")
    stream = zlib.decompressobj(16 + zlib.MAX_WBITS)
    raw = stream.decompress(kernel) + stream.flush()
    if not stream.eof:
        raise SystemExit(f"[错误] {label} gzip 不完整")
    used = len(kernel) - len(stream.unused_data)
    return kernel[:used], stream.unused_data, raw

stock_data, stock_kernel = boot_kernel(stock_path)
out_data, out_kernel = boot_kernel(output_path)
stock_gzip, stock_tail, stock_raw = split_gzip(stock_kernel, "原厂")
out_gzip, out_tail, out_raw = split_gzip(out_kernel, "新 boot")
input_gzip = image_path.read_bytes()

print(f"原厂 kernel：{len(stock_kernel)} bytes")
print(f"新 boot kernel：{len(out_kernel)} bytes")
print(f"原厂 DTB/RTIC：{len(stock_tail)} bytes，FDT={stock_tail.count(bytes.fromhex('d00dfeed'))}")
print(f"新 boot DTB/RTIC：{len(out_tail)} bytes，FDT={out_tail.count(bytes.fromhex('d00dfeed'))}")
print(f"新解压 Image：{len(out_raw)} bytes")

if out_gzip != input_gzip:
    raise SystemExit("[错误] 新 boot 内的 gzip 流与输入 Image.gz 不一致")
if out_tail != stock_tail:
    raise SystemExit("[错误] 新 boot 的 DTB/RTIC 与原厂不完全一致，拒绝交付")
if len(out_tail) != len(stock_tail):
    raise SystemExit("[错误] 新 boot 出现 DTB 尾部重复")

print("[通过] gzip 内核已替换；DTB/RTIC 与原厂逐字节一致且只有一份。")
print(f"新 boot SHA256：{hashlib.sha256(out_data).hexdigest()}")
PY

cd "$OUTPUT_PARENT"
sha256sum "$OUTPUT" > "$OUTPUT.sha256"

printf '\n==================================================\n'
printf '正确打包完成：\n%s\n%s\n' "$OUTPUT" "$OUTPUT.sha256"
printf '先临时测试：\nfastboot boot %q\n' "$OUTPUT"
printf '不要执行 fastboot flash boot。\n'
printf '==================================================\n'
