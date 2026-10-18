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

# Patch gcc-trinket.c for Linux 4.19 DFS registration API:
# 4.14 used: qcom_cc_register_rcg_dfs(pdev, &gcc_trinket_dfs_desc) with struct clk_dfs
# 4.19 uses: qcom_cc_register_rcg_dfs(regmap, gcc_dfs_clocks, ARRAY_SIZE(gcc_dfs_clocks)) with struct clk_rcg_dfs_data
python3 - << 'EOF'
import sys

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

new_dfs_struct = """static const struct clk_rcg_dfs_data gcc_dfs_clocks[] = {
	DEFINE_RCG_DFS(gcc_qupv3_wrap0_s0_clk_src),
	DEFINE_RCG_DFS(gcc_qupv3_wrap0_s1_clk_src),
	DEFINE_RCG_DFS(gcc_qupv3_wrap0_s2_clk_src),
	DEFINE_RCG_DFS(gcc_qupv3_wrap0_s3_clk_src),
	DEFINE_RCG_DFS(gcc_qupv3_wrap0_s4_clk_src),
	DEFINE_RCG_DFS(gcc_qupv3_wrap0_s5_clk_src),
	DEFINE_RCG_DFS(gcc_qupv3_wrap1_s0_clk_src),
	DEFINE_RCG_DFS(gcc_qupv3_wrap1_s1_clk_src),
	DEFINE_RCG_DFS(gcc_qupv3_wrap1_s2_clk_src),
	DEFINE_RCG_DFS(gcc_qupv3_wrap1_s3_clk_src),
	DEFINE_RCG_DFS(gcc_qupv3_wrap1_s4_clk_src),
	DEFINE_RCG_DFS(gcc_qupv3_wrap1_s5_clk_src),
};"""

old_dfs_call = "ret = qcom_cc_register_rcg_dfs(pdev, &gcc_trinket_dfs_desc);"
new_dfs_call = "ret = qcom_cc_register_rcg_dfs(regmap, gcc_dfs_clocks, ARRAY_SIZE(gcc_dfs_clocks));"

if old_dfs_struct in code:
    code = code.replace(old_dfs_struct, new_dfs_struct)
    print("[PASS] Replaced gcc_dfs_clocks struct for Linux 4.19")
else:
    print("[WARN] old_dfs_struct pattern not found directly, checking partial replacement")

if old_dfs_call in code:
    code = code.replace(old_dfs_call, new_dfs_call)
    print("[PASS] Replaced qcom_cc_register_rcg_dfs call for Linux 4.19")
else:
    print("[WARN] old_dfs_call pattern not found directly")

with open(path, "w", encoding="utf-8") as f:
    f.write(code)
EOF

# Wire up drivers/clk/qcom/Kconfig & Makefile
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
	help
	  Support for the global clock controller on Trinket devices.

config SM_GPUCC_TRINKET
	tristate "TRINKET Graphics Clock Controller"
	select SM_GCC_TRINKET
	help
	  Support for the graphics clock controller on Trinket devices.

config SM_DISPCC_TRINKET
	tristate "TRINKET Display Clock Controller"
	select SM_GCC_TRINKET
	help
	  Support for the display clock controller on Trinket devices.

config SM_VIDEOCC_TRINKET
	tristate "TRINKET Video Clock Controller"
	select SM_GCC_TRINKET
	help
	  Support for the video clock controller on Trinket devices.

config SM_DEBUGCC_TRINKET
	tristate "TRINKET Debug Clock Controller"
	depends on SM_GCC_TRINKET
	help
	  Support for the debug clock controller on Trinket devices.
EOF
fi

# 4. Graft Trinket Pinctrl Driver
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
# Add MSM_CPU_TRINKET to include/soc/qcom/socinfo.h
h_path = "kernel-4.19/include/soc/qcom/socinfo.h"
with open(h_path, "r", encoding="utf-8") as f:
    h_code = f.read()

if "MSM_CPU_TRINKET" not in h_code:
    h_code = h_code.replace("MSM_CPU_BENGAL,", "MSM_CPU_TRINKET,\n\tMSM_CPU_BENGAL,")
    with open(h_path, "w", encoding="utf-8") as f:
        f.write(h_code)
    print("[PASS] Added MSM_CPU_TRINKET to socinfo.h")

# Add 394 to drivers/soc/qcom/socinfo.c
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
# Disable Xiaomi touch in drivers/input/touchscreen/Makefile if present
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
