#!/usr/bin/env bash
# CI-only overlay: BBR configuration, in-tree mq-deadline, Re:Kernel and
# Baseband-guard. No TCP Brutal stand-in, ADIOS alias, or Droidspaces.
# Does not commit kernel source; mutates the runner checkout only.
set -Eeuo pipefail

KERNEL_DIR="${KERNEL_DIR:-$GITHUB_WORKSPACE/$KERNEL_REL}"
OUT_DIR="${OUT_DIR:-out-pchm30-a16-bpf}"
REKERNEL_REPO="${REKERNEL_REPO:-https://github.com/Sakion-Team/Re-Kernel.git}"
REKERNEL_COMMIT="${REKERNEL_COMMIT:-5adec4896a549af60fab2ab59441a777551763b9}"
LOG="$GITHUB_WORKSPACE/run28-extra-features.log"
PROOF="$GITHUB_WORKSPACE/run28-extra-features-proof.txt"

exec > >(tee "$LOG") 2>&1
cd "$KERNEL_DIR"

echo '===== RUN28 EXTRA FEATURES (4.14 CI overlay, Re-Kernel on, no Droidspaces) ====='
echo "kernel_dir=$KERNEL_DIR"
echo "out_dir=$OUT_DIR"
echo "rekernel_commit=$REKERNEL_COMMIT"
test -f "$OUT_DIR/.config"
test -x scripts/config

enable_opt() {
  local opt="$1"
  scripts/config --file "$OUT_DIR/.config" -e "$opt"
}
disable_opt() {
  local opt="$1"
  scripts/config --file "$OUT_DIR/.config" -d "$opt"
}

select_bbr_default() {
  # DEFAULT_TCP_CONG is a derived string. Set the Kconfig choice itself so
  # olddefconfig cannot restore the previous DEFAULT_CUBIC selection.
  local opt
  for opt in DEFAULT_BIC DEFAULT_CUBIC DEFAULT_HTCP DEFAULT_HYBLA \
    DEFAULT_VEGAS DEFAULT_VENO DEFAULT_WESTWOOD DEFAULT_DCTCP DEFAULT_CDG \
    DEFAULT_RENO; do
    disable_opt "$opt"
  done
  enable_opt DEFAULT_BBR
}

echo '===== STAGE NETWORK CONFIGURATION + BBR ====='
for opt in \
  TCP_CONG_ADVANCED TCP_CONG_BBR TCP_CONG_CUBIC TCP_CONG_WESTWOOD \
  NET_SCHED NET_SCH_FQ NET_SCH_FQ_CODEL \
  IP_SET IP_SET_HASH_IP IP_SET_HASH_NET NETFILTER_XT_SET \
  NETFILTER NETFILTER_ADVANCED NF_CONNTRACK \
  IP_NF_IPTABLES IP_NF_FILTER NF_NAT IP_NF_NAT \
  IP_NF_TARGET_MASQUERADE NETFILTER_XT_TARGET_MASQUERADE \
  NETFILTER_XT_TARGET_TCPMSS NETFILTER_XT_MATCH_ADDRTYPE \
  IP_NF_TARGET_TTL IP6_NF_IPTABLES IP6_NF_FILTER IP6_NF_TARGET_HL \
  IP6_NF_MATCH_HL NETFILTER_XT_TARGET_LOG NETFILTER_XT_MATCH_COMMENT \
  NETFILTER_XT_MATCH_MULTIPORT \
  IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES \
  TUN VETH CIFS CIFS_XATTR CIFS_POSIX WIREGUARD; do
  enable_opt "$opt"
done
# TCP_CONG_ADVANCED exposes NEW children (BIC first). Seed them as =n so
# SukiSU silentoldconfig does not abort.
for opt in \
  TCP_CONG_BIC TCP_CONG_HTCP TCP_CONG_HSTCP TCP_CONG_HYBLA \
  TCP_CONG_VEGAS TCP_CONG_NV TCP_CONG_SCALABLE TCP_CONG_LP \
  TCP_CONG_VENO TCP_CONG_YEAH TCP_CONG_ILLINOIS TCP_CONG_DCTCP \
  TCP_CONG_CDG TCP_MD5SIG; do
  disable_opt "$opt"
done
select_bbr_default

# The previous stand-in fixed TCP pacing at 125000 bytes/s and did not
# implement the TCP Brutal control API. Stop compiling that feature.
disable_opt TCP_CONG_BRUTAL

# Keep the actual in-tree scheduler; an extra Kconfig alias is not ADIOS.
disable_opt MQ_IOSCHED_ADIOS
enable_opt MQ_IOSCHED_DEADLINE

echo '===== STAGE REKERNEL ====='
REK_SRC="$GITHUB_WORKSPACE/.run28-rekernel"
REK_STATE='pending'
rm -rf "$REK_SRC"
git init -q "$REK_SRC"
git -C "$REK_SRC" remote add origin "$REKERNEL_REPO"
git -C "$REK_SRC" fetch --no-tags --depth=1 origin "$REKERNEL_COMMIT"
git -C "$REK_SRC" checkout -q --detach FETCH_HEAD
test -f "$REK_SRC/Integrate/patches.sh"
chmod +x "$REK_SRC/Integrate/patches.sh"
set +e
bash "$REK_SRC/Integrate/patches.sh"
REK_RC=$?
set -e

python3 - <<'PY'
from pathlib import Path
import re

renames = {
    'BINDER': 'REKERNEL_BINDER',
    'SIGNAL': 'REKERNEL_SIGNAL',
    'NETWORK': 'REKERNEL_NETWORK',
    'REPLY': 'REKERNEL_REPLY',
    'TRANSACTION': 'REKERNEL_TRANSACTION',
    'OVERFLOW': 'REKERNEL_OVERFLOW',
}

def rewrite_idents(text):
    for old, new in renames.items():
        text = re.sub(r'\b' + old + r'\b', new, text)
    return text

# Remove any previous pre-include stub that called frozen()/freezing()
# before linux/types.h and linux/freezer.h were visible.
pre_stub_re = re.compile(
    r'(?:#ifndef JOBCTL_TRAP_FREEZE[\s\S]*?)?'
    r'static inline bool rekernel_frozen_task_group\(struct task_struct \*?task\)\s*'
    r'\{[\s\S]*?\}\s*',
    re.M,
)

hdr = Path('drivers/rekernel/rekernel.h')
if hdr.exists():
    s = hdr.read_text()
    s = pre_stub_re.sub('', s, count=1)
    if '#include <linux/sched.h>' not in s:
        s = s.replace('#include <linux/types.h>\n',
                      '#include <linux/types.h>\n#include <linux/sched.h>\n', 1)
    if '#ifndef JOBCTL_TRAP_FREEZE' not in s:
        needle = '#include <linux/freezer.h>\n'
        guard = (
            '#include <linux/freezer.h>\n'
            '#ifndef JOBCTL_TRAP_FREEZE\n'
            '#define JOBCTL_TRAP_FREEZE 0\n'
            '#endif\n'
        )
        if needle in s:
            s = s.replace(needle, guard, 1)
        else:
            s = '#ifndef JOBCTL_TRAP_FREEZE\n#define JOBCTL_TRAP_FREEZE 0\n#endif\n' + s
    s = s.replace('frozen_task_group(', 'rekernel_frozen_task_group(')
    s = rewrite_idents(s)
    hdr.write_text(s)
    print('rewrote drivers/rekernel/rekernel.h after includes')

src = Path('drivers/rekernel/rekernel.c')
if src.exists():
    s = src.read_text()
    s = pre_stub_re.sub('', s, count=1)
    s = s.replace('frozen_task_group(', 'rekernel_frozen_task_group(')
    s = rewrite_idents(s)
    src.write_text(s)
    print('rewrote drivers/rekernel/rekernel.c enums only (no pre-include stub)')

sig = Path('kernel/signal.c')
if sig.exists():
    s = sig.read_text()
    n = s.replace('rekernel_report(SIGNAL,', 'rekernel_report(REKERNEL_SIGNAL,')
    if n != s:
        sig.write_text(n)
        print('rewrote kernel/signal.c rekernel_report type')

binder = Path('drivers/android/binder.c')
if binder.exists():
    bs = binder.read_text()
    bs2 = bs.replace('frozen_task_group(', 'rekernel_frozen_task_group(')
    bs2 = bs2.replace('rekernel_report(BINDER,', 'rekernel_report(REKERNEL_BINDER,')
    if 'if ((t->flags & TF_UPDATE_TXN) && rekernel_frozen_task_group(proc->tsk)) {' in bs2:
        bs2 = bs2.replace(
            'if ((t->flags & TF_UPDATE_TXN) && rekernel_frozen_task_group(proc->tsk)) {',
            'if ((t->flags & TF_UPDATE_TXN) && (rekernel_frozen_task_group(proc->tsk) || proc->is_frozen)) {'
        )
    bh = Path('include/uapi/linux/android/binder.h')
    has_uapi_tf = bh.exists() and 'TF_UPDATE_TXN' in bh.read_text()
    if not has_uapi_tf and '#ifndef TF_UPDATE_TXN' not in bs2 and '#define TF_UPDATE_TXN' not in bs2:
        guard = (
            '#ifndef TF_UPDATE_TXN\n'
            '#define TF_UPDATE_TXN 0x40\n'
            '#endif\n'
        )
        bs2 = guard + bs2
        print('injected 4.14 binder TF_UPDATE_TXN stub')
    if '#include <../rekernel/rekernel.h>' not in bs2:
        hook_inc = (
            '#ifdef CONFIG_REKERNEL\n'
            '#include <../rekernel/rekernel.h>\n'
            '#endif /* CONFIG_REKERNEL */\n'
        )
        bs2 = hook_inc + bs2
        print('injected rekernel.h include into binder.c')
    helper = (
        '#ifdef CONFIG_REKERNEL\n'
        'void rekernel_binder_transaction(bool reply, struct binder_transaction *t,\n'
        '\t\tstruct binder_node *target_node, struct binder_transaction_data *tr)\n'
        '{\n'
        '\tstruct binder_proc *to_proc;\n'
        '\tstruct binder_alloc *target_alloc;\n'
        '\tif (!t || !t->to_proc)\n'
        '\t\treturn;\n'
        '\tto_proc = t->to_proc;\n'
        '\tif (reply)\n'
        '\t\tbinder_reply_handler(task_tgid_nr(current), current, to_proc->pid, to_proc->tsk, false, tr);\n'
        '\telse if (t->from && t->from->proc)\n'
        '\t\tbinder_trans_handler(t->from->proc->pid, t->from->proc->tsk, to_proc->pid, to_proc->tsk, false, tr);\n'
        '\telse {\n'
        '\t\tbinder_trans_handler(task_tgid_nr(current), current, to_proc->pid, to_proc->tsk, true, tr);\n'
        '\t\ttarget_alloc = &to_proc->alloc;\n'
        '\t\tif (target_alloc->free_async_space < (target_alloc->buffer_size / 10 + 0x300))\n'
        '\t\t\tbinder_overflow_handler(task_tgid_nr(current), current, to_proc->pid, to_proc->tsk, true, tr);\n'
        '\t}\n'
        '}\n'
        '#endif /* CONFIG_REKERNEL */\n'
    )
    if 'void rekernel_binder_transaction(' not in bs2:
        needle_fn = 'trace_binder_transaction(reply, t, target_node);'
        if needle_fn in bs2:
            bs2 = bs2.replace(needle_fn, helper + '\t' + needle_fn, 1)
            print('injected rekernel_binder_transaction helper')
        else:
            bs2 = helper + bs2
            print('prepended rekernel_binder_transaction helper')
    if 'rekernel_binder_transaction(reply, t, target_node, tr);' not in bs2:
        needle = 'trace_binder_transaction(reply, t, target_node);'
        call = (
            '#ifdef CONFIG_REKERNEL\n'
            '\trekernel_binder_transaction(reply, t, target_node, tr);\n'
            '#endif /* CONFIG_REKERNEL */\n'
            '\t' + needle
        )
        if needle in bs2:
            bs2 = bs2.replace(needle, call, 1)
            print('fallback hooked trace_binder_transaction')
        else:
            print('no trace_binder_transaction needle; hooks may be partial')
    if bs2 != bs:
        binder.write_text(bs2)
        print('rewrote drivers/android/binder.c 4.14 compat')
PY

enable_opt REKERNEL
disable_opt REKERNEL_NETWORK
if [ -f drivers/rekernel/rekernel.c ] && grep -Fq 'source "drivers/rekernel/Kconfig"' drivers/Kconfig && grep -Fq 'obj-$(CONFIG_REKERNEL) += rekernel/' drivers/Makefile; then
  if grep -Fq 'rekernel_binder_transaction' drivers/android/binder.c && grep -Fq 'rekernel_report' kernel/signal.c; then
    REK_STATE='y-hooks'
  else
    REK_STATE='y-source-hooks-partial'
  fi
else
  REK_STATE="copy-failed-rc${REK_RC}"
fi

echo '===== CONFIRM BBG ====='
if [ -L security/baseband-guard ] || [ -d security/baseband-guard ]; then
  enable_opt SECURITY
  enable_opt BBG
  disable_opt BBG_BLOCK_BOOT
  disable_opt BBG_BLOCK_RECOVERY
  BBG_STATE='present'
else
  BBG_STATE='missing-run17-not-applied'
fi

# Request all required options before Kconfig resolves their dependencies.
enable_opt TCP_CONG_ADVANCED
enable_opt TCP_CONG_BBR
enable_opt TCP_CONG_CUBIC
enable_opt TCP_CONG_WESTWOOD
disable_opt TCP_CONG_BRUTAL
enable_opt NET_SCH_FQ
enable_opt NET_SCH_FQ_CODEL
enable_opt MQ_IOSCHED_DEADLINE
disable_opt MQ_IOSCHED_ADIOS
enable_opt REKERNEL
disable_opt REKERNEL_NETWORK
select_bbr_default

echo '===== RESOLVE AND VERIFY FINAL CONFIGURATION ====='
# olddefconfig is noninteractive. A failure must stop the build, rather than
# emitting a proof for options which Kconfig has never accepted.
make_args=(O="$OUT_DIR" ARCH=arm64 LOCALVERSION=+)
for compiler_var in CC REAL_CC LD CROSS_COMPILE CROSS_COMPILE_ARM32 CLANG_TRIPLE; do
  if [ -n "${!compiler_var:-}" ]; then
    make_args+=("$compiler_var=${!compiler_var}")
  fi
done
make "${make_args[@]}" olddefconfig
grep -Fxq 'CONFIG_TCP_CONG_BBR=y' "$OUT_DIR/.config"
grep -Fxq 'CONFIG_DEFAULT_BBR=y' "$OUT_DIR/.config"
grep -Fxq 'CONFIG_DEFAULT_TCP_CONG="bbr"' "$OUT_DIR/.config"
grep -Fxq 'CONFIG_NET_SCH_FQ=y' "$OUT_DIR/.config"
grep -Fxq 'CONFIG_MQ_IOSCHED_DEADLINE=y' "$OUT_DIR/.config"
grep -Fxq 'CONFIG_REKERNEL=y' "$OUT_DIR/.config"
! grep -Eq '^CONFIG_(TCP_CONG_BRUTAL|MQ_IOSCHED_ADIOS)=[ym]$' "$OUT_DIR/.config"

{
  echo "rekernel_commit=$REKERNEL_COMMIT"
  echo 'droidspaces=off'
  echo 'network_enhance=configuration_only'
  echo 'tcp_cong_default=bbr'
  echo 'tcp_brutal=disabled'
  echo 'adios=not_integrated'
  echo 'io_scheduler=mq-deadline-built'
  echo "bbg=$BBG_STATE"
  echo "rekernel=$REK_STATE"
  echo '===== RESOLVED CONFIGURATION ====='
  grep -E '^CONFIG_(TCP_CONG_BBR|TCP_CONG_BRUTAL|TCP_CONG_BIC|TCP_CONG_ADVANCED|DEFAULT_BBR|DEFAULT_TCP_CONG|NET_SCH_FQ|MQ_IOSCHED_ADIOS|MQ_IOSCHED_DEADLINE|REKERNEL|BBG|IP_SET|WIREGUARD|CIFS|TUN|VETH)=' "$OUT_DIR/.config"
  echo '===== SOURCE MARKERS ====='
  test -f drivers/rekernel/rekernel.c && echo 'rekernel.c=yes'
  grep -Fq 'REKERNEL_SIGNAL' drivers/rekernel/rekernel.h && echo 'rekernel_enum_prefixed=yes'
} | tee "$PROOF"

echo "[PASS] BBR default and mq-deadline configuration verified; TCP Brutal and ADIOS disabled (rekernel=$REK_STATE bbg=$BBG_STATE)"
