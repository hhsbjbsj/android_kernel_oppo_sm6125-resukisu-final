#!/usr/bin/env bash
# Apply the official Linux 4.14.190 -> 4.14.200 delta on the tested Run 194 tree.
set -Eeuo pipefail
cd "$GITHUB_WORKSPACE/$KERNEL_REL"
report="$GITHUB_WORKSPACE/openela-report/stable200"
mkdir -p "$report"
base=e5a54aa2d312e75fe4bc66c7b84400b02266e946
target=bae31eef2a167ef160ab2703b6a2f5bbecd98d92
upstream=https://github.com/gregkh/linux.git
for version in 190 200; do
    timeout 300 git fetch --no-tags --depth=1 "$upstream" "refs/tags/v4.14.$version"
    expected=$base
    if [ "$version" = 200 ]; then expected=$target; fi
    test "$(git rev-parse 'FETCH_HEAD^{commit}')" = "$expected"
done

git diff --name-only --ignore-submodules=all -z HEAD -- |
    git --literal-pathspecs add -u --pathspec-from-file=- --pathspec-file-nul
if ! git diff --cached --quiet --ignore-submodules=all; then
    git -c user.name='PCHM30 stable CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit -m 'ci: snapshot the prepared Run 191 kernel'
fi
previous="$GITHUB_WORKSPACE/run194-4.14.190.patch"
test "$(git hash-object "$previous")" = 586292d51f13443b0b609e842344b36f0fe579a6
git apply --index "$previous"
git -c user.name='PCHM30 stable CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m 'kernel: reconstruct the exact Run 194 stable source delta'
vendor=$(git rev-parse HEAD)

snapshot() {
    git -c user.name='PCHM30 stable CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit-tree "$1^{tree}" -p "$base" -m "$2"
}
ours=$(snapshot "$vendor" 'Phone-tested PCHM30 Run 194 build baseline')
theirs=$(snapshot "$target" 'Official Linux 4.14.200')
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
        if path == "arch/arm64/kvm/hyp/entry.S" and oid.decode() == "2c2b588a73b7baf7b5dd14a0fc71ef3efd95903b":
            # The vendor uses x29 for the guest context and preserves x18 for SCS.
            edits = (
                (b"#include <asm/asm-offsets.h>",
                 b"#include <asm/alternative.h>\n#include <asm/asm-offsets.h>"),
                (b"\tadd\tx29, x0, #VCPU_CONTEXT",
                 b"\t// Now the host state is stored if we have a pending RAS SError it must\n\t// affect the host. If any asynchronous exception is pending we defer\n\t// the guest entry.\n\tmrs\tx1, isr_el1\n\tcbz\tx1,  1f\n\tmov\tx0, #ARM_EXCEPTION_IRQ\n\tret\n\n1:\n\tadd\tx29, x0, #VCPU_CONTEXT"),
                (b"\t.global\tabort_guest_exit_start\nabort_guest_exit_start:\n\n\tisb\n\n\t.global\tabort_guest_exit_end\nabort_guest_exit_end:\n\n\t// If the exception took place, restore the EL1 exception\n\t// context so that we can report some information.\n\t// Merge the exception code with the SError pending bit.\n\ttbz\tx0, #ARM_EXIT_WITH_SERROR_BIT, 1f\n\tmsr\telr_el2, x2\n\tmsr\tesr_el2, x3\n\tmsr\tspsr_el2, x4\n\torr\tx0, x0, x5\n1:\tret\n",
                 b"abort_guest_exit_start:\n\n\tisb\n\nabort_guest_exit_end:\n\tmsr\tdaifset, #4\t// Mask aborts\n\tret\n\n\t_kvm_extable\tabort_guest_exit_start, 9997f\n\t_kvm_extable\tabort_guest_exit_end, 9997f\n9997:\n\tmsr\tdaifset, #4\t// Mask aborts\n\tmov\tx0, #(1 << ARM_EXIT_WITH_SERROR_BIT)\n\n\t// restore the EL1 exception context so that we can report some\n\t// information. Merge the exception code with the SError pending bit.\n\tmsr\telr_el2, x2\n\tmsr\tesr_el2, x3\n\tmsr\tspsr_el2, x4\n\torr\tx0, x0, x5\n1:\tret\n"),
            )
            after = before
            for old, new in edits:
                if after.count(old) != 1:
                    raise SystemExit("Unexpected vendor ARM64 KVM entry layout")
                after = after.replace(old, new, 1)
            result = "adapted-KVM-entry-with-vendor-x18-preservation"
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
    "prepared_run194_tree": vendor,
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
    raise SystemExit("Review the remaining 4.14.200 merge conflicts before compiling the updated tree")

header = git("show", f"{tree}:arch/arm64/include/asm/alternative.h")
linker = git("show", f"{tree}:arch/arm64/kernel/vmlinux.lds.S")
cpu = git("show", f"{tree}:arch/arm64/kernel/cpufeature.c")
kvm_entry = git("show", f"{tree}:arch/arm64/kvm/hyp/entry.S")
kvm_switch = git("show", f"{tree}:arch/arm64/kvm/hyp/switch.c")
alternative = header.split(b'"664:', 1)[1].split(b'".endif', 1)[0]
if (b".subsection 1" not in header or b".altinstr_replacement" in header + linker
        or alternative.count(b".org") != 2 or alternative.find(b".previous") < alternative.rfind(b".org")
        or b"KEEP(*(.altinstructions))" not in linker):
    raise SystemExit("ARM64 replacement padding and linker retention must be updated together")
for level in (0, 1, 2):
    if f"FTR_NONSTRICT, FTR_LOWER_SAFE, ID_AA64PFR0_EL{level}_SHIFT".encode() not in cpu:
        raise SystemExit(f"Missing ARM64 exception-level feature handling for EL{level}")
if (b"*(__kvm_ex_table)" not in linker or b"__start___kvm_ex_table" not in kvm_switch
        or b"mrs\tx1, isr_el1" not in kvm_entry or b"_kvm_extable\tabort_guest_exit_start" not in kvm_entry
        or b"add\tx29, x0, #VCPU_CONTEXT" not in kvm_entry):
    raise SystemExit("ARM64 KVM entry, exception table and vendor register convention must agree")
version = git("show", f"{tree}:Makefile")
if b"SUBLEVEL = 200\n" not in version:
    raise SystemExit("The merged upstream Makefile does not identify Linux 4.14.200")

(report / "candidate.patch").write_bytes(git("diff", "--binary", "--no-renames", vendor, tree))
PY

git apply --index "$report/candidate.patch"
git diff --cached --stat > "$report/applied-stat.txt"
git -c user.name='PCHM30 stable CI' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m 'kernel: merge Linux 4.14.200 on the tested Run 194 source'
