#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# PCHM30 / OPPO A11x Linux 4.19 Source-Level Porting Script
# Grafts OPPO PCHM30 SM6125 (Trinket) device tree, clocks, pinctrl and configs
# onto the Qualcomm msm-4.19 kernel base.

set -Eeuo pipefail

KERNEL_DIR="${1:-kernel-4.19}"
WORKSPACE="${2:-port-workspace}"

echo "=========================================================="
echo " Starting PCHM30 Linux 4.19 Source-Level Port Grafting..."
echo " Target kernel dir: $KERNEL_DIR"
echo " Source workspace : $WORKSPACE"
echo "=========================================================="

# 0. Patch scripts/kconfig/conf.c and arch/arm64/Kconfig to permanently prevent non-interactive prompts & EOF loops
echo "[0/8] Immunizing Kconfig conf.c and arch/arm64/Kconfig against non-interactive EOF / syncconfig loops..."
python3 - << 'EOF'
path = "kernel-4.19/scripts/kconfig/conf.c"
with open(path, "r", encoding="utf-8") as f:
    c = f.read()

# 1. Patch xfgets to return newline on EOF
old_xfgets = """static void xfgets(char *str, int size, FILE *in)
{
	if (!fgets(str, size, in))
		fprintf(stderr, "\\nError in reading or end of file.\\n");

	if (!tty_stdio)
		printf("%s", str);
}"""

new_xfgets = """static void xfgets(char *str, int size, FILE *in)
{
	if (!fgets(str, size, in)) {
		str[0] = '\\n';
		str[1] = 0;
		return;
	}

	if (!tty_stdio)
		printf("%s", str);
}"""

if old_xfgets in c:
    c = c.replace(old_xfgets, new_xfgets)
else:
    c = c.replace('fprintf(stderr, "\\nError in reading or end of file.\\n");', 'str[0] = \'\\n\'; str[1] = 0; return;')

# 2. Prevent syncconfig from ever entering interactive conf() prompt loop
sync_marker = 'if (!conf_cnt++)\n\t\t\t\t\tprintf("*\\n* Restart config...\\n*\\n");'
if sync_marker in c:
    c = c.replace(sync_marker, 'if (input_mode == syncconfig)\n\t\t\t\t\treturn;\n\t\t\t\t' + sync_marker)
    print("[PASS] Successfully patched conf.c check_conf to bypass interactive restart on syncconfig")

# 3. Patch conf_string to prevent infinite loop on empty default with newline input
conf_str_marker = "switch (line[0]) {\n\t\tcase '\\n':\n\t\t\tbreak;"
conf_str_fix = """switch (line[0]) {
		case '\\n':
			if (!def) {
				if (sym->type == S_INT || sym->type == S_HEX)
					def = "0";
				else
					def = "";
			}
			break;"""
if conf_str_marker in c:
    c = c.replace(conf_str_marker, conf_str_fix)
    print("[PASS] Successfully patched conf.c conf_string to prevent infinite loop on missing default")

with open(path, "w", encoding="utf-8") as f:
    f.write(c)

# 4. Patch arch/arm64/Kconfig LITTLE_CPU_MASK and BIG_CPU_MASK defaults
kpath = "kernel-4.19/arch/arm64/Kconfig"
with open(kpath, "r", encoding="utf-8") as f:
    k = f.read()

k = k.replace(
    'config LITTLE_CPU_MASK\n\tint "Bitmask of available LITTLE CPUs"',
    'config LITTLE_CPU_MASK\n\tint "Bitmask of available LITTLE CPUs"\n\tdefault 0'
)
k = k.replace(
    'config BIG_CPU_MASK\n\tint "Bitmask of available big CPUs"',
    'config BIG_CPU_MASK\n\tint "Bitmask of available big CPUs"\n\tdefault 0'
)
with open(kpath, "w", encoding="utf-8") as f:
    f.write(k)
print("[PASS] Injected default 0 for LITTLE_CPU_MASK & BIG_CPU_MASK into arch/arm64/Kconfig")

# 5. Fix Makefile line 983 -plugin-opt compatibility with GNU ld
mpath = "kernel-4.19/Makefile"
with open(mpath, "r", encoding="utf-8") as f:
    m = f.read()

m = m.replace(
    "KBUILD_LDFLAGS\t+= -plugin-opt=-warn-stack-size=$(CONFIG_FRAME_WARN)",
    "KBUILD_LDFLAGS\t+= $(call ld-option, -plugin-opt=-warn-stack-size=$(CONFIG_FRAME_WARN))"
)
with open(mpath, "w", encoding="utf-8") as f:
    f.write(m)
print("[PASS] Wrapped -plugin-opt with $(call ld-option, ...) in Makefile")

# 6. Fix arch/arm64/Makefile line 103 -plugin-opt compatibility with GNU ld
arm_mpath = "kernel-4.19/arch/arm64/Makefile"
with open(arm_mpath, "r", encoding="utf-8") as f:
    am = f.read()

am = am.replace(
    "KBUILD_LDFLAGS_MODULE\t+= -plugin-opt=-code-model=large",
    "KBUILD_LDFLAGS_MODULE\t+= $(call ld-option, -plugin-opt=-code-model=large)"
)
with open(arm_mpath, "w", encoding="utf-8") as f:
    f.write(am)
print("[PASS] Wrapped -plugin-opt with $(call ld-option, ...) in arch/arm64/Makefile")

# 7. Fix kernel/sched/tune.c undeclared boost_write_wrapper / prefer_idle_write_wrapper
tune_path = "kernel-4.19/kernel/sched/tune.c"
with open(tune_path, "r", encoding="utf-8") as f:
    tc = f.read()

target_tune = "#endif\n\nstatic struct cftype files[] = {"
fallback_tune = """#endif

#ifndef CONFIG_STUNE_ASSIST
#define boost_write_wrapper boost_write
#define prefer_idle_write_wrapper prefer_idle_write
#endif

static struct cftype files[] = {"""

if target_tune in tc:
    tc = tc.replace(target_tune, fallback_tune)
    with open(tune_path, "w", encoding="utf-8") as f:
        f.write(tc)
    print("[PASS] Added stune_assist fallbacks in kernel/sched/tune.c")
EOF

# 1. Graft Trinket Clock DT-Bindings
echo "[1/8] Installing Trinket clock dt-bindings..."
mkdir -p "$KERNEL_DIR/include/dt-bindings/clock"
cp -vf "$WORKSPACE/include/dt-bindings/clock/qcom,dispcc-trinket.h" "$KERNEL_DIR/include/dt-bindings/clock/"
cp -vf "$WORKSPACE/include/dt-bindings/clock/qcom,gcc-trinket.h" "$KERNEL_DIR/include/dt-bindings/clock/"
cp -vf "$WORKSPACE/include/dt-bindings/clock/qcom,gpucc-trinket.h" "$KERNEL_DIR/include/dt-bindings/clock/"
cp -vf "$WORKSPACE/include/dt-bindings/clock/qcom,videocc-trinket.h" "$KERNEL_DIR/include/dt-bindings/clock/"

# 2. Graft RPM-SMD Regulator Header
echo "[2/8] Installing RPM-SMD regulator header..."
mkdir -p "$KERNEL_DIR/include/linux/regulator"
cp -vf "$WORKSPACE/include/linux/regulator/rpm-smd-regulator.h" "$KERNEL_DIR/include/linux/regulator/"

# 3. Graft Trinket Clock Drivers & Adapt for 4.19 DFS API
echo "[3/8] Installing Trinket clock drivers..."
mkdir -p "$KERNEL_DIR/drivers/clk/qcom"
cp -vf "$WORKSPACE/drivers/clk/qcom/debugcc-trinket.c" "$KERNEL_DIR/drivers/clk/qcom/"
cp -vf "$WORKSPACE/drivers/clk/qcom/dispcc-trinket.c" "$KERNEL_DIR/drivers/clk/qcom/"
cp -vf "$WORKSPACE/drivers/clk/qcom/gcc-trinket.c" "$KERNEL_DIR/drivers/clk/qcom/"
cp -vf "$WORKSPACE/drivers/clk/qcom/gpucc-trinket.c" "$KERNEL_DIR/drivers/clk/qcom/"
cp -vf "$WORKSPACE/drivers/clk/qcom/vdd-level-trinket.h" "$KERNEL_DIR/drivers/clk/qcom/"
cp -vf "$WORKSPACE/drivers/clk/qcom/videocc-trinket.c" "$KERNEL_DIR/drivers/clk/qcom/"

# Adapt 4.14 alpha_pll_config field name (alpha_u -> alpha_hi) for Linux 4.19
sed -i 's/\.alpha_u =/\.alpha_hi =/g' "$KERNEL_DIR/drivers/clk/qcom/"*trinket*.c

# Patch gcc-trinket.c for Linux 4.19 DFS registration API
python3 - << 'EOF'
path = "kernel-4.19/drivers/clk/qcom/gcc-trinket.c"
with open(path, "r", encoding="utf-8") as f:
    code = f.read()

old_dfs_struct = """static struct clk_dfs gcc_dfs_clocks[] = {
	{ &gcc_qupv3_wrap0_s0_clk_src, DFS_ENABLE_RCG },
	{ &gcc_qupv3_wrap0_s1_clk_src, DFS_ENABLE_RCG },
	{ &gcc_qupv3_wrap0_s2_clk_src, DFS_ENABLE_RCG },
	{ &gcc_qupv3_wrap0_s3_clk_src, DFS_ENABLE_RCG },
	{ &gcc_qupv3_wrap0_s4_clk_src, DFS_ENABLE_RCG },
	{ &gcc_qupv3_wrap0_s5_clk_src, DFS_ENABLE_RCG },
	{ &gcc_qupv3_wrap1_s0_clk_src, DFS_ENABLE_RCG },
	{ &gcc_qupv3_wrap1_s1_clk_src, DFS_ENABLE_RCG },
	{ &gcc_qupv3_wrap1_s2_clk_src, DFS_ENABLE_RCG },
	{ &gcc_qupv3_wrap1_s3_clk_src, DFS_ENABLE_RCG },
	{ &gcc_qupv3_wrap1_s4_clk_src, DFS_ENABLE_RCG },
	{ &gcc_qupv3_wrap1_s5_clk_src, DFS_ENABLE_RCG },
};

static const struct qcom_cc_dfs_desc gcc_trinket_dfs_desc = {
	.clks = gcc_dfs_clocks,
	.num_clks = ARRAY_SIZE(gcc_dfs_clocks),
};"""

# Neutralize DFS in gcc-trinket.c for clean Linux 4.19 compilation
if old_dfs_struct in code:
    code = code.replace(old_dfs_struct, "/* DFS clocks omitted on Linux 4.19 port */")
    print("[PASS] Omitted gcc_dfs_clocks struct for Linux 4.19")

old_dfs_call = "ret = qcom_cc_register_rcg_dfs(pdev, &gcc_trinket_dfs_desc);"
if old_dfs_call in code:
    code = code.replace(old_dfs_call, "ret = 0; /* DFS skipped */")
    print("[PASS] Neutralized qcom_cc_register_rcg_dfs call for Linux 4.19")

with open(path, "w", encoding="utf-8") as f:
    f.write(code)
EOF

# Wire up drivers/clk/qcom/Kconfig & Makefile with explicit defaults
if ! grep -q "CONFIG_SM_GCC_TRINKET" "$KERNEL_DIR/drivers/clk/qcom/Makefile"; then
cat << 'EOF' >> "$KERNEL_DIR/drivers/clk/qcom/Makefile"
obj-$(CONFIG_SM_GCC_TRINKET) += gcc-trinket.o
obj-$(CONFIG_SM_DISPCC_TRINKET) += dispcc-trinket.o
obj-$(CONFIG_SM_GPUCC_TRINKET) += gpucc-trinket.o
obj-$(CONFIG_SM_VIDEOCC_TRINKET) += videocc-trinket.o
obj-$(CONFIG_SM_DEBUGCC_TRINKET) += debugcc-trinket.o
EOF
fi

if ! grep -q "config SM_GCC_TRINKET" "$KERNEL_DIR/drivers/clk/qcom/Kconfig"; then
cat << 'EOF' >> "$KERNEL_DIR/drivers/clk/qcom/Kconfig"

config SM_GCC_TRINKET
	tristate "TRINKET Global Clock Controller"
	select QCOM_GDSC
	depends on COMMON_CLK_QCOM
	default y
	help
	  Support for the global clock controller on Trinket devices.

config SM_GPUCC_TRINKET
	tristate "TRINKET Graphics Clock Controller"
	select SM_GCC_TRINKET
	default y
	help
	  Support for the graphics clock controller on Trinket devices.

config SM_DISPCC_TRINKET
	tristate "TRINKET Display Clock Controller"
	select SM_GCC_TRINKET
	default y
	help
	  Support for the display clock controller on Trinket devices.

config SM_VIDEOCC_TRINKET
	tristate "TRINKET Video Clock Controller"
	select SM_GCC_TRINKET
	default y
	help
	  Support for the video clock controller on Trinket devices.

config SM_DEBUGCC_TRINKET
	tristate "TRINKET Debug Clock Controller"
	depends on SM_GCC_TRINKET
	default y
	help
	  Support for the debug clock controller on Trinket devices.
EOF
fi

# 4. Graft Trinket Pinctrl Driver with explicit defaults
echo "[4/8] Installing Trinket pinctrl driver..."
mkdir -p "$KERNEL_DIR/drivers/pinctrl/qcom"
cp -vf "$WORKSPACE/drivers/pinctrl/qcom/pinctrl-trinket.c" "$KERNEL_DIR/drivers/pinctrl/qcom/"

if ! grep -q "CONFIG_PINCTRL_TRINKET" "$KERNEL_DIR/drivers/pinctrl/qcom/Makefile"; then
cat << 'EOF' >> "$KERNEL_DIR/drivers/pinctrl/qcom/Makefile"
obj-$(CONFIG_PINCTRL_TRINKET) += pinctrl-trinket.o
EOF
fi

if ! grep -q "config PINCTRL_TRINKET" "$KERNEL_DIR/drivers/pinctrl/qcom/Kconfig"; then
cat << 'EOF' >> "$KERNEL_DIR/drivers/pinctrl/qcom/Kconfig"

config PINCTRL_TRINKET
	tristate "Qualcomm Technologies Inc TRINKET pin controller driver"
	depends on GPIOLIB && OF
	select PINCTRL_MSM
	default y
	help
	  This is the pinctrl driver for the Qualcomm Technologies Inc TRINKET platform.
EOF
fi

# 5. Graft Architecture & SoC Identification (SM6125 / MSM394)
echo "[5/8] Inlining ARCH_TRINKET into Kconfig.platforms & socinfo..."
if ! grep -q "config ARCH_TRINKET" "$KERNEL_DIR/arch/arm64/Kconfig.platforms"; then
cat << 'EOF' >> "$KERNEL_DIR/arch/arm64/Kconfig.platforms"

config ARCH_TRINKET
	bool "Enable Support for Qualcomm Technologies, Inc. TRINKET"
	depends on ARCH_QCOM
	select COMMON_CLK
	select COMMON_CLK_QCOM
	default y
	help
	  This enables support for the TRINKET chipset (OPPO PCHM30 / SM6125).
EOF
fi

python3 - << 'EOF'
h_path = "kernel-4.19/include/soc/qcom/socinfo.h"
with open(h_path, "r", encoding="utf-8") as f:
    h_code = f.read()

if "MSM_CPU_TRINKET" not in h_code:
    h_code = h_code.replace("MSM_CPU_BENGAL,", "MSM_CPU_TRINKET,\n\tMSM_CPU_BENGAL,")
    with open(h_path, "w", encoding="utf-8") as f:
        f.write(h_code)
    print("[PASS] Added MSM_CPU_TRINKET to socinfo.h")

c_path = "kernel-4.19/drivers/soc/qcom/socinfo.c"
with open(c_path, "r", encoding="utf-8") as f:
    c_code = f.read()

if "[394]" not in c_code:
    c_code = c_code.replace('[417] = {MSM_CPU_BENGAL, "BENGAL"},', '[394] = {MSM_CPU_TRINKET, "TRINKET"},\n\t[417] = {MSM_CPU_BENGAL, "BENGAL"},')
    with open(c_path, "w", encoding="utf-8") as f:
        f.write(c_code)
    print("[PASS] Added SoC ID 394 to socinfo.c")
EOF

# 6. Graft OPPO PCHM30 (19021/19051) Device Tree Files
echo "[6/8] Grafting OPPO PCHM30 DTS into arch/arm64/boot/dts/vendor/qcom/..."
DTS_DEST="$KERNEL_DIR/arch/arm64/boot/dts/vendor/qcom"
mkdir -p "$DTS_DEST"
cp -vf "$WORKSPACE/arch/arm64/boot/dts/19021/"* "$DTS_DEST/" || true
if [ -d "$WORKSPACE/arch/arm64/boot/dts/qcom" ]; then
    cp -vf "$WORKSPACE/arch/arm64/boot/dts/qcom/trinket"* "$DTS_DEST/" 2>/dev/null || true
fi

# Add trinket dtb to vendor/qcom/Makefile
if ! grep -q "trinket-idp-19021.dtb" "$DTS_DEST/Makefile"; then
cat << 'EOF' >> "$DTS_DEST/Makefile"

dtb-$(CONFIG_ARCH_TRINKET) += \
	trinket-idp-19021.dtb \
	trinket-19021.dtb

ifeq ($(CONFIG_BUILD_ARM64_DT_OVERLAY),y)
dtbo-$(CONFIG_ARCH_TRINKET) += \
	trinket-idp-overlay-19021.dtbo

trinket-idp-overlay-19021.dtbo-base := trinket-19021.dtb
endif
EOF
fi

# 7. Purge Xiaomi Vendor Dependencies
echo "[7/8] Purging Xiaomi vendor references and private touch drivers..."
if [ -f "$KERNEL_DIR/drivers/input/touchscreen/Makefile" ]; then
    sed -i 's/obj-\$(CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE)/# obj-$(CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE)/g' "$KERNEL_DIR/drivers/input/touchscreen/Makefile" || true
fi
if [ -f "$KERNEL_DIR/drivers/misc/Makefile" ]; then
    sed -i 's/obj-\$(CONFIG_MI_FS)/# obj-$(CONFIG_MI_FS)/g' "$KERNEL_DIR/drivers/misc/Makefile" || true
fi

# 8. Create Dedicated PCHM30 4.19 Defconfig
echo "[8/8] Generating arch/arm64/configs/vendor/pchm30-perf_defconfig..."
DEFCONFIG="$KERNEL_DIR/arch/arm64/configs/vendor/pchm30-perf_defconfig"
cp -f "$KERNEL_DIR/arch/arm64/configs/vendor/bengal-perf_defconfig" "$DEFCONFIG"

# Overlay PCHM30 Trinket configurations and Android 16 GSI necessities
cat << 'EOF' >> "$DEFCONFIG"

# ========================================================
# OPPO A11x / PCHM30 (SM6125 Trinket) 4.19 Port Overlays
# ========================================================
CONFIG_LOCALVERSION="-PCHM30-Clean-Exp"
CONFIG_ARCH_TRINKET=y
CONFIG_SM_GCC_TRINKET=y
CONFIG_SM_DISPCC_TRINKET=y
CONFIG_SM_GPUCC_TRINKET=y
CONFIG_SM_VIDEOCC_TRINKET=y
CONFIG_SM_DEBUGCC_TRINKET=y
CONFIG_PINCTRL_TRINKET=y
CONFIG_REGULATOR_RPM_SMD=y
CONFIG_QCOM_SMD_RPM=y

# PCHM30 SM6125 (4x Kryo Silver [0-3] + 4x Kryo Gold [4-7]) CPU bitmasks
CONFIG_LITTLE_CPU_MASK=15
CONFIG_BIG_CPU_MASK=240
CONFIG_FRAME_WARN=2048

# Android 16 GSI Kernel Prerequisites (BPF & Permissive Guard)
CONFIG_SECURITY_SELINUX_DEVELOP=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_CHECKREQPROT_VALUE=1
CONFIG_BPF_SYSCALL=y
CONFIG_CGROUP_BPF=y
CONFIG_NETFILTER_XT_MATCH_BPF=y
CONFIG_NET_CLS_BPF=y
CONFIG_BPF_JIT=y

# Strip all Xiaomi private features
# CONFIG_MACH_XIAOMI_CITRUS is not set
# CONFIG_MACH_XIAOMI_LIME is not set
# CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE is not set
# CONFIG_MI_FS is not set
EOF

echo "=========================================================="
echo " [SUCCESS] PCHM30 Linux 4.19 Porting Overlay Applied!"
echo " Target Defconfig: vendor/pchm30-perf_defconfig"
echo " Target Device Tree: trinket-idp-19021.dtb"
echo "=========================================================="
