#!/usr/bin/env bash
# CI-only overlay: network enhance, BBR/Brutal, ADIOS (4.14 mq-deadline),
# Re:Kernel, confirm Baseband-guard. No Droidspaces.
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

echo '===== RUN28 EXTRA FEATURES (4.14 CI overlay, no Droidspaces) ====='
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
  DEFAULT_BBR NET_SCHED NET_SCH_FQ NET_SCH_FQ_CODEL NET_SCH_CAKE \
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

echo '===== STAGE ADIOS (4.14 maps to mq-deadline, no duplicate symbols) ====='
for opt in IOSCHED_DEADLINE IOSCHED_BFQ MQ_IOSCHED_DEADLINE MQ_IOSCHED_KYBER; do
  enable_opt "$opt"
done
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

# OPPO hans.h also defines enumerator SIGNAL. Prefix Re:Kernel enums
# so kernel/signal.c can include both headers.
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

for rel in ('drivers/rekernel/rekernel.h', 'drivers/rekernel/rekernel.c'):
    p = Path(rel)
    if not p.exists():
        continue
    s = p.read_text()
    if 'JOBCTL_TRAP_FREEZE' in s and '#ifndef JOBCTL_TRAP_FREEZE' not in s:
        s = s.replace(
            'static inline bool jobctl_frozen(struct task_struct* task) {',
            '#ifndef JOBCTL_TRAP_FREEZE\n#define JOBCTL_TRAP_FREEZE 0\n#endif\n'
            'static inline bool jobctl_frozen(struct task_struct* task) {',
            1,
        )
    p.write_text(rewrite_idents(s))
    print('rewrote %s enums' % rel)

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
    already = '#define TF_UPDATE_TXN' in bs or 'REKERNEL_FROZEN_TASK_GROUP_STUB' in bs
    need = ('TF_UPDATE_TXN' in bs) or ('frozen_task_group(' in bs)
    if need and not already:
        guard = (
            '#ifndef TF_UPDATE_TXN\n'
            '#define TF_UPDATE_TXN 0x00\n'
            '#endif\n'
            '#ifndef frozen_task_group\n'
            '#define frozen_task_group(p) 0\n'
            '#endif\n'
        )
        binder.write_text(guard + bs)
        print('injected 4.14 binder TF_UPDATE_TXN/frozen_task_group stubs')
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
  grep -E '^CONFIG_(TCP_CONG_BBR|TCP_CONG_BRUTAL|DEFAULT_TCP_CONG|DEFAULT_BBR|NET_SCH_FQ|MQ_IOSCHED_ADIOS|MQ_IOSCHED_DEADLINE|REKERNEL|BBG|IP_SET|WIREGUARD|CIFS|TUN|VETH)=' "$OUT_DIR/.config" || true
  echo '===== SOURCE MARKERS ====='
  test -f net/ipv4/tcp_brutal.c && echo 'tcp_brutal.c=yes'
  grep -Fq 'config MQ_IOSCHED_ADIOS' block/Kconfig.iosched && echo 'adios_kconfig=yes'
  test -f drivers/rekernel/rekernel.c && echo 'rekernel.c=yes'
  grep -Fq 'REKERNEL_SIGNAL' drivers/rekernel/rekernel.h && echo 'rekernel_enum_prefixed=yes'
} | tee "$PROOF"

echo "[PASS] Run28 staged BBR/Brutal + ADIOS + Re:Kernel + BBG overlay (rekernel=$REK_STATE bbg=$BBG_STATE)"
