# PCHM30 Run17 — real-device verified flashables

This branch permanently stores the exact Run17 kernel that passed real-device testing on PCHM30 / OPPO A11x.

- Original Actions run: `32022682577`
- Source commit: `942335793248cdfda03afc85319cd011ce507061`
- Kernel Image SHA256: `f92896bb8549849de1d5bff41a2e66a936fba702544b61ec8e72c428a8ffe0ea`
- Real-device result: Android boots, Wi-Fi works, speaker works, old matching WLAN/audio module is not required.

## Reuse

**Recommended:** flash `PCHM30-A16-RUN17-BUILTIN-RUNTIME-VERIFIED-AK3.zip` in a compatible recovery. It performs a kernel-only replacement and preserves the installed boot ramdisk/DTB layout.

`PCHM30-A16-RUN17-VERIFIED-Image` is the raw kernel Image, not a boot.img; do not flash it directly to the boot partition.
