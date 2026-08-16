#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL"

echo '===== PATCH A16 unprivileged_bpf_disabled SYSCTL SEMANTICS ====='
python3 - <<'PY'
from pathlib import Path
p = Path('kernel/sysctl.c')
s = p.read_text()

handler = r'''
#ifdef CONFIG_BPF_SYSCALL
/*
 * Android 16 netbpfload writes 0 to unprivileged_bpf_disabled during boot.
 * The stock 4.14 table only accepts the value 1, so even the harmless 0 -> 0
 * write returns -EINVAL.  Keep the old one-way security property for value 1,
 * while accepting the modern 0/1/2 state model: 0 = enabled, 1 = permanently
 * disabled until reboot, 2 = disabled but administratively reversible.
 */
static int a16_unprivileged_bpf_handler(struct ctl_table *table, int write,
					void __user *buffer, size_t *lenp,
					loff_t *ppos)
{
	int ret;
	int old = sysctl_unprivileged_bpf_disabled;
	int val = old;
	struct ctl_table tmp = *table;

	tmp.data = &val;
	ret = proc_dointvec_minmax(&tmp, write, buffer, lenp, ppos);
	if (ret || !write)
		return ret;

	/* Preserve the stock 4.14 lock-down guarantee once value 1 is set. */
	if (old == 1 && val != 1)
		return -EPERM;

	sysctl_unprivileged_bpf_disabled = val;
	return 0;
}
#endif

'''

if 'static int a16_unprivileged_bpf_handler(' not in s:
    anchor = 'static struct ctl_table kern_table[] = {\n'
    if s.count(anchor) != 1:
        raise SystemExit(f'kern_table definition anchor count={s.count(anchor)}')
    s = s.replace(anchor, handler + anchor, 1)

needle = '.procname\t= "unprivileged_bpf_disabled",'
pos = s.find(needle)
if pos < 0:
    raise SystemExit('unprivileged_bpf_disabled sysctl entry not found')
start = s.rfind('#ifdef CONFIG_BPF_SYSCALL', 0, pos)
end = s.find('\t},', pos)
if start < 0 or end < 0:
    raise SystemExit('unable to isolate unprivileged_bpf_disabled table entry')
end += len('\t},')
block = s[start:end]
block = block.replace('/* only handle a transition from default "0" to "1" */\n\t\t.proc_handler\t= proc_dointvec_minmax,',
                      '/* Android 16 compatible 0/1/2 handler; value 1 remains locked. */\n\t\t.proc_handler\t= a16_unprivileged_bpf_handler,')
block = block.replace('\t\t.extra1\t\t= &one,\n\t\t.extra2\t\t= &one,',
                      '\t\t.extra1\t\t= &zero,\n\t\t.extra2\t\t= &two,')
if 'a16_unprivileged_bpf_handler' not in block or '&zero' not in block or '&two' not in block:
    raise SystemExit('failed to rewrite BPF sysctl entry')
s = s[:start] + block + s[end:]
p.write_text(s)
PY

grep -q 'static int a16_unprivileged_bpf_handler' kernel/sysctl.c
grep -A10 'procname.*unprivileged_bpf_disabled' kernel/sysctl.c | grep -q 'a16_unprivileged_bpf_handler'
grep -A10 'procname.*unprivileged_bpf_disabled' kernel/sysctl.c | grep -q 'extra1.*&zero'
grep -A10 'procname.*unprivileged_bpf_disabled' kernel/sysctl.c | grep -q 'extra2.*&two'
git diff --check -- kernel/sysctl.c
echo '[PASS] Android 16 can write unprivileged_bpf_disabled=0 without weakening locked state 1'
