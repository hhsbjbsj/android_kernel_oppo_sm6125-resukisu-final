#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL_DIR"

git fetch --no-tags --depth=1 origin "$EXP2_BRANCH"
git show "FETCH_HEAD:$EXP2_WORKFLOW" > "$GITHUB_WORKSPACE/exp2-success.yml"
grep -Fq 'PCHM30 A16 BTF EXP2 Diagnose' "$GITHUB_WORKSPACE/exp2-success.yml"

cat > "$GITHUB_WORKSPACE/run-exp2-step.py" <<'PY'
import os, subprocess, sys
from pathlib import Path
if len(sys.argv) != 2:
    raise SystemExit('usage: run-exp2-step.py <step name>')
name = sys.argv[1]
workspace = Path(os.environ['GITHUB_WORKSPACE'])
lines = (workspace / 'exp2-success.yml').read_text().splitlines(True)
marker = f'      - name: {name}\n'
try:
    start = lines.index(marker)
except ValueError:
    raise SystemExit(f'EXP2 step not found: {name}')
end = len(lines)
for i in range(start + 1, len(lines)):
    if lines[i].startswith('      - name: '):
        end = i
        break
block = lines[start:end]
workdir = None
run_index = None
inline_script = None
for i, line in enumerate(block):
    if line.startswith('        working-directory: '):
        workdir = line.split(': ', 1)[1].strip()
    if line.startswith('        run: '):
        value = line.split(': ', 1)[1].rstrip('\n')
        if value in ('|', '|-', '|+', '>', '>-', '>+'):
            run_index = i + 1
        else:
            inline_script = value
        break
if inline_script is None and run_index is None:
    raise SystemExit(f'EXP2 step is not a shell run step: {name}')
if inline_script is not None:
    script = inline_script + '\n'
else:
    script_lines = []
    for line in block[run_index:]:
        if line.startswith('          '):
            script_lines.append(line[10:])
        elif line.strip() == '':
            script_lines.append('\n')
        else:
            raise SystemExit(f'unexpected indentation: {line!r}')
    script = ''.join(script_lines)
cwd = workspace / workdir if workdir else workspace
print(f'===== REUSE EXP2 STEP: {name} =====', flush=True)
subprocess.run(['bash', '-c', 'set -Eeuo pipefail\n' + script], cwd=cwd,
               check=True, env=os.environ.copy())
PY
python3 -m py_compile "$GITHUB_WORKSPACE/run-exp2-step.py"

sync_github_env() {
  [ -f "$GITHUB_ENV" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      ''|*[^A-Za-z0-9_]*) continue ;;
    esac
    export "$key=$value"
  done < "$GITHUB_ENV"
}
run_step() {
  python3 "$GITHUB_WORKSPACE/run-exp2-step.py" "$1"
  sync_github_env
}

run_step 'Prepare successful WiFi step runner'
run_step 'Prepare successful EXP1 step runner'
run_step 'Prepare proven root step runner'
run_step 'Pin rootless baseline and prepare A16 step runner'
run_step 'Reproduce exact successful A16 source state'
run_step 'Layer verified ReSukiSU SUSFS hooks'
run_step 'Patch netbpfload uname compatibility'
run_step 'Prepare proven A16 root config'
run_step 'Enable BPF stream parser for sockmap sockhash'
run_step 'Relax module signature enforcement for WiFi experiment only'

git fetch --no-tags --depth=1 origin "$GITHUB_SHA"
for script in \
  exp3-a16-runtime-compat.sh \
  exp3-btf-backport.sh \
  exp3-btf-modern-observed.sh \
  run16-builtin-wifi-audio.sh; do
  git show "$GITHUB_SHA:.github/scripts/$script" > "$GITHUB_WORKSPACE/$script"
  chmod +x "$GITHUB_WORKSPACE/$script"
done
"$GITHUB_WORKSPACE/exp3-a16-runtime-compat.sh"
"$GITHUB_WORKSPACE/exp3-btf-backport.sh"
"$GITHUB_WORKSPACE/exp3-btf-modern-observed.sh"
"$GITHUB_WORKSPACE/run16-builtin-wifi-audio.sh"

run_step 'Instrument exact BTF rejection path'
run_step 'Build BTF EXP2 kernel'

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
VMLINUX="$OUT_DIR/vmlinux"
test -s "$IMAGE"
test -s "$VMLINUX"

echo '===== RUN16 VERIFY TRUE BUILT-INS ====='
test -s "$OUT_DIR/techpack/audio/built-in.o"
test -s "$OUT_DIR/techpack/audio/ipc/built-in.o"
test -s "$OUT_DIR/techpack/audio/dsp/built-in.o"
test -s "$OUT_DIR/techpack/audio/asoc/built-in.o"
test -s "$OUT_DIR/techpack/audio/asoc/codecs/wcd934x/built-in.o"
test -s "$OUT_DIR/techpack/audio/asoc/codecs/sia81xx/built-in.o"
test -s "$OUT_DIR/drivers/staging/qcacld-3.0/built-in.o"
test -s "$OUT_DIR/drivers/platform/msm/msm_11ad/built-in.o"

if find "$OUT_DIR/techpack/audio" -type f -name '*.ko' -print -quit | grep -q .; then
  echo '[FATAL] audio .ko still produced in built-in experiment'
  find "$OUT_DIR/techpack/audio" -type f -name '*.ko' -print
  exit 91
fi
if find "$OUT_DIR/drivers/staging/qcacld-3.0" -type f -name '*.ko' -print -quit | grep -q .; then
  echo '[FATAL] wlan.ko still produced in built-in experiment'
  find "$OUT_DIR/drivers/staging/qcacld-3.0" -type f -name '*.ko' -print
  exit 92
fi

grep -q '^CONFIG_QCA_CLD_WLAN=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_MSM_11AD=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_BPF_STREAM_PARSER=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_MODVERSIONS=y$' "$OUT_DIR/.config"

nm "$VMLINUX" | grep -Eq '[[:space:]]apr_probe$'
nm "$VMLINUX" | grep -Eq '[[:space:]]q6core_probe$'
nm "$VMLINUX" | grep -Eq '[[:space:]]tavil_cdc_mclk_enable$'
nm "$VMLINUX" | grep -Eq '[[:space:]]sia81xx_'
nm "$VMLINUX" | grep -Eq '[[:space:]]wlan_hdd_'
strings -a "$IMAGE" | grep -Fq 'PCHM30 A16 late-DLKM: schedule APR child population from probe'
strings -a "$IMAGE" | grep -Fq 'PCHM30 A16 late-DLKM: AVS not ready, defer q6core probe'
strings -a "$IMAGE" | grep -Fq 'A16-BPF compat uname:'
nm "$VMLINUX" | grep -q ' sock_map_ops$'
nm "$VMLINUX" | grep -q ' sock_hash_ops$'

{
  echo '===== built-in object sizes ====='
  stat -c '%s %n' \
    "$OUT_DIR/techpack/audio/built-in.o" \
    "$OUT_DIR/techpack/audio/ipc/built-in.o" \
    "$OUT_DIR/techpack/audio/dsp/built-in.o" \
    "$OUT_DIR/techpack/audio/asoc/built-in.o" \
    "$OUT_DIR/techpack/audio/asoc/codecs/wcd934x/built-in.o" \
    "$OUT_DIR/techpack/audio/asoc/codecs/sia81xx/built-in.o" \
    "$OUT_DIR/drivers/staging/qcacld-3.0/built-in.o" \
    "$OUT_DIR/drivers/platform/msm/msm_11ad/built-in.o"
  echo '===== key vmlinux symbols ====='
  nm "$VMLINUX" | grep -E ' apr_probe$| q6core_probe$| tavil_cdc_mclk_enable$| sia81xx_| wlan_hdd_' | head -n 120
} | tee "$GITHUB_WORKSPACE/run16-builtin-proof.txt"

find "$OUT_DIR/techpack/audio" "$OUT_DIR/drivers/staging/qcacld-3.0" \
  -type f -name '*.ko' -print > "$GITHUB_WORKSPACE/run16-unwanted-ko.txt"
test ! -s "$GITHUB_WORKSPACE/run16-unwanted-ko.txt"

sha256sum "$IMAGE" | tee "$GITHUB_WORKSPACE/Image-run16-builtin.sha256"
cp -a "$OUT_DIR/Module.symvers" "$GITHUB_WORKSPACE/Module.symvers.run16-builtin"

echo '[PASS] Run16 links WLAN + msm_11ad + complete Run15 audio closure into vmlinux/Image; no matching KSU driver module required'
