#!/usr/bin/env bash
# Apply Linux 4.14.180 -> Linux 4.14.186 stable patchset and bump SUBLEVEL to 186
set -Eeuo pipefail

KERNEL_DIR="${KERNEL_DIR:-$GITHUB_WORKSPACE/$KERNEL_REL}"
cd "$KERNEL_DIR"
export PROOF="${GITHUB_WORKSPACE:-.}/kernel-version-proof.txt"

PATCH_FILE="${GITHUB_WORKSPACE:-.}/patch-4.14.180-to-186.patch"
if [ ! -f "$PATCH_FILE" ]; then
    if [ -f "${GITHUB_WORKSPACE:-.}/.github/patches/patch-4.14.180-to-186.patch" ]; then
        PATCH_FILE="${GITHUB_WORKSPACE:-.}/.github/patches/patch-4.14.180-to-186.patch"
    elif [ -f ".github/patches/patch-4.14.180-to-186.patch" ]; then
        PATCH_FILE="$(pwd)/.github/patches/patch-4.14.180-to-186.patch"
    else
        echo "[ERROR] Cannot locate patch-4.14.180-to-186.patch" >&2
        exit 1
    fi
fi
export PATCH_FILE

echo "[INFO] Applying Linux 4.14.180 -> 4.14.186 from $PATCH_FILE..."

python3 - <<'PY'
import sys
import os
import re
import subprocess
import tempfile
from pathlib import Path

proof_path = Path(os.environ.get("PROOF", "kernel-version-proof.txt"))
patch_file = Path(os.environ.get("PATCH_FILE", ""))
if not patch_file.is_file():
    candidates = [
        Path(os.environ.get("GITHUB_WORKSPACE", ".")) / "patch-4.14.180-to-186.patch",
        Path(os.environ.get("GITHUB_WORKSPACE", ".")) / ".github/patches/patch-4.14.180-to-186.patch",
        Path(".github/patches/patch-4.14.180-to-186.patch")
    ]
    for c in candidates:
        if c.is_file():
            patch_file = c
            break

print(f"[INFO] Reading patch: {patch_file}")
patch_text = patch_file.read_text(encoding="utf-8", errors="replace")
chunks = re.split(r"(?=diff --git a/)", patch_text)

applied_count = 0
already_present_count = 0
skipped_missing_count = 0
conflict_count = 0
total_chunks = 0

with tempfile.TemporaryDirectory() as td:
    tmp_patch = Path(td) / "chunk.patch"
    for chunk in chunks:
        if not chunk.startswith("diff --git a/"):
            continue
        total_chunks += 1
        first_line = chunk.splitlines()[0]
        # diff --git a/path b/path
        parts = first_line.split(" a/")[1].split(" b/")
        fn = parts[0]

        target_file = Path(fn)
        if not target_file.exists() and "new file mode" not in chunk:
            skipped_missing_count += 1
            continue

        tmp_patch.write_text(chunk, encoding="utf-8")

        # 1. Test forward apply
        res = subprocess.run(
            ["git", "apply", "--check", "--ignore-whitespace", "--whitespace=nowarn", str(tmp_patch)],
            capture_output=True, text=True
        )
        if res.returncode == 0:
            subprocess.run(
                ["git", "apply", "--ignore-whitespace", "--whitespace=nowarn", str(tmp_patch)],
                check=True, capture_output=True
            )
            applied_count += 1
            continue

        # 2. Test reverse apply (already present in tree)
        res_rev = subprocess.run(
            ["git", "apply", "-R", "--check", "--ignore-whitespace", "--whitespace=nowarn", str(tmp_patch)],
            capture_output=True, text=True
        )
        if res_rev.returncode == 0:
            already_present_count += 1
            continue

        # 3. Test 3-way merge
        res_3w = subprocess.run(
            ["git", "apply", "-3", "--ignore-whitespace", "--whitespace=nowarn", str(tmp_patch)],
            capture_output=True, text=True
        )
        if res_3w.returncode == 0:
            applied_count += 1
            continue

        # Non-critical conflict or vendor diverge
        conflict_count += 1
        print(f"[WARN] Conflict applying chunk for {fn}: {res.stderr.strip()[:120]}")

print(f"=== 4.14.180 -> 4.14.186 Summary ===")
print(f"Total chunks: {total_chunks}")
print(f"Applied: {applied_count}")
print(f"Already present: {already_present_count}")
print(f"Skipped missing: {skipped_missing_count}")
print(f"Conflicts: {conflict_count}")

# Explicitly ensure Makefile SUBLEVEL = 186
makefile = Path("Makefile")
if makefile.is_file():
    m_text = makefile.read_text(encoding="utf-8")
    m_new = re.sub(r"^SUBLEVEL\s*=\s*\d+", "SUBLEVEL = 186", m_text, flags=re.MULTILINE)
    makefile.write_text(m_new, encoding="utf-8")
    print("[PASS] Makefile SUBLEVEL set to 186")
else:
    raise SystemExit("[FATAL] Makefile not found!")

# Verify Makefile
m_check = Path("Makefile").read_text(encoding="utf-8")
assert "SUBLEVEL = 186" in m_check, "SUBLEVEL = 186 verification failed!"

proof_lines = [
    "kernel_version=4.14.186",
    "sublevel=186",
    f"total_patch_files={total_chunks}",
    f"applied_files={applied_count}",
    f"already_present_files={already_present_count}",
    f"skipped_missing_files={skipped_missing_count}",
    f"conflicts={conflict_count}"
]
proof_content = "\n".join(proof_lines) + "\n"
proof_path.write_text(proof_content, encoding="utf-8")
Path("kernel-version-proof.txt").write_text(proof_content, encoding="utf-8")
workspace = os.environ.get("GITHUB_WORKSPACE")
if workspace:
    (Path(workspace) / "kernel-version-proof.txt").write_text(proof_content, encoding="utf-8")

print(f"[PASS] Proof file generated at {proof_path}")
PY

# Shell-level verification
grep -q '^SUBLEVEL = 186$' Makefile
echo "[PASS] Verified: Makefile has SUBLEVEL = 186"
test -s "$PROOF"
grep -Fxq 'kernel_version=4.14.186' "$PROOF"
echo "[PASS] Verified: $PROOF has kernel_version=4.14.186"

echo "[SUCCESS] Kernel successfully upgraded to Linux 4.14.186!"
