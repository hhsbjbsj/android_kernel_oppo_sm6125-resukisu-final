# PCHM30 SM6125 LK2nd port

Run22 is an isolated LK2nd bring-up branch based on the proven Run20 kernel baseline.

Hardware identity is taken from the existing kernel DTS (`arch/arm64/boot/dts/qcom/trinket.dtsi`): Qualcomm TRINKET / SM6125, msm-id 394, PMIC pm6125 + pmi632.

The first CI gate is deliberately non-flashable. It audits upstream LK2nd, extracts the PCHM30/SM6125 boot-critical facts already present in this repository, and emits a port skeleton. A flashable `lk2nd.img` must not be produced until SM6125 memory placement, platform clocks/timer/GIC, storage, USB fastboot and recovery path are implemented and validated rather than inherited blindly from msm8953.
