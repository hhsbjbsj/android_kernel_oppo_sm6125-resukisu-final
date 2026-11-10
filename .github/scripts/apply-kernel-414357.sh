#!/usr/bin/env bash
# Merge the upstream stable/OpenELA source changes onto the OPPO/Android tree.
# The default mode refuses unresolved source conflicts. CI may compile a partial
# tree for diagnosis without advancing its patchlevel or packaging a release.
set -Eeuo pipefail

cd "${KERNEL_DIR:-$GITHUB_WORKSPACE/$KERNEL_REL}"
report="$GITHUB_WORKSPACE/openela-report"
mkdir -p "$report"
rm -f -- "$GITHUB_WORKSPACE/kernel-version-proof.txt"

base=ab9dfda232481dcfaf549ce774004d116fc80c13
target=1e6347375d088ecc896aabb067131d0f9e3c0575
# The legacy preparation flow stages generated files and nested vendor
# repositories. Snapshot remaining tracked source edits without changing any
# nested repository's commit or collecting untracked build outputs.
git diff --name-status --ignore-submodules=all HEAD -- > "$report/prepared-tracked-changes.tsv"
if [[ -s "$report/prepared-tracked-changes.tsv" ]]; then
    git diff --name-only --ignore-submodules=all -z HEAD -- | \
        git --literal-pathspecs add -u --pathspec-from-file=- --pathspec-file-nul
fi
if ! git diff --cached --quiet --ignore-submodules=all; then
    git -c user.name='PCHM30 OpenELA CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit -m 'ci: snapshot prepared PCHM30 source'
fi
git diff --quiet --ignore-submodules=all HEAD --
vendor=$(git rev-parse HEAD)

timeout 300 git fetch --no-tags --depth=1 https://github.com/gregkh/linux.git refs/tags/v4.14.180
test "$(git rev-parse 'FETCH_HEAD^{commit}')" = "$base"
timeout 300 git fetch --no-tags --depth=1 https://github.com/openela/kernel-lts.git refs/tags/v4.14.357-openela
test "$(git rev-parse 'FETCH_HEAD^{commit}')" = "$target"
git show "$target:Makefile" > "$report/upstream-makefile.txt"
grep -Fxq 'SUBLEVEL = 357' "$report/upstream-makefile.txt"

# The vendor snapshot has independent Git history. Make the stable 4.14.180
# tree the explicit comparison base without importing vendor-incompatible
# source wholesale. The temporary commits only exist on this runner.
snapshot() {
    git -c user.name='PCHM30 OpenELA CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit-tree "$1^{tree}" -p "$base" -m "$2"
}
ours=$(snapshot "$vendor" 'Prepared PCHM30 kernel')
theirs=$(snapshot "$target" 'Pinned OpenELA upstream')
git diff --no-renames --name-status "$base" "$target" > "$report/upstream-paths.tsv"
merge_status=0
git -c merge.renames=false merge-tree --write-tree -z "$ours" "$theirs" > "$report/merge-tree.bin" || merge_status=$?
if (( merge_status > 1 )); then exit "$merge_status"; fi

# Keep the strict conflict list for the release gate. For the compile trial,
# retain the vendor side of overlapping hunks while merging disjoint hunks.
if (( merge_status == 1 )) && [[ "${OPENELA_COMPILE_CANDIDATE:-}" == 1 ]]; then
    candidate_status=0
    git -c merge.renames=false merge-tree --write-tree -z -X ours "$ours" "$theirs" \
        > "$report/compile-merge-tree.bin" || candidate_status=$?
    if (( candidate_status > 1 )); then exit "$candidate_status"; fi
fi

export OPENELA_VENDOR="$vendor" OPENELA_BASE="$base" OPENELA_TARGET="$target" OPENELA_REPORT="$report"
python3 - <<'PY'
import json
import os
import re
import subprocess
from pathlib import Path

def git(*args):
    return subprocess.check_output(["git", *args])

report = Path(os.environ["OPENELA_REPORT"])
vendor = os.environ["OPENELA_VENDOR"]
def read_merge(path):
    entries = path.read_bytes().split(b"\0")
    conflicts = set()
    for entry in entries[1:]:
        if not entry:
            break
        match = re.fullmatch(rb"[0-7]{6} [0-9a-f]{40} [123]\t(.+)", entry, re.S)
        if not match:
            raise SystemExit(f"Unexpected merge-tree index record: {entry!r}")
        conflicts.add(os.fsdecode(match[1]))
    return entries[0].decode("ascii"), conflicts

# Floppy's matching Kconfig changes can be replayed on these exact inputs.
# Keep the vendor menu boundaries and verify the final blobs against Floppy.
def resolve_kconfig(tree):
    from tempfile import TemporaryDirectory

    target = os.environ["OPENELA_TARGET"]
    fixes = {
        "drivers/char/Kconfig": (
            "b92228b9851d68c3d75cf5a8525d86a928978c65",
            "e329d1cc019ae7e3736d77e83690af17e6db7270",
            "3f34cdc45309f770fe491ea4b9c01fea7bfa1aff",
        ),
        "lib/Kconfig": (
            "eec1142136dc065ed61a49034e2e54c3e4662446",
            "1a33e93659517f11ee7c232dc911fa757f20b116",
            "89b299f7f06ff8aa812db33281d77f578d785129",
        ),
    }
    resolved = set()
    with TemporaryDirectory() as temporary:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(temporary) / "index"))

        def index(*args):
            return subprocess.check_output(["git", *args], env=env)

        index("read-tree", tree)
        for path, (vendor_oid, upstream_oid, expected_oid) in fixes.items():
            actual_oid = git("rev-parse", f"{vendor}:{path}").decode().strip()
            if git("rev-parse", f"{target}:{path}").decode().strip() != upstream_oid:
                raise SystemExit(f"Unexpected upstream Kconfig blob: {path}")

            content = git("cat-file", "blob", actual_oid)
            upstream = git("cat-file", "blob", upstream_oid)
            if path == "drivers/char/Kconfig":
                begin = upstream.index(b"config RANDOM_TRUST_CPU\n")
                end = upstream.index(b"\nendmenu", begin)
                rng_options = upstream[begin:end] + b"\n"
                if rng_options not in content:
                    menu_end = b"\nendmenu\n\nconfig OKL4_PIPE\n"
                    if (content.count(menu_end) != 1 or b"config RANDOM_TRUST_CPU\n" in content
                            or b"config RANDOM_TRUST_BOOTLOADER\n" in content):
                        print(f"Unrecognized prepared Kconfig, leaving unresolved: {path}: {actual_oid}", flush=True)
                        continue
                    content = content.replace(menu_end, b"\n" + rng_options + menu_end[1:], 1)
            else:
                # The build adds LZ4K/LZ4KD options to this file before the
                # merge. Apply only OpenELA's HAVE_ARCH_BITREVERSE change.
                old = b"config HAVE_ARCH_BITREVERSE\n\tbool\n\tdefault n\n\tdepends on BITREVERSE\n\thelp\n"
                new = b"config HAVE_ARCH_BITREVERSE\n\tbool\n\tdefault n\n\thelp\n"
                if content.count(old) == 1 and new not in content:
                    content = content.replace(old, new, 1)
                elif content.count(new) != 1:
                    print(f"Unrecognized prepared Kconfig, leaving unresolved: {path}: {actual_oid}", flush=True)
                    continue
            oid = subprocess.check_output(["git", "hash-object", "-w", "--stdin"], input=content).decode().strip()
            if actual_oid == vendor_oid and oid != expected_oid:
                raise SystemExit(f"Resolved Kconfig differs from the reviewed Floppy blob: {path}: {oid}")
            mode = git("ls-tree", vendor, "--", path).split()[0].decode()
            index("update-index", "--add", "--cacheinfo", f"{mode},{oid},{path}")
            resolved.add(path)
        return index("write-tree").decode().strip(), resolved

merged_tree, conflicts = read_merge(report / "merge-tree.bin")
merged_tree, resolved = resolve_kconfig(merged_tree)
conflicts -= resolved
candidate = report / "compile-merge-tree.bin"
if conflicts and candidate.exists():
    merged_tree, excluded = read_merge(candidate)
    merged_tree, trial_resolved = resolve_kconfig(merged_tree)
    excluded -= trial_resolved
else:
    excluded = set(conflicts)
(report / "resolved-paths.txt").write_text("".join(path + "\n" for path in sorted(resolved)))
changed = git("diff", "--no-renames", "--name-only", "-z", vendor, merged_tree)
paths = [os.fsdecode(path) for path in changed.split(b"\0") if path]
if conflicts:
    # Keep the paired vendor Kbuild files for the trial. The hunk merge
    # can split Makefile conditionals, and the existing asm/bugs.h wrapper
    # may still reference the generic header.
    excluded.update({"Makefile", "scripts/Makefile.build", "include/asm-generic/bugs.h"})
    excluded.update(path for path in paths if path.startswith(".elts/"))
(report / "deferred-paths.txt").write_text("".join(path + "\n" for path in sorted(excluded)))

applied = [path for path in paths if path not in excluded]
proof = {
    "base_commit": os.environ["OPENELA_BASE"],
    "target_commit": os.environ["OPENELA_TARGET"],
    "prepared_vendor_commit": vendor,
    "source_merge_clean": not conflicts,
    "conflict_count": len(conflicts),
    "reviewed_kconfig_resolutions": sorted(resolved),
    "candidate_strategy": "vendor-overlap-hunks" if candidate.exists() else "strict",
    "deferred_paths": len(excluded),
    "candidate_paths": len(applied),
}
(report / "merge-summary.json").write_text(json.dumps(proof, indent=2) + "\n")
(report / "conflicts.txt").write_text("".join(path + "\n" for path in sorted(conflicts)))
(report / "candidate-paths.txt").write_text("".join(path + "\n" for path in applied))
print(json.dumps(proof), flush=True)
if conflicts and os.environ.get("OPENELA_COMPILE_CANDIDATE") != "1":
    raise SystemExit("OpenELA has unresolved source conflicts. See conflicts.txt.")
if not applied:
    raise SystemExit("No OpenELA source changes to apply.")
with (report / "candidate.patch").open("wb") as patch:
    subprocess.run(
        ["git", "--literal-pathspecs", "diff", "--binary", "--no-renames",
         vendor, merged_tree, "--", *applied],
        check=True, stdout=patch,
    )
PY

git apply --check --index "$report/candidate.patch"
git apply --index "$report/candidate.patch"
git diff --cached --stat > "$report/applied-stat.txt"
git diff --cached --quiet && { echo 'OpenELA staged no source changes' >&2; exit 1; }
git -c user.name='PCHM30 OpenELA CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m 'kernel: integrate OpenELA 4.14.357 source changes for CI'

if [[ -s "$report/conflicts.txt" ]]; then
    echo 'Compiling a partial OpenELA candidate. See the unresolved paths in the artifact.'
    exit 0
fi

grep -Fxq 'SUBLEVEL = 357' Makefile
printf 'kernel_version=4.14.357\nsublevel=357\nupstream_base=%s\nupstream_commit=%s\nintegrated_commit=%s\nconflicts=0\n' \
    "$base" "$target" "$(git rev-parse HEAD)" > "$GITHUB_WORKSPACE/kernel-version-proof.txt"
