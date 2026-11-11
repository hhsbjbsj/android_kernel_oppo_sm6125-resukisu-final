#!/usr/bin/env bash
# Replay the complete Linux 4.14.186 -> 4.14.190 delta on the prepared Run 191 tree.
set -Eeuo pipefail
cd "$GITHUB_WORKSPACE/$KERNEL_REL"
report="$GITHUB_WORKSPACE/openela-report/stable190"
mkdir -p "$report"
base=f49027cf4ff06c384e4e16a8d45dc77bf6af3577
target=e5a54aa2d312e75fe4bc66c7b84400b02266e946
upstream=https://github.com/gregkh/linux.git
for version in 186 190; do
    timeout 300 git fetch --no-tags --depth=1 "$upstream" "refs/tags/v4.14.$version"
    expected=$base
    if [ "$version" = 190 ]; then expected=$target; fi
    test "$(git rev-parse 'FETCH_HEAD^{commit}')" = "$expected"
done

git diff --name-only --ignore-submodules=all -z HEAD -- |
    git --literal-pathspecs add -u --pathspec-from-file=- --pathspec-file-nul
if ! git diff --cached --quiet --ignore-submodules=all; then
    git -c user.name='PCHM30 stable CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit -m 'ci: snapshot the prepared Run 191 kernel'
fi
vendor=$(git rev-parse HEAD)

snapshot() {
    git -c user.name='PCHM30 stable CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit-tree "$1^{tree}" -p "$base" -m "$2"
}
ours=$(snapshot "$vendor" 'Phone-tested PCHM30 build baseline')
theirs=$(snapshot "$target" 'Official Linux 4.14.190')
status=0
git -c merge.renames=false merge-tree --write-tree -z "$ours" "$theirs" > "$report/merge-tree.bin" || status=$?
if (( status > 1 )); then exit "$status"; fi

python3 - "$report" "$base" "$target" "$vendor" <<'PY'
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

report = Path(sys.argv[1])
base, target, vendor = sys.argv[2:]

def git(*args, **kwargs):
    return subprocess.check_output(["git", *args], **kwargs)

entries = (report / "merge-tree.bin").read_bytes().split(b"\0")
tree = entries[0].decode()
conflicts = set()
for line in entries[1:]:
    if not line:
        break
    match = re.fullmatch(rb"[0-7]{6} [0-9a-f]{40} [123]\t(.+)", line, re.S)
    if not match:
        raise SystemExit(f"Unexpected merge index entry: {line!r}")
    conflicts.add(os.fsdecode(match[1]))

resolved = {}
with TemporaryDirectory() as tmp:
    env = dict(os.environ, GIT_INDEX_FILE=str(Path(tmp) / "index"))
    git("read-tree", tree, env=env)
    for path in sorted(conflicts):
        original = git("--literal-pathspecs", "ls-tree", "-z", vendor, "--", path)
        source = git("--literal-pathspecs", "ls-tree", "-z", base, "--", path)
        dest = git("--literal-pathspecs", "ls-tree", "-z", target, "--", path)
        records = [record.split(b"\t", 1)[0].split() for record in (original, source, dest)]
        if any(len(record) != 3 or record[0] not in (b"100644", b"100755") for record in records):
            continue
        (mode, _, oid), (source_mode, _, source_oid), (target_mode, _, target_oid) = records
        if source_mode != target_mode:
            continue
        before = git("cat-file", "blob", oid.decode())
        if path == "arch/arm64/kernel/vmlinux.lds.S":
            upstream_old = b"\t.altinstr_replacement : {\n\t\t*(.altinstr_replacement)\n\t}\n"
            vendor_old = b"\t.altinstr_replacement : {\n\t\tKEEP(*(.altinstr_replacement))\n\t}\n"
            upstream_before = git("cat-file", "blob", source_oid.decode())
            upstream_after = git("cat-file", "blob", target_oid.decode())
            if (before.count(vendor_old) != 1 or upstream_before.count(upstream_old) != 1
                    or upstream_before.replace(upstream_old, b"", 1) != upstream_after):
                continue
            after = before.replace(vendor_old, b"", 1)
            result = "adapted-ARM64-alternative-linker-section"
        else:
            patch = git("--literal-pathspecs", "diff", "--binary", "--no-renames", base, target, "--", path)
            if not patch or b"\0" in before or b"\nGIT binary patch" in patch:
                continue
            file = Path(tmp) / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(before)
            file.chmod(0o755 if mode == b"100755" else 0o644)

            def apply(*flags):
                return subprocess.run(["git", "apply", "--whitespace=nowarn", *flags],
                                      cwd=tmp, input=patch, capture_output=True).returncode == 0

            forward = apply("--check")
            reverse = apply("--reverse", "--check")
            if forward == reverse:
                continue
            if forward:
                if not apply():
                    continue
                after = file.read_bytes()
                if after == before or not apply("--reverse") or file.read_bytes() != before:
                    continue
                result = "exact-upstream-hunks-applied"
            else:
                if not apply("--reverse") or not apply() or file.read_bytes() != before:
                    continue
                after = before
                result = "exact-upstream-hunks-already-present"

        after_oid = git("hash-object", "-w", "--stdin", input=after).decode().strip()
        git("update-index", "--cacheinfo", f"{mode.decode()},{after_oid},{path}", env=env)
        resolved[path] = result
    tree = git("write-tree", env=env).decode().strip()

conflicts -= resolved.keys()
upstream_paths = git("diff", "--name-only", "-z", "--no-renames", base, target)
changed_paths = git("diff", "--name-only", "-z", "--no-renames", vendor, tree)
summary = {
    "base": base,
    "target": target,
    "prepared_run191_tree": vendor,
    "upstream_paths": upstream_paths.count(b"\0"),
    "changed_paths": changed_paths.count(b"\0"),
    "reviewed": resolved,
    "unresolved_paths": sorted(conflicts),
}
(report / "merge-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2), flush=True)
if conflicts:
    for path in sorted(conflicts):
        data = git("--literal-pathspecs", "diff", "--no-renames", base, vendor, "--", path)
        directory = report / "conflicts" / path
        directory.parent.mkdir(parents=True, exist_ok=True)
        directory.with_name(directory.name + ".vendor.diff").write_bytes(data)
    raise SystemExit("Review the remaining 4.14.190 merge conflicts before compiling the updated tree")

header = git("show", f"{tree}:arch/arm64/include/asm/alternative.h")
assembly = git("show", f"{tree}:arch/arm64/kernel/alternative.c")
linker = git("show", f"{tree}:arch/arm64/kernel/vmlinux.lds.S")
if (b".subsection 1" not in header or b".altinstr_replacement" in header + linker
        or b"return !(pc >= replptr && pc <= (replptr + alt->alt_len));" not in assembly
        or b"KEEP(*(.altinstructions))" not in linker):
    raise SystemExit("ARM64 instruction alternatives and vendor linker retention must be migrated together")
version = git("show", f"{tree}:Makefile")
if b"SUBLEVEL = 190\n" not in version:
    raise SystemExit("The merged upstream Makefile does not identify Linux 4.14.190")

(report / "candidate.patch").write_bytes(git("diff", "--binary", "--no-renames", vendor, tree))
PY

git apply --index --check "$report/candidate.patch"
git apply --index "$report/candidate.patch"
git diff --cached --stat > "$report/applied-stat.txt"
git -c user.name='PCHM30 stable CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m 'kernel: merge the Linux 4.14.190 stable source delta on Run 191'
