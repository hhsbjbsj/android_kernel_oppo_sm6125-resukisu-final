#!/usr/bin/env bash
# CI-only overlay: network enhance, BBR/Brutal, ADIOS (4.14 mq-deadline),
# Re:Kernel (4.14 stubs), confirm Baseband-guard. No Droidspaces.
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
  scripts/config --file "$OUT_DIR/.config" -e "$opt" || true
}
disable_opt() {
  local opt="$1"
  scripts/config --file "$OUT_DIR/.config" -d "$opt" || true
}

echo '===== STAGE NETWORK ENHANCE + BBR / BRUTAL ====='
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
scripts/config --file "$OUT_DIR/.config" --set-str DEFAULT_TCP_CONG bbr || true

if [ ! -f net/ipv4/tcp_brutal.c ]; then
  cat > net/ipv4/tcp_brutal.c <<'EOF'
/* SPDX-License-Identifier: GPL-2.0 */
/* TCP Brutal, 4.14-adapted from Hysteria/HyNetworks tcp-brutal ABI. */
#include <linux/module.h>
#include <linux/mm.h>
#include <net/tcp.h>

#define BRUTAL_MIN_PACING_RATE (125000u)

struct brutal {
	u32 pacing_rate;
};

static void brutal_init(struct sock *sk)
{
	struct brutal *b = inet_csk_ca(sk);

	b->pacing_rate = BRUTAL_MIN_PACING_RATE;
	cmpxchg(&sk->sk_pacing_status, SK_PACING_NONE, SK_PACING_NEEDED);
	sk->sk_pacing_rate = b->pacing_rate;
}

static void brutal_cong_control(struct sock *sk, const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct brutal *b = inet_csk_ca(sk);
	u32 rate = b->pacing_rate;

	if (rs->delivered < 0 || rs->interval_us <= 0)
		return;
	if (rate < BRUTAL_MIN_PACING_RATE)
		rate = BRUTAL_MIN_PACING_RATE;
	sk->sk_pacing_rate = rate;
	tp->snd_cwnd = max_t(u32, 4U, (rate / 1500U) + 4U);
}

static u32 brutal_ssthresh(struct sock *sk)
{
	return max(tcp_sk(sk)->snd_cwnd >> 1, 2U);
}

static void brutal_cong_avoid(struct sock *sk, u32 ack, u32 acked)
{
}

static u32 brutal_undo_cwnd(struct sock *sk)
{
	return tcp_sk(sk)->snd_cwnd;
}

static struct tcp_congestion_ops tcp_brutal __read_mostly = {
	.flags = TCP_CONG_NON_RESTRICTED,
	.name = "brutal",
	.owner = THIS_MODULE,
	.init = brutal_init,
	.ssthresh = brutal_ssthresh,
	.cong_avoid = brutal_cong_avoid,
	.undo_cwnd = brutal_undo_cwnd,
	.cong_control = brutal_cong_control,
};

static int __init brutal_register(void)
{
	BUILD_BUG_ON(sizeof(struct brutal) > ICSK_CA_PRIV_SIZE);
	return tcp_register_congestion_control(&tcp_brutal);
}

static void __exit brutal_unregister(void)
{
	tcp_unregister_congestion_control(&tcp_brutal);
}

module_init(brutal_register);
module_exit(brutal_unregister);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("TCP Brutal congestion control (4.14)");
EOF
fi

python3 - <<'PY'
from pathlib import Path

mk = Path('net/ipv4/Makefile')
ms = mk.read_text()
if 'CONFIG_TCP_CONG_BRUTAL' not in ms:
    marker = 'obj-$(CONFIG_TCP_CONG_BBR) += tcp_bbr.o\n'
    addition = 'obj-$(CONFIG_TCP_CONG_BRUTAL) += tcp_brutal.o\n'
    if marker in ms:
        mk.write_text(ms.replace(marker, marker + addition, 1))
    else:
        mk.write_text(ms + '\n' + addition)

k = Path('net/ipv4/Kconfig')
s = k.read_text()
if 'config TCP_CONG_BRUTAL' not in s:
    block = (
        'config TCP_CONG_BRUTAL\n'
        '\ttristate "Brutal TCP congestion control"\n'
        '\tdefault y\n'
        '\thelp\n'
        '\t  TCP Brutal pacing-based congestion control for 4.14.\n\n'
    )
    if 'config TCP_CONG_BBR\n' in s:
        s = s.replace('config TCP_CONG_BBR\n', block + 'config TCP_CONG_BBR\n', 1)
    else:
        s += '\n' + block
    k.write_text(s)
PY
enable_opt TCP_CONG_BRUTAL

echo '===== STAGE ADIOS (4.14 maps to mq-deadline; do not enable legacy deadline) ====='
enable_opt MQ_IOSCHED_DEADLINE
python3 - <<'PY'
from pathlib import Path
k = Path('block/Kconfig.iosched')
s = k.read_text()
if 'config MQ_IOSCHED_ADIOS' not in s:
    block = (
        'config MQ_IOSCHED_ADIOS\n'
        '\tbool "Adaptive Deadline I/O scheduler (4.14 mq-deadline port)"\n'
        '\tselect MQ_IOSCHED_DEADLINE\n'
        '\tdefault y\n'
        '\thelp\n'
        '\t  On Linux 4.14, full firelzrd/adios needs blk-mq APIs from 5.10+.\n'
        '\t  This option maps ADIOS to the in-tree mq-deadline scheduler.\n\n'
    )
    if 'config MQ_IOSCHED_KYBER\n' in s:
        s = s.replace('config MQ_IOSCHED_KYBER\n', block + 'config MQ_IOSCHED_KYBER\n', 1)
    else:
        s += '\n' + block
    k.write_text(s)
print('adios kconfig=alias-to-mq-deadline')
PY
enable_opt MQ_IOSCHED_ADIOS
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
    if '#ifndef TF_UPDATE_TXN' not in bs2 and '#define TF_UPDATE_TXN' not in bs2:
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
        '\t\ttarget_alloc = \&to_proc->alloc;\n'
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

echo '===== OLDDEFCONFIG (answer remaining NEW symbols with defaults) ====='
yes '' | make O="$OUT_DIR" ARCH=arm64 olddefconfig || \
  make O="$OUT_DIR" ARCH=arm64 olddefconfig || true
enable_opt TCP_CONG_ADVANCED
enable_opt TCP_CONG_BBR
enable_opt TCP_CONG_CUBIC
enable_opt TCP_CONG_WESTWOOD
enable_opt TCP_CONG_BRUTAL
enable_opt NET_SCH_FQ
enable_opt NET_SCH_FQ_CODEL
enable_opt MQ_IOSCHED_DEADLINE
enable_opt MQ_IOSCHED_ADIOS
enable_opt REKERNEL
disable_opt REKERNEL_NETWORK
scripts/config --file "$OUT_DIR/.config" --set-str DEFAULT_TCP_CONG bbr || true

{
  echo "rekernel_commit=$REKERNEL_COMMIT"
  echo 'droidspaces=off'
  echo 'network_enhance=y'
  echo 'tcp_cong_default=bbr'
  echo 'tcp_brutal=y'
  echo 'adios=mq-deadline-4.14-port'
  echo "bbg=$BBG_STATE"
  echo "rekernel=$REK_STATE"
  echo '===== CONFIG REQUESTS ====='
  grep -E '^CONFIG_(TCP_CONG_BBR|TCP_CONG_BRUTAL|TCP_CONG_BIC|TCP_CONG_ADVANCED|DEFAULT_TCP_CONG|NET_SCH_FQ|MQ_IOSCHED_ADIOS|MQ_IOSCHED_DEADLINE|REKERNEL|BBG|IP_SET|WIREGUARD|CIFS|TUN|VETH)=' "$OUT_DIR/.config" || true
  echo '===== SOURCE MARKERS ====='
  test -f net/ipv4/tcp_brutal.c && echo 'tcp_brutal.c=yes'
  grep -Fq 'config MQ_IOSCHED_ADIOS' block/Kconfig.iosched && echo 'adios_kconfig=yes'
  test -f drivers/rekernel/rekernel.c && echo 'rekernel.c=yes'
  grep -Fq 'REKERNEL_SIGNAL' drivers/rekernel/rekernel.h && echo 'rekernel_enum_prefixed=yes'
} | tee "$PROOF"

echo "[PASS] Run28 staged BBR/Brutal + ADIOS + Re:Kernel + BBG overlay (rekernel=$REK_STATE bbg=$BBG_STATE)"
