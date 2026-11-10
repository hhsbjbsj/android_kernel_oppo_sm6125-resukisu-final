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
vendor=$(git rev-parse HEAD)
git diff --quiet HEAD -- || {
    echo "Commit the prepared OPPO source before applying OpenELA." >&2
    exit 1
}

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
entries = (report / "merge-tree.bin").read_bytes().split(b"\0")
merged_tree = entries[0].decode("ascii")
conflicts = set()
for entry in entries[1:]:
    if not entry:
        break
    match = re.fullmatch(rb"[0-7]{6} [0-9a-f]{40} [123]\t(.+)", entry, re.S)
    if not match:
        raise SystemExit(f"Unexpected merge-tree index record: {entry!r}")
    conflicts.add(os.fsdecode(match[1]))

changed = git("diff", "--no-renames", "--name-only", "-z", vendor, merged_tree)
paths = [os.fsdecode(path) for path in changed.split(b"\0") if path]
excluded = set(conflicts)
if conflicts:
    # Keep the actual base release and omit OpenELA's release bookkeeping.
    excluded.add("Makefile")
    excluded.update(path for path in paths if path.startswith(".elts/"))

applied = [path for path in paths if path not in excluded]
proof = {
    "base_commit": os.environ["OPENELA_BASE"],
    "target_commit": os.environ["OPENELA_TARGET"],
    "prepared_vendor_commit": vendor,
    "source_merge_clean": not conflicts,
    "conflict_count": len(conflicts),
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
