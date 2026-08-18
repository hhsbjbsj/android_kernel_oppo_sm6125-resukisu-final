# PCHM30 A16 SukiSU Run23 verified AK3

This branch is the product archive for the successful and device-validated Run23 #5 kernel.

- Root: SukiSU Ultra + SUSFS 2.2.0
- KPM: enabled with the 4.14 runtime fix
- Source branch: `pchm30-a16-run23-kpm-runtimefix-btf`
- Source run: `32165962039` / run number `5`
- Source commit: `64d77ea102b168372067d8e651e8d7178a198201`
- GitHub artifact: `PCHM30-A16-RUN23-KPM-RUNTIMEFIX-BTF-5`
- GitHub artifact ID: `9337439851`
- AK3 SHA256: `79affeb902789af760bd422ab4be6184b0b29313b7c8fae77544b3360916baa2`

Validated on device:

- SukiSU root works
- SUSFS present
- KPM load ENTER/EXIT observed
- KPM list ENTER/EXIT observed repeatedly
- SukiSU Manager remained responsive after KPM import
- BTF sysfs file present/readable
- KPROBES/KRETPROBES present
- BBG/LZ4K/LZ4KD built in
- built-in Wi-Fi and Audio work

Expected flash artifact path:

`artifacts/PCHM30-A16-SukiSU-RUN23-KPM-RUNTIMEFIX-BTF-AK3.zip`

The checksum and complete source metadata are stored under `artifacts/`.
