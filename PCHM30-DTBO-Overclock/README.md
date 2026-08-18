# OPPO A11x / PCHM30 DTBO Display Overclock

Device: OPPO A11x / PCHM30 / project 19021  
SoC: Qualcomm SM6125  
Display: 720x1600

## Final test results

| Refresh rate | Result |
|---|---|
| 60 Hz | ✅ Stock / stable |
| 75 Hz | ✅ Fully working / recommended |
| 80 Hz | ❌ Boots and displays normally, but touch input is unavailable after boot |
| 90 Hz | ❌ Display corruption / artifacts |

## Final recommendation

**75 Hz is the practical stable limit on the tested device.**

75 Hz has been tested on real hardware and works normally, including display and touch input.

80 Hz can boot and the LCD itself displays normally, but touch input becomes unavailable after boot. This makes 80 Hz unusable as a daily configuration on the tested device.

90 Hz causes visible display corruption.

Therefore only the verified 60 Hz stock image and 75 Hz working image are kept in this repository.

---

## DTBO information

PCHM30 has standalone DTBO partitions:

```text
dtbo
dtbobak
```

Observed boot property:

```text
ro.boot.dtbo_idx=10
```

Stock DTBO table:

```text
entry_count = 32
page_size   = 4096
entry       = 10
dt_size     = 173731
dt_offset   = 1489306
```

Entry 10 contains five PCHM30 / OPPO 19021 720x1600 panel definitions:

- ILI9881 AUO
- NT36525B BOE
- ILI9881 Tianma
- NT36525B HLT
- ILI9881 INX

Original refresh property:

```text
qcom,mdss-dsi-panel-framerate = 0x3c
```

Values used during testing:

```text
0x3c = 60 Hz
0x4b = 75 Hz
0x50 = 80 Hz
0x5a = 90 Hz
```

## Working 75 Hz modification

Exactly five bytes are changed in the complete stock `dtbo.img`.

1-based offsets:

```text
1509878
1512002
1514486
1516610
1519098
```

All five changes:

```text
0x3c -> 0x4b
```

Verification:

```text
TOTAL DTBO DIFFERENCES: 5
IMAGE SIZE: 25165824 bytes
```

## SHA256

Stock 60 Hz:

```text
f50b9d85a6ec60b6ba773cdc1c9af3a920de2257cc76eca191a3f9b7c4cd63a5
```

Working 75 Hz:

```text
a2a049601f096c8e3555270c07f41f19533bbbd7b52aa03898e10a38c5871c87
```

These hashes apply to the tested PCHM30 DTBO image only.

---

## Included files

```text
images/
├── PCHM30-dtbo-60-STOCK.img
├── PCHM30-dtbo-75-WORKING.img
├── SHA256SUMS
├── flash-dtbo-windows.cmd
└── flash-dtbo-mt.sh
```

The 80 Hz and 90 Hz images are intentionally not included because both are unusable on the tested device.

---

## Windows flasher

Use:

```text
flash-dtbo-windows.cmd
```

Requirements:

- Windows ADB / platform-tools available in PATH
- phone connected through ADB
- root available through `su`
- the `.cmd` file and DTBO `.img` file(s) must be in the same folder

The script:

1. Searches its own folder for files whose names contain `dtbo` and end in `.img`.
2. Lists all matching images and asks which one to flash.
3. Backs up the current device DTBO to `PCHM30-dtbo-backup-before-flash.img` in the same folder.
4. Requires the user to type `yes` before writing.
5. Writes the selected image to `/dev/block/by-name/dtbo` with `dd`.
6. Runs `sync` and reboots.

---

## MT Manager terminal flasher

Use:

```text
flash-dtbo-mt.sh
```

Put the script and DTBO `.img` file(s) in the same folder on the phone.

Open MT Manager terminal and get root first:

```sh
su
```

Then execute the script, for example:

```sh
sh ./flash-dtbo-mt.sh
```

The script:

1. Searches the script directory for files whose names contain `dtbo` and end in `.img`.
2. Lists all matching images and asks which one to flash.
3. Backs up the current DTBO to `PCHM30-dtbo-backup-before-flash.img` in the same folder.
4. Requires `yes` before flashing.
5. Writes the selected image to `/dev/block/by-name/dtbo`.
6. Runs `sync` and reboots.

---

## Manual recovery

If an experimental DTBO causes a problem but fastboot is available, restore the verified 75 Hz image:

```bash
fastboot flash dtbo PCHM30-dtbo-75-WORKING.img
fastboot reboot
```

Or restore stock 60 Hz:

```bash
fastboot flash dtbo PCHM30-dtbo-60-STOCK.img
fastboot reboot
```

Keep the physical `dtbobak` partition untouched as an additional recovery copy.

---

## Warning

Display overclocking operates the panel/display stack outside the manufacturer's validated specification.

Observed failures on this device include:

- 80 Hz: display works but touch input is unavailable
- 90 Hz: display corruption / artifacts

Other possible failures include flickering, black screen, wake-from-sleep failure, increased power consumption and additional heat.

**Final tested daily configuration: 75 Hz.**
