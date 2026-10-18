# SM6125 (Trinket / PCHM30) Linux 4.19 Clean Porting Roadmap

## 1. Project Background & Rationale
This branch is a pristine experimental branch dedicated to porting and rebasing the Qualcomm SM6125 (Snapdragon 665 / Trinket) platform for OPPO A11x (PCHM30) to **Linux Kernel 4.19**.

- **Clean Baseline**: Forked directly from the verified real-device bootable stock baseline (£73ddf382080253b631c299b7df03d0142a376\).
- **Zero Intrusive Mods**: Completely free of legacy baseband guards, lz4kd hacks, fake uname intercepts, and private custom patches.
- **Reference Project**: **Qualcomm Bengal (SM6115 / SM6225) CAF \msm-4.19\ Architecture** (as featured in Motorola SM6225 / LineageOS Bengal trees).

---

## 2. Why Qualcomm Bengal (SM6115) as the Reference Project?
1. **Identical Core Silicon Architecture**:
   - CPU: 8x Kryo 260 (4x Cortex-A73 Gold + 4x Cortex-A53 Silver)
   - GPU: Adreno 610
   - DSP: Hexagon 686
   - PMIC & Interconnect: SPMI, RPMh, PM6125 power delivery
2. **Official CAF 4.19 Support**:
   - Unlike Trinket (SM6125) which was launched on CAF 4.14, Bengal (SM6115) received full first-class **CAF Linux 4.19 BSP** support (\endor/bengal-perf_defconfig\ in \kernel/msm-4.19\).
   - Using Bengal as the 4.19 upstream source eliminates the massive incompatibilities of generic AOSP/Linux upstreaming, guaranteeing native Qualcomm techpack and clock subsystem harmony.

---

## 3. Step-by-Step Porting Roadmap

### Phase 1: Pure Baseline & CI Infrastructure (Current)
- [x] Establish pure stock baseline branch \exp-4.19-clean- [x] Eliminate all legacy meatshield/watchdog overrides
- [x] Configure dedicated, clean GitHub Actions build workflow (\.github/workflows/exp-4.19-clean-build.yml\)

### Phase 2: CAF Bengal 4.19 Tree Alignment
- Import clean CAF \msm-4.19\ / Bengal kernel core
- Reconcile arch/arm64 configuration and compiler flags (LLVM / Clang 15+)

### Phase 3: SoC Clock & Pin Controller Migration
- Port \drivers/clk/qcom/dispcc-sm6125.c\ and \gpucc-sm6125.c\ into 4.19 clock framework
- Align \drivers/pinctrl/qcom/pinctrl-sm6125.c
### Phase 4: Device Tree (DTS) Forward-Porting
- Adapt \rch/arm64/boot/dts/qcom/trinket.dtsi\ to 4.19 binding rules
- Adapt board device trees:
  - PM6125 regulator constraints
  - DSI panel timings & display techpack
  - Touchscreen (Goodix/FTS) I2C/SPI nodes

### Phase 5: Hardware & Peripheral Stabilization
- Screen display (DRM / MSM DPU) bringup
- Touchscreen & battery charging validation
- Camera & Audio HAL interface verification (uapi structure compat)
