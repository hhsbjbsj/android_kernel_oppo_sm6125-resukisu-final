#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="${KERNEL_DIR:-$GITHUB_WORKSPACE/$KERNEL_REL}"
OUT_DIR="${OUT_DIR:-out-pchm30-a16-bpf}"
BBG_COMMIT="a54e0dc6cf0aff4dd87fec49644a02d2eb612905"
SUKISU_PATCH_COMMIT="547ae94bcaec53d030398f857950c64662043a5d"
LOG="$GITHUB_WORKSPACE/run17-bbg-zram.log"
PROOF="$GITHUB_WORKSPACE/run17-bbg-zram-stage-proof.txt"

exec > >(tee "$LOG") 2>&1
cd "$KERNEL_DIR"

echo '===== RUN17 ADD BBG + LZ4K/LZ4KD ====='
echo "kernel_dir=$KERNEL_DIR"
echo "out_dir=$OUT_DIR"
echo "bbg_commit=$BBG_COMMIT"
echo "sukisu_patch_commit=$SUKISU_PATCH_COMMIT"

test -f "$OUT_DIR/.config"
test -x scripts/config

# ---------------------------------------------------------------------------
# 1) Baseband Guard (BBG) - pinned upstream, old/non-GKI path enabled by setup.
# Keep boot/recovery writable so existing AnyKernel/recovery/fastboot workflows
# are not broken by this experiment.
# ---------------------------------------------------------------------------
echo '===== STAGE BBG ====='
rm -rf Baseband-guard
git init -q Baseband-guard
git -C Baseband-guard remote add origin https://github.com/vc-teahouse/Baseband-guard.git
git -C Baseband-guard fetch --no-tags --depth=1 origin "$BBG_COMMIT"
git -C Baseband-guard checkout -q --detach FETCH_HEAD
chmod +x Baseband-guard/setup.sh
bash Baseband-guard/setup.sh "$BBG_COMMIT"

# 4.14 does not have modern DEFINE_LSM infrastructure, so Baseband-guard's
# setup script patches the old SELinux credential storage path. Keep this
# explicit and fail if the integration did not land.
test -L security/baseband-guard
grep -Fq 'obj-$(CONFIG_BBG) += baseband-guard/' security/Makefile
grep -Fq 'source "security/baseband-guard/Kconfig"' security/Kconfig

# ---------------------------------------------------------------------------
# 2) LZ4K / LZ4KD for ZRAM.
# Only import algorithm + crypto/zram glue. Deliberately DO NOT import the
# unrelated 5.10 module.c blacklist/version-relaxation changes from the
# SukiSU patch set.
# ---------------------------------------------------------------------------
echo '===== STAGE LZ4K / LZ4KD ====='
PATCH_TREE="$GITHUB_WORKSPACE/.run17-sukisu-patch"
rm -rf "$PATCH_TREE"
git init -q "$PATCH_TREE"
git -C "$PATCH_TREE" remote add origin https://github.com/SukiSU-Ultra/SukiSU_patch.git
git -C "$PATCH_TREE" fetch --no-tags --depth=1 origin "$SUKISU_PATCH_COMMIT"
git -C "$PATCH_TREE" checkout -q --detach FETCH_HEAD

rm -rf lib/lz4k lib/lz4kd
cp -a "$PATCH_TREE/other/zram/lz4k/lib/lz4k" lib/
cp -a "$PATCH_TREE/other/zram/lz4k/lib/lz4kd" lib/
cp -f "$PATCH_TREE/other/zram/lz4k/include/linux/lz4k.h" include/linux/lz4k.h
cp -f "$PATCH_TREE/other/zram/lz4k/include/linux/lz4kd.h" include/linux/lz4kd.h
cp -f "$PATCH_TREE/other/zram/lz4k/crypto/lz4k.c" crypto/lz4k.c
cp -f "$PATCH_TREE/other/zram/lz4k/crypto/lz4kd.c" crypto/lz4kd.c

python3 - <<'PY'
from pathlib import Path


def insert_after(path, marker, addition, guard):
    p = Path(path)
    s = p.read_text()
    if guard in s:
        return
    if marker not in s:
        raise SystemExit(f'marker not found in {path}: {marker!r}')
    p.write_text(s.replace(marker, marker + addition, 1))


def insert_before(path, marker, addition, guard):
    p = Path(path)
    s = p.read_text()
    if guard in s:
        return
    if marker not in s:
        raise SystemExit(f'marker not found in {path}: {marker!r}')
    p.write_text(s.replace(marker, addition + marker, 1))


insert_after(
    'lib/Kconfig',
    'config LZ4_DECOMPRESS\n\ttristate\n',
    '\nconfig LZ4K_COMPRESS\n\ttristate\n\n'
    'config LZ4K_DECOMPRESS\n\ttristate\n\n'
    'config LZ4KD_COMPRESS\n\ttristate\n\n'
    'config LZ4KD_DECOMPRESS\n\ttristate\n',
    'config LZ4K_COMPRESS',
)

insert_after(
    'lib/Makefile',
    'obj-$(CONFIG_LZ4_DECOMPRESS) += lz4/\n',
    'obj-$(CONFIG_LZ4K_COMPRESS) += lz4k/\n'
    'obj-$(CONFIG_LZ4K_DECOMPRESS) += lz4k/\n'
    'obj-$(CONFIG_LZ4KD_COMPRESS) += lz4kd/\n'
    'obj-$(CONFIG_LZ4KD_DECOMPRESS) += lz4kd/\n',
    'CONFIG_LZ4K_COMPRESS',
)

insert_before(
    'crypto/Kconfig',
    'config CRYPTO_LZ4HC\n',
    'config CRYPTO_LZ4K\n'
    '\ttristate "LZ4K compression algorithm"\n'
    '\tselect CRYPTO_ALGAPI\n'
    '\tselect CRYPTO_ACOMP2\n'
    '\tselect LZ4K_COMPRESS\n'
    '\tselect LZ4K_DECOMPRESS\n'
    '\thelp\n'
    '\t  LZ4K compression algorithm optimized for ZRAM workloads.\n\n'
    'config CRYPTO_LZ4KD\n'
    '\ttristate "LZ4KD compression algorithm"\n'
    '\tselect CRYPTO_ALGAPI\n'
    '\tselect CRYPTO_ACOMP2\n'
    '\tselect LZ4KD_COMPRESS\n'
    '\tselect LZ4KD_DECOMPRESS\n'
    '\thelp\n'
    '\t  LZ4KD compression algorithm optimized for ZRAM workloads.\n\n',
    'config CRYPTO_LZ4K',
)

insert_after(
    'crypto/Makefile',
    'obj-$(CONFIG_CRYPTO_LZ4HC) += lz4hc.o\n',
    'obj-$(CONFIG_CRYPTO_LZ4K) += lz4k.o\n'
    'obj-$(CONFIG_CRYPTO_LZ4KD) += lz4kd.o\n',
    'CONFIG_CRYPTO_LZ4K',
)

insert_after(
    'drivers/block/zram/zcomp.c',
    '#if IS_ENABLED(CONFIG_CRYPTO_LZ4HC)\n\t"lz4hc",\n#endif\n',
    '#if IS_ENABLED(CONFIG_CRYPTO_LZ4K)\n\t"lz4k",\n#endif\n'
    '#if IS_ENABLED(CONFIG_CRYPTO_LZ4KD)\n\t"lz4kd",\n#endif\n',
    'CONFIG_CRYPTO_LZ4KD',
)

p = Path('drivers/block/zram/zram_drv.c')
s = p.read_text()
old = 'static const char *default_compressor = "lzo";'
new = 'static const char *default_compressor = "lz4kd";'
if new not in s:
    if old not in s:
        raise SystemExit('zram default compressor marker not found')
    p.write_text(s.replace(old, new, 1))
PY

# Enable the two algorithms built-in. LZ4KD is the default ZRAM compressor;
# LZ4K stays available as a fallback/alternative through comp_algorithm.
scripts/config --file "$OUT_DIR/.config" \
  -e SECURITY \
  -e BBG \
  -d BBG_BLOCK_BOOT \
  -d BBG_BLOCK_RECOVERY \
  -e ZRAM \
  -e CRYPTO_LZ4K \
  -e CRYPTO_LZ4KD \
  -e LZ4K_COMPRESS \
  -e LZ4K_DECOMPRESS \
  -e LZ4KD_COMPRESS \
  -e LZ4KD_DECOMPRESS

# Do not touch KPM in this experiment.
if grep -q '^CONFIG_KPM=y$' "$OUT_DIR/.config"; then
  echo '[FATAL] CONFIG_KPM unexpectedly enabled; Run17 BBG/ZRAM experiment must not add KPM'
  exit 71
fi

{
  echo "BBG_COMMIT=$BBG_COMMIT"
  echo "SUKISU_PATCH_COMMIT=$SUKISU_PATCH_COMMIT"
  echo 'BBG_SETUP=old/non-GKI-compatible path staged'
  echo 'BBG_BLOCK_BOOT=n'
  echo 'BBG_BLOCK_RECOVERY=n'
  echo 'ZRAM_DEFAULT=lz4kd'
  echo 'ZRAM_ALGOS=lz4k,lz4kd'
  echo 'KPM=not-added'
  echo '===== CONFIG REQUESTS ====='
  grep -E '^CONFIG_(BBG|ZRAM|CRYPTO_LZ4K|CRYPTO_LZ4KD|LZ4K_|LZ4KD_)' "$OUT_DIR/.config" || true
  echo '===== SOURCE MARKERS ====='
  grep -n 'default_compressor = "lz4kd"' drivers/block/zram/zram_drv.c
  grep -n 'CONFIG_CRYPTO_LZ4KD' drivers/block/zram/zcomp.c
  grep -n 'CONFIG_BBG' security/Makefile
} | tee "$PROOF"

echo '[PASS] Run17 staged BBG plus LZ4K/LZ4KD without KPM or unrelated module.c changes'
