#!/usr/bin/env bash
# Preserve the Run152 release label for existing boot/module compatibility.
# This step changes version metadata only; it does not import Linux 4.14.357
# stable fixes and makes no claim about runtime boot stability.
set -Eeuo pipefail

KERNEL_DIR="${KERNEL_DIR:-$GITHUB_WORKSPACE/$KERNEL_REL}"
cd "$KERNEL_DIR"
export PROOF="${GITHUB_WORKSPACE:-.}/kernel-version-proof.txt"

echo "[INFO] Current kernel directory: $(pwd)"
echo '[INFO] Preserving legacy 4.14.357-perf+ release label (metadata only)'

python3 - <<'PY'
import os
import re
from pathlib import Path

proof_path = Path(os.environ.get("PROOF", "kernel-version-proof.txt"))
previous_proof = proof_path.read_text(encoding="utf-8") if proof_path.is_file() else ""
previous_proof_path = proof_path.with_name("kernel-414186-proof.txt")

# Keep the preceding patch stage's measured results. Do not replace them with
# invented counts or silently turn a partial backport into a full stable update.
if previous_proof and "release_label_only=yes\n" not in previous_proof:
    previous_proof_path.write_text(previous_proof, encoding="utf-8")

makefile = Path("Makefile")
m_text = makefile.read_text(encoding="utf-8")
version = re.search(r"^VERSION\s*=\s*(\d+)$", m_text, re.M)
patchlevel = re.search(r"^PATCHLEVEL\s*=\s*(\d+)$", m_text, re.M)
sublevel = re.search(r"^SUBLEVEL\s*=\s*(\d+)$", m_text, re.M)
if not (version and patchlevel and sublevel):
    raise SystemExit("[FATAL] Cannot read the Makefile version fields")
if (version.group(1), patchlevel.group(1)) != ("4", "14"):
    raise SystemExit("[FATAL] The Run152 compatibility label is only for this 4.14 tree")
previous_version = ".".join(m.group(1) for m in (version, patchlevel, sublevel))
if "release_label_only=yes\n" in previous_proof:
    saved = re.search(r"^previous_makefile_version=(.+)$", previous_proof, re.M)
    if saved:
        previous_version = saved.group(1)

new_lines = []
for line in m_text.splitlines():
    if line.startswith("SUBLEVEL ="):
        new_lines.append("SUBLEVEL = 357")
    elif line.startswith("EXTRAVERSION ="):
        new_lines.append("EXTRAVERSION =")
    elif "expr $(VERSION) \\* 65536 + 0$(PATCHLEVEL) \\* 256 + 0$(SUBLEVEL)" in line:
        # Keep the existing Run152 LINUX_VERSION_CODE saturation behavior.
        new_lines.append(line.replace("0$(SUBLEVEL)", "255"))
    else:
        new_lines.append(line)
makefile.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
assert "SUBLEVEL = 357" in makefile.read_text(encoding="utf-8")

out_dir = os.environ.get("OUT_DIR")
if out_dir and Path(out_dir).is_dir():
    p_out = Path(out_dir)
    p_kr = p_out / "include" / "config" / "kernel.release"
    p_uts = p_out / "include" / "generated" / "utsrelease.h"
    p_kr.parent.mkdir(parents=True, exist_ok=True)
    p_uts.parent.mkdir(parents=True, exist_ok=True)
    p_kr.write_text("4.14.357-perf+\n", encoding="utf-8")
    p_uts.write_text('#define UTS_RELEASE "4.14.357-perf+"\n', encoding="utf-8")

proof_lines = [
    "kernel_release_label=4.14.357-perf+",
    "kernel_version_label=4.14.357",
    "sublevel_label=357",
    "release_label_only=yes",
    "full_4.14.357_backport=no",
    f"previous_makefile_version={previous_version}",
    "previous_stage_proof=" + (
        previous_proof_path.name if previous_proof_path.is_file() else "not_available"
    ),
]
proof_content = "\n".join(proof_lines) + "\n"
destinations = {proof_path.resolve(), Path("kernel-version-proof.txt").resolve()}
workspace = os.environ.get("GITHUB_WORKSPACE")
if workspace:
    destinations.add((Path(workspace) / "kernel-version-proof.txt").resolve())
for destination in destinations:
    destination.write_text(proof_content, encoding="utf-8")
print("[PASS] Recorded the compatibility label separately from stable-patch provenance")
PY

grep -q '^SUBLEVEL = 357$' Makefile
test -s "$PROOF"
grep -Fxq 'kernel_release_label=4.14.357-perf+' "$PROOF"
grep -Fxq 'release_label_only=yes' "$PROOF"
grep -Fxq 'full_4.14.357_backport=no' "$PROOF"
echo '[PASS] Legacy release label preserved; no 4.14.357 stable-upgrade claim'
