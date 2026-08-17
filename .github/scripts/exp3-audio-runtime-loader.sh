#!/usr/bin/env bash
set -Eeuo pipefail

MODROOT="$GITHUB_WORKSPACE/audio-ksu-module"
RAW="$MODROOT/system/vendor/lib/modules/exp3_audio_raw"
test -d "$RAW"

# Run12 proved every listed module can reach Live, but the old loader attempted
# them alphabetically only at late_start. That generated hundreds of transient
# Unknown-symbol lines and did not restore speaker output. Load the exact graph
# earlier and in the dependency waves observed to converge on the device.
cat > "$MODROOT/audio-load-ordered.sh" <<'EOF'
#!/system/bin/sh
MODDIR=${0%/*}
RAW="$MODDIR/system/vendor/lib/modules/exp3_audio_raw"
LOG=/data/local/tmp/pchm30-exp3-audio-loader.log

loaded() {
  n=$(basename "$1" .ko | tr '-' '_')
  grep -q "^${n} " /proc/modules 2>/dev/null
}
load_one() {
  ko="$1"
  [ -f "$RAW/$ko" ] || return 0
  loaded "$ko" && return 0
  if insmod "$RAW/$ko" 2>>"$LOG"; then
    echo "PASS ordered $ko" >>"$LOG"
    return 0
  fi
  echo "DEFER ordered $ko" >>"$LOG"
  return 1
}

# These waves are not guesses: they reproduce the successful dependency
# convergence observed on PCHM30 Run12, but execute before late_start.
W1='hdmi_dlkm.ko pinctrl_wcd_dlkm.ko snd_event_dlkm.ko stub_dlkm.ko swr_dlkm.ko wcd937x_slave_dlkm.ko wcd_core_dlkm.ko wcd_spi_dlkm.ko wglink_dlkm.ko wsa881x_dlkm.ko'
W2='bolero_cdc_dlkm.ko mbhc_dlkm.ko va_macro_dlkm.ko'
W3='apr_dlkm.ko q6_dlkm.ko sia81xx_dlkm.ko swr_ctrl_dlkm.ko tfa98xx-v6_dlkm.ko tx_macro_dlkm.ko usf_dlkm.ko wcd9xxx_dlkm.ko wcd_cpe_dlkm.ko wsa_macro_dlkm.ko q6_notifier_dlkm.ko q6_pdr_dlkm.ko'
W4='adsp_loader_dlkm.ko cpe_lsm_dlkm.ko platform_dlkm.ko rx_macro_dlkm.ko wcd9335_dlkm.ko wcd934x_dlkm.ko wcd937x_dlkm.ko'
W5='native_dlkm.ko machine_dlkm.ko'

# Providers can be deferred by DSP/service readiness. Retry each full topology a
# few times, always keeping machine last; unlike Run12, do not brute-force every
# file in lexical order.
for pass in 1 2 3 4; do
  echo "===== ordered audio pass $pass =====" >>"$LOG"
  for x in $W1; do load_one "$x" || true; done
  for x in $W2; do load_one "$x" || true; done
  for x in $W3; do load_one "$x" || true; done
  for x in $W4; do load_one "$x" || true; done
  for x in $W5; do load_one "$x" || true; done
  grep -q '^machine_dlkm ' /proc/modules 2>/dev/null && break
  sleep 1
done
EOF
chmod 0755 "$MODROOT/audio-load-ordered.sh"

cat > "$MODROOT/post-fs-data.sh" <<'EOF'
#!/system/bin/sh
MODDIR=${0%/*}
LOG=/data/local/tmp/pchm30-exp3-audio-loader.log
{
  echo "===== $(date) EXP3 ordered audio post-fs-data ====="
  echo 'Loading matching audio graph before late_start; machine is always last.'
} >"$LOG"
"$MODDIR/audio-load-ordered.sh"
{
  echo '===== post-fs-data modules ====='
  grep -E '^(machine_dlkm|platform_dlkm|wcd934x_dlkm|sia81xx_dlkm|q6_dlkm|apr_dlkm) ' /proc/modules || true
} >>"$LOG"
EOF
chmod 0755 "$MODROOT/post-fs-data.sh"

cat > "$MODROOT/service.sh" <<'EOF'
#!/system/bin/sh
MODDIR=${0%/*}
LOG=/data/local/tmp/pchm30-exp3-audio-loader.log
exec >>"$LOG" 2>&1

echo "===== $(date) EXP3 audio service verification ====="
# One deterministic retry after vendor DSP services are up.
"$MODDIR/audio-load-ordered.sh"

# Give deferred ASoC probes a short window to register the card before HAL is
# restarted. This makes 'module Live' insufficient as a success criterion.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if [ -r /proc/asound/cards ] && ! grep -q 'no soundcards' /proc/asound/cards 2>/dev/null; then
    break
  fi
  sleep 1
done

echo '===== /proc/asound/cards ====='
cat /proc/asound/cards 2>&1 || true
echo '===== /proc/asound/pcm ====='
cat /proc/asound/pcm 2>&1 || true
echo '===== key audio modules ====='
grep -E '^(machine_dlkm|platform_dlkm|wcd934x_dlkm|sia81xx_dlkm|q6_dlkm|apr_dlkm) ' /proc/modules || true

# Restart HAL only after the matching graph has had a chance to register ALSA.
for svc in vendor.audio-hal-2-0 vendor.audio-hal-4-0 vendor.audio-hal audioserver; do
  state=$(getprop "init.svc.$svc")
  [ -n "$state" ] || continue
  echo "restart $svc (was $state)"
  setprop ctl.restart "$svc"
done
EOF
chmod 0755 "$MODROOT/service.sh"

echo '[PASS] audio runtime changed from late lexical retries to ordered post-fs-data topology load'
