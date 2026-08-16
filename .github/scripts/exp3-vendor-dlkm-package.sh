#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee "$GITHUB_WORKSPACE/vendor-dlkm-package.log") 2>&1

MODROOT="$GITHUB_WORKSPACE/audio-ksu-module"
EXPORT="$GITHUB_WORKSPACE/vendor-dlkm-exp3"
WLAN="$GITHUB_WORKSPACE/wlan-a16-exp1.ko"
MSM11AD="$GITHUB_WORKSPACE/msm_11ad_proxy-exp3.ko"

test -d "$MODROOT/system/vendor/lib/modules"
test -s "$WLAN"
test -s "$MSM11AD"
rm -rf "$EXPORT"
mkdir -p "$EXPORT"

# Replace the two additional stock modules proven by the real-device report to
# have a stale module_layout CRC.  Audio files are already populated by the
# full TRINKET audio builder in this same MODROOT.
cp -f "$WLAN" "$MODROOT/system/vendor/lib/modules/wlan.ko"
cp -f "$MSM11AD" "$MODROOT/system/vendor/lib/modules/msm_11ad_proxy.ko"

cat > "$MODROOT/module.prop" <<'EOF'
id=pchm30_exp3_matching_vendor_dlkm
name=PCHM30 EXP3 Matching Vendor DLKM
version=EXP3
versionCode=9
author=hhsbjbsj
description=Matching WLAN, msm_11ad_proxy and full TRINKET audio DLKMs rebuilt against the exact EXP3 Android 16 kernel ABI. Keeps CONFIG_MODVERSIONS enabled; no force-load bypass.
EOF

# Append conservative fallback loading.  Magic-mount is preferred because it
# lets vendor init consume the matching files directly.  If an old stock module
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

# Keep a manifest that makes it obvious which stale-stock errors this package
# is intended to eliminate, instead of hiding them by disabling MODVERSIONS.
cat > "$EXPORT/real-device-bugs.txt" <<'EOF'
[FIXED/REBUILT]
- wlan: stock module_layout mismatch -> matching qcacld wlan.ko
- msm_11ad_proxy: stock module_layout mismatch -> in-tree rebuild against EXP3 Module.symvers
- snd_event_dlkm / wglink_dlkm / q6_pdr_dlkm / pinctrl_wcd_dlkm / swr_dlkm
- hdmi_dlkm / wcd_spi_dlkm / stub_dlkm / wcd_core_dlkm
- full TRINKET machine/platform/Bolero/macro/codec dependency graph

[KERNEL COMPAT]
- Android 16 unprivileged_bpf_disabled=0 write: stock 4.14 accepted only value 1;
  EXP3 uses 0/1/2-compatible handler while preserving locked state 1.
- BTF VAR/DATASEC + precise verifier diagnostics retained.

[DEPENDENT / VERIFY ON DEVICE]
- NetworkStats Null bpf map / Failed to parse bpf iface stats: expected to clear when
  the remaining BTF verifier rejection is fully fixed; do not patch userspace around it.
- android.hardware Call trace: old collector omitted the stack body; next collector captures
  full dmesg so any remaining trace can be fixed from the actual caller/PC rather than guessed.
EOF

# Record all actual overlay module files and checksums.
find "$MODROOT/system/vendor/lib/modules" -type f -name '*.ko' -print | sort > "$EXPORT/vendor-overlay-files.txt"
find "$MODROOT/system/vendor/lib/modules" -type f -name '*.ko' -exec sha256sum {} \; | sort > "$EXPORT/vendor-overlay.sha256"

# Include a tiny on-device shell collector in the module as well.  It does not
# alter the system; it captures the evidence needed to close any remaining bug.
cat > "$MODROOT/collect-exp3.sh" <<'EOF'
#!/system/bin/sh
OUT=/data/local/tmp/exp3-diagnose
mkdir -p "$OUT"
dmesg > "$OUT/dmesg-full.txt"
logcat -b all -d > "$OUT/logcat-all.txt" 2>&1
cat /proc/modules > "$OUT/proc-modules.txt"
cat /proc/sys/kernel/unprivileged_bpf_disabled > "$OUT/unprivileged_bpf_disabled.txt" 2>&1
find /vendor/lib/modules -maxdepth 1 -type f -name '*.ko' -print > "$OUT/vendor-modules.txt" 2>&1
find /sys/fs/bpf -maxdepth 4 -type f -o -type d > "$OUT/bpf-fs.txt" 2>&1
uname -a > "$OUT/uname.txt"
getprop > "$OUT/getprop.txt"
{
  echo '===== ABI/BTF/CRASH FILTER ====='
  grep -Ei 'module_layout|Unknown symbol|invalid module format|A16-BTF|BTF loading error|Null bpf map|Failed to parse bpf|Call trace:|BUG:|Oops|panic|lockup|RCU stall' "$OUT/dmesg-full.txt" || true
} > "$OUT/summary.txt"
echo "$OUT"
EOF
chmod 0755 "$MODROOT/collect-exp3.sh"

(cd "$MODROOT" && zip -qr "$GITHUB_WORKSPACE/PCHM30-EXP3-MATCHING-VENDOR-DLKM-KSU.zip" .)
sha256sum "$GITHUB_WORKSPACE/PCHM30-EXP3-MATCHING-VENDOR-DLKM-KSU.zip" | tee "$EXPORT/vendor-ksu.sha256"

echo '[PASS] unified EXP3 vendor DLKM replacement package ready'
