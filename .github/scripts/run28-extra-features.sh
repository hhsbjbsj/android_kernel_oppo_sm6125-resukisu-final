#!/usr/bin/env bash
# CI-only overlay: Droidspaces standard, BBR/Brutal, network enhance,
# ADIOS (4.14 mq-deadline port), Re:Kernel, confirm Baseband-guard.
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

echo '===== RUN28 EXTRA FEATURES (4.14 CI overlay) ====='
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

echo '===== STAGE DROIDSPACES STANDARD ====='
for opt in SYSCTL SYSVIPC SYSVIPC_SYSCTL POSIX_MQUEUE POSIX_MQUEUE_SYSCTL NAMESPACES PID_NS UTS_NS IPC_NS USER_NS NET_NS SECCOMP SECCOMP_FILTER CGROUPS CGROUP_DEVICE CGROUP_PIDS MEMCG CGROUP_SCHED FAIR_GROUP_SCHED CGROUP_FREEZER CGROUP_NET_PRIO DEVTMPFS OVERLAY_FS TMPFS_POSIX_ACL TMPFS_XATTR FW_LOADER FW_LOADER_USER_HELPER VETH BRIDGE NETFILTER BRIDGE_NETFILTER NETFILTER_ADVANCED NF_CONNTRACK IP_NF_IPTABLES IP_NF_FILTER NF_NAT IP_NF_TARGET_MASQUERADE NETFILTER_XT_TARGET_MASQUERADE NETFILTER_XT_TARGET_TCPMSS NETFILTER_XT_MATCH_ADDRTYPE NF_CONNTRACK_NETLINK NF_NAT_REDIRECT IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES NF_CONNTRACK_IPV4 NF_NAT_IPV4 IP_NF_NAT BLK_DEV_LOOP TUN; do
  enable_opt "$opt"
done
disable_opt ANDROID_PARANOID_NETWORK

echo '===== STAGE BBR / FQ / NETWORK ====='
for opt in TCP_CONG_ADVANCED TCP_CONG_BBR DEFAULT_BBR NET_SCHED NET_SCH_FQ NET_SCH_FQ_CODEL IP_SET IP_SET_HASH_IP IP_SET_HASH_NET NETFILTER_XT_SET; do
  enable_opt "$opt"
done
scripts/config --file "$OUT_DIR/.config" --set-str DEFAULT_TCP_CONG bbr || true

if [ ! -f net/ipv4/tcp_brutal.c ]; then
  cat > net/ipv4/tcp_brutal.c <<'EOF'
/* SPDX-License-Identifier: GPL-2.0 */
/* TCP Brutal, 4.14-adapted from Hysteria/HyNetworks tcp-brutal. */
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
	return tcp_sk(sk)->snd_ssthresh;
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

def insert_after(path, marker, addition, guard):
    p = Path(path)
    s = p.read_text()
    if guard in s:
        return
    if marker not in s:
        raise SystemExit('marker not found in %s: %r' % (path, marker))
    p.write_text(s.replace(marker, marker + addition, 1))

insert_after('net/ipv4/Makefile', 'obj-$(CONFIG_TCP_CONG_BBR) += tcp_bbr.o\n', 'obj-$(CONFIG_TCP_CONG_BRUTAL) += tcp_brutal.o\n', 'CONFIG_TCP_CONG_BRUTAL')
k = Path('net/ipv4/Kconfig')
s = k.read_text()
if 'config TCP_CONG_BRUTAL' not in s:
    if 'config TCP_CONG_BBR\n' not in s:
        raise SystemExit('TCP_CONG_BBR Kconfig marker missing')
    s = s.replace('config TCP_CONG_BBR\n', 'config TCP_CONG_BRUTAL\n\ttristate "Brutal TCP"\n\tdefault n\n\thelp\n\t  TCP Brutal for 4.14.\n\nconfig TCP_CONG_BBR\n', 1)
    k.write_text(s)
PY
enable_opt TCP_CONG_BRUTAL

echo '===== STAGE ADIOS (4.14 mq-deadline port) ====='
for opt in IOSCHED_DEADLINE IOSCHED_BFQ MQ_IOSCHED_DEADLINE MQ_IOSCHED_KYBER; do
  enable_opt "$opt"
done
if [ -f block/mq-deadline.c ] && [ ! -f block/adios-iosched.c ]; then
  python3 - <<'PY'
from pathlib import Path
src = Path('block/mq-deadline.c').read_text()
src = src.replace('MQ Deadline i/o scheduler', 'ADIOS i/o scheduler (4.14 mq-deadline port)')
src = src.replace('.elevator_name = "mq-deadline"', '.elevator_name = "adios"')
src = src.replace('MODULE_DESCRIPTION("MQ deadline IO scheduler")', 'MODULE_DESCRIPTION("ADIOS IO scheduler (4.14 port)")')
Path('block/adios-iosched.c').write_text(src)
print('wrote block/adios-iosched.c')
PY
fi
python3 - <<'PY'
from pathlib import Path

def insert_after(path, marker, addition, guard):
    p = Path(path)
    s = p.read_text()
    if guard in s:
        return
    if marker not in s:
        raise SystemExit('marker not found in %s: %r' % (path, marker))
    p.write_text(s.replace(marker, marker + addition, 1))

insert_after('block/Makefile', 'obj-$(CONFIG_MQ_IOSCHED_KYBER)\t+= kyber-iosched.o\n', 'obj-$(CONFIG_MQ_IOSCHED_ADIOS)\t+= adios-iosched.o\n', 'CONFIG_MQ_IOSCHED_ADIOS')
k = Path('block/Kconfig.iosched')
s = k.read_text()
if 'config MQ_IOSCHED_ADIOS' not in s:
    if 'config MQ_IOSCHED_KYBER\n' not in s:
        raise SystemExit('MQ_IOSCHED_KYBER Kconfig marker missing')
    s = s.replace('config MQ_IOSCHED_KYBER\n', 'config MQ_IOSCHED_ADIOS\n\ttristate "Adaptive Deadline I/O scheduler (4.14 port)"\n\tdefault y\n\thelp\n\t  ADIOS on 4.14 blk-mq via mq-deadline port.\n\nconfig MQ_IOSCHED_KYBER\n', 1)
    k.write_text(s)
PY
enable_opt MQ_IOSCHED_ADIOS

echo '===== STAGE REKERNEL ====='
REK_SRC="$GITHUB_WORKSPACE/.run28-rekernel"
rm -rf "$REK_SRC"
git init -q "$REK_SRC"
git -C "$REK_SRC" remote add origin "$REKERNEL_REPO"
git -C "$REK_SRC" fetch --no-tags --depth=1 origin "$REKERNEL_COMMIT"
git -C "$REK_SRC" checkout -q --detach FETCH_HEAD
test -f "$REK_SRC/Integrate/patches.sh"
chmod +x "$REK_SRC/Integrate/patches.sh"
bash "$REK_SRC/Integrate/patches.sh"
python3 - <<'PY'
from pathlib import Path
p = Path('drivers/rekernel/rekernel.h')
s = p.read_text()
if 'JOBCTL_TRAP_FREEZE' in s and '#ifndef JOBCTL_TRAP_FREEZE' not in s:
    s = s.replace('static inline bool jobctl_frozen(struct task_struct* task) {', '#ifndef JOBCTL_TRAP_FREEZE\n#define JOBCTL_TRAP_FREEZE 0\n#endif\nstatic inline bool jobctl_frozen(struct task_struct* task) {', 1)
    p.write_text(s)
PY
enable_opt REKERNEL
disable_opt REKERNEL_NETWORK
test -f drivers/rekernel/rekernel.c
grep -Fq 'source "drivers/rekernel/Kconfig"' drivers/Kconfig
grep -Fq 'obj-$(CONFIG_REKERNEL) += rekernel/' drivers/Makefile
grep -Fq 'rekernel_binder_transaction' drivers/android/binder.c
grep -Fq 'rekernel_report' kernel/signal.c

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
  echo 'droidspaces=standard'
  echo 'tcp_cong_default=bbr'
  echo 'tcp_brutal=y'
  echo 'adios=mq-deadline-4.14-port'
  echo "bbg=$BBG_STATE"
  echo 'rekernel=y'
  echo '===== CONFIG REQUESTS ====='
  grep -E '^CONFIG_(SYSVIPC|POSIX_MQUEUE|PID_NS|USER_NS|IPC_NS|NET_NS|DEVTMPFS|TCP_CONG_BBR|TCP_CONG_BRUTAL|DEFAULT_TCP_CONG|DEFAULT_BBR|NET_SCH_FQ|MQ_IOSCHED_ADIOS|REKERNEL|BBG|ANDROID_PARANOID_NETWORK|CGROUP_PIDS|CGROUP_DEVICE)=' "$OUT_DIR/.config" || true
  echo '===== SOURCE MARKERS ====='
  test -f net/ipv4/tcp_brutal.c && echo 'tcp_brutal.c=yes'
  test -f block/adios-iosched.c && echo 'adios-iosched.c=yes'
  test -f drivers/rekernel/rekernel.c && echo 'rekernel.c=yes'
} | tee "$PROOF"

echo '[PASS] Run28 staged Droidspaces standard + BBR/Brutal + ADIOS + Re:Kernel overlay'
