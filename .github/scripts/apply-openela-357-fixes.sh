#!/usr/bin/env bash
# Backport selected fixes carried by OpenELA 4.14.357 in groups.
# This deliberately excludes release metadata and does not advance SUBLEVEL.
set -Eeuo pipefail
trap 'printf "OpenELA point fixes failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
cd "${KERNEL_DIR:-$GITHUB_WORKSPACE/$KERNEL_REL}"
report="$GITHUB_WORKSPACE/openela-report"
mkdir -p "$report"
rm -f -- "$GITHUB_WORKSPACE/kernel-version-proof.txt"
ext4_base=c5d214f6f7937b271afa7342a5630fc4b7aa9845
base=a76b6a6556353484f6f29572989cd37b6cff90cc
target=1e6347375d088ecc896aabb067131d0f9e3c0575
timeout 300 git fetch --no-tags --depth=1 https://github.com/openela/kernel-lts.git "$ext4_base" "$base" "$target"
git cat-file -e "$ext4_base^{commit}"
git cat-file -e "$base^{commit}"
git cat-file -e "$target^{commit}"
git diff --stat "$base" "$target"
printf 'scope=selected-fixes-through-4.14.357\next4_base=%s\nbase=%s\ntarget=%s\n' "$ext4_base" "$base" "$target" > "$report/point-release.txt"
printf 'group\tstatus\n' > "$report/fixes.tsv"

apply_group() {
    local name=$1
    local patch_base=$2
    local patch_target=$3
    shift 3
    local patch="$report/$name.patch"
    local status
    git diff --binary --no-renames "$patch_base" "$patch_target" -- "$@" > "$patch"
    if [[ ! -s "$patch" ]]; then
        printf '%s\tmissing-upstream-delta\n' "$name" | tee -a "$report/fixes.tsv"
        return 1
    fi
    if git apply --reverse --check "$patch" > "$report/$name.log" 2>&1; then
        status=already-present
    elif git apply --check "$patch" >> "$report/$name.log" 2>&1; then
        git apply "$patch" >> "$report/$name.log" 2>&1
        git --literal-pathspecs add -A -- "$@"
        status=applied
    else
        # --3way --check can succeed even if the merge itself conflicts.
        # Try the merge on a scratch index to keep all files in the group
        # together and avoid leaving conflict stages in the build checkout.
        local scratch
        local resolved="$report/$name-resolved.patch"
        scratch=$(mktemp -d)
        GIT_INDEX_FILE="$scratch/index" git read-tree HEAD
        status=deferred-conflict
        if GIT_INDEX_FILE="$scratch/index" git apply --cached --3way "$patch" >> "$report/$name.log" 2>&1; then
            GIT_INDEX_FILE="$scratch/index" git diff --cached --binary HEAD -- "$@" > "$resolved"
            if [[ ! -s "$resolved" ]]; then
                status=already-present
            elif git apply --check "$resolved" >> "$report/$name.log" 2>&1; then
                git apply "$resolved" >> "$report/$name.log" 2>&1
                git --literal-pathspecs add -A -- "$@"
                status=applied-three-way
            fi
        fi
        rm -f -- "$scratch/index"
        rmdir -- "$scratch"
    fi
    printf '%s\t%s\n' "$name" "$status" | tee -a "$report/fixes.tsv"
    if [[ "$status" == deferred-conflict ]]; then
        tail -n 6 "$report/$name.log"
    fi
}

apply_group clock-devres "$base" "$target" drivers/clk/clk-devres.c
apply_group ocfs2-quota "$base" "$target" fs/ocfs2/quota_global.c fs/ocfs2/quota_local.c
apply_group ip-fragments "$base" "$target" include/linux/skbuff.h net/core/sock_destructor.h \
    net/ipv4/inet_fragment.c net/ipv4/ip_fragment.c net/ipv6/netfilter/nf_conntrack_reasm.c
apply_group ima "$base" "$target" security/integrity/ima/ima_api.c security/integrity/ima/ima_template_lib.c

# These two filesystem fixes are present in the final 4.14.357 tree.
# Apply only their 4.14.356 hunks, keeping OPPO's other ext4 changes.
git diff --exit-code "$base" "$target" -- fs/ext4/ialloc.c fs/ext4/xattr.c
apply_group ext4-inode-allocation "$ext4_base" "$base" fs/ext4/ialloc.c
apply_group ext4-xattr-locks "$ext4_base" "$base" fs/ext4/xattr.c

# PCHM30 selects OPPO's external oext4 tree in fs/Makefile. The link points
# into the reconstructed vendor checkout, so these patches are not staged in
# the kernel Git index. Record the exact upstream hunks and the vendor result.
if [[ "$TARGET_PRODUCT" != qssi ]]; then
    active_ext4=$(realpath -e fs/oext4)
    case "$active_ext4/" in
        "$GITHUB_WORKSPACE"/source/android/vendor/oplus/kernel_4.14/ext4/) ;;
        *) printf 'Unexpected PCHM30 ext4 path: %s\n' "$active_ext4" >&2; exit 1 ;;
    esac
    for group in ext4-inode-allocation ext4-xattr-locks; do
        patch_file="$report/$group.patch"
        patch_log="$report/oext4-$group.log"
        if patch --directory="$active_ext4" -p3 --fuzz=0 --force --reverse --dry-run \
            < "$patch_file" > "$patch_log" 2>&1; then
            status=already-present
        else
            patch --directory="$active_ext4" -p3 --fuzz=0 --force --forward --dry-run \
                < "$patch_file" >> "$patch_log" 2>&1
            patch --directory="$active_ext4" -p3 --fuzz=0 --force --forward --no-backup-if-mismatch \
                < "$patch_file" >> "$patch_log" 2>&1
            status=applied
        fi
        printf 'oext4-%s\t%s\n' "$group" "$status" | tee -a "$report/fixes.tsv"
    done
    sha256sum "$active_ext4/ialloc.c" "$active_ext4/xattr.c" > "$report/oext4-patched-sources.sha256"
fi

# The legacy 4.14.186 step reports conflicts for these paths. Carry
# the exact fixes over the vendor interfaces without replacing either file.
python3 - "$report" <<'PY'
import difflib
import sys
from pathlib import Path

report = Path(sys.argv[1])
old_counter = b"\n{\n\tint nr_calls;\n"
new_counter = b"\n{\n\tint nr_calls = 0;\n"
groups = {
    "baseline-cpu-pm": {
        "kernel/cpu_pm.c": [
            (signature + old_counter, signature + new_counter)
            for signature in (
                b"int cpu_pm_enter(void)",
                b"int cpu_cluster_pm_enter(unsigned long aff_level)",
            )
        ],
    },
    "baseline-conntrack": {
        "include/net/netfilter/nf_conntrack.h": [
            (b"\tu8 __nfct_init_offset[0];\n", b"\tstruct { } __nfct_init_offset;\n"),
        ],
        "net/netfilter/nf_conntrack_core.c": [
            (b"\tmemset(&ct->__nfct_init_offset[0], 0,\n",
             b"\tmemset(&ct->__nfct_init_offset, 0,\n"),
            (b"\t       offsetof(struct nf_conn, __nfct_init_offset[0]));\n",
             b"\t       offsetof(struct nf_conn, __nfct_init_offset));\n"),
        ],
    },
}

changes = {}
results = {}
for group, files in groups.items():
    changed = False
    for name, edits in files.items():
        source = Path(name)
        original = source.read_bytes()
        fixed = original
        for old, new in edits:
            if fixed.count(old) == 1 and new not in fixed:
                fixed = fixed.replace(old, new, 1)
            elif old in fixed or fixed.count(new) != 1:
                raise SystemExit(f"Unexpected vendor source context in {source}")
        if fixed != original:
            changes[source] = (original, fixed)
            changed = True
    results[group] = "applied" if changed else "already-present"

patch = []
for source, (original, fixed) in changes.items():
    source.write_bytes(fixed)
    patch.extend(difflib.diff_bytes(
        difflib.unified_diff, original.splitlines(keepends=True), fixed.splitlines(keepends=True),
        fromfile=f"a/{source}".encode(), tofile=f"b/{source}".encode(),
    ))
(report / "baseline-4.14.186-reconciled.patch").write_bytes(b"".join(patch))
with (report / "fixes.tsv").open("a") as log:
    for group, status in results.items():
        row = f"{group}\t{status}"
        print(row)
        print(row, file=log)
PY

grep -Eq '[[:blank:]](applied|applied-three-way|already-present)$' "$report/fixes.tsv"
git diff --stat --ignore-submodules=all HEAD -- \
    drivers/clk/clk-devres.c fs/ocfs2 include/linux/skbuff.h net/core/sock_destructor.h \
    net/ipv4/inet_fragment.c net/ipv4/ip_fragment.c net/ipv6/netfilter/nf_conntrack_reasm.c \
    security/integrity/ima fs/ext4/ialloc.c fs/ext4/xattr.c kernel/cpu_pm.c \
    include/net/netfilter/nf_conntrack.h net/netfilter/nf_conntrack_core.c > "$report/applied-stat.txt"
! grep -Fxq 'SUBLEVEL = 357' Makefile
