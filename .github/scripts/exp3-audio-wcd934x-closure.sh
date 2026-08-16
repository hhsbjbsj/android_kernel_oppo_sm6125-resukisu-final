#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee "$GITHUB_WORKSPACE/audio-wcd934x-closure.log") 2>&1

KERNEL="$GITHUB_WORKSPACE/$KERNEL_REL"
KOUT="$KERNEL/$OUT_DIR"
AUDIO="$GITHUB_WORKSPACE/source/android/vendor/qcom/opensource/audio-kernel"
AOUT="$GITHUB_WORKSPACE/audio-product"
EXPORT="$GITHUB_WORKSPACE/audio-exp3"
MODROOT="$GITHUB_WORKSPACE/audio-ksu-module"
WCD934X="$AUDIO/asoc/codecs/wcd934x"
ASOC="$AUDIO/asoc"

for f in \
  "$WCD934X/Kbuild" \
  "$ASOC/Kbuild" \
  "$AUDIO/config/trinketauto.conf" \
  "$AOUT/obj/vendor/qcom/opensource/audio-kernel/ipc/Module.symvers" \
  "$AOUT/obj/vendor/qcom/opensource/audio-kernel/dsp/Module.symvers" \
  "$AOUT/obj/vendor/qcom/opensource/audio-kernel/asoc/codecs/Module.symvers" \
  "$AOUT/obj/vendor/qcom/opensource/audio-kernel/asoc/codecs/wcd937x/Module.symvers" \
  "$AOUT/obj/vendor/qcom/opensource/audio-kernel/soc/Module.symvers"; do
  test -e "$f" || { echo "[FATAL] required input missing: $f"; exit 71; }
done

grep -q '^CONFIG_SND_SOC_WCD934X=m' "$AUDIO/config/trinketauto.conf"
grep -q '^CONFIG_SND_SOC_SM6150=m' "$AUDIO/config/trinketauto.conf"
grep -q '^CONFIG_MODVERSIONS=y$' "$KOUT/.config"

common_make=(
  ARCH=arm64 LOCALVERSION=+
  CC="$CC" REAL_CC="$REAL_CC" LD="$LD"
  CROSS_COMPILE="$CROSS_COMPILE"
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32"
  CLANG_TRIPLE="$CLANG_TRIPLE"
  OUT="$AOUT" AUDIO_ROOT="$AUDIO"
  BOARD_PLATFORM=trinket CONFIG_ARCH_TRINKET=y CONFIG_SND_SOC_SM6150=m
  KBUILD_MODPOST_WARN=0
)

echo '===== BUILD REAL WCD934X/TAVIL PROVIDER ====='
rm -f "$WCD934X/Module.symvers" "$WCD934X/modules.order"
rm -rf "$WCD934X/.tmp_versions"
make -C "$KERNEL" O="$KOUT" M="$WCD934X" \
  "${common_make[@]}" MODNAME=wcd934x_dlkm modules -j"$(nproc)"

test -s "$WCD934X/wcd934x_dlkm.ko"
test -s "$WCD934X/Module.symvers"
mkdir -p "$AOUT/obj/vendor/qcom/opensource/audio-kernel/asoc/codecs/wcd934x"
cp -f "$WCD934X/Module.symvers" \
  "$AOUT/obj/vendor/qcom/opensource/audio-kernel/asoc/codecs/wcd934x/Module.symvers"

# These are the exact Tavil providers that Run10 machine_dlkm was missing.
for sym in \
  tavil_cdc_mclk_tx_enable \
  tavil_codec_info_create_codec_entry \
  tavil_cdc_mclk_enable \
  tavil_set_spkr_mode \
  tavil_mbhc_hs_detect \
  tavil_get_afe_config \
  tavil_set_spkr_gain_offset; do
  grep -q "[[:space:]]${sym}[[:space:]]" "$WCD934X/Module.symvers" || {
    echo "[FATAL] WCD934X did not export Run10-missing symbol: $sym"
    exit 72
  }
done

echo '===== REBUILD ASOC MACHINE/PLATFORM AGAINST REAL WCD934X SYMVERS ====='
rm -f "$ASOC/Module.symvers" "$ASOC/modules.order"
rm -rf "$ASOC/.tmp_versions"
make -C "$KERNEL" O="$KOUT" M="$ASOC" \
  "${common_make[@]}" MODNAME=platform_dlkm modules -j"$(nproc)"

test -s "$ASOC/machine_dlkm.ko"
test -s "$ASOC/platform_dlkm.ko"
test -s "$ASOC/Module.symvers"
mkdir -p "$AOUT/obj/vendor/qcom/opensource/audio-kernel/asoc"
cp -f "$ASOC/Module.symvers" "$AOUT/obj/vendor/qcom/opensource/audio-kernel/asoc/Module.symvers"

mkdir -p "$EXPORT/raw" "$MODROOT/system/vendor/lib/modules/exp3_audio_raw" "$MODROOT/system/vendor/lib/modules"
cp -f "$WCD934X/wcd934x_dlkm.ko" "$EXPORT/raw/wcd934x_dlkm.ko"
cp -f "$ASOC/machine_dlkm.ko" "$EXPORT/raw/machine_dlkm.ko"
cp -f "$ASOC/platform_dlkm.ko" "$EXPORT/raw/platform_dlkm.ko"

cp -f "$WCD934X/wcd934x_dlkm.ko" "$MODROOT/system/vendor/lib/modules/exp3_audio_raw/wcd934x_dlkm.ko"
cp -f "$WCD934X/wcd934x_dlkm.ko" "$MODROOT/system/vendor/lib/modules/audio_wcd934x.ko"
cp -f "$ASOC/machine_dlkm.ko" "$MODROOT/system/vendor/lib/modules/exp3_audio_raw/machine_dlkm.ko"
cp -f "$ASOC/machine_dlkm.ko" "$MODROOT/system/vendor/lib/modules/audio_machine_trinket.ko"
cp -f "$ASOC/platform_dlkm.ko" "$MODROOT/system/vendor/lib/modules/exp3_audio_raw/platform_dlkm.ko"
cp -f "$ASOC/platform_dlkm.ko" "$MODROOT/system/vendor/lib/modules/audio_platform.ko"

# Verify the rebuilt machine carries version records for all Tavil imports when
# the host modprobe implementation can dump them. Missing CRC records here was
# the Run10 false-success condition caused by an empty placeholder symvers.
if command -v modprobe >/dev/null 2>&1; then
  modprobe --dump-modversions "$ASOC/machine_dlkm.ko" > "$GITHUB_WORKSPACE/machine-exp3.modversions.txt" 2>/dev/null || true
  for sym in \
    tavil_cdc_mclk_tx_enable \
    tavil_codec_info_create_codec_entry \
    tavil_cdc_mclk_enable \
    tavil_set_spkr_mode \
    tavil_mbhc_hs_detect \
    tavil_get_afe_config \
    tavil_set_spkr_gain_offset; do
    grep -q "[[:space:]]${sym}$" "$GITHUB_WORKSPACE/machine-exp3.modversions.txt" || {
      echo "[FATAL] rebuilt machine_dlkm lacks modversion record for $sym"
      exit 73
    }
  done
fi

find "$EXPORT/raw" -maxdepth 1 -type f -name '*.ko' -printf '%f\n' | sort > "$EXPORT/audio-modules.txt"
find "$EXPORT/raw" -maxdepth 1 -type f -name '*.ko' -exec sha256sum {} \; | sort > "$EXPORT/audio-modules.sha256"

# Make runtime success/failure unambiguous. Repeated loading remains useful for
# the whole cyclic graph, but WCD934X and machine are now mandatory outcomes.
cat >> "$MODROOT/service.sh" <<'EOF'

echo '===== EXP3 WCD934X / MACHINE CLOSURE CHECK ====='
if ! grep -q '^wcd934x_dlkm ' /proc/modules 2>/dev/null; then
  insmod "$RAW/wcd934x_dlkm.ko" 2>/dev/null || true
fi
if ! grep -q '^machine_dlkm ' /proc/modules 2>/dev/null; then
  insmod "$RAW/machine_dlkm.ko" 2>/dev/null || true
fi
if grep -q '^wcd934x_dlkm ' /proc/modules 2>/dev/null; then
  echo 'PASS wcd934x_dlkm loaded'
else
  echo 'FAIL wcd934x_dlkm missing'
fi
if grep -q '^machine_dlkm ' /proc/modules 2>/dev/null; then
  echo 'PASS machine_dlkm loaded'
else
  echo 'FAIL machine_dlkm missing; speaker path cannot be considered fixed'
  dmesg | grep -E 'machine_dlkm|wcd934x_dlkm|tavil_|Unknown symbol' | tail -n 160 || true
fi
EOF
chmod 0755 "$MODROOT/service.sh"

# Refresh the standalone audio package too; the unified vendor package is made
# in the next workflow step from this same MODROOT.
(cd "$MODROOT" && zip -qr "$GITHUB_WORKSPACE/PCHM30-EXP3-AUDIO-DLKM-KSU.zip" .)
sha256sum "$GITHUB_WORKSPACE/PCHM30-EXP3-AUDIO-DLKM-KSU.zip" > "$EXPORT/audio-ksu.sha256"

sha256sum "$WCD934X/wcd934x_dlkm.ko" "$ASOC/machine_dlkm.ko" "$ASOC/platform_dlkm.ko" \
  | tee "$GITHUB_WORKSPACE/audio-wcd934x-closure.sha256"
echo '[PASS] real WCD934X/Tavil provider built; machine/platform rebuilt against closed Trinket codec graph'
