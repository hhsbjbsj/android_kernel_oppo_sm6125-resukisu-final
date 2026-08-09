# PCHM30 / OPPO A11x — ReSukiSU + SUSFS 2.2.0

Real-device verified release for OPPO A11x (PCHM30 / SM6125 / Android 11).

## Verified status

- ReSukiSU gitlink: beaaea0eb895dc41e7b9bf5e3f39e57aa9635bab
- SUSFS: v2.2.0
- SUSFS optional features: all enabled
- G1: PASS
- G2: PASS
- G3: PASS
- G4 FULL: PASS
- ReSukiSU Manager: supported
- SUSFS Manager detection: v2.2.0
- Android boot / SystemUI / touch / fullscreen gestures: normal

## Critical PCHM30 compatibility rule

Do **not** add `atomic_t filter_count` to `struct seccomp`.

PCHM30's stock Linux 4.14 seccomp ABI must remain:

```c
struct seccomp {
    int mode;
    struct seccomp_filter *filter;
};
```

The native Linux 4.14 `put_seccomp_filter()` path is retained.

A generic non-GKI SUSFS inline helper force-added `filter_count`, which made
ReSukiSU detect a newer seccomp model. On this device that produced a long
second boot, partial/broken SystemUI, a dark-to-bright transition, frozen input,
and soft reboot. Restoring the stock seccomp ABI fixed the issue while retaining
all ReSukiSU inline hooks and every SUSFS v2.2.0 feature.

## Build config

Use:

`configs/PCHM30-resukisu-susfs220-full.config`

No private module-signing key is included.
