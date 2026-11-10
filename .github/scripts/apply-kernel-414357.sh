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

# Replay reviewed OpenELA changes while preserving unrelated OPPO edits.
def resolve_reviewed(tree, trial=False):
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
        "scripts/Makefile.build": (
            "74ce588c69513197a354ef0032c2145e91ee0641",
            "f4b752cb17516a8e0151538f4cdb220a469a4add",
            None,
        ),
        "arch/arm64/kernel/setup.c": (
            "6332b164ffdbd1d480efcf80091dcafb50bbcd99",
            "01b15d9dd8d62de74b8e6c0701f3d0ba3e675e1e",
            "a8ec91c6df156516cd0c1571bf3ca05e44395e45",
        ),
        "arch/arm64/mm/mmu.c": (
            "7060791a7c0d7f93f025d533585bb02cada9fab4",
            "ce8c57d70e5fc74428dd558032868b94b47fe122",
            None,
        ),
        "include/linux/clk.h": (
            "d53415dc58670876ed153456247cb95a9484d042",
            "136a64bddcd93d633db6c699eb01aa0ff5b43a3a",
            None,
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
                raise SystemExit(f"Unexpected upstream blob for reviewed resolution: {path}")

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
            elif path == "lib/Kconfig":
                # The build adds LZ4K/LZ4KD options to this file before the
                # merge. Apply only OpenELA's HAVE_ARCH_BITREVERSE change.
                old = b"config HAVE_ARCH_BITREVERSE\n\tbool\n\tdefault n\n\tdepends on BITREVERSE\n\thelp\n"
                new = b"config HAVE_ARCH_BITREVERSE\n\tbool\n\tdefault n\n\thelp\n"
                if content.count(old) == 1 and new not in content:
                    content = content.replace(old, new, 1)
                elif content.count(new) != 1:
                    print(f"Unrecognized prepared Kconfig, leaving unresolved: {path}: {actual_oid}", flush=True)
                    continue
            elif path == "scripts/Makefile.build":
                # Both ends of this guard must enclose the same vendor recipe.
                start = b"ifdef CONFIG_FTRACE_MCOUNT_RECORD\nifdef BUILD_C_RECORDMCOUNT\n"
                end = b"endif # CONFIG_FTRACE_MCOUNT_RECORD\n"
                guard = b"ifndef CC_USING_RECORD_MCOUNT\n"
                if content.count(start) != 1 or content.count(end) != 1 or guard in content:
                    print(f"Unrecognized recordmcount recipe, leaving unresolved: {path}: {actual_oid}", flush=True)
                    continue
                left = upstream.index(guard)
                right = upstream.index(b"ifdef BUILD_C_RECORDMCOUNT\n", left)
                content = content.replace(
                    start, b"ifdef CONFIG_FTRACE_MCOUNT_RECORD\n" + upstream[left:right]
                    + b"ifdef BUILD_C_RECORDMCOUNT\n", 1,
                )
                content = content.replace(end, b"endif # CC_USING_RECORD_MCOUNT\n" + end, 1)
            elif path in {"arch/arm64/kernel/setup.c", "arch/arm64/mm/mmu.c"}:
                # Keep the OPPO source outside the OpenELA FDT and trampoline
                # changes. Floppy applies the same coordinated API transition.
                edits = {
                    "arch/arm64/kernel/setup.c": (
                        (b"extern void *__init __fixmap_remap_fdt(phys_addr_t dt_phys, int *size,\n\t\t\t\t       pgprot_t prot);\n",
                         b""),
                        (b"fdt = __fixmap_remap_fdt(dt_phys, &size, PAGE_KERNEL);",
                         b"fdt = fixmap_remap_fdt(dt_phys, &size, PAGE_KERNEL);"),
                        (b"static void __init setup_machine_fdt(phys_addr_t dt_phys)\n{\n\tvoid *dt_virt = fixmap_remap_fdt(dt_phys);\n\tconst char *machine_name;\n\n\tif (!dt_virt || !early_init_dt_scan(dt_virt)) {\n\t\tpr_crit(\"\\n\"\n\t\t\t\"Error: invalid device tree blob at physical address %pa (virtual address 0x%p)\\n\"\n\t\t\t\"The dtb must be 8-byte aligned and must not exceed 2 MB in size\\n\"\n\t\t\t\"\\nPlease check your bootloader.\",\n\t\t\t&dt_phys, dt_virt);\n\n\t\twhile (true)\n\t\t\tcpu_relax();\n\t}\n\n\tmachine_name = arch_read_machine_name();\n\tif (!machine_name)\n\t\treturn;\n\n\tpr_info(\"Machine: %s\\n\", machine_name);\n\tdump_stack_set_arch_desc(\"%s (DT)\", machine_name);\n}\n\n",
                         b"static void __init setup_machine_fdt(phys_addr_t dt_phys)\n{\n\tint size;\n\tvoid *dt_virt = fixmap_remap_fdt(dt_phys, &size, PAGE_KERNEL);\n\tconst char *machine_name;\n\n\tif (dt_virt)\n\t\tmemblock_reserve(dt_phys, size);\n\n\tif (!dt_virt || !early_init_dt_scan(dt_virt)) {\n\t\tpr_crit(\"\\n\"\n\t\t\t\"Error: invalid device tree blob at physical address %pa (virtual address 0x%p)\\n\"\n\t\t\t\"The dtb must be 8-byte aligned and must not exceed 2 MB in size\\n\"\n\t\t\t\"\\nPlease check your bootloader.\",\n\t\t\t&dt_phys, dt_virt);\n\n\t\twhile (true)\n\t\t\tcpu_relax();\n\t}\n\n\t/* Early fixups are done, map the FDT as read-only now */\n\tfixmap_remap_fdt(dt_phys, &size, PAGE_KERNEL_RO);\n\n\tmachine_name = arch_read_machine_name();\n\tif (!machine_name)\n\t\treturn;\n\n\tpr_info(\"Machine: %s\\n\", machine_name);\n\tdump_stack_set_arch_desc(\"%s (DT)\", machine_name);\n}\n\n"),
                    ),
                    "arch/arm64/mm/mmu.c": (
                        (b"static int __init map_entry_trampoline(void)\n{\n\textern char __entry_tramp_text_start[];\n\n\tpgprot_t prot = rodata_enabled ? PAGE_KERNEL_ROX : PAGE_KERNEL_EXEC;\n\tphys_addr_t pa_start = __pa_symbol(__entry_tramp_text_start);\n\n\t/* The trampoline is always mapped and can therefore be global */\n\tpgprot_val(prot) &= ~PTE_NG;\n\n\t/* Map only the text into the trampoline page table */\n\tmemset(tramp_pg_dir, 0, PGD_SIZE);\n\t__create_pgd_mapping(tramp_pg_dir, pa_start, TRAMP_VALIAS, PAGE_SIZE,\n\t\t\t     prot, pgd_pgtable_alloc, 0);\n\n\t/* Map both the text and data into the kernel page table */\n\t__set_fixmap(FIX_ENTRY_TRAMP_TEXT, pa_start, prot);\n\tif (IS_ENABLED(CONFIG_RANDOMIZE_BASE)) {\n\t\textern char __entry_tramp_data_start[];\n\n\t\t__set_fixmap(FIX_ENTRY_TRAMP_DATA,\n\t\t\t     __pa_symbol(__entry_tramp_data_start),\n\t\t\t     PAGE_KERNEL_RO);\n\t}\n\n\treturn 0;\n}\n",
                         b"static int __init map_entry_trampoline(void)\n{\n\tint i;\n\textern char __entry_tramp_text_start[];\n\n\tpgprot_t prot = rodata_enabled ? PAGE_KERNEL_ROX : PAGE_KERNEL_EXEC;\n\tphys_addr_t pa_start = __pa_symbol(__entry_tramp_text_start);\n\n\t/* The trampoline is always mapped and can therefore be global */\n\tpgprot_val(prot) &= ~PTE_NG;\n\n\t/* Map only the text into the trampoline page table */\n\tmemset(tramp_pg_dir, 0, PGD_SIZE);\n\t__create_pgd_mapping(tramp_pg_dir, pa_start, TRAMP_VALIAS,\n\t\t\t     entry_tramp_text_size(), prot, pgd_pgtable_alloc,\n\t\t\t     0);\n\n\t/* Map both the text and data into the kernel page table */\n\tfor (i = 0; i < DIV_ROUND_UP(entry_tramp_text_size(), PAGE_SIZE); i++)\n\t\t__set_fixmap(FIX_ENTRY_TRAMP_TEXT1 - i,\n\t\t\t     pa_start + i * PAGE_SIZE, prot);\n\n\tif (IS_ENABLED(CONFIG_RANDOMIZE_BASE)) {\n\t\textern char __entry_tramp_data_start[];\n\n\t\t__set_fixmap(FIX_ENTRY_TRAMP_DATA,\n\t\t\t     __pa_symbol(__entry_tramp_data_start),\n\t\t\t     PAGE_KERNEL_RO);\n\t}\n\n\treturn 0;\n}\n"),
                        (b"void *__init __fixmap_remap_fdt(phys_addr_t dt_phys, int *size, pgprot_t prot)",
                         b"void *__init fixmap_remap_fdt(phys_addr_t dt_phys, int *size, pgprot_t prot)"),
                        (b"void *__init fixmap_remap_fdt(phys_addr_t dt_phys)\n{\n\tvoid *dt_virt;\n\tint size;\n\n\tdt_virt = __fixmap_remap_fdt(dt_phys, &size, PAGE_KERNEL_RO);\n\tif (!dt_virt)\n\t\treturn NULL;\n\n\tmemblock_reserve(dt_phys, size);\n\n\t/*\n\t * memblock_dbg is not up because of parse_early_param get called after\n\t * setup_machine_fd. To capture fdt reserved info below pr_info is\n\t * added.\n\t */\n\tpr_info(\"memblock_reserve: 0x%x %pS\\n\", size - 1, (void *) _RET_IP_);\n\n\treturn dt_virt;\n}\n\n",
                         b""),
                    ),
                }[path]
                if any(content.count(old) != 1 for old, new in edits):
                    print(f"Unrecognized ARM64 source, leaving unresolved: {path}: {actual_oid}", flush=True)
                    continue
                for old, new in edits:
                    content = content.replace(old, new, 1)
            elif path == "include/linux/clk.h":
                # Floppy starts from this same header. Import the three OpenELA
                # API blocks, retaining OPPO's existing CONFIG_OF condition.
                if actual_oid != vendor_oid:
                    print(f"Unrecognized clock header, leaving unresolved: {path}: {actual_oid}", flush=True)
                    continue
                for first, last, vendor_anchor in (
                    (b"/**\n * devm_clk_get_prepared -", b"/**\n * devm_get_clk_from_child -", None),
                    (b"static inline struct clk *devm_clk_get_prepared(",
                     b"static inline int devm_clk_bulk_get(", None),
                    (b"/**\n * clk_get_optional -",
                     b"#if defined(CONFIG_OF) && defined(CONFIG_COMMON_CLK)\nstruct clk *of_clk_get(",
                     b"#if defined(CONFIG_OF)\nstruct clk *of_clk_get("),
                ):
                    anchor = vendor_anchor or last
                    if content.count(anchor) != 1:
                        raise SystemExit(f"Unexpected clock API insertion anchor: {anchor!r}")
                    begin = upstream.index(first)
                    end = upstream.index(last, begin)
                    content = content.replace(anchor, upstream[begin:end] + anchor, 1)

            oid = subprocess.check_output(["git", "hash-object", "-w", "--stdin"], input=content).decode().strip()
            if expected_oid and actual_oid == vendor_oid and oid != expected_oid:
                raise SystemExit(f"Resolution differs from the reviewed Floppy blob: {path}: {oid}")
            mode = git("ls-tree", vendor, "--", path).split()[0].decode()
            index("update-index", "--add", "--cacheinfo", f"{mode},{oid},{path}")
            resolved.add(path)
        if trial:
            path = "init/main.c"
            content = git("show", f"{tree}:{path}")
            obsolete = b"\tcheck_bugs();\n"
            replacement = b"\tarch_cpu_finalize_init();\n"
            anchor = b"\tcalibrate_delay();\n"
            if content.count(obsolete) == 1:
                content = content.replace(obsolete, b"", 1)
                if replacement not in content:
                    if content.count(anchor) != 1:
                        raise SystemExit("Could not locate OpenELA CPU initialization point in init/main.c")
                    content = content.replace(anchor, anchor + b"\n" + replacement, 1)
                oid = subprocess.check_output(["git", "hash-object", "-w", "--stdin"], input=content).decode().strip()
                mode = git("ls-tree", tree, "--", path).split()[0].decode()
                index("update-index", "--cacheinfo", f"{mode},{oid},{path}")
                print("Trial only: synchronized the CPU finalization call in init/main.c", flush=True)
        return index("write-tree").decode().strip(), resolved

merged_tree, conflicts = read_merge(report / "merge-tree.bin")
merged_tree, resolved = resolve_reviewed(merged_tree)
conflicts -= resolved
candidate = report / "compile-merge-tree.bin"
if conflicts and candidate.exists():
    merged_tree, excluded = read_merge(candidate)
    merged_tree, trial_resolved = resolve_reviewed(merged_tree, trial=True)
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
    excluded.update({"Makefile", "include/asm-generic/bugs.h"})
    if "scripts/Makefile.build" not in resolved:
        excluded.add("scripts/Makefile.build")
    excluded.update(path for path in paths if path.startswith(".elts/"))
(report / "deferred-paths.txt").write_text("".join(path + "\n" for path in sorted(excluded)))

applied = [path for path in paths if path not in excluded]
proof = {
    "base_commit": os.environ["OPENELA_BASE"],
    "target_commit": os.environ["OPENELA_TARGET"],
    "prepared_vendor_commit": vendor,
    "source_merge_clean": not conflicts,
    "conflict_count": len(conflicts),
    "reviewed_resolutions": sorted(resolved),
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
