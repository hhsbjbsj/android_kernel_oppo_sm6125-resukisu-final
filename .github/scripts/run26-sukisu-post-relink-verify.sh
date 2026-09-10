#!/usr/bin/env bash
# Post-BTF verify for Run26 SukiSU. Accepts SukiSU v4.2 SID strings and SUSFS 2.3.0.
set -Eeuo pipefail
echo '===== Run26 SukiSU post-relink verify (SUSFS 2.3.0 + SukiSU v4.2) ====='
IMAGE="$OUT_DIR/arch/arm64/boot/Image"
VMLINUX="$OUT_DIR/vmlinux"
STRINGS="$GITHUB_WORKSPACE/run19-prepatch-image-strings.txt"
NMFILE="$GITHUB_WORKSPACE/run19-vmlinux-nm.txt"
fail() { echo "[FAIL] $*"; exit 1; }
pass() { echo "[PASS] $*"; }
need_file() { test -s "$1" || fail "missing/empty $1"; pass "file $(basename "$1")"; }
need_line() { grep -Fxq "$2" "$1" || fail "exact line missing in $(basename "$1"): $2"; pass "$2"; }
need_cfg() { grep -q "^$1=y$" "$OUT_DIR/.config" || fail "$1 not =y"; pass "$1=y"; }
need_str() { grep -Fq "$1" "$STRINGS" || fail "Image string missing: $1"; pass "string $1"; }
need_any_str() {
  local label="$1"; shift
  local pat
  for pat in "$@"; do
    if grep -Fq "$pat" "$STRINGS"; then
      pass "string $label ($pat)"
      return 0
    fi
  done
  fail "Image string missing for $label (tried: $*)"
}
need_sym() { grep -Eq "[[:space:]]$1$" "$NMFILE" || fail "nm symbol missing: $1"; pass "nm $1"; }

need_file "$IMAGE"
need_file "$VMLINUX"
need_file "$GITHUB_WORKSPACE/run18-sukisu-proof.txt"
need_file "$GITHUB_WORKSPACE/run19-kpm-config-proof.txt"
if test -s "$GITHUB_WORKSPACE/run16-unwanted-ko.txt"; then
  fail 'run16-unwanted-ko.txt is non-empty'
else
  pass 'no unwanted .ko list'
fi
need_line "$GITHUB_WORKSPACE/run18-sukisu-proof.txt" "sukisu_commit=$SUKISU_COMMIT"
if grep -Fxq 'susfs_version=v2.3.0' "$GITHUB_WORKSPACE/run19-kpm-config-proof.txt"; then
  pass 'susfs_version=v2.3.0'
else
  echo '[dump] run19-kpm-config-proof.txt'; cat "$GITHUB_WORKSPACE/run19-kpm-config-proof.txt" || true
  fail 'susfs_version is not v2.3.0 in run19-kpm-config-proof.txt'
fi
need_line "$GITHUB_WORKSPACE/run19-kpm-config-proof.txt" 'kpm=config-enabled'
if grep -Fq '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h; then
  pass 'SUSFS_VERSION v2.3.0 header'
else
  echo '[dump] SUSFS_VERSION lines'; grep -n SUSFS_VERSION include/linux/susfs.h || true
  fail 'include/linux/susfs.h is not SUSFS 2.3'
fi
HEAD="$(git -C KernelSU rev-parse HEAD 2>/dev/null || echo missing)"
if test "$HEAD" = "$SUKISU_COMMIT"; then
  pass "KernelSU HEAD $HEAD"
else
  fail "KernelSU HEAD $HEAD != $SUKISU_COMMIT"
fi

need_cfg CONFIG_QCA_CLD_WLAN
need_cfg CONFIG_MSM_11AD
need_cfg CONFIG_KSU
need_cfg CONFIG_KSU_SUSFS
need_cfg CONFIG_KPM
need_cfg CONFIG_KALLSYMS
need_cfg CONFIG_KALLSYMS_ALL
need_cfg CONFIG_BPF_STREAM_PARSER
need_cfg CONFIG_MODVERSIONS
need_cfg CONFIG_BBG
need_cfg CONFIG_CRYPTO_LZ4K
need_cfg CONFIG_CRYPTO_LZ4KD
need_cfg CONFIG_LZ4K_COMPRESS
need_cfg CONFIG_LZ4K_DECOMPRESS
need_cfg CONFIG_LZ4KD_COMPRESS
need_cfg CONFIG_LZ4KD_DECOMPRESS

strings -a "$IMAGE" > "$STRINGS"
need_str 'PCHM30 RUN17 built-in WLAN delayed start armed'
need_str 'PCHM30 RUN17 built-in WLAN delayed start succeeded'
need_str 'PCHM30 RUN17 q6core active reprobe armed'
need_str 'PCHM30 RUN17 q6core active reprobe succeeded'
need_str 'baseband_guard power by'
need_any_str 'zygote-SID' \
  'manager spawn zygote SID mismatch' \
  'Cached zygote SID' \
  'Failed to cache zygote SID'
need_any_str 'kpm-stub' \
  'kpm: Stub function called (sukisu_kpm_load_module_path)' \
  'kpm: Stub function called'

nm "$VMLINUX" > "$NMFILE"
need_sym hdd_driver_load
need_sym q6core_probe
need_sym pchm30_builtin_wlan_start_workfn
need_sym pchm30_q6core_retry_workfn
need_sym bbg_init
need_sym lz4k_mod_init
need_sym lz4kd_mod_init
need_sym ksu_handle_setresuid
need_sym sukisu_handle_kpm
need_sym sukisu_kpm_load_module_path
need_sym sukisu_compact_find_symbol
grep -Fq 'default_compressor = "lz4kd"' drivers/block/zram/zram_drv.c || fail 'zram default_compressor is not lz4kd'
pass 'zram default_compressor=lz4kd'
echo '[PASS] Run26 pre-patch Image contains KPM interface and Run18 features'
