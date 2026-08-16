#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL_DIR"

# Load the proven EXP2 workflow and reuse its already validated reconstruction,
# root, uname, sockmap and matching-WLAN steps verbatim.
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

# Fetch EXP3-specific compatibility helpers from the exact triggering commit.
git fetch --no-tags --depth=1 origin "$GITHUB_SHA"
git show "$GITHUB_SHA:.github/scripts/exp3-a16-runtime-compat.sh" > "$GITHUB_WORKSPACE/exp3-a16-runtime-compat.sh"
git show "$GITHUB_SHA:.github/scripts/exp3-btf-backport.sh" > "$GITHUB_WORKSPACE/exp3-btf-backport.sh"
chmod +x "$GITHUB_WORKSPACE/exp3-a16-runtime-compat.sh" "$GITHUB_WORKSPACE/exp3-btf-backport.sh"
"$GITHUB_WORKSPACE/exp3-a16-runtime-compat.sh"
"$GITHUB_WORKSPACE/exp3-btf-backport.sh"

run_step 'Instrument exact BTF rejection path'
run_step 'Build BTF EXP2 kernel'
run_step 'Build matching OPPO qcacld wlan module'

# The real-device report also showed the stock msm_11ad_proxy.ko rejected by
# module_layout. It is an in-tree module (CONFIG_MSM_11AD=m), so rebuild it
# against the exact same .config/Module.symvers as this EXP3 Image.
echo '===== BUILD MATCHING MSM 11AD PROXY ====='
grep -q '^CONFIG_MSM_11AD=m$' "$OUT_DIR/.config"
unset LLVM LLVM_IAS KBUILD_COMPILER_STRING
make O="$OUT_DIR" ARCH=arm64 LOCALVERSION=+ \
  CC="$CC" REAL_CC="$REAL_CC" LD="$LD" \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  CLANG_TRIPLE="$CLANG_TRIPLE" \
  drivers/platform/msm/msm_11ad/msm_11ad_proxy.ko -j"$(nproc)"
MSM11AD="$OUT_DIR/drivers/platform/msm/msm_11ad/msm_11ad_proxy.ko"
test -s "$MSM11AD"
cp -f "$MSM11AD" "$GITHUB_WORKSPACE/msm_11ad_proxy-exp3.ko"
sha256sum "$GITHUB_WORKSPACE/msm_11ad_proxy-exp3.ko" | tee "$GITHUB_WORKSPACE/msm_11ad_proxy-exp3.sha256"
readelf -p .modinfo "$GITHUB_WORKSPACE/msm_11ad_proxy-exp3.ko" | tee "$GITHUB_WORKSPACE/msm_11ad_proxy-exp3.modinfo.txt" || true
nm -u "$GITHUB_WORKSPACE/msm_11ad_proxy-exp3.ko" | sort -u > "$GITHUB_WORKSPACE/msm_11ad_proxy-exp3.undefined.txt" || true

# OPPO TRINKET audio headers use an external-linkage C inline helper. Keep the
# semantics but make the helper private to each translation unit before the
# full matching audio graph is rebuilt by the next workflow step.
AUDIO_SND_EVENT="$GITHUB_WORKSPACE/source/android/vendor/qcom/opensource/audio-kernel/include/soc/snd_event.h"
test -f "$AUDIO_SND_EVENT"
if grep -q '^inline bool is_snd_event_fwk_enabled' "$AUDIO_SND_EVENT"; then
  sed -i 's/^inline bool is_snd_event_fwk_enabled/static inline bool is_snd_event_fwk_enabled/' "$AUDIO_SND_EVENT"
fi
grep -q '^static inline bool is_snd_event_fwk_enabled' "$AUDIO_SND_EVENT"
echo '[PASS] snd_event helper uses static inline for matching audio DLKM build'

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
VMLINUX="$OUT_DIR/vmlinux"
test -s "$IMAGE"
test -s "$VMLINUX"
test -s "$GITHUB_WORKSPACE/wlan-a16-exp1.ko"
test -s "$GITHUB_WORKSPACE/msm_11ad_proxy-exp3.ko"
grep -q '^CONFIG_BPF_STREAM_PARSER=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_STREAM_PARSER=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_NET_SOCK_MSG=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT_DIR/.config"
grep -q '^# CONFIG_MODULE_SIG_FORCE is not set$' "$OUT_DIR/.config"
grep -q '^CONFIG_MODVERSIONS=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_MSM_11AD=m$' "$OUT_DIR/.config"
nm "$VMLINUX" | grep -q ' sock_map_ops$'
nm "$VMLINUX" | grep -q ' sock_hash_ops$'
strings -a "$IMAGE" | grep -Fq 'A16-BPF compat uname:'
grep -q 'static int a16_unprivileged_bpf_handler' kernel/sysctl.c
grep -A10 'procname.*unprivileged_bpf_disabled' kernel/sysctl.c | grep -q 'extra1.*&zero'
grep -A10 'procname.*unprivileged_bpf_disabled' kernel/sysctl.c | grep -q 'extra2.*&two'
grep -Eq 'BTF_KIND_VAR[^0-9]*14' include/uapi/linux/btf.h
grep -Eq 'BTF_KIND_DATASEC[^0-9]*15' include/uapi/linux/btf.h
grep -q '\[BTF_KIND_VAR\].*= &var_ops' kernel/bpf/btf.c
grep -q '\[BTF_KIND_DATASEC\].*= &datasec_ops' kernel/bpf/btf.c
sha256sum "$IMAGE" | tee "$GITHUB_WORKSPACE/Image-btf-exp3.sha256"
cp -a "$OUT_DIR/Module.symvers" "$GITHUB_WORKSPACE/Module.symvers.a16-btf-exp3"
echo '[PASS] EXP3 preserves A16/root/sockmap, adds BTF support, A16 BPF sysctl compatibility, WLAN and 11ad ABI matches'
