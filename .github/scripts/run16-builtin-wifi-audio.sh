#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee "$GITHUB_WORKSPACE/run16-builtin-stage.log") 2>&1

KERNEL="$GITHUB_WORKSPACE/$KERNEL_REL"
KOUT="$KERNEL/$OUT_DIR"
VENDOR_QCOM="$GITHUB_WORKSPACE/source/android/vendor/qcom/opensource"
AUDIO_SRC="$VENDOR_QCOM/audio-kernel"
WLAN_SRC="$VENDOR_QCOM/wlan"
AUDIO_DST="$KERNEL/techpack/audio"
STAGING="$KERNEL/drivers/staging"

for f in \
  "$AUDIO_SRC/Makefile" \
  "$AUDIO_SRC/ipc/Kbuild" \
  "$AUDIO_SRC/dsp/Kbuild" \
  "$AUDIO_SRC/asoc/Kbuild" \
  "$AUDIO_SRC/asoc/codecs/Kbuild" \
  "$AUDIO_SRC/asoc/codecs/wcd934x/Kbuild" \
  "$AUDIO_SRC/config/trinketauto.conf" \
  "$AUDIO_SRC/config/trinketautoconf.h" \
  "$WLAN_SRC/qcacld-3.0/Kbuild" \
  "$WLAN_SRC/qcacld-3.0/Kconfig"; do
  test -f "$f" || { echo "[FATAL] missing built-in input: $f"; exit 81; }
done
for d in "$WLAN_SRC/qca-wifi-host-cmn" "$WLAN_SRC/fw-api"; do
  test -d "$d" || { echo "[FATAL] missing WLAN sibling tree: $d"; exit 82; }
done

grep -Fq 'PCHM30 A16 late-DLKM: schedule APR child population from probe' "$AUDIO_SRC/ipc/apr.c"
grep -Fq 'PCHM30 A16 late-DLKM: AVS not ready, defer q6core probe' "$AUDIO_SRC/dsp/q6core.c"

echo '===== STAGE RUN16 AUDIO INTO techpack/audio ====='
rm -rf "$AUDIO_DST"
cp -a "$AUDIO_SRC" "$AUDIO_DST"

SND_EVENT="$AUDIO_DST/include/soc/snd_event.h"
if grep -q '^inline bool is_snd_event_fwk_enabled' "$SND_EVENT"; then
  sed -i 's/^inline bool is_snd_event_fwk_enabled/static inline bool is_snd_event_fwk_enabled/' "$SND_EVENT"
fi
grep -q '^static inline bool is_snd_event_fwk_enabled' "$SND_EVENT"

python3 - <<'PY'
import os, re
from pathlib import Path
root = Path(os.environ['GITHUB_WORKSPACE']) / os.environ['KERNEL_REL'] / 'techpack/audio'
changed = 0
for p in root.rglob('Kbuild'):
    s = p.read_text()
    ns, n = re.subn(r'(?m)^[ \t]*AUDIO_ROOT[ \t]*:=[^\n]*techpack/audio[^\n]*$',
                    '\tAUDIO_ROOT := $(srctree)/techpack/audio', s)
    if n:
        p.write_text(ns)
        changed += n
print(f'normalized AUDIO_ROOT assignments={changed}')
if changed < 4:
    raise SystemExit('too few AUDIO_ROOT normalizations; vendor tree layout changed')
PY

python3 - <<'PY'
import os, re
from pathlib import Path
root = Path(os.environ['GITHUB_WORKSPACE']) / os.environ['KERNEL_REL'] / 'techpack/audio/config'
src = root / 'trinketauto.conf'
dst = root / 'trinketauto_builtin.conf'
lines = []
converted = 0
for line in src.read_text().splitlines():
    m = re.fullmatch(r'(CONFIG_[A-Za-z0-9_]+)=m', line)
    if m:
        line = m.group(1) + '=y'
        converted += 1
    lines.append(line)
dst.write_text('\n'.join(lines) + '\n')
print(f'trinket audio m->y conversions={converted}')
if converted < 35:
    raise SystemExit('unexpectedly small Trinket audio closure')
if any(line.endswith('=m') for line in lines if not line.startswith('#')):
    raise SystemExit('module-valued audio config remained in builtin profile')
PY

grep -q '^CONFIG_MSM_QDSP6_APRV2_RPMSG=y$' "$AUDIO_DST/config/trinketauto_builtin.conf"
grep -q '^CONFIG_SND_SOC_SM6150=y$' "$AUDIO_DST/config/trinketauto_builtin.conf"
grep -q '^CONFIG_SND_SOC_WCD934X=y$' "$AUDIO_DST/config/trinketauto_builtin.conf"
grep -q '^CONFIG_SND_SOC_SIA81XX=y$' "$AUDIO_DST/config/trinketauto_builtin.conf"

python3 - <<'PY'
import os
from pathlib import Path
p = Path(os.environ['GITHUB_WORKSPACE']) / os.environ['KERNEL_REL'] / 'techpack/audio/Makefile'
s = p.read_text()
marker = '# RUN16_TRINKET_BUILTIN_PROFILE'
if marker not in s:
    anchor = '# Use USERINCLUDE when you must reference the UAPI directories only.\n'
    if anchor not in s:
        raise SystemExit('audio Makefile USERINCLUDE anchor missing')
    block = """# RUN16_TRINKET_BUILTIN_PROFILE
ifeq ($(CONFIG_ARCH_TRINKET), y)
include $(srctree)/techpack/audio/config/trinketauto_builtin.conf
export
endif

"""
    s = s.replace(anchor, block + anchor, 1)
    anchor2 = 'obj-y += soc/\n'
    if anchor2 not in s:
        raise SystemExit('audio Makefile obj-y anchor missing')
    block2 = """ifeq ($(CONFIG_ARCH_TRINKET), y)
LINUXINCLUDE += -include $(srctree)/techpack/audio/config/trinketautoconf.h
endif

"""
    s = s.replace(anchor2, block2 + anchor2, 1)
    p.write_text(s)
PY

grep -Fq 'RUN16_TRINKET_BUILTIN_PROFILE' "$AUDIO_DST/Makefile"
grep -Fq 'trinketauto_builtin.conf' "$AUDIO_DST/Makefile"

python3 - <<'PY'
import os
from pathlib import Path
p = Path(os.environ['GITHUB_WORKSPACE']) / os.environ['KERNEL_REL'] / 'techpack/audio/asoc/codecs/Kbuild'
s = p.read_text()
marker = '# RUN16_OPLUS_PA_BUILTIN_DIRS'
if marker not in s:
    s += """
# RUN16_OPLUS_PA_BUILTIN_DIRS
ifeq ($(KERNEL_BUILD), 1)
obj-y += bolero/
obj-y += tfa98xx-v6/
obj-y += sia81xx/
endif
"""
    p.write_text(s)
PY

for d in bolero tfa98xx-v6 sia81xx; do
  test -f "$AUDIO_DST/asoc/codecs/$d/Kbuild" || { echo "[FATAL] missing codec/PA Kbuild: $d"; exit 83; }
done

grep -Fq 'obj-y += bolero/' "$AUDIO_DST/asoc/codecs/Kbuild"

echo '===== STAGE RUN16 QCACLD INTO drivers/staging ====='
rm -rf "$STAGING/qcacld-3.0" "$STAGING/qca-wifi-host-cmn" "$STAGING/fw-api"
cp -a "$WLAN_SRC/qcacld-3.0" "$STAGING/qcacld-3.0"
cp -a "$WLAN_SRC/qca-wifi-host-cmn" "$STAGING/qca-wifi-host-cmn"
cp -a "$WLAN_SRC/fw-api" "$STAGING/fw-api"

if ! grep -Fq 'RUN16_QCACLD_BUILTIN' "$STAGING/Makefile"; then
  cat >> "$STAGING/Makefile" <<'EOF2'

# RUN16_QCACLD_BUILTIN
obj-$(CONFIG_QCA_CLD_WLAN) += qcacld-3.0/
EOF2
fi
if ! grep -Fq 'RUN16_QCACLD_BUILTIN' "$STAGING/Kconfig"; then
  cat >> "$STAGING/Kconfig" <<'EOF2'

# RUN16_QCACLD_BUILTIN
source "drivers/staging/qcacld-3.0/Kconfig"
EOF2
fi

grep -Fq 'obj-$(CONFIG_QCA_CLD_WLAN) += qcacld-3.0/' "$STAGING/Makefile"
grep -Fq 'source "drivers/staging/qcacld-3.0/Kconfig"' "$STAGING/Kconfig"

cd "$KERNEL"
./scripts/config --file "$OUT_DIR/.config" -e ARCH_TRINKET -e STAGING -e QCA_CLD_WLAN -e MSM_11AD
unset LLVM LLVM_IAS KBUILD_COMPILER_STRING
make O="$OUT_DIR" ARCH=arm64 LOCALVERSION=+ \
  CC="$CC" REAL_CC="$REAL_CC" LD="$LD" \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  CLANG_TRIPLE="$CLANG_TRIPLE" olddefconfig

grep -q '^CONFIG_ARCH_TRINKET=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_STAGING=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_QCA_CLD_WLAN=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_MSM_11AD=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_MODVERSIONS=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT_DIR/.config"

cat > "$GITHUB_WORKSPACE/run16-builtin-manifest.txt" <<EOF2
RUN16 base: Run15 Golden commit 05d746a3cf68dad58ba671fede606a081589d9fe
Audio source: OPPO vendor commit $OPPO_VENDOR_COMMIT -> techpack/audio
Audio profile: trinketauto.conf converted m->y
APR latefix: preserved from Run15
Q6core EPROBE_DEFER latefix: preserved from Run15
WiFi source: qcacld-3.0 + qca-wifi-host-cmn + fw-api -> drivers/staging
CONFIG_QCA_CLD_WLAN=y
CONFIG_MSM_11AD=y
No KSU driver overlay is required by the Run16 design.
EOF2

find "$AUDIO_DST" -type f \( -name Makefile -o -name Kbuild -o -name 'trinketauto_builtin.conf' \) -print | sort \
  > "$GITHUB_WORKSPACE/run16-audio-build-files.txt"
sha256sum "$AUDIO_DST/config/trinketauto_builtin.conf" "$STAGING/qcacld-3.0/Kbuild" \
  > "$GITHUB_WORKSPACE/run16-staged-source.sha256"

echo '[PASS] Run16 WiFi + complete Run15 audio closure staged for true built-in kernel build'
