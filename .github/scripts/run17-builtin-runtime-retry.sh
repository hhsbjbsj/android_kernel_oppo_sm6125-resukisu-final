#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee "$GITHUB_WORKSPACE/run17-builtin-runtime.log") 2>&1

KERNEL="$GITHUB_WORKSPACE/$KERNEL_REL"
WLAN="$KERNEL/drivers/staging/qcacld-3.0/core/hdd/src/wlan_hdd_main.c"
Q6="$KERNEL/techpack/audio/dsp/q6core.c"
APR="$KERNEL/techpack/audio/ipc/apr.c"

for f in "$WLAN" "$Q6" "$APR"; do
  test -f "$f" || { echo "[FATAL] Run17 staged source missing: $f"; exit 101; }
done

grep -Fq 'PCHM30 A16 late-DLKM: schedule APR child population from probe' "$APR"
grep -Fq 'PCHM30 A16 late-DLKM: AVS not ready, defer q6core probe' "$Q6"

echo '===== RUN17 PATCH BUILT-IN QCACLD SELF-START ====='
python3 - <<'PY'
import os, re
from pathlib import Path

p = Path(os.environ['GITHUB_WORKSPACE']) / os.environ['KERNEL_REL'] / 'drivers/staging/qcacld-3.0/core/hdd/src/wlan_hdd_main.c'
s = p.read_text()

if '#include <linux/workqueue.h>' not in s:
    anchor = '#include <linux/kernel.h>\n'
    if anchor not in s:
        raise SystemExit('wlan kernel.h include anchor missing')
    s = s.replace(anchor, anchor + '#include <linux/workqueue.h>\n', 1)

marker = 'PCHM30 RUN17 built-in WLAN delayed start armed'
if marker not in s:
    pat = re.compile(r'#else\nstatic int __init hdd_module_init\(void\)\n\{.*?\n\}\n#endif', re.S)
    m = pat.search(s)
    if not m:
        raise SystemExit('built-in hdd_module_init block not found')
    repl = r'''#else
#define PCHM30_BUILTIN_WLAN_FIRST_DELAY_MS 5000
#define PCHM30_BUILTIN_WLAN_RETRY_MS 2000
#define PCHM30_BUILTIN_WLAN_RETRY_MAX 40

static struct delayed_work pchm30_builtin_wlan_start_work;
static unsigned int pchm30_builtin_wlan_start_tries;

static void pchm30_builtin_wlan_start_workfn(struct work_struct *work)
{
	int ret;

	if (!wlan_loader || wlan_loader->loaded_state)
		return;

	pchm30_builtin_wlan_start_tries++;
	pr_info("PCHM30 RUN17 built-in WLAN delayed start attempt %u\n",
		pchm30_builtin_wlan_start_tries);

	ret = hdd_driver_load();
	if (!ret) {
		wlan_loader->loaded_state = MODULE_INITIALIZED;
		pr_info("PCHM30 RUN17 built-in WLAN delayed start succeeded\n");
		return;
	}

	pr_warn("PCHM30 RUN17 built-in WLAN delayed start failed ret=%d\n",
		ret);
	if (pchm30_builtin_wlan_start_tries < PCHM30_BUILTIN_WLAN_RETRY_MAX) {
		schedule_delayed_work(&pchm30_builtin_wlan_start_work,
			msecs_to_jiffies(PCHM30_BUILTIN_WLAN_RETRY_MS));
	} else {
		pr_err("PCHM30 RUN17 built-in WLAN delayed start exhausted retries\n");
	}
}

static int __init hdd_module_init(void)
{
	int ret = -EINVAL;

	ret = wlan_init_sysfs();
	if (ret) {
		hdd_err("Failed to create sysfs entry");
		return ret;
	}

	INIT_DELAYED_WORK(&pchm30_builtin_wlan_start_work,
			  pchm30_builtin_wlan_start_workfn);
	schedule_delayed_work(&pchm30_builtin_wlan_start_work,
		msecs_to_jiffies(PCHM30_BUILTIN_WLAN_FIRST_DELAY_MS));
	pr_info("PCHM30 RUN17 built-in WLAN delayed start armed\n");

	return 0;
}
#endif'''
    s = s[:m.start()] + repl + s[m.end():]

p.write_text(s)
PY

grep -Fq 'PCHM30 RUN17 built-in WLAN delayed start armed' "$WLAN"
grep -Fq 'hdd_driver_load();' "$WLAN"
grep -Fq 'schedule_delayed_work(&pchm30_builtin_wlan_start_work' "$WLAN"

echo '===== RUN17 PATCH Q6CORE ACTIVE REPROBE AFTER AVS TIMING MISS ====='
python3 - <<'PY'
import os
from pathlib import Path

p = Path(os.environ['GITHUB_WORKSPACE']) / os.environ['KERNEL_REL'] / 'techpack/audio/dsp/q6core.c'
s = p.read_text()

if '#include <linux/workqueue.h>' not in s:
    anchor = '#include <linux/delay.h>\n'
    if anchor not in s:
        raise SystemExit('q6core delay.h include anchor missing')
    s = s.replace(anchor, anchor + '#include <linux/workqueue.h>\n#include <linux/device.h>\n', 1)

helper_marker = 'PCHM30 RUN17 q6core active reprobe attempt'
if helper_marker not in s:
    anchor = 'static struct q6core_str q6core_lcl;\n'
    if anchor not in s:
        raise SystemExit('q6core_lcl anchor missing')
    helper = r'''

#define PCHM30_Q6CORE_RETRY_MS 2000
#define PCHM30_Q6CORE_RETRY_MAX 45
static struct platform_device *pchm30_q6core_retry_pdev;
static struct delayed_work pchm30_q6core_retry_work;
static atomic_t pchm30_q6core_retry_armed = ATOMIC_INIT(0);
static unsigned int pchm30_q6core_retry_tries;

static void pchm30_q6core_retry_workfn(struct work_struct *work)
{
	struct platform_device *pdev = READ_ONCE(pchm30_q6core_retry_pdev);
	int ret;

	if (!pdev)
		return;

	if (READ_ONCE(pdev->dev.driver))
		goto done;

	pchm30_q6core_retry_tries++;
	dev_info(&pdev->dev, "PCHM30 RUN17 q6core active reprobe attempt %u\n",
		 pchm30_q6core_retry_tries);

	ret = device_attach(&pdev->dev);
	if (ret > 0 || READ_ONCE(pdev->dev.driver)) {
		dev_info(&pdev->dev, "PCHM30 RUN17 q6core active reprobe succeeded\n");
		goto done;
	}

	if (pchm30_q6core_retry_tries < PCHM30_Q6CORE_RETRY_MAX) {
		schedule_delayed_work(&pchm30_q6core_retry_work,
			msecs_to_jiffies(PCHM30_Q6CORE_RETRY_MS));
		return;
	}

	dev_err(&pdev->dev, "PCHM30 RUN17 q6core active reprobe exhausted retries\n");

done:
	WRITE_ONCE(pchm30_q6core_retry_pdev, NULL);
	atomic_set(&pchm30_q6core_retry_armed, 0);
	put_device(&pdev->dev);
}

static void pchm30_q6core_schedule_retry(struct platform_device *pdev)
{
	if (atomic_cmpxchg(&pchm30_q6core_retry_armed, 0, 1))
		return;

	get_device(&pdev->dev);
	WRITE_ONCE(pchm30_q6core_retry_pdev, pdev);
	pchm30_q6core_retry_tries = 0;
	INIT_DELAYED_WORK(&pchm30_q6core_retry_work,
			  pchm30_q6core_retry_workfn);
	schedule_delayed_work(&pchm30_q6core_retry_work,
		msecs_to_jiffies(PCHM30_Q6CORE_RETRY_MS));
	dev_info(&pdev->dev, "PCHM30 RUN17 q6core active reprobe armed\n");
}
'''
    s = s.replace(anchor, anchor + helper, 1)

call_marker = 'PCHM30 RUN17 q6core active reprobe armed'
avs_marker = 'PCHM30 A16 late-DLKM: AVS not ready, defer q6core probe'
pos = s.find(avs_marker)
if pos < 0:
    raise SystemExit('Run15 q6core AVS defer marker missing')
retpos = s.find('return -EPROBE_DEFER;', pos)
if retpos < 0:
    raise SystemExit('q6core EPROBE_DEFER after AVS marker missing')
window = s[pos:retpos]
if 'pchm30_q6core_schedule_retry(pdev);' not in window:
    indent = '\t\t'
    s = s[:retpos] + 'pchm30_q6core_schedule_retry(pdev);\n' + indent + s[retpos:]

p.write_text(s)
PY

grep -Fq 'PCHM30 RUN17 q6core active reprobe attempt' "$Q6"
grep -Fq 'pchm30_q6core_schedule_retry(pdev);' "$Q6"
grep -Fq 'device_attach(&pdev->dev);' "$Q6"

cat > "$GITHUB_WORKSPACE/run17-builtin-runtime-proof.txt" <<'EOF'
RUN17 runtime fix keeps WLAN and audio as true built-ins.
WLAN: built-in qcacld retains boot_wlan sysfs compatibility and additionally retries hdd_driver_load() from delayed work after filesystem/vendor firmware are expected to become available.
Audio: Run15 APR child population and q6core AVS defer behavior are preserved; q6core now actively retries device_attach() after AVS timing misses so a userspace/DSP readiness transition cannot leave it permanently deferred.
No wlan.ko or audio DLKM fallback is introduced.
EOF

echo '[PASS] Run17 runtime retries staged without reverting any driver to modules'
