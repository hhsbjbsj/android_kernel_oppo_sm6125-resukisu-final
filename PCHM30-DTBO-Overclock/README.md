# OPPO A11x / PCHM30 DTBO Display Overclock

Device: OPPO A11x / PCHM30 / 19021  
SoC: Qualcomm SM6125  
Display: 720x1600

## Test results

| Refresh rate | Result |
|---|---|
| 60 Hz | Stock / stable |
| 75 Hz | Working / tested |
| 90 Hz | Unstable / display corruption |

**Recommended refresh rate: 75 Hz**

75 Hz has been tested on the real device. Android correctly reports and runs the display at 75 Hz.

90 Hz was tested using the same DTBO modification method, but caused visible display corruption. The 90 Hz image is therefore not included.

## DTBO information

PCHM30 has standalone DTBO partitions:

```text
dtbo
dtbobak
ro.boot.dtbo_idx=10
entry_count = 32
page_size   = 4096
entry       = 10
dt_size     = 173731
dt_offset   = 1489306
Entry 10 contains five PCHM30 / OPPO 19021 720x1600 panels:

ILI9881 AUO
NT36525B BOE
ILI9881 Tianma
NT36525B HLT
ILI9881 INX

Original refresh property:

qcom,mdss-dsi-panel-framerate = 0x3c

Values:

0x3c = 60 Hz
0x4b = 75 Hz
0x5a = 90 Hz
75 Hz modification

Exactly five bytes are changed in the complete stock dtbo.img.

1-based offsets:

1509878
1512002
1514486
1516610
1519098

All five changes:

0x3c -> 0x4b

Verification:

TOTAL DTBO DIFFERENCES: 5
IMAGE SIZE: 25165824 bytes
SHA256

Stock 60 Hz:

f50b9d85a6ec60b6ba773cdc1c9af3a920de2257cc76eca191a3f9b7c4cd63a5

Working 75 Hz:

a2a049601f096c8e3555270c07f41f19533bbbd7b52aa03898e10a38c5871c87
Included images
images/PCHM30-dtbo-60-STOCK.img
images/PCHM30-dtbo-75-WORKING.img

The 90 Hz image is intentionally omitted because it caused display corruption.

Flash 75 Hz with root
adb push PCHM30-dtbo-75-WORKING.img /sdcard/dtbo-75.img
adb shell su -c "dd if=/sdcard/dtbo-75.img of=/dev/block/by-name/dtbo bs=4M"
adb shell su -c "sync"
adb reboot
Recovery

Restore working 75 Hz:

fastboot flash dtbo PCHM30-dtbo-75-WORKING.img
fastboot reboot

Restore stock 60 Hz:

fastboot flash dtbo PCHM30-dtbo-60-STOCK.img
fastboot reboot

Keep the physical dtbobak partition untouched as an additional recovery copy.

Warning

Display overclocking operates the panel outside its original validated specification.

Possible failures include display corruption, flickering, black screen, wake-from-sleep failure, increased power consumption and additional heat.

The tested device is stable at 75 Hz but produces display corruption at 90 Hz.

Final recommendation: 75 Hz.
