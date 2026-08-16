#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee "$GITHUB_WORKSPACE/vendor-dlkm-package.log") 2>&1

MODROOT="$GITHUB_WORKSPACE/audio-ksu-module"
EXPORT="$GITHUB_WORKSPACE/vendor-dlkm-exp3"
WLAN_RAW="$GITHUB_WORKSPACE/wlan-a16-exp1.ko"
WLAN_RUNTIME="$GITHUB_WORKSPACE/wlan-a16-exp1-runtime.ko"
MSM11AD="$GITHUB_WORKSPACE/msm_11ad_proxy-exp3.ko"

test -d "$MODROOT/system/vendor/lib/modules"
test -s "$WLAN_RAW"
test -s "$MSM11AD"
rm -rf "$EXPORT"
mkdir -p "$EXPORT"

# Run10 accidentally put the 318 MB unstripped qcacld build artifact directly
# at /vendor/lib/modules/wlan.ko.  The previously proven real-device WLAN KSU
# module is the same matching driver after debug sections are removed (~15 MB).
# Strip debug only: keep ELF symbols/modversions/module metadata intact.
cp -f "$WLAN_RAW" "$WLAN_RUNTIME"
STRIP_BIN="$(command -v llvm-strip || true)"
if [ -z "$STRIP_BIN" ] && [ -n "${TOOLCHAIN_ROOT:-}" ]; then
  STRIP_BIN="$(find "$TOOLCHAIN_ROOT" -type f -name llvm-strip -perm -u+x -print -quit 2>/dev/null || true)"
fi
if [ -z "$STRIP_BIN" ]; then
  echo '[FATAL] llvm-strip not found; refusing to package the 318 MB debug WLAN module'
  exit 81
fi
"$STRIP_BIN" --strip-debug "$WLAN_RUNTIME"
test -s "$WLAN_RUNTIME"
raw_size="$(stat -c %s "$WLAN_RAW")"
runtime_size="$(stat -c %s "$WLAN_RUNTIME")"
echo "WLAN raw bytes=$raw_size runtime bytes=$runtime_size"
[ "$runtime_size" -lt "$raw_size" ] || { echo '[FATAL] WLAN debug stripping did not reduce artifact'; exit 82; }
# Guard against ever reintroducing the Run10 318 MB runtime packaging bug.
[ "$runtime_size" -lt 50000000 ] || { echo "[FATAL] runtime WLAN still unexpectedly huge: $runtime_size"; exit 83; }
sha256sum "$WLAN_RAW" "$WLAN_RUNTIME" | tee "$EXPORT/wlan-runtime.sha256"

# Replace the two additional stock modules proven by the real-device report to
# have a stale module_layout CRC. Audio files are already populated by the
# full TRINKET audio builder + WCD934X closure in this same MODROOT.
cp -f "$WLAN_RUNTIME" "$MODROOT/system/vendor/lib/modules/wlan.ko"
cp -f "$MSM11AD" "$MODROOT/system/vendor/lib/modules/msm_11ad_proxy.ko"

cat > "$MODROOT/module.prop" <<'EOF'
id=pchm30_exp3_matching_vendor_dlkm
name=PCHM30 EXP3 Matching Vendor DLKM
version=EXP3-WCD934X-WLAN-RUNTIME
versionCode=11
author=hhsbjbsj
description=Matching runtime-stripped WLAN, msm_11ad_proxy and WCD934X-closed TRINKET audio DLKMs rebuilt against the exact EXP3 Android 16 kernel ABI. Keeps CONFIG_MODVERSIONS enabled; no force-load bypass.
EOF

# Append conservative fallback loading. Magic-mount is preferred because it
# lets vendor init consume the matching files directly. If an old stock module
# was attempted before the overlay became visible, load the matching module only
# when that module is still absent from /proc/modules.
cat >> "$MODROOT/service.sh" <<'EOF'

echo "===== EXP3 non-audio vendor fallback ====="
if ! grep -q '^msm_11ad_proxy ' /proc/modules 2>/dev/null; then
  if insmod /vendor/lib/modules/msm_11ad_proxy.ko 2>/dev/null; then
    echo 'PASS msm_11ad_proxy fallback load'
  else
    echo 'INFO msm_11ad_proxy fallback not loaded (may be unused on this hardware)'
  fi
fi

if ! grep -q '^wlan ' /proc/modules 2>/dev/null; then
  if insmod /vendor/lib/modules/wlan.ko 2>/dev/null; then
    echo 'PASS wlan fallback load'
  else
    echo 'WARN wlan fallback load failed; inspect dmesg/CNSS state'
  fi
fi
EOF
chmod 0755 "$MODROOT/service.sh"

cat > "$EXPORT/real-device-bugs.txt" <<'EOF'
[FIXED/REBUILT]
- wlan: stock module_layout mismatch -> matching qcacld wlan.ko; runtime package strips debug-only sections (Run10 mistakenly packaged the 318 MB debug ELF)
- msm_11ad_proxy: stock module_layout mismatch -> in-tree rebuild against EXP3 Module.symvers
- snd_event_dlkm / wglink_dlkm / q6_pdr_dlkm / pinctrl_wcd_dlkm / swr_dlkm
- hdmi_dlkm / wcd_spi_dlkm / stub_dlkm / wcd_core_dlkm
- WCD934X/Tavil provider is built explicitly and machine/platform are rebuilt against its real Module.symvers

[KERNEL COMPAT]
- Android 16 unprivileged_bpf_disabled=0 write: Run10 real-device PASS.
- BTF VAR/DATASEC + precise verifier diagnostics retained; modern FUNC/kind 17+ work remains.

[DEPENDENT / VERIFY ON DEVICE]
- Speaker: require both wcd934x_dlkm and machine_dlkm loaded, registered ALSA card, and audible phone speaker output.
- NetworkStats Null bpf map / Failed to parse bpf iface stats: expected to clear only after remaining BTF verifier rejection is fixed; do not patch userspace around it.
- Stability collector must only flag literal kernel Call trace/panic/Oops/lockup/RCU-stall signatures.
EOF

find "$MODROOT/system/vendor/lib/modules" -type f -name '*.ko' -print | sort > "$EXPORT/vendor-overlay-files.txt"
find "$MODROOT/system/vendor/lib/modules" -type f -name '*.ko' -exec sha256sum {} \; | sort > "$EXPORT/vendor-overlay.sha256"
stat -c '%n %s bytes' "$MODROOT/system/vendor/lib/modules/wlan.ko" > "$EXPORT/wlan-runtime-size.txt"

cat > "$MODROOT/collect-exp3.sh" <<'EOF'
#!/system/bin/sh
OUT=/data/local/tmp/exp3-diagnose
mkdir -p "$OUT"
dmesg > "$OUT/dmesg-full.txt"
logcat -b all -d > "$OUT/logcat-all.txt" 2>&1
cat /proc/modules > "$OUT/proc-modules.txt"
cat /proc/sys/kernel/unprivileged_bpf_disabled > "$OUT/unprivileged_bpf_disabled.txt" 2>&1
find /vendor/lib/modules -maxdepth 1 -type f -name '*.ko' -print > "$OUT/vendor-modules.txt" 2>&1
find /sys/fs/bpf -maxdepth 4 \( -type f -o -type d \) -print > "$OUT/bpf-fs.txt" 2>&1
uname -a > "$OUT/uname.txt"
getprop > "$OUT/getprop.txt"
cat /proc/asound/cards > "$OUT/asound-cards.txt" 2>&1 || true
cat /proc/asound/pcm > "$OUT/asound-pcm.txt" 2>&1 || true
dumpsys media.audio_flinger > "$OUT/audio-flinger.txt" 2>&1 || true
dumpsys audio > "$OUT/audio-service.txt" 2>&1 || true
{
  echo '===== ABI/BTF FILTER ====='
  grep -Ei 'module_layout|Unknown symbol|invalid module format|A16-BTF|BTF loading error|Null bpf map|Failed to parse bpf' "$OUT/dmesg-full.txt" || true
  echo '===== REAL KERNEL CRASH FILTER ====='
  grep -Ei 'Call trace:|Kernel panic|Oops:|BUG:|soft lockup|hard LOCKUP|RCU stall' "$OUT/dmesg-full.txt" || true
  echo '===== AUDIO CLOSURE ====='
  grep -E '^(wcd934x_dlkm|machine_dlkm|platform_dlkm|wcd937x_dlkm|wcd9335_dlkm|q6_dlkm|apr_dlkm) ' "$OUT/proc-modules.txt" || true
} > "$OUT/summary.txt"
echo "$OUT"
EOF
chmod 0755 "$MODROOT/collect-exp3.sh"

(cd "$MODROOT" && zip -qr "$GITHUB_WORKSPACE/PCHM30-EXP3-MATCHING-VENDOR-DLKM-KSU.zip" .)
sha256sum "$GITHUB_WORKSPACE/PCHM30-EXP3-MATCHING-VENDOR-DLKM-KSU.zip" | tee "$EXPORT/vendor-ksu.sha256"

echo '[PASS] unified EXP3 vendor DLKM package uses proven-size runtime WLAN and WCD934X-closed audio graph'
