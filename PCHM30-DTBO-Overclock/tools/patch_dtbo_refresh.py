#!/usr/bin/env python3

import argparse
import hashlib
from pathlib import Path

STOCK_SHA256 = "f50b9d85a6ec60b6ba773cdc1c9af3a920de2257cc76eca191a3f9b7c4cd63a5"
SIZE = 25165824

POSITIONS = [
    1509878,
    1512002,
    1514486,
    1516610,
    1519098,
]

VALUES = {
    75: 0x4b,
    90: 0x5a,
}

p = argparse.ArgumentParser(
    description="Patch OPPO A11x / PCHM30 DTBO refresh rate"
)
p.add_argument("input")
p.add_argument("output")
p.add_argument("--hz", type=int, required=True, choices=[75, 90])
args = p.parse_args()

src = Path(args.input)
dst = Path(args.output)

data = bytearray(src.read_bytes())

if len(data) != SIZE:
    raise SystemExit(
        f"ERROR: unexpected size {len(data)}, expected {SIZE}"
    )

sha = hashlib.sha256(data).hexdigest()

print("Input SHA256:", sha)

if sha != STOCK_SHA256:
    raise SystemExit(
        "ERROR: input is not the verified PCHM30 stock DTBO"
    )

target = VALUES[args.hz]

changed = 0

for pos in POSITIONS:
    i = pos - 1

    if data[i] != 0x3c:
        raise SystemExit(
            f"ERROR: offset {pos}: expected 0x3c, "
            f"got 0x{data[i]:02x}"
        )

    data[i] = target
    changed += 1

    print(
        f"[PATCH] offset {pos}: "
        f"0x3c -> 0x{target:02x}"
    )

if changed != 5:
    raise SystemExit(
        f"ERROR: expected 5 changes, got {changed}"
    )

dst.write_bytes(data)

print()
print("[PASS]")
print("Refresh rate :", args.hz, "Hz")
print("Changed bytes:", changed)
print("Output size  :", len(data))
print(
    "Output SHA256:",
    hashlib.sha256(data).hexdigest()
)

if args.hz == 90:
    print()
    print(
        "WARNING: 90 Hz caused display corruption "
        "on the tested PCHM30."
    )
