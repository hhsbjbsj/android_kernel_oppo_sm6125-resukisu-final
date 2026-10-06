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

sync_github_env

if [ -z "${RESUKISU_COMMIT:-}" ] || [ "${RESUKISU_COMMIT:-}" = "auto" ] || [ "${RESUKISU_COMMIT:-}" = "main" ]; then
  RSHA=""
  for i in 1 2 3; do
    RSHA="$(git ls-remote https://github.com/Baka-SU/BakaSU.git refs/heads/main | awk '{print $1}')"
    [ -n "$RSHA" ] && break
    RSHA="$(git ls-remote https://github.com/ReSukiSU/ReSukiSU.git refs/heads/main | awk '{print $1}')"
    [ -n "$RSHA" ] && break
    sleep 2
  done
  if [ -n "$RSHA" ]; then
    echo "Resolved latest BakaSU (ReSukiSU) main commit: $RSHA"
    export RESUKISU_COMMIT="$RSHA"
    if [ -n "${GITHUB_ENV:-}" ] && [ -f "${GITHUB_ENV:-}" ]; then
      echo "RESUKISU_COMMIT=$RSHA" >> "$GITHUB_ENV"
    fi
  fi
fi

run_step 'Prepare successful WiFi step runner'
run_step 'Prepare successful EXP1 step runner'
run_step 'Prepare proven root step runner'
run_step 'Pin rootless baseline and prepare A16 step runner'
run_step 'Reproduce exact successful A16 source state'

echo '===== APPLY NABU ANDROID 17 VERIFIED EBPF SUITE FROM COMMIT ====='
git fetch --no-tags --depth=1 origin "$GITHUB_SHA"
git checkout "$GITHUB_SHA" -- \
  kernel/bpf \
  include/linux/bpf.h \
  include/linux/bpf-cgroup.h \
  include/linux/bpf_types.h \
  include/linux/bpf_verifier.h \
  include/linux/btf.h \
  include/linux/filter.h \
  include/linux/tnum.h \
  include/linux/uaccess.h \
  include/linux/atomic.h \
  include/linux/netdevice.h \
  include/net/sock.h \
  include/net/udp.h \
  include/net/addrconf.h \
  include/net/tcp.h \
  include/net/bpf_sk_storage.h \
  include/net/xdp.h \
  include/net/transp_v6.h \
  include/uapi/linux/bpf.h \
  include/uapi/linux/btf.h \
  mm/maccess.c \
  net/core/Makefile \
  net/core/filter.c \
  net/core/sock.c \
  net/core/bpf_sk_storage.c \
  net/core/xdp.c \
  net/ipv4/af_inet.c \
  net/ipv4/tcp_ipv4.c \
  net/ipv4/udp.c \
  net/ipv6/af_inet6.c \
  net/ipv6/tcp_ipv6.c \
  net/ipv6/udp.c \
  tools/include/linux/filter.h \
  tools/include/uapi/linux/bpf.h \
  tools/include/uapi/linux/btf.h \
  arch/arm64/net/bpf_jit_comp.c \
  include/linux/device_cgroup.h \
  kernel/trace/bpf_trace.c \
  drivers/net/imq_a16_xfrm_compat.h \
  drivers/net/tun.c \
  net/bpf/test_run.c \
  net/core/flow_dissector.c \
  net/ipv4/tcp.c \
  net/ipv4/tcp_ulp.c \
  net/ipv4/Makefile

rm -f kernel/bpf/vfs_mkobj_compat.* kernel/bpf/atomic_cond_read_compat.h

if grep -q "BPF_CGROUP_RUN_PROG_DEVICE_CGROUP" include/linux/device_cgroup.h 2>/dev/null; then
  sed -i '1i #ifndef BPF_CGROUP_RUN_PROG_DEVICE_CGROUP\n#define BPF_CGROUP_RUN_PROG_DEVICE_CGROUP(type, major, minor, access) 0\n#endif' include/linux/device_cgroup.h
fi

git add -A \
  kernel/bpf \
  kernel/trace/bpf_trace.c \
  drivers/net \
  include/linux \
  include/net \
  include/uapi/linux/bpf.h \
  include/uapi/linux/btf.h \
  mm/maccess.c \
  net/bpf \
  net/core \
  net/ipv4 \
  net/ipv6 \
  tools/include \
  arch/arm64/net/bpf_jit_comp.c
git commit -m 'feat(bpf): integrate Android 17-verified BPF suite from nabu' || true
echo '[PASS] Android 17 verified BPF suite from nabu overlaid onto SM6125 tree'

run_step 'Layer verified ReSukiSU SUSFS hooks'
run_step 'Patch netbpfload uname compatibility'
run_step 'Prepare proven A16 root config'

echo '===== SMOKE-COMPILE REPAIRED BPF CLOSURE BEFORE LONG BUILD ====='
unset LLVM LLVM_IAS KBUILD_COMPILER_STRING
make O="$OUT_DIR" ARCH=arm64 LOCALVERSION=+ \
  CC="$CC" REAL_CC="$REAL_CC" LD="$LD" \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  CLANG_TRIPLE="$CLANG_TRIPLE" \
  kernel/bpf/verifier.o kernel/bpf/core.o kernel/bpf/helpers.o kernel/bpf/syscall.o fs/proc/proc_sysctl.o kernel/trace/bpf_trace.o drivers/net/imq.o net/core/filter.o drivers/net/tun.o net/bpf/test_run.o net/core/flow_dissector.o net/ipv4/tcp.o net/core/dev.o net/ipv4/tcp_ipv4.o net/ipv4/tcp_ulp.o net/ipv4/udp.o net/ipv6/udp.o net/netfilter/xt_connmark.o net/netfilter/xt_mark.o net/core/xdp.o -j"$(nproc)"
test -s "$OUT_DIR/kernel/bpf/verifier.o"
test -s "$OUT_DIR/kernel/bpf/core.o"
test -s "$OUT_DIR/kernel/bpf/helpers.o"
test -s "$OUT_DIR/kernel/bpf/syscall.o"
test -s "$OUT_DIR/fs/proc/proc_sysctl.o"
test -s "$OUT_DIR/kernel/trace/bpf_trace.o"
test -s "$OUT_DIR/drivers/net/imq.o"
test -s "$OUT_DIR/net/core/filter.o"
test -s "$OUT_DIR/drivers/net/tun.o"
test -s "$OUT_DIR/net/bpf/test_run.o"
test -s "$OUT_DIR/net/core/flow_dissector.o"
test -s "$OUT_DIR/net/ipv4/tcp.o"
test -s "$OUT_DIR/net/core/dev.o"
test -s "$OUT_DIR/net/ipv4/tcp_ipv4.o"
test -s "$OUT_DIR/net/ipv4/tcp_ulp.o"
test -s "$OUT_DIR/net/ipv4/udp.o"
test -s "$OUT_DIR/net/ipv6/udp.o"
test -s "$OUT_DIR/net/netfilter/xt_connmark.o"
test -s "$OUT_DIR/net/netfilter/xt_mark.o"
test -s "$OUT_DIR/net/core/xdp.o"
echo '[PASS] repaired verifier/core/helpers/syscall/proc_sysctl/bpf_trace/imq/filter/tun/test_run/flow_dissector/tcp/dev/tcp_ipv4/tcp_ulp/udp/xt_connmark/xt_mark/xdp smoke compile before long build'

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
RUN16_BUILD_LOG="$GITHUB_WORKSPACE/run26-build.log"
verify_builtin_archive() {
  local rel="$1"
  local abs="$OUT_DIR/$rel"
  if [ -s "$abs" ]; then
    printf '[PASS] built-in archive retained: %s (%s bytes)\n' "$rel" "$(stat -c %s "$abs")"
    return 0
  fi
  if [ -s "$RUN16_BUILD_LOG" ] && grep -Fq "  AR      $rel" "$RUN16_BUILD_LOG"; then
    printf '[INFO] built-in archive was produced then discarded by final Kbuild link: %s\n' "$rel"
    return 0
  fi
  printf '[FATAL] no retained archive and no AR build evidence: %s\n' "$rel" >&2
  return 1
}

RUN16_ARCHIVES=(
  'techpack/audio/built-in.o'
  'techpack/audio/ipc/built-in.o'
  'techpack/audio/dsp/built-in.o'
  'techpack/audio/asoc/built-in.o'
  'techpack/audio/asoc/codecs/wcd934x/built-in.o'
  'techpack/audio/asoc/codecs/sia81xx/built-in.o'
  'drivers/staging/qcacld-3.0/built-in.o'
  'drivers/platform/msm/msm_11ad/built-in.o'
)
for rel in "${RUN16_ARCHIVES[@]}"; do
  verify_builtin_archive "$rel"
done

if [ -n "$(find "$OUT_DIR/techpack/audio" -type f -name '*.ko' -print -quit)" ]; then
  echo '[FATAL] audio .ko still produced in built-in experiment'
  find "$OUT_DIR/techpack/audio" -type f -name '*.ko' -print
  exit 91
fi
if [ -n "$(find "$OUT_DIR/drivers/staging/qcacld-3.0" -type f -name '*.ko' -print -quit)" ]; then
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

# Avoid false exit 141 under `set -o pipefail`: grep -q may exit as soon as it
# finds a match, which can SIGPIPE a still-writing nm/strings producer. Materialize
# the complete streams once, then validate the files.
RUN16_NM_ALL="$GITHUB_WORKSPACE/run16-vmlinux-nm-all.txt"
RUN16_STRINGS_ALL="$GITHUB_WORKSPACE/run16-image-strings-all.txt"
nm "$VMLINUX" > "$RUN16_NM_ALL"
strings -a "$IMAGE" > "$RUN16_STRINGS_ALL"

grep -Eq '[[:space:]]apr_probe$' "$RUN16_NM_ALL"
grep -Eq '[[:space:]]q6core_probe$' "$RUN16_NM_ALL"
grep -Eq '[[:space:]]tavil_cdc_mclk_enable$' "$RUN16_NM_ALL"
grep -Eq '[[:space:]]sia81xx_' "$RUN16_NM_ALL"
grep -Eq '[[:space:]]wlan_hdd_' "$RUN16_NM_ALL"
grep -Eq '[[:space:]]msm_11ad_probe$' "$RUN16_NM_ALL"
grep -Fq 'PCHM30 A16 late-DLKM: schedule APR child population from probe' "$RUN16_STRINGS_ALL"
grep -Fq 'PCHM30 A16 late-DLKM: AVS not ready, defer q6core probe' "$RUN16_STRINGS_ALL"
grep -Fq 'A16-BPF compat uname:' "$RUN16_STRINGS_ALL"
grep -q ' sock_map_ops$' "$RUN16_NM_ALL"
grep -q ' stack_map_ops$' "$RUN16_NM_ALL"
grep -q ' ringbuf_map_ops$' "$RUN16_NM_ALL"
grep -q ' sk_storage_map_ops$' "$RUN16_NM_ALL"

{
  echo '===== built-in archive evidence ====='
  for rel in "${RUN16_ARCHIVES[@]}"; do
    if [ -s "$OUT_DIR/$rel" ]; then
      stat -c '%s %n' "$OUT_DIR/$rel"
    else
      printf 'linked-and-discarded %s\n' "$rel"
    fi
  done
  echo '===== key vmlinux symbols ====='
  grep -E ' apr_probe$| q6core_probe$| tavil_cdc_mclk_enable$| sia81xx_| wlan_hdd_| msm_11ad_probe$' "$RUN16_NM_ALL" > "$GITHUB_WORKSPACE/run16-key-vmlinux-symbols.txt"
  head -n 140 "$GITHUB_WORKSPACE/run16-key-vmlinux-symbols.txt"
} | tee "$GITHUB_WORKSPACE/run16-builtin-proof.txt"

find "$OUT_DIR/techpack/audio" "$OUT_DIR/drivers/staging/qcacld-3.0" \
  -type f -name '*.ko' -print > "$GITHUB_WORKSPACE/run16-unwanted-ko.txt"
test ! -s "$GITHUB_WORKSPACE/run16-unwanted-ko.txt"

sha256sum "$IMAGE" | tee "$GITHUB_WORKSPACE/Image-run16-builtin.sha256"
cp -a "$OUT_DIR/Module.symvers" "$GITHUB_WORKSPACE/Module.symvers.run16-builtin"

echo '[PASS] Run16 links WLAN + msm_11ad + complete Run15 audio closure into vmlinux/Image; no matching KSU driver module required'
