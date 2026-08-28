#!/usr/bin/env bash
# Run25: SM6125 mainline probe based on proven PCHM30 / run24 identity.
# Audit + compile experiment. Does NOT produce a safe Android flash.
set -u
set -o pipefail

ROOT="$(cd "${GITHUB_WORKSPACE:-.}" && pwd)"
OUT="$ROOT/out-run25"
VENDOR_DTS="$ROOT/arch/arm64/boot/dts/qcom/trinket.dtsi"
LINUX="$ROOT/linux-mainline"
CROSS=aarch64-linux-gnu-
JOBS="$(nproc)"
mkdir -p "$OUT/dtbs" "$OUT/pchm30-skeleton" "$OUT/mainline-boards"
REPORT="$OUT/PCHM30-SM6125-MAINLINE-REPORT.txt"
VERDICT="$OUT/FLASH-VERDICT.txt"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log; log "===== $* ====="; }

: > "$REPORT"
log "PCHM30 / OPPO A11x / SM6125 mainline experiment"
log "run24_base=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
log "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "jobs=$JOBS"
log "host=$(uname -a)"
log "cross=$(${CROSS}gcc -dumpversion 2>/dev/null || echo missing)"

MAIN_SOC=no
PCHM30_BOARD=no
DTB_OK=0
DTB_FAIL=0
SKEL_OK=no
IMAGE_OK=no
LINUX_SHA=unknown
MAIN_SOC_PATH=""

section "1. Proven vendor TRINKET identity (run24)"
if [[ ! -f "$VENDOR_DTS" ]]; then
  log "[FATAL] missing vendor DTS: $VENDOR_DTS"
  exit 2
fi
{
  grep -E 'model =|compatible =|qcom,msm-id|qcom,msm-name|qcom,pmic-name' "$VENDOR_DTS" | head -n 40
  echo
  echo '--- reserved-memory / storage hints ---'
  grep -nE 'reserved-memory|hyp_region|smem_region|cont_splash|ufshc|sdhc' "$VENDOR_DTS" | head -n 40
} | tee -a "$REPORT"

if grep -q 'compatible = "qcom,trinket"' "$VENDOR_DTS" \
  && grep -q 'qcom,msm-id = <394 0x10000>' "$VENDOR_DTS" \
  && grep -q 'qcom,pmic-name = "pm6125 + pmi632"' "$VENDOR_DTS"; then
  log "[PASS] vendor identity: trinket / msm-id 394 / pm6125+pmi632"
else
  log "[FATAL] vendor DTS does not match proven PCHM30 TRINKET identity"
  exit 3
fi

section "2. Clone Linux mainline (torvalds/linux, depth=1)"
rm -rf "$LINUX"
if ! git clone --depth=1 https://github.com/torvalds/linux.git "$LINUX"; then
  log "[FATAL] git clone torvalds/linux failed"
  exit 4
fi
LINUX_SHA="$(git -C "$LINUX" rev-parse HEAD)"
printf '%s\n' "$LINUX_SHA" > "$OUT/linux-mainline.sha"
log "linux_commit=$LINUX_SHA"
log "linux_describe=$(git -C "$LINUX" describe --always --tags)"
log "linux_head=$(git -C "$LINUX" log -1 --oneline)"

section "3. Mainline SM6125 / TRINKET DTS inventory"
DTS_DIR="$LINUX/arch/arm64/boot/dts/qcom"
{
  echo "dts_dir=$DTS_DIR"
  echo '--- sm6125* ---'
  find "$LINUX/arch/arm64/boot/dts" -iname '*sm6125*' | sort || echo '(none)'
  echo
  echo '--- trinket* ---'
  find "$LINUX/arch/arm64/boot/dts" -iname '*trinket*' | sort || echo '(none)'
  echo
  echo '--- pchm30 / oppo / a11 ---'
  find "$LINUX/arch/arm64/boot/dts" -iname '*pchm30*' -o -iname '*oppo*' -o -iname '*a11x*' | sort || echo '(none)'
  echo
  echo '--- pm6125 / pmi632 ---'
  find "$LINUX/arch/arm64/boot/dts" \( -iname '*pm6125*' -o -iname '*pmi632*' \) | sort || echo '(none)'
  echo
  echo '--- Makefile sm6125 lines ---'
  grep -n sm6125 "$DTS_DIR/Makefile" 2>/dev/null || echo '(no Makefile hits)'
} | tee -a "$REPORT"

mapfile -t SM6125_DTS < <(find "$LINUX/arch/arm64/boot/dts" -name 'sm6125*.dts' | sort)
mapfile -t SM6125_DTSI < <(find "$LINUX/arch/arm64/boot/dts" -name 'sm6125*.dtsi' | sort)
log "sm6125_dts_count=${#SM6125_DTS[@]}"
log "sm6125_dtsi_count=${#SM6125_DTSI[@]}"

if [[ -f "$DTS_DIR/sm6125.dtsi" ]]; then
  MAIN_SOC=yes
  MAIN_SOC_PATH="$DTS_DIR/sm6125.dtsi"
  log "[PASS] mainline has sm6125.dtsi"
elif ((${#SM6125_DTSI[@]} > 0)); then
  MAIN_SOC=yes
  MAIN_SOC_PATH="${SM6125_DTSI[0]}"
  log "[PASS] mainline SM6125 dtsi at $MAIN_SOC_PATH"
else
  log "[FAIL] mainline has no sm6125*.dtsi"
fi

if [[ -n "$MAIN_SOC_PATH" && -f "$MAIN_SOC_PATH" ]]; then
  {
    echo "--- $(basename "$MAIN_SOC_PATH") identity ---"
    grep -nE 'model =|compatible =|qcom,msm-id|memory@|reserved-memory' "$MAIN_SOC_PATH" | head -n 80
  } | tee -a "$REPORT"
  cp -f "$MAIN_SOC_PATH" "$OUT/mainline-boards/"
fi

if ((${#SM6125_DTS[@]} > 0)); then
  for f in "${SM6125_DTS[@]}"; do
    base="$(basename "$f")"
    log "board_dts=$base"
    cp -f "$f" "$OUT/mainline-boards/"
    {
      echo "--- $base head ---"
      grep -nE 'model =|compatible =|#include' "$f" | head -n 40
    } | tee -a "$REPORT"
    if grep -qiE 'pchm30|oppo|a11x|OP4A54' "$f"; then
      PCHM30_BOARD=yes
      log "[HIT] $base mentions PCHM30/OPPO"
    fi
  done
else
  log "[INFO] no sm6125*.dts board files found"
fi
log "pchm30_board_dts=$PCHM30_BOARD"

section "4. Compile existing mainline SM6125 DTBs"
cd "$LINUX"
if ! make ARCH=arm64 CROSS_COMPILE="$CROSS" defconfig; then
  log "[FATAL] mainline defconfig failed"
  exit 5
fi
if ((${#SM6125_DTS[@]} > 0)); then
  for dts in "${SM6125_DTS[@]}"; do
    stem="$(basename "${dts%.dts}")"
    rel="qcom/${stem}.dtb"
    log "compile $rel"
    if make ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" "$rel"; then
      src="$LINUX/arch/arm64/boot/dts/$rel"
      alt="$(find "$LINUX/arch/arm64/boot/dts" -name "${stem}.dtb" | head -n 1)"
      if [[ -s "$src" ]]; then
        cp -f "$src" "$OUT/dtbs/"
        DTB_OK=$((DTB_OK + 1))
        log "[PASS] $rel $(stat -c%s "$src") bytes"
      elif [[ -n "$alt" && -s "$alt" ]]; then
        cp -f "$alt" "$OUT/dtbs/"
        DTB_OK=$((DTB_OK + 1))
        log "[PASS] $alt $(stat -c%s "$alt") bytes"
      else
        DTB_FAIL=$((DTB_FAIL + 1))
        log "[FAIL] $rel missing after make"
      fi
    else
      DTB_FAIL=$((DTB_FAIL + 1))
      log "[FAIL] make $rel"
    fi
  done
else
  log "[SKIP] no SM6125 board dts to compile"
fi
log "dtb_ok=$DTB_OK dtb_fail=$DTB_FAIL"

section "5. PCHM30 skeleton DTS on mainline SM6125"
SKEL="$DTS_DIR/sm6125-oppo-pchm30.dts"
INCLUDES=()
if [[ -f "$DTS_DIR/sm6125.dtsi" ]]; then
  INCLUDES+=('#include "sm6125.dtsi"')
elif [[ -n "$MAIN_SOC_PATH" ]]; then
  rel_inc="$(realpath --relative-to="$DTS_DIR" "$MAIN_SOC_PATH")"
  INCLUDES+=("#include \"${rel_inc}\"")
fi
for inc in pm6125.dtsi pmi632.dtsi; do
  if [[ -f "$DTS_DIR/$inc" ]]; then
    INCLUDES+=("#include \"$inc\"")
  else
    log "[INFO] missing $DTS_DIR/$inc (skeleton will omit it)"
  fi
done

{
  echo '// SPDX-License-Identifier: GPL-2.0-only'
  echo '/*'
  echo ' * EXPERIMENTAL skeleton only. Not a complete PCHM30 board port.'
  echo ' * OPPO A11x / PCHM30 / SM6125 (trinket), msm-id 394, pm6125 + pmi632.'
  echo ' */'
  echo '/dts-v1/;'
  echo
  for line in "${INCLUDES[@]+"${INCLUDES[@]}"}"; do
    echo "$line"
  done
  cat <<'EOF'

/ {
	model = "OPPO A11x PCHM30 (experimental mainline skeleton)";
	compatible = "oppo,pchm30", "qcom,sm6125";
	qcom,msm-id = <394 0x10000>;
	chassis-type = "handset";
};
EOF
} > "$SKEL"
cp -f "$SKEL" "$OUT/pchm30-skeleton/"
log "skeleton dts written with includes: ${INCLUDES[*]:-none}"

if [[ ! -f "$DTS_DIR/sm6125.dtsi" && -z "$MAIN_SOC_PATH" ]]; then
  log "[SKIP] no SM6125 SoC dtsi; cannot compile PCHM30 skeleton"
else
  if ! grep -q 'sm6125-oppo-pchm30.dtb' "$DTS_DIR/Makefile"; then
    printf '\ndtb-$(CONFIG_ARCH_QCOM) += sm6125-oppo-pchm30.dtb\n' >> "$DTS_DIR/Makefile"
  fi
  if make ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" qcom/sm6125-oppo-pchm30.dtb; then
    if [[ -s "$DTS_DIR/sm6125-oppo-pchm30.dtb" ]]; then
      cp -f "$DTS_DIR/sm6125-oppo-pchm30.dtb" "$OUT/pchm30-skeleton/"
      SKEL_OK=yes
      log "[PASS] skeleton DTB compiled (SoC-only, missing display/UFS/USB/panel)"
    else
      found="$(find "$LINUX/arch/arm64/boot/dts" -name 'sm6125-oppo-pchm30.dtb' | head -n 1)"
      if [[ -n "$found" && -s "$found" ]]; then
        cp -f "$found" "$OUT/pchm30-skeleton/"
        SKEL_OK=yes
        log "[PASS] skeleton DTB compiled at $found"
      else
        log "[FAIL] skeleton dtb missing after make"
      fi
    fi
  else
    log "[FAIL] skeleton DTB did not compile; capture make error above"
  fi
fi
log "pchm30_skeleton_dtb=$SKEL_OK"

# Intermediate verdict so a later Image.gz failure still leaves a report.
cat > "$VERDICT" <<EOF
PCHM30 / OPPO A11x / SM6125  —  FLASH VERDICT (partial, before Image.gz)
=======================================================================
linux_commit=$LINUX_SHA
run24_base=$(git -C "$ROOT" rev-parse HEAD)
mainline_sm6125_soc=$MAIN_SOC
pchm30_board_dts=$PCHM30_BOARD
dtb_ok=$DTB_OK
dtb_fail=$DTB_FAIL
pchm30_skeleton_dtb=$SKEL_OK
image_ok=$IMAGE_OK
EOF

section "6. Best-effort mainline Image.gz (defconfig, NOT Android 4.14)"
set +e
make ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" Image.gz
MAKE_RC=$?
set -e
if [[ $MAKE_RC -eq 0 && -s "$LINUX/arch/arm64/boot/Image.gz" ]]; then
  cp -f "$LINUX/arch/arm64/boot/Image.gz" "$OUT/"
  IMAGE_OK=yes
  log "[PASS] Image.gz $(stat -c%s "$LINUX/arch/arm64/boot/Image.gz") bytes"
elif [[ -s "$LINUX/arch/arm64/boot/Image" ]]; then
  gzip -c "$LINUX/arch/arm64/boot/Image" > "$OUT/Image.gz"
  IMAGE_OK=yes
  log "[PASS] gzipped Image -> Image.gz $(stat -c%s "$OUT/Image.gz") bytes"
else
  log "[FAIL] Image.gz build failed rc=$MAKE_RC"
fi
log "image_ok=$IMAGE_OK"
log "skip_bootimg=yes (will not pack a flashable boot.img)"

section "7. Flash verdict"
cat > "$VERDICT" <<EOF
PCHM30 / OPPO A11x / SM6125  —  FLASH VERDICT
==============================================
linux_commit=$LINUX_SHA
run24_base=$(git -C "$ROOT" rev-parse HEAD)
mainline_sm6125_soc=$MAIN_SOC
mainline_soc_path=$MAIN_SOC_PATH
pchm30_board_dts=$PCHM30_BOARD
dtb_ok=$DTB_OK
dtb_fail=$DTB_FAIL
pchm30_skeleton_dtb=$SKEL_OK
image_ok=$IMAGE_OK

A) Current 4.14 custom kernel (run24 hide / AnyKernel3)
   YES — only boot is enough.
   PCHM30 is non-A/B. AK3 dump_boot/write_boot replaces Image and
   keeps the installed ramdisk + DTB. That is how the bootable
   baseline was proven: Magisk ramdisk kept, kernel replaced.
   Do not flash dtbo / vendor / super for a kernel-only swap.

B) Linux mainline on this phone
   NO — you cannot just flash boot and keep Android.
   Reasons:
   1. Mainline has SM6125 SoC support and boards for Sony PDX201,
      Xiaomi ginkgo / willow / laurel_sprout. There is NO
      oppo,pchm30 / A11x board DTS.
   2. Stock Android ramdisk, vendor modules, dtbo overlays and
      4.14 ABI will not run on a 6.x/7.x mainline kernel.
   3. Run22 already showed lk2nd has no native SM6125 target.
      Mainline phones in this class normally need lk2nd or a
      working aboot path plus a Linux initramfs, not Magisk.
   4. The skeleton DTB is SoC-only. Missing panel, UFS/eMMC
      regulator, USB, touch, Wi-Fi, audio. Even if aboot accepts
      a packed boot.img, the kernel will not bring up Android.
   5. This job does not upload any flashable boot.img.

What to flash today if you want a working phone:
   Flash the run24 AnyKernel3 ZIP (kernel-only, boot partition).
   That is the hide + KPM + BTF line that already built green.

What a real mainline port still needs (after this CI):
   - PCHM30 board DTS (panel, UFS, USB, PMICs, reserved-memory)
   - lk2nd SM6125 target OR confirmed aboot boot.img path
   - Linux initramfs / postmarketOS, not ColorOS ramdisk
EOF
cat "$VERDICT" | tee -a "$REPORT"
log "finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
test -s "$VERDICT"
echo "[PASS] Run25 report written"
