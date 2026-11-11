#!/usr/bin/env bash
# Reproduce Run 202 with the phone-tested ARM64 boot interfaces and storage.
set -Eeuo pipefail
cd "$GITHUB_WORKSPACE/$KERNEL_REL"

report="$GITHUB_WORKSPACE/openela-report"
source_delta="$GITHUB_WORKSPACE/run202-reference/openela-report/candidate.patch"
mkdir -p "$report"
printf '%s  %s\n' 3f8ff5e24fb3fcac28f09447a6b4b45d996924e0ce378fe941cfc28cd6c86a97 "$source_delta" | sha256sum -c -

git diff --name-only --ignore-submodules=all -z HEAD -- |
    git --literal-pathspecs add -u --pathspec-from-file=- --pathspec-file-nul
if ! git diff --cached --quiet --ignore-submodules=all; then
    git -c user.name='PCHM30 OpenELA CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit -m 'kernel: snapshot the prepared PCHM30 source'
fi
run194="$GITHUB_WORKSPACE/run194-4.14.190.patch"
run197="$GITHUB_WORKSPACE/run197-4.14.200.patch"
test "$(git hash-object "$run194")" = 586292d51f13443b0b609e842344b36f0fe579a6
test "$(git hash-object "$run197")" = 06fa2f6f585fc399c27530aa221746dbdf12395f
git apply --index "$run194"
git apply --index "$run197"
git -c user.name='PCHM30 OpenELA CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m 'kernel: reconstruct the phone-tested Run 197 source'
vendor=$(git rev-parse HEAD)
grep -Fxq 'SUBLEVEL = 200' Makefile

git apply --index "$source_delta"
boot_paths=(
    arch/arm64/Kconfig
    arch/arm64/Kconfig.platforms
    arch/arm64/Makefile
    arch/arm64/include/asm
    arch/arm64/kernel
    arch/arm64/kvm
    arch/arm64/mm
    drivers/of/fdt.c
)
git diff --cached --no-renames --name-only -z "$vendor" -- "${boot_paths[@]}" > "$report/boot-compatibility-paths.bin"
test -s "$report/boot-compatibility-paths.bin"
tr '\0' '\n' < "$report/boot-compatibility-paths.bin" > "$report/boot-compatibility-paths.txt"
git diff --cached --no-renames --binary "$vendor" -- "${boot_paths[@]}" > "$report/boot-compatibility-deferred.patch"
git --literal-pathspecs restore --source="$vendor" --staged --worktree \
    --pathspec-from-file="$report/boot-compatibility-paths.bin" --pathspec-file-nul
git diff --cached --quiet "$vendor" -- "${boot_paths[@]}"
git diff --quiet -- "${boot_paths[@]}"
git diff --cached --no-renames --binary "$vendor" > "$report/candidate.patch"
git diff --cached --stat "$vendor" > "$report/applied-stat.txt"
grep -Fxq 'SUBLEVEL = 357' Makefile
git -c user.name='PCHM30 OpenELA CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m 'kernel: integrate OpenELA with the verified PCHM30 boot interfaces'

# The Run 202 vendor-only storage patch is outside candidate.patch. Keeping the
# reconstructed vendor source here also retains the Run 197 UFS/MMC/F2FS paths.
printf 'source_run=42992776272\nreference_run=42973424849\nactive_storage=Run197\n' > "$report/boot-compatibility.txt"
: > "$report/conflicts.txt"
python3 - "$report" "$vendor" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

report = Path(sys.argv[1])
source = json.loads(Path(report.parent / "run202-reference/openela-report/merge-summary.json").read_text())
if source["conflict_count"] != 0 or source["target_commit"] != "1e6347375d088ecc896aabb067131d0f9e3c0575":
    raise SystemExit("The Run 202 artifact does not match the reviewed OpenELA source")
source["prepared_vendor_commit"] = sys.argv[2]
source["candidate_paths"] = subprocess.check_output(
    ["git", "diff", "--name-only", "-z", sys.argv[2], "HEAD"]
).count(b"\0")
source["boot_compatibility_paths"] = (report / "boot-compatibility-paths.txt").read_text().splitlines()
source["boot_compatibility_reference"] = "Run 197"
(report / "merge-summary.json").write_text(json.dumps(source, indent=2) + "\n")
print(f"OpenELA source paths applied: {source['candidate_paths']}")
print(f"ARM64 and FDT paths retained from Run 197: {len(source['boot_compatibility_paths'])}")
PY

# The active memory-tracking functions come from the reconstructed OPPO
# vendor tree via mm/malloc_track, outside the kernel Git index.
python3 - "$report" <<'PY'
import difflib
import sys
from pathlib import Path

changes = []
for name, symbol in (
    ("vmalloc_track.c", "create_vmalloc_debug"),
    ("slub_track.c", "create_kmalloc_debug"),
):
    source = Path("mm/malloc_track") / name
    if not source.is_file():
        continue
    original = source.read_text()
    old = f"\nint __init {symbol}("
    export = f"EXPORT_SYMBOL({symbol});"
    if original.count(old) != 1 or export not in original:
        raise SystemExit(f"Unexpected OPPO tracking implementation in {source}")
    fixed = original.replace(old, f"\nint {symbol}(", 1)
    source.write_text(fixed)
    changes.extend(difflib.unified_diff(
        original.splitlines(keepends=True), fixed.splitlines(keepends=True),
        fromfile=f"a/{source}", tofile=f"b/{source}",
    ))
    print(f"Keep the active OPPO tracking implementation resident: {symbol}", flush=True)

if changes:
    (Path(sys.argv[1]) / "oppo-vendor-runtime.patch").write_text("".join(changes))
PY


printf 'kernel_version=4.14.357\nsublevel=357\nupstream_base=%s\nupstream_commit=%s\nintegrated_commit=%s\nconflicts=0\nboot_compat_reference=Run197\n' \
    bae31eef2a167ef160ab2703b6a2f5bbecd98d92 1e6347375d088ecc896aabb067131d0f9e3c0575 \
    "$(git rev-parse HEAD)" > "$GITHUB_WORKSPACE/kernel-version-proof.txt"
