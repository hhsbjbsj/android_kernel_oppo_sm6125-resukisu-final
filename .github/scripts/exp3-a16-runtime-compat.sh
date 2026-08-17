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

echo '===== PATCH PCHM30 LATE AUDIO DLKM APR CHILD POPULATION ====='
python3 - <<'PY'
from pathlib import Path

root = Path(__import__('os').environ['GITHUB_WORKSPACE']) / 'source/android/vendor/qcom/opensource/audio-kernel'
apr = root / 'ipc/apr.c'
q6core = root / 'dsp/q6core.c'
if not apr.is_file() or not q6core.is_file():
    raise SystemExit(f'audio source missing: apr={apr} q6core={q6core}')

s = apr.read_text()
old = '''\tapr_tal_init();

\tret = snd_event_client_register(&pdev->dev, &apr_ssr_ops, NULL);'''
new = '''\tapr_tal_init();

\t/*
\t * PCHM30 Android 16 late-DLKM recovery.
\t *
\t * The stock path populates APR child platform devices from apr_adsp_up().
\t * When apr_dlkm is inserted after ADSP is already running, the one-shot
\t * AUDIO_NOTIFIER_SERVICE_UP edge has already happened.  The APR parent can
\t * bind successfully while q6core and the SM6150 sound-card devices are
\t * never created.  Populate once from probe as well.  OF population skips
\t * nodes that are already populated, so the normal notifier path remains
\t * valid when it did run first.
\t */
\tdev_info(&pdev->dev,
\t\t "PCHM30 A16 late-DLKM: schedule APR child population from probe\\n");
\tschedule_work(&apr_priv->add_chld_dev_work);

\tret = snd_event_client_register(&pdev->dev, &apr_ssr_ops, NULL);'''
if 'PCHM30 A16 late-DLKM: schedule APR child population from probe' not in s:
    if s.count(old) != 1:
        raise SystemExit(f'apr probe anchor count={s.count(old)}')
    s = s.replace(old, new, 1)
apr.write_text(s)

s = q6core.read_text()
old = '''\trc = q6core_is_avs_up(&avs_state);
\tif (rc < 0)
\t\tgoto err;
\tq6core_lcl.avs_state = avs_state;'''
new = '''\trc = q6core_is_avs_up(&avs_state);
\tif (rc < 0) {
\t\t/*
\t\t * APR can now create this platform device before AVS is ready.
\t\t * Do not make that first timing miss permanent: ask the driver core
\t\t * to retry the probe after the remaining audio/ADSP dependencies land.
\t\t */
\t\tdev_warn(&pdev->dev,
\t\t\t "PCHM30 A16 late-DLKM: AVS not ready, defer q6core probe\\n");
\t\treturn -EPROBE_DEFER;
\t}
\tq6core_lcl.avs_state = avs_state;'''
if 'PCHM30 A16 late-DLKM: AVS not ready, defer q6core probe' not in s:
    if s.count(old) != 1:
        raise SystemExit(f'q6core probe anchor count={s.count(old)}')
    s = s.replace(old, new, 1)
q6core.write_text(s)
PY

APR_SRC="$GITHUB_WORKSPACE/source/android/vendor/qcom/opensource/audio-kernel/ipc/apr.c"
Q6CORE_SRC="$GITHUB_WORKSPACE/source/android/vendor/qcom/opensource/audio-kernel/dsp/q6core.c"
grep -Fq 'PCHM30 A16 late-DLKM: schedule APR child population from probe' "$APR_SRC"
grep -Fq 'schedule_work(&apr_priv->add_chld_dev_work);' "$APR_SRC"
grep -Fq 'PCHM30 A16 late-DLKM: AVS not ready, defer q6core probe' "$Q6CORE_SRC"
grep -Fq 'return -EPROBE_DEFER;' "$Q6CORE_SRC"
echo '[PASS] APR late-load path will create q6core/sound children and q6core can defer until AVS is ready'
