#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee "$GITHUB_WORKSPACE/audio-dlkm-build.log") 2>&1

KERNEL="$GITHUB_WORKSPACE/$KERNEL_REL"
KOUT="$KERNEL/$OUT_DIR"
AUDIO="$GITHUB_WORKSPACE/source/android/vendor/qcom/opensource/audio-kernel"
AOUT="$GITHUB_WORKSPACE/audio-product"
EXPORT="$GITHUB_WORKSPACE/audio-exp3"
MODROOT="$GITHUB_WORKSPACE/audio-ksu-module"

for f in \
  "$AUDIO/config/trinketauto.conf" \
  "$AUDIO/ipc/Kbuild" \
  "$AUDIO/dsp/Kbuild" \
  "$AUDIO/dsp/codecs/Kbuild" \
  "$AUDIO/soc/Kbuild" \
  "$AUDIO/asoc/Kbuild" \
  "$AUDIO/asoc/codecs/Kbuild" \
  "$AUDIO/asoc/codecs/bolero/Kbuild" \
  "$AUDIO/asoc/codecs/wcd937x/Kbuild"; do
  test -f "$f"
done
test -s "$KOUT/Module.symvers"
grep -q '^CONFIG_MODVERSIONS=y$' "$KOUT/.config"

# Preserve the OPPO semantics while avoiding an external-linkage C-inline
# trap when one header is included by multiple independently linked DLKMs.
SND_EVENT="$AUDIO/include/soc/snd_event.h"
test -f "$SND_EVENT"
if grep -q '^inline bool is_snd_event_fwk_enabled' "$SND_EVENT"; then
  sed -i 's/^inline bool is_snd_event_fwk_enabled/static inline bool is_snd_event_fwk_enabled/' "$SND_EVENT"
fi
grep -q '^static inline bool is_snd_event_fwk_enabled' "$SND_EVENT"

rm -rf "$AOUT" "$EXPORT" "$MODROOT"
mkdir -p "$EXPORT/raw" "$MODROOT/system/vendor/lib/modules/exp3_audio_raw"

# Android's DLKM build wires Module.symvers between these directories.  The
# graph contains cycles (ASoC <-> codecs/Bolero/WCD937X), so a one-pass hand
# ordering is not reliable.  Seed every node with WARN mode first, then rebuild
# the whole graph strictly once all exported symbol tables exist.
CORE_DIRS=(
  ipc
  dsp
  dsp/codecs
  soc
  asoc/codecs
  asoc/codecs/bolero
  asoc/codecs/wcd937x
  asoc
)
OPTIONAL_DIRS=(
  asoc/codecs/tfa98xx-v6
  asoc/codecs/sia81xx
)
ALL_DIRS=("${CORE_DIRS[@]}" "${OPTIONAL_DIRS[@]}")

for rel in "${ALL_DIRS[@]}"; do
  mkdir -p "$AOUT/obj/vendor/qcom/opensource/audio-kernel/$rel"
  : > "$AOUT/obj/vendor/qcom/opensource/audio-kernel/$rel/Module.symvers"
done
# Some Kbuilds list legacy sibling symbol tables even when the target doesn't
# produce those drivers.  Supply empty placeholders for the same reason the
# Android build creates their output directories.
for rel in \
  asoc/codecs/wcd934x asoc/codecs/sdm660_cdc asoc/codecs/msm_sdw \
  asoc/codecs/wcd9360; do
  mkdir -p "$AOUT/obj/vendor/qcom/opensource/audio-kernel/$rel"
  : > "$AOUT/obj/vendor/qcom/opensource/audio-kernel/$rel/Module.symvers"
done

modname_for() {
  case "$1" in
    ipc) echo apr_dlkm ;;
    dsp) echo q6_dlkm ;;
    dsp/codecs) echo native_dlkm ;;
    soc) echo soc_dlkm ;;
    asoc) echo platform_dlkm ;;
    asoc/codecs) echo wcd_core_dlkm ;;
    asoc/codecs/bolero) echo bolero_cdc_dlkm ;;
    asoc/codecs/wcd937x) echo wcd937x_dlkm ;;
    asoc/codecs/tfa98xx-v6) echo tfa98xx-v6_dlkm ;;
    asoc/codecs/sia81xx) echo sia81xx_dlkm ;;
    *) return 1 ;;
  esac
}

build_one() {
  local rel="$1" warn="$2" required="$3"
  local dir="$AUDIO/$rel" modname
  modname="$(modname_for "$rel")"
  if [ ! -f "$dir/Kbuild" ]; then
    [ "$required" = 0 ] && { echo "[SKIP] optional audio dir absent: $rel"; return 0; }
    echo "[FATAL] required audio dir absent: $rel"
    return 61
  fi

  echo "===== AUDIO ${warn:+SEED }BUILD rel=$rel MODNAME=$modname KBUILD_MODPOST_WARN=$warn ====="
  rm -f "$dir/Module.symvers" "$dir/modules.order"
  rm -rf "$dir/.tmp_versions"

  set +e
  make -C "$KERNEL" O="$KOUT" M="$dir" \
    ARCH=arm64 LOCALVERSION=+ \
    CC="$CC" REAL_CC="$REAL_CC" LD="$LD" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    CLANG_TRIPLE="$CLANG_TRIPLE" \
    OUT="$AOUT" AUDIO_ROOT="$AUDIO" MODNAME="$modname" \
    BOARD_PLATFORM=trinket CONFIG_ARCH_TRINKET=y CONFIG_SND_SOC_SM6150=m \
    KBUILD_MODPOST_WARN="$warn" modules -j"$(nproc)"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    if [ "$required" = 0 ]; then
      echo "[WARN] optional audio module group failed: $rel rc=$rc"
      return 0
    fi
    echo "[FATAL] required audio module group failed: $rel rc=$rc"
    return "$rc"
  fi

  mkdir -p "$AOUT/obj/vendor/qcom/opensource/audio-kernel/$rel"
  if [ -s "$dir/Module.symvers" ]; then
    cp -f "$dir/Module.symvers" "$AOUT/obj/vendor/qcom/opensource/audio-kernel/$rel/Module.symvers"
  elif [ "$required" = 1 ]; then
    echo "[FATAL] no Module.symvers produced for required group: $rel"
    return 62
  fi
}

# Phase 1: seed exported symbols.  Undefined imports are expected here.
for rel in "${CORE_DIRS[@]}"; do build_one "$rel" 1 1; done
for rel in "${OPTIONAL_DIRS[@]}"; do build_one "$rel" 1 0; done

# Phase 2: all core imports must now resolve against the complete symbol graph.
for rel in "${CORE_DIRS[@]}"; do build_one "$rel" 0 1; done
# OPLUS amplifier variants are built when their source/config is usable.  Both
# are retained because different PCHM30 production lots/vendor trees can select
# a different external amplifier; the machine driver has OPLUS hooks for them.
for rel in "${OPTIONAL_DIRS[@]}"; do build_one "$rel" 0 0; done

# A strict second pass must not leave unresolved-symbol warnings in required
# modules.  Kbuild's successful modpost is the primary gate; additionally keep
# all produced .ko files for offline ABI inspection.
find "$AUDIO" -type f -name '*.ko' -path "$AUDIO/*" -print0 | while IFS= read -r -d '' ko; do
  case "$ko" in
    "$AUDIO"/ipc/*|"$AUDIO"/dsp/*|"$AUDIO"/soc/*|"$AUDIO"/asoc/*)
      cp -f "$ko" "$EXPORT/raw/$(basename "$ko")" ;;
  esac
done

test -n "$(find "$EXPORT/raw" -maxdepth 1 -type f -name '*.ko' -print -quit)"

# These are the modules already proven by the real-device log to be rejected
# by module_layout and therefore are non-negotiable for the speaker fix.
REQUIRED_KO=(
  wglink_dlkm.ko q6_pdr_dlkm.ko pinctrl_wcd_dlkm.ko swr_dlkm.ko
  snd_event_dlkm.ko wcd_core_dlkm.ko wcd_spi_dlkm.ko stub_dlkm.ko
  hdmi_dlkm.ko
)
# These complete the TRINKET playback/control chain described by the stock
# trinketauto.conf/Android.mk and are required for a genuinely useful audio set.
PLAYBACK_KO=(
  apr_dlkm.ko q6_dlkm.ko q6_notifier_dlkm.ko platform_dlkm.ko machine_dlkm.ko
  bolero_cdc_dlkm.ko wsa_macro_dlkm.ko rx_macro_dlkm.ko
)
for ko in "${REQUIRED_KO[@]}" "${PLAYBACK_KO[@]}"; do
  test -s "$EXPORT/raw/$ko" || { echo "[FATAL] required TRINKET audio module missing: $ko"; exit 63; }
done

android_name() {
  case "$1" in
    apr_dlkm.ko) echo audio_apr.ko ;;
    wglink_dlkm.ko) echo audio_wglink.ko ;;
    q6_dlkm.ko) echo audio_q6.ko ;;
    native_dlkm.ko) echo audio_native.ko ;;
    usf_dlkm.ko) echo audio_usf.ko ;;
    adsp_loader_dlkm.ko) echo audio_adsp_loader.ko ;;
    q6_notifier_dlkm.ko) echo audio_q6_notifier.ko ;;
    q6_pdr_dlkm.ko) echo audio_q6_pdr.ko ;;
    pinctrl_wcd_dlkm.ko) echo audio_pinctrl_wcd.ko ;;
    pinctrl_lpi_dlkm.ko) echo audio_pinctrl_lpi.ko ;;
    swr_dlkm.ko) echo audio_swr.ko ;;
    swr_ctrl_dlkm.ko) echo audio_swr_ctrl.ko ;;
    snd_event_dlkm.ko) echo audio_snd_event.ko ;;
    platform_dlkm.ko) echo audio_platform.ko ;;
    cpe_lsm_dlkm.ko) echo audio_cpe_lsm.ko ;;
    machine_dlkm.ko) echo audio_machine_trinket.ko ;;
    wcd_core_dlkm.ko) echo audio_wcd_core.ko ;;
    wcd9xxx_dlkm.ko) echo audio_wcd9xxx.ko ;;
    wcd_cpe_dlkm.ko) echo audio_wcd_cpe.ko ;;
    wcd_spi_dlkm.ko) echo audio_wcd_spi.ko ;;
    wcd9335_dlkm.ko) echo audio_wcd9335.ko ;;
    wsa881x_dlkm.ko) echo audio_wsa881x.ko ;;
    stub_dlkm.ko) echo audio_stub.ko ;;
    mbhc_dlkm.ko) echo audio_mbhc.ko ;;
    hdmi_dlkm.ko) echo audio_hdmi.ko ;;
    bolero_cdc_dlkm.ko) echo audio_bolero_cdc.ko ;;
    wsa_macro_dlkm.ko) echo audio_wsa_macro.ko ;;
    va_macro_dlkm.ko) echo audio_va_macro.ko ;;
    tx_macro_dlkm.ko) echo audio_tx_macro.ko ;;
    rx_macro_dlkm.ko) echo audio_rx_macro.ko ;;
    wcd937x_dlkm.ko) echo audio_wcd937x.ko ;;
    wcd937x_slave_dlkm.ko) echo audio_wcd937x_slave.ko ;;
    tfa98xx-v6_dlkm.ko) echo audio_tfa98xx-v6.ko ;;
    sia81xx_dlkm.ko) echo audio_sia81xx.ko ;;
    *) echo "$1" ;;
  esac
}

# Keep a raw private copy for late_start manual loading and also place Android
# product names in the vendor overlay.  If KernelSU's magic mount is early
# enough, vendor init sees the matching files directly.  If it isn't, service.sh
# below loads the same modules after /data is available and restarts audio.
for ko in "$EXPORT"/raw/*.ko; do
  base="$(basename "$ko")"
  cp -f "$ko" "$MODROOT/system/vendor/lib/modules/exp3_audio_raw/$base"
  cp -f "$ko" "$MODROOT/system/vendor/lib/modules/$(android_name "$base")"
done

KCRC="$(awk '$2 == "module_layout" {print $1; exit}' "$KOUT/Module.symvers")"
: > "$EXPORT/module-layout.txt"
echo "kernel module_layout CRC=$KCRC" | tee -a "$EXPORT/module-layout.txt"
for ko in "$EXPORT"/raw/*.ko; do
  echo "===== $(basename "$ko") =====" | tee -a "$EXPORT/module-layout.txt"
  readelf -p .modinfo "$ko" | grep -E 'vermagic|name=' | tee -a "$EXPORT/module-layout.txt" || true
  if command -v modprobe >/dev/null 2>&1; then
    modprobe --dump-modversions "$ko" 2>/dev/null | grep module_layout | tee -a "$EXPORT/module-layout.txt" || true
  fi
done

cat > "$MODROOT/module.prop" <<'EOF'
id=pchm30_exp3_audio_dlkm
name=PCHM30 EXP3 Matching Audio DLKM
version=Run8
versionCode=8
author=hhsbjbsj
description=Full TRINKET audio DLKM graph rebuilt against the EXP3 Android 16 kernel ABI; includes late-start recovery loader for early vendor module-load failures.
EOF

cat > "$MODROOT/service.sh" <<'EOF'
#!/system/bin/sh
MODDIR=${0%/*}
RAW="$MODDIR/system/vendor/lib/modules/exp3_audio_raw"
LOG=/data/local/tmp/pchm30-exp3-audio-loader.log
exec >>"$LOG" 2>&1

echo "===== $(date) EXP3 audio late-start loader ====="
# Let vendor services settle; stock early DLKM attempts have already failed on
# the old module_layout CRC, so load the matching graph and then restart audio.
sleep 3

# Repeated passes avoid hard-coding every symbol dependency edge. insmod of a
# module whose dependency is not ready fails harmlessly in an early pass and is
# retried after providers are loaded.
for pass in 1 2 3 4 5 6 7 8; do
  progress=0
  for ko in "$RAW"/*.ko; do
    [ -f "$ko" ] || continue
    name=$(basename "$ko" .ko | tr '-' '_')
    grep -q "^${name} " /proc/modules 2>/dev/null && continue
    if insmod "$ko" 2>/dev/null; then
      echo "PASS[$pass] $(basename "$ko")"
      progress=1
    fi
  done
  [ "$progress" = 0 ] && break
  sleep 1
done

echo "===== loaded audio modules ====="
cat /proc/modules | grep -E '(^| )(apr|wglink|q6_|snd_event|swr|wcd|wsa|bolero|macro|machine|platform|sia|tfa)' || true

# Restart whichever stock/GSI audio services actually exist on this build.
for svc in vendor.audio-hal-2-0 vendor.audio-hal-4-0 vendor.audio-hal audioserver; do
  state=$(getprop "init.svc.$svc")
  [ -n "$state" ] || continue
  echo "restart $svc (was $state)"
  setprop ctl.restart "$svc"
done
EOF
chmod 0755 "$MODROOT/service.sh"

cat > "$MODROOT/post-fs-data.sh" <<'EOF'
#!/system/bin/sh
# Magic-mount provides the preferred early replacement.  This script only
# records whether vendor module paths are visible; actual fallback loading is
# deliberately deferred to service.sh after dependencies/services settle.
MODDIR=${0%/*}
LOG=/data/local/tmp/pchm30-exp3-audio-loader.log
echo "===== $(date) EXP3 audio post-fs-data =====" >"$LOG"
ls -l /vendor/lib/modules 2>/dev/null | head -n 20 >>"$LOG" || true
EOF
chmod 0755 "$MODROOT/post-fs-data.sh"

(cd "$MODROOT" && zip -qr "$GITHUB_WORKSPACE/PCHM30-EXP3-AUDIO-DLKM-KSU.zip" .)
sha256sum "$GITHUB_WORKSPACE/PCHM30-EXP3-AUDIO-DLKM-KSU.zip" | tee "$EXPORT/audio-ksu.sha256"
find "$EXPORT/raw" -maxdepth 1 -type f -name '*.ko' -exec sha256sum {} \; | sort > "$EXPORT/audio-modules.sha256"
find "$EXPORT/raw" -maxdepth 1 -type f -name '*.ko' -printf '%f\n' | sort | tee "$EXPORT/audio-modules.txt"

echo '[PASS] full matching TRINKET audio DLKM graph rebuilt and packaged'
