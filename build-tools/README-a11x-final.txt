OPPO A11x / PCHM30 最终 ReSukiSU 版
===================================

这不是在上次 step2 上继续补丁。它会从 OPPO 官方固定提交重新创建干净目录，
不会修改你现在的源码目录，也不会复用任何上次的 out/ 或内建 techpack。

一、解压并运行
--------------

把压缩包放到服务器，例如 /root/kernel/a11x-final，然后执行：

  mkdir -p /root/kernel/a11x-final
  cd /root/kernel/a11x-final
  tar -xzf a11x-final-resukisu-clean-dlkm-v8.tar.gz
  cd a11x-final-resukisu-clean-dlkm-v8
  chmod +x *.sh apply-resukisu-hooks.py

设置你之前成功编译时使用的同一套工具链路径：

  export SDCLANG_DIR=/你的路径/Snapdragon-LLVM-10.0.7
  export GCC64_DIR=/你的路径/aarch64-linux-android-4.9
  export GCC32_DIR=/你的路径/arm-linux-androideabi-4.9
  export MAGISKBOOT=/你的路径/magiskboot

然后只运行这一条：

  ./a11x-final-clean-resukisu.sh \
    /root/kernel/source/oppo-a11x-resukisu-work \
    /root/kernel/source/a11x-resukisu-boot-repack/boot-stock.img \
    /root/kernel/source/oppo-a11x-resukisu-work/a11x-stock-vs-built-report-20260719-000324/phone/stock-running.config

如果服务器已经有 ReSukiSU 仓库，可在上面命令前额外设置：

  export RESUKISU_REPO=/绝对路径/ReSukiSU

脚本会强制检出 ReSukiSU 提交
930f61a654f35b98577e5da781fb30f9a1bc678b，不会使用变化中的 main。

二、输出与启动
------------

成功时脚本末尾会直接打印 boot.img 的绝对路径。文件名固定为：

  a11x-final-resukisu-boot.img

只做临时启动：

  fastboot boot /脚本打印的完整路径/a11x-final-resukisu-boot.img

不要执行 fastboot flash boot。

三、最后对照结论
----------------

  项目                  A11x 官方实际方式             本最终版
  audio/data            vendor 外置 DLKM              保持外置，不拷入 techpack
  OPPO 内核设备树       不生成 appended DTB           纯 Image.gz + 原厂唯一 DTB 尾部
  模块 ABI              CONFIG_MODVERSIONS=y          保持 y
  模块签名              原厂私钥签名并强制验证        关闭验证，允许原厂 vendor 模块加载
  ReSukiSU 4.14         必须 manual hook               固定四组必要 Hook
  SUSFS/tracepoint      非 4.14 最小启动所需           全部关闭
  编译器/链接器         SDClang 10.0.7 / GNU ld 2.27  强制校验一致

XiKoTaSu 的 SM7150 内建 audio 方法不符合 A11x 官方 Android.mk；FlopKernel 的
小米 SM6125 使用 Image.gz-dtb，也与 A11x 原厂 config 和 boot 结构不符；
Winkmoon 的 MT6833 是 MediaTek 平台。这三条均不再移植。

四、终止条件
------------

这就是本项目最后一版。如果这个镜像仍然在 fastboot boot 后回到或停在
Fastboot，说明 OPPO 公布的源码/模块 ABI 仍缺少原厂私有部分，本项目到此停止，
不再要求你提交报告，也不再给下一版。
