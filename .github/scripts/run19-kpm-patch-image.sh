#!/usr/bin/env bash
set -Eeuo pipefail
IMAGE="$OUT_DIR/arch/arm64/boot/Image"
PATCH_REPO="$GITHUB_WORKSPACE/SukiSU_patch"
PATCH_DIR="$GITHUB_WORKSPACE/run19-kpm-patch"
PRE_IMAGE="$GITHUB_WORKSPACE/PCHM30-A16-RUN19-KPM-PREPATCH-Image-${GITHUB_RUN_NUMBER}"

cp -f "$IMAGE" "$PRE_IMAGE"
rm -rf "$PATCH_REPO" "$PATCH_DIR"
git clone --filter=blob:none --no-checkout "$SUKISU_PATCH_REPO" "$PATCH_REPO"
git -C "$PATCH_REPO" fetch --no-tags origin "$SUKISU_PATCH_COMMIT"
git -C "$PATCH_REPO" checkout --detach "$SUKISU_PATCH_COMMIT"
test "$(git -C "$PATCH_REPO" rev-parse HEAD)" = "$SUKISU_PATCH_COMMIT"

mkdir -p "$PATCH_DIR"
cp -a "$PATCH_REPO/kpm/." "$PATCH_DIR/"
cp -f "$IMAGE" "$PATCH_DIR/Image"
chmod +x "$PATCH_DIR/patch_linux" "$PATCH_DIR/kptools" || true

python3 - "$PATCH_DIR/Image" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
d = p.read_bytes()[:64]
if len(d) < 64 or d[56:60] != b'ARM\x64':
    raise SystemExit('pre-patch Image lost ARM64 Image magic')
print('pre-patch ARM64 Image magic: PASS')
PY

BEFORE_SHA="$(sha256sum "$PATCH_DIR/Image" | awk '{print $1}')"
BEFORE_SIZE="$(stat -c%s "$PATCH_DIR/Image")"
(
  cd "$PATCH_DIR"
  ./patch_linux 2>&1 | tee "$GITHUB_WORKSPACE/run19-kpm-patcher.log"
)
test -s "$PATCH_DIR/oImage"

python3 - "$PATCH_DIR/oImage" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
d = p.read_bytes()[:64]
if len(d) < 64 or d[56:60] != b'ARM\x64':
    raise SystemExit('patched oImage lost ARM64 Image magic')
print('patched ARM64 Image magic: PASS')
PY

AFTER_SHA="$(sha256sum "$PATCH_DIR/oImage" | awk '{print $1}')"
AFTER_SIZE="$(stat -c%s "$PATCH_DIR/oImage")"
test "$BEFORE_SHA" != "$AFTER_SHA"
cp -f "$PATCH_DIR/oImage" "$IMAGE"

{
  echo "sukisu_patch_commit=$SUKISU_PATCH_COMMIT"
  echo "before_sha256=$BEFORE_SHA"
  echo "after_sha256=$AFTER_SHA"
  echo "before_size=$BEFORE_SIZE"
  echo "after_size=$AFTER_SIZE"
  sha256sum "$PATCH_REPO/kpm/patch_linux" | sed 's#  .*#  patch_linux#'
  sha256sum "$PATCH_REPO/kpm/kpimg" | sed 's#  .*#  kpimg#'
  echo 'arm64_magic_before=pass'
  echo 'arm64_magic_after=pass'
  echo 'kpm_final_image=patched'
} | tee "$GITHUB_WORKSPACE/run19-kpm-final-proof.txt"

strings -a "$IMAGE" > "$GITHUB_WORKSPACE/run19-patched-image-strings.txt"
test -s "$GITHUB_WORKSPACE/run19-kpm-patcher.log"
grep -Fxq 'kpm_final_image=patched' "$GITHUB_WORKSPACE/run19-kpm-final-proof.txt"
echo '[PASS] final Run19 Image was changed by pinned KPM patcher and retains ARM64 Image header magic'
