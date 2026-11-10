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
# Match the original CAF inputs used by the Redmi Note 8 donor. Only
# target-identical donor outputs are eligible for a source-tree resolution.
timeout 300 git fetch --no-tags --depth=1 --filter=blob:none \
    https://github.com/FlopKernel-Series/flop_trinket-mi_kernel.git \
    1a096135285e10af5823e83460c6755af3ad37b5 \
    0cb4cc5d83b2c1a76a08bac48ee33d88535898bc \
    86c833a1bbf4e8676cbed693326c01c6a707eb84
# GitHub's pinned ancestry comparison confirms that the LineageOS donor
# descends from the same OpenELA target. Its pure common-source ports can be
# reused when both current donors agree and OPPO starts from the same CAF blob.
lineage=8aaa002bfb7ba1cac2c02dbb42ae0259ef2e47ba
timeout 300 git fetch --no-tags --depth=1 \
    https://github.com/LineageOS/android_kernel_xiaomi_sm6125.git "$lineage"
test "$(git rev-parse 'FETCH_HEAD^{commit}')" = "$lineage"
git show "$lineage:Makefile" | sed -n '1,6p' > "$report/lineage-version.txt"
grep -Fxq 'SUBLEVEL = 357' "$report/lineage-version.txt"
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
        "arch/arm64/include/asm/cputype.h": (
            "a021546eb4fec31f13c824ce3c0b700c90e0c3b2",
            "134cc1c8e464d7e0a08989c241efb45256ff2ea3",
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
        "kernel/power/wakelock.c": (
            "105df4dfc783971acdd1d17ee2971cb892c97d02",
            "b929b39633839a9991cdd9c1b900491db3627be6",
            None,
        ),
        "kernel/sched/cpufreq_schedutil.c": (
            "e9743a6b3c8296661c435a5a78d43f961e7af741",
            "90a998638bdd109e788af8cc391529f042b92b3b",
            None,
        ),
        "fs/file_table.c": (
            "c038d33c4c5bd5777b4fbb2ab4551814530e9705",
            "4ceb4982ffea1374a6f1adc473f940b54ad7b1c8",
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
            elif path == "arch/arm64/include/asm/cputype.h":
                if actual_oid != vendor_oid:
                    print(f"Unrecognized CPU part table, leaving unresolved: {path}: {actual_oid}", flush=True)
                    continue
                for begin, end in (
                    (b"#define ARM_CPU_PART_NEOVERSE_N1", b"\n#define APM_CPU_PART_POTENZA"),
                    (b"#define MIDR_NEOVERSE_N1", b"#define MIDR_THUNDERX\t"),
                ):
                    start = upstream.index(begin)
                    finish = upstream.index(end, start)
                    if content.count(end) != 1:
                        raise SystemExit(f"Unexpected ARM64 MIDR insertion anchor: {end!r}")
                    content = content.replace(end, upstream[start:finish] + end, 1)
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
            elif path == "kernel/power/wakelock.c":
                if actual_oid != vendor_oid:
                    print(f"Unrecognized wakelock source, leaving unresolved: {path}: {actual_oid}", flush=True)
                    continue
                first = b"ssize_t pm_show_wakelocks(char *buf, bool show_active)\n"
                last = b"#if CONFIG_PM_WAKELOCKS_LIMIT > 0"
                start = content.index(first)
                end = content.index(last, start)
                upstream_start = upstream.index(first)
                upstream_end = upstream.index(last, upstream_start)
                show = upstream[upstream_start:upstream_end].replace(b"wl->ws.active", b"wl->ws->active")
                content = content[:start] + show + content[end:]
            elif path == "kernel/sched/cpufreq_schedutil.c":
                if actual_oid != vendor_oid:
                    print(f"Unrecognized schedutil source, leaving unresolved: {path}: {actual_oid}", flush=True)
                    continue
                old_free = b"static void sugov_tunables_free(struct sugov_tunables *tunables)\n"
                new_free = b"static void sugov_tunables_free(struct kobject *kobj)\n"
                ktype = b"static struct kobj_type sugov_tunables_ktype = {\n"
                clear = b"static void sugov_clear_global_tunables(void)\n"
                start = upstream.index(new_free)
                end = upstream.index(ktype, start)
                release = upstream[start:end]
                old_start = content.index(old_free)
                old_end = content.index(b"\n}\n", old_start) + len(b"\n}\n")
                new_start = upstream.index(clear)
                new_end = upstream.index(b"\n}\n", new_start) + len(b"\n}\n")
                content = content[:old_start] + upstream[new_start:new_end] + content[old_end:]
                content = content.replace(ktype, release + ktype, 1)
                ops = b"\t.sysfs_ops = &governor_sysfs_ops,\n"
                content = content.replace(ops, ops + b"\t.release = &sugov_tunables_free,\n", 1)
                old_call = b"sugov_tunables_free(tunables);"
                if content.count(old_call) != 2:
                    raise SystemExit("Unexpected schedutil tunable cleanup call sites")
                content = content.replace(old_call, b"sugov_clear_global_tunables();")
                # Save OPPO's policy tunables while this reference still owns
                # the kobject. gov_attr_set_put() can drop the final reference.
                start = content.index(b"static void sugov_exit(")
                end = content.index(b"static int sugov_start(", start)
                exit_fn = content[start:end]
                before = b"\tcount = gov_attr_set_put("
                after = b"\tmutex_unlock(&global_tunables_lock);\n"
                if exit_fn.count(before) != 1 or exit_fn.count(after) != 1:
                    raise SystemExit("Unexpected schedutil exit structure")
                exit_fn = exit_fn.replace(before, b"\tkobject_get(&tunables->attr_set.kobj);\n" + before, 1)
                exit_fn = exit_fn.replace(after, b"\tkobject_put(&tunables->attr_set.kobj);\n" + after, 1)
                content = content[:start] + exit_fn + content[end:]
            elif path == "fs/file_table.c":
                if actual_oid != vendor_oid:
                    print(f"Unrecognized file reference handling, leaving unresolved: {path}: {actual_oid}", flush=True)
                    continue
                first = b"void fput(struct file *file)\n"
                new_first = b"void fput_many(struct file *file, unsigned int refs)\n"
                last = b"/*\n * synchronous analog of fput();"
                old_start = content.index(first)
                old_end = content.index(last, old_start)
                new_start = upstream.index(new_first)
                new_end = upstream.index(last, new_start)
                old_block = content[old_start:old_end]
                new_block = upstream[new_start:new_end]
                expected = old_block.replace(first, new_first, 1).replace(
                    b"atomic_long_dec_and_test(&file->f_count)",
                    b"atomic_long_sub_and_test(refs, &file->f_count)", 1,
                ) + first + b"{\n\tfput_many(file, 1);\n}\n\n"
                if expected != new_block:
                    raise SystemExit("Unexpected semantic difference in the OpenELA fput change")
                content = content[:old_start] + new_block + content[old_end:]
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

            path = "kernel/cpu.c"
            content = git("show", f"{tree}:{path}")
            header = b"#include <linux/random.h>\n"
            if b"= random_prepare_cpu," in content and header not in content:
                anchor = b"#include <linux/percpu-rwsem.h>\n"
                if content.count(anchor) != 1:
                    raise SystemExit("Could not locate the RNG include anchor in kernel/cpu.c")
                content = content.replace(anchor, anchor + header, 1)
                oid = subprocess.check_output(["git", "hash-object", "-w", "--stdin"], input=content).decode().strip()
                mode = git("ls-tree", tree, "--", path).split()[0].decode()
                index("update-index", "--cacheinfo", f"{mode},{oid},{path}")
                print("Trial only: imported the RNG hotplug declarations in kernel/cpu.c", flush=True)

            def stage_trial(path, content):
                oid = subprocess.check_output(["git", "hash-object", "-w", "--stdin"],
                                              input=content).decode().strip()
                mode = git("ls-tree", tree, "--", path).split()[0].decode()
                index("update-index", "--cacheinfo", f"{mode},{oid},{path}")
                print(f"Trial only: synchronized the upstream API in {path}", flush=True)

            path = "mm/maccess.c"
            content = git("show", f"{tree}:{path}")
            first = b"long __weak probe_user_read("
            last = b"EXPORT_SYMBOL_GPL(probe_user_read);"
            blocks = list(re.finditer(re.escape(first) + rb".*?" + re.escape(last), content, re.S))
            if len(blocks) == 2:
                upstream = git("show", f"{target}:{path}")
                begin = upstream.index(first)
                end = upstream.index(last, begin) + len(last)
                wanted = upstream[begin:end]
                # Retain a single OpenELA implementation with its user range
                # validation. Refuse to edit unrelated blocks of the file.
                if not any(match.group() == wanted for match in blocks):
                    raise SystemExit("Neither duplicate probe_user_read matches OpenELA")
                seen = False

                def deduplicate(match):
                    nonlocal seen
                    if not seen and match.group() == wanted:
                        seen = True
                        return wanted
                    return b""

                content = re.sub(re.escape(first) + rb".*?" + re.escape(last), deduplicate, content, flags=re.S)
                stage_trial(path, content)

            path = "kernel/events/core.c"
            content = git("show", f"{tree}:{path}")
            obsolete = b"goto fail_free_name;"
            cleanup = b"fail:\n\tkfree(filename);\n\tfree_filters_list(filters);"
            if obsolete in content and b"\nfail_free_name:\n" not in content:
                if content.count(cleanup) != 1 or content.count(obsolete) > 2:
                    raise SystemExit("Could not verify the OpenELA perf filter cleanup path")
                stage_trial(path, content.replace(obsolete, b"goto fail;"))

            path = "kernel/bpf/hashtab.c"
            content = git("show", f"{tree}:{path}")
            obsolete = b"map->ops->map_fd_put_ptr(ptr);"
            if obsolete in content:
                if content.count(obsolete) != 1:
                    raise SystemExit("Unexpected number of legacy BPF hashtab callback calls")
                at = content.index(obsolete)
                if b"fd_htab_map_get_ptr(map, l)" not in content[max(0, at - 180):at]:
                    raise SystemExit("Could not verify the BPF hashtab cleanup callback context")
                stage_trial(path, content.replace(obsolete, b"map->ops->map_fd_put_ptr(map, ptr, true);", 1))

            path = "mm/page_alloc.c"
            content = git("show", f"{tree}:{path}")
            header = b"#include <linux/khugepaged.h>\n"
            if b"khugepaged_min_free_kbytes_update();" in content and header not in content:
                anchor = b"#include <linux/mm.h>\n"
                if content.count(anchor) != 1:
                    raise SystemExit("Could not locate the khugepaged include anchor")
                stage_trial(path, content.replace(anchor, anchor + header, 1))

            path = "fs/fs-writeback.c"
            content = git("show", f"{tree}:{path}")
            old_call = b"\tif (unlikely(block_dump > 1))\n\t\tblock_dump___mark_inode_dirty(inode);\n"
            if old_call in content and b"static noinline void block_dump___mark_inode_dirty" not in content:
                if content.count(old_call) != 1:
                    raise SystemExit("Unexpected retired writeback logging call sites")
                stage_trial(path, content.replace(old_call, b"", 1))

            path = "security/selinux/hooks.c"
            content = git("show", f"{tree}:{path}")
            first = content.index(b"static int selinux_binder_set_context_mgr(")
            end = content.index(b"static int selinux_ptrace_access_check(", first)
            hooks = content[first:end]

            def use_cred_sid(match):
                signature, body = match.groups()
                if b"const struct cred *" not in signature:
                    return match.group()
                body = re.sub(rb"\btask_sid\((mgr|from|to)\)", rb"cred_sid(\1)", body)
                return signature + body

            fixed = re.sub(
                rb"(static int selinux_binder_[a-z_]+\([^)]*\)\n\{)(.*?\n\})",
                use_cred_sid, hooks, flags=re.S,
            )
            if fixed != hooks:
                stage_trial(path, content[:first] + fixed + content[end:])

            path = "mm/memory.c"
            content = git("show", f"{tree}:{path}")
            old_cow = b"\t\tcow_user_page(new_page, old_page, vmf->address, vma);"
            if old_cow in content:
                upstream = git("show", f"{target}:{path}")
                begin = upstream.index(b"\t\tif (!cow_user_page(new_page, old_page, vmf)) {")
                finish = upstream.index(b"\n\t\t}", begin) + len(b"\n\t\t}")
                if content.count(old_cow) != 1:
                    raise SystemExit("Unexpected legacy COW call sites")
                stage_trial(path, content.replace(old_cow, upstream[begin:finish], 1))

            path = "fs/eventpoll.c"
            content = git("show", f"{tree}:{path}")
            start = content.index(b"static int ep_create_wakeup_source(")
            end = content.index(b"\n}\n", start) + len(b"\n}\n")
            wakeup = content[start:end]
            old_name = (
                b"\tname = epi->ffd.file->f_path.dentry->d_name.name;\n"
                b"\tws = wakeup_source_register(NULL, name);"
            )
            if old_name in wakeup:
                upstream = git("show", f"{target}:{path}")
                begin = upstream.index(b"\ttake_dentry_name_snapshot(&n, epi->ffd.file->f_path.dentry);")
                finish = upstream.index(b"\trelease_dentry_name_snapshot(&n);", begin)
                finish += len(b"\trelease_dentry_name_snapshot(&n);")
                snapshot = upstream[begin:finish].replace(
                    b"wakeup_source_register(n.name)", b"wakeup_source_register(NULL, n.name)"
                )
                wakeup = wakeup.replace(old_name, snapshot, 1).replace(b"\tconst char *name;\n", b"", 1)
                if b"\tstruct name_snapshot n;\n" not in wakeup:
                    anchor = b"\tstruct wakeup_source *ws;\n"
                    if wakeup.count(anchor) != 1:
                        raise SystemExit("Could not locate the epoll wakeup-source declaration")
                    wakeup = wakeup.replace(anchor, b"\tstruct name_snapshot n;\n" + anchor, 1)
                stage_trial(path, content[:start] + wakeup + content[end:])

            path = "drivers/char/random.c"
            content = git("show", f"{tree}:{path}")
            legacy_chacha = b"#include <crypto/chacha20.h>\n"
            if legacy_chacha in content:
                stage_trial(path, content.replace(legacy_chacha, b"#include <crypto/chacha.h>\n", 1))

            path = "include/crypto/chacha.h"
            content = git("show", f"{tree}:{path}")
            if b"static inline void chacha_init_consts(" not in content:
                source = git("show", f"{target}:include/crypto/chacha20.h")
                start = source.index(b"enum chacha_constants {")
                end = source.index(b"\n#endif", start)
                helpers = source[start:end]
                aliases = (
                    b"#ifndef CHACHA20_KEY_SIZE\n#define CHACHA20_KEY_SIZE CHACHA_KEY_SIZE\n#endif\n"
                    b"#ifndef CHACHA20_BLOCK_SIZE\n#define CHACHA20_BLOCK_SIZE CHACHA_BLOCK_SIZE\n#endif\n\n"
                )
                final = content.rfind(b"#endif")
                if final < 0:
                    raise SystemExit("Could not locate the ChaCha header guard")
                stage_trial(path, content[:final] + aliases + helpers + b"\n" + content[final:])

            path = "lib/Makefile"
            content = git("show", f"{tree}:{path}")
            if b" chacha.o " not in content and b" chacha20.o " in content:
                if content.count(b" chacha20.o ") != 1:
                    raise SystemExit("Unexpected ChaCha object selection")
                stage_trial(path, content.replace(b" chacha20.o ", b" chacha.o ", 1))

            path = "lib/vsprintf.c"
            content = git("show", f"{tree}:{path}")
            old_callback = b"static void fill_random_ptr_key(struct random_ready_callback *unused)\n"
            if old_callback in content:
                new_callback = (
                    b"static int fill_random_ptr_key(struct notifier_block *unused,\n"
                    b"                               unsigned long action, void *data)\n"
                )
                content = content.replace(old_callback, new_callback, 1)
                old_end = b"\tWRITE_ONCE(have_filled_random_ptr_key, true);\n}"
                if content.count(old_end) != 1:
                    raise SystemExit("Could not verify the hashed-pointer RNG readiness callback")
                content = content.replace(old_end, b"\tWRITE_ONCE(have_filled_random_ptr_key, true);\n\treturn NOTIFY_DONE;\n}", 1)
                content = content.replace(b"static struct random_ready_callback random_ready", b"static struct notifier_block random_ready", 1)
                content = content.replace(b"\t.func = fill_random_ptr_key", b"\t.notifier_call = fill_random_ptr_key", 1)
                content = content.replace(b"add_random_ready_callback(&random_ready)", b"register_random_ready_notifier(&random_ready)", 1)
                content = content.replace(b"fill_random_ptr_key(&random_ready);", b"fill_random_ptr_key(&random_ready, 0, NULL);", 1)
                if b"#include <linux/notifier.h>\n" not in content:
                    source = b"#include <linux/random.h>\n"
                    if content.count(source) != 1:
                        raise SystemExit("Could not locate the pointer hashing RNG header")
                    content = content.replace(source, source + b"#include <linux/notifier.h>\n", 1)
                stage_trial(path, content)

            path = "drivers/soc/qcom/early_random.c"
            content = git("show", f"{tree}:{path}")
            old_seed = (
                b"add_hwgenerator_randomness(random_buffer, bytes_received,\n"
                b"\t\t\t\t\t   bytes_received << 3);"
            )
            if old_seed in content:
                content = content.replace(b"#include <linux/hw_random.h>", b"#include <linux/random.h>", 1)
                content = content.replace(old_seed, b"add_bootloader_randomness(random_buffer, bytes_received);", 1)
                stage_trial(path, content)

            path = "drivers/soc/qcom/event_timer.c"
            content = git("show", f"{tree}:{path}")
            old_root = b"\t.head = RB_ROOT,\n\t.next = NULL,\n"
            if old_root in content:
                if content.count(old_root) != 1:
                    raise SystemExit("Unexpected QCOM event timer queue initializers")
                stage_trial(path, content.replace(old_root, b"\t.rb_root = RB_ROOT_CACHED,\n", 1))
        return index("write-tree").decode().strip(), resolved

# A three-way merge may report an overlap even if the complete upstream
# patch still applies, or is already present, in the vendor file. Accept only
# unambiguous regular-file patches that round-trip byte for byte.
def resolve_exact_patches(conflicts):
    from tempfile import TemporaryDirectory

    base = os.environ["OPENELA_BASE"]
    target = os.environ["OPENELA_TARGET"]
    updates = {}
    results = {}

    def entry(tree, path):
        record = git("--literal-pathspecs", "ls-tree", "-z", tree, "--", path)
        return record.split(b"\t", 1)[0].split() if record else []

    with TemporaryDirectory() as temporary:
        for path in sorted(conflicts):
            old, new, current = (entry(tree, path) for tree in (base, target, vendor))
            if any(len(item) != 3 or item[0] not in {b"100644", b"100755"}
                   for item in (old, new, current)):
                continue
            if old[0] != new[0]:
                continue
            original = git("cat-file", "blob", current[2].decode())
            patch = git("--literal-pathspecs", "diff", "--no-renames", "--no-ext-diff",
                        "--no-textconv", base, target, "--", path)
            if not patch or b"\0" in original or b"\nBinary files " in patch:
                continue
            file = Path(temporary) / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(original)
            file.chmod(0o755 if current[0] == b"100755" else 0o644)

            def apply(*flags):
                return subprocess.run(
                    ["git", "apply", "--whitespace=nowarn", *flags],
                    input=patch, cwd=temporary, capture_output=True,
                ).returncode == 0

            forward = apply("--check")
            reverse = apply("--reverse", "--check")
            if forward == reverse:
                continue
            if forward:
                if not apply():
                    continue
                content = file.read_bytes()
                if content == original or not apply("--reverse") or file.read_bytes() != original:
                    continue
                results[path] = "applied-exact"
            else:
                if not apply("--reverse") or not apply() or file.read_bytes() != original:
                    continue
                content = original
                results[path] = "already-present-exact"
            oid = subprocess.check_output(["git", "hash-object", "-w", "--stdin"],
                                          input=content).decode().strip()
            updates[path] = (current[0].decode(), oid)
    return updates, results


def update_tree(tree, updates):
    from tempfile import TemporaryDirectory

    if not updates:
        return tree
    with TemporaryDirectory() as temporary:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(temporary) / "index"))
        subprocess.run(["git", "read-tree", tree], env=env, check=True)
        for path, (mode, oid) in updates.items():
            subprocess.run(["git", "update-index", "--add", "--cacheinfo", f"{mode},{oid},{path}"],
                           env=env, check=True)
        return subprocess.check_output(["git", "write-tree"], env=env).decode().strip()


# Resolve only files that start from an identical known Floppy input
# and end in exactly the pinned OpenELA blob on both source projects.
def donor_target_matches(conflicts):
    def blobs(ref):
        records = git("ls-tree", "-rz", ref).split(b"\0")
        return {
            path.decode(): metadata.split()
            for metadata, path in (record.split(b"\t", 1) for record in records if record)
        }

    old_inputs = [
        blobs("1a096135285e10af5823e83460c6755af3ad37b5"),
        blobs("0cb4cc5d83b2c1a76a08bac48ee33d88535898bc"),
    ]
    donor = blobs("86c833a1bbf4e8676cbed693326c01c6a707eb84")
    lineage = blobs("8aaa002bfb7ba1cac2c02dbb42ae0259ef2e47ba")
    upstream = blobs(os.environ["OPENELA_TARGET"])
    prepared = blobs(vendor)
    updates = {}
    results = {}
    for path in sorted(conflicts):
        current, latest, target_blob = (table.get(path) for table in (prepared, donor, upstream))
        if not current or not latest or not target_blob:
            continue
        if any(item[0] not in {b"100644", b"100755"} for item in (current, latest, target_blob)):
            continue
        matches = [
            old for old in old_inputs
            if old.get(path) and old[path][2] == current[2]
        ]
        if not matches:
            continue
        if "/boot/dts/" in path or "/configs/" in path or path.startswith(".github/"):
            continue
        if latest[2] == target_blob[2]:
            updates[path] = (current[0].decode(), target_blob[2].decode())
            results[path] = "same-donor-input-and-identical-openela-output"
            continue
        common = lineage.get(path)
        if common and common[0] in {b"100644", b"100755"} and common[2] == latest[2]:
            updates[path] = (current[0].decode(), common[2].decode())
            results[path] = "same-CAF-input-and-matching-LineageOS-Floppy-357-port"
            continue
        # These USB donor differences were checked separately. Keep
        # LineageOS's ep0 dequeue and RNDIS response lock, omit Floppy's
        # optional USB insertion switch, and retain its checked allocation.
        reviewed_usb = {
            "drivers/net/usb/usbnet.c": (donor, "f63efa49b615ee0cff73c16d9ac30dab6098a441"),
            "drivers/usb/core/hub.c": (lineage, "95a9267f4ffc7447ffd4d02d08df1724dd82024c"),
            "drivers/usb/gadget/function/f_fs.c": (lineage, "d2f08c1940539c3a7981411b7edf8aadca35690b"),
            "drivers/usb/gadget/function/rndis.h": (lineage, "16f229028ba0649427aa301a23061be5b6f9b741"),
        }
        if path in reviewed_usb:
            source, expected = reviewed_usb[path]
            port = source.get(path)
            if not port or port[2].decode() != expected:
                raise SystemExit(f"Unexpected reviewed USB donor blob: {path}")
            if path == "drivers/net/usb/usbnet.c":
                # The Floppy fetch is tree-filtered. Recreate its sole delta
                # from the already-fetched LineageOS blob and verify its ID.
                original = git("cat-file", "blob", lineage[path][2].decode())
                old = (b"urb->sg = kmalloc((num_sgs + 1) * sizeof(struct scatterlist),\n"
                       b"\t\t\t  GFP_ATOMIC);")
                new = (b"urb->sg = kmalloc_array(num_sgs + 1, sizeof(struct scatterlist),\n"
                       b"\t\t\t\tGFP_ATOMIC);")
                if original.count(old) != 1:
                    raise SystemExit("Unexpected USB-network scatterlist allocation")
                content = original.replace(old, new, 1)
                actual = subprocess.check_output(["git", "hash-object", "-w", "--stdin"],
                                                 input=content).decode().strip()
                if actual != expected:
                    raise SystemExit("USB-network port differs from the reviewed donor")
            updates[path] = (current[0].decode(), expected)
            results[path] = "same-CAF-input-and-reviewed-USB-donor-port"
            continue

        # When Floppy retains local CAF edits, prove that its final file is
        # exactly OpenELA plus the complete original OPPO delta. A failed
        # hunk, binary delta or different output leaves the conflict open.
        from tempfile import TemporaryDirectory

        original_base = git("--literal-pathspecs", "ls-tree", "-z", os.environ["OPENELA_BASE"], "--", path)
        if not original_base or original_base.split()[0] not in {b"100644", b"100755"}:
            continue
        delta = git("--literal-pathspecs", "diff", "--no-renames", "--no-ext-diff", "--no-textconv",
                    os.environ["OPENELA_BASE"], vendor, "--", path)
        original_target = git("cat-file", "blob", target_blob[2].decode())
        if not delta or b"\0" in original_target or b"\nBinary files " in delta:
            continue
        with TemporaryDirectory() as temporary:
            file = Path(temporary) / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(original_target)
            file.chmod(0o755 if target_blob[0] == b"100755" else 0o644)

            def apply(*flags):
                return subprocess.run(
                    ["git", "apply", "--whitespace=nowarn", *flags],
                    input=delta, cwd=temporary, capture_output=True,
                ).returncode == 0

            if not apply("--check") or not apply():
                continue
            content = file.read_bytes()
            oid = subprocess.check_output(["git", "hash-object", "-w", "--stdin"], input=content).strip()
            if oid != latest[2] or not apply("--reverse") or file.read_bytes() != original_target:
                continue
            updates[path] = (current[0].decode(), oid.decode())
            results[path] = "donor-preserves-complete-original-vendor-delta"
    return updates, results


merged_tree, conflicts = read_merge(report / "merge-tree.bin")
merged_tree, resolved = resolve_reviewed(merged_tree)
conflicts -= resolved
exact_updates, exact_results = resolve_exact_patches(conflicts)
conflicts -= exact_updates.keys()
donor_updates, donor_results = donor_target_matches(conflicts)
conflicts -= donor_updates.keys()
merged_tree = update_tree(merged_tree, {**exact_updates, **donor_updates})
(report / "donor-resolutions.tsv").write_text(
    "".join(f"{path}\t{status}\n" for path, status in sorted(donor_results.items()))
)
(report / "exact-resolutions.tsv").write_text(
    "".join(f"{path}\t{status}\n" for path, status in sorted(exact_results.items()))
)
candidate = report / "compile-merge-tree.bin"
if conflicts and candidate.exists():
    merged_tree, excluded = read_merge(candidate)
    merged_tree, trial_resolved = resolve_reviewed(merged_tree, trial=True)
    merged_tree = update_tree(merged_tree, {**exact_updates, **donor_updates})
    excluded -= trial_resolved | exact_updates.keys() | donor_updates.keys()
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
    if "scripts/Makefile.build" not in resolved and "scripts/Makefile.build" not in exact_updates:
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
    "exact_resolutions": exact_results,
    "donor_target_identical_resolutions": donor_results,
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
