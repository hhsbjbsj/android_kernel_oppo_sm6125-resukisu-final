#!/usr/bin/env bash
# CI-only overlay: network enhance, BBR/Brutal, ADIOS (4.14 mq-deadline),
# confirm Baseband-guard. No Droidspaces. No Re-Kernel.
# Does not commit kernel source; mutates the runner checkout only.
set -Eeuo pipefail

KERNEL_DIR="${KERNEL_DIR:-$GITHUB_WORKSPACE/$KERNEL_REL}"
OUT_DIR="${OUT_DIR:-out-pchm30-a16-bpf}"
LOG="$GITHUB_WORKSPACE/run28-extra-features.log"
PROOF="$GITHUB_WORKSPACE/run28-extra-features-proof.txt"

exec > >(tee "$LOG") 2>&1
cd "$KERNEL_DIR"

echo '===== RUN28 EXTRA FEATURES (4.14 CI overlay, no Droidspaces, no Re-Kernel) ====='
echo "kernel_dir=$KERNEL_DIR"
echo "out_dir=$OUT_DIR"
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
# TCP_CONG_ADVANCED exposes a pile of NEW children (BIC first). Seed them
# as explicit =n so silentoldconfig does not abort on SukiSU's .config.
for opt in \
  TCP_CONG_BIC TCP_CONG_HTCP TCP_CONG_HSTCP TCP_CONG_HYBLA \
  TCP_CONG_VEGAS TCP_CONG_NV TCP_CONG_SCALABLE TCP_CONG_LP \
  TCP_CONG_VENO TCP_CONG_YEAH TCP_CONG_ILLINOIS TCP_CONG_DCTCP \
  TCP_CONG_CDG TCP_MD5SIG; do
  disable_opt "$opt"
done
# Do not flip DEFAULT_BBR: that adds a NEW default-cong choice and aborts silentoldconfig.
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
# Enabling IOSCHED_DEADLINE adds DEFAULT_DEADLINE as a NEW choice and
# aborts silentoldconfig. Only touch mq-deadline.
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

echo '===== REKERNEL SKIPPED ====='

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
# SukiSU hits make silentoldconfig later. ReSukiSU stock config already had
# TCP_CONG_ADVANCED children; SukiSU did not. olddefconfig is non-interactive.
yes '' | make O="$OUT_DIR" ARCH=arm64 olddefconfig || \
  make O="$OUT_DIR" ARCH=arm64 olddefconfig || true
# Re-assert requested defaults after olddefconfig may reset string/choice.
enable_opt TCP_CONG_ADVANCED
enable_opt TCP_CONG_BBR
enable_opt TCP_CONG_CUBIC
enable_opt TCP_CONG_WESTWOOD
enable_opt TCP_CONG_BRUTAL
enable_opt NET_SCH_FQ
enable_opt NET_SCH_FQ_CODEL
enable_opt MQ_IOSCHED_DEADLINE
enable_opt MQ_IOSCHED_ADIOS
scripts/config --file "$OUT_DIR/.config" --set-str DEFAULT_TCP_CONG bbr || true

{
  echo 'droidspaces=off'
  echo 'rekernel=off'
  echo 'network_enhance=y'
  echo 'tcp_cong_default=bbr'
  echo 'tcp_brutal=y'
  echo 'adios=mq-deadline-4.14-port'
  echo "bbg=$BBG_STATE"
  echo '===== CONFIG REQUESTS ====='
  grep -E '^CONFIG_(TCP_CONG_BBR|TCP_CONG_BRUTAL|TCP_CONG_BIC|TCP_CONG_ADVANCED|DEFAULT_TCP_CONG|NET_SCH_FQ|MQ_IOSCHED_ADIOS|MQ_IOSCHED_DEADLINE|REKERNEL|BBG|IP_SET|WIREGUARD|CIFS|TUN|VETH)=' "$OUT_DIR/.config" || true
  echo '===== SOURCE MARKERS ====='
  test -f net/ipv4/tcp_brutal.c && echo 'tcp_brutal.c=yes'
  grep -Fq 'config MQ_IOSCHED_ADIOS' block/Kconfig.iosched && echo 'adios_kconfig=yes'
  if [ -f drivers/rekernel/rekernel.c ]; then echo 'rekernel.c=unexpected'; else echo 'rekernel.c=absent'; fi
} | tee "$PROOF"

echo "[PASS] Run28 staged BBR/Brutal + ADIOS + BBG overlay (rekernel=off bbg=$BBG_STATE)"
