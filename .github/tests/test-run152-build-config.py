#!/usr/bin/env python3
"""Host regressions for the generated Run152 freezer/config/package scripts.

These checks use the kernel's own Kconfig parser and generated C; they do not
claim to replace a device boot test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / ".github/scripts"
SCRIPT_NAMES = (
    "apply-cgroup-v2-freezer.sh",
    "run28-extra-features.sh",
    "apply-kernel-414357.sh",
    "package-pchm30-run17-ak3.sh",
)


def run(args, *, cwd=None, env=None, input=None):
    result = subprocess.run(
        args, cwd=cwd, env=env, input=input, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    if result.returncode:
        raise AssertionError(f"{args!r} failed ({result.returncode}):\n{result.stdout}")
    return result.stdout


def heredoc(text, marker):
    start = text.index(f"<<'{marker}'\n") + len(f"<<'{marker}'\n")
    return text[start:text.index(f"\n{marker}\n", start)]


def syntax_checks():
    for name in SCRIPT_NAMES:
        path = SCRIPTS / name
        run(["bash", "-n", str(path)])
        text = path.read_text()
        for marker in re.findall(r"^python3[^\n]* <<'(\w+)'$", text, re.M):
            compile(heredoc(text, marker), f"{name}:{marker}", "exec")


def freezer_inheritance(tmp):
    tree = tmp / "freezer"
    files = (
        "kernel/cgroup/Makefile", "kernel/cgroup/freezer.c",
        "include/linux/cgroup-defs.h", "include/linux/cgroup.h",
        "include/linux/sched.h", "include/linux/sched/jobctl.h",
        "kernel/cgroup/cgroup-internal.h", "kernel/cgroup/cgroup.c",
        "kernel/fork.c", "kernel/signal.c",
    )
    for name in files:
        destination = tree / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, destination)
    env = dict(os.environ, KERNEL_DIR=str(tree), GITHUB_WORKSPACE=str(tree))
    script = SCRIPTS / "apply-cgroup-v2-freezer.sh"
    run(["bash", str(script)], env=env)
    cgroup_file = tree / "kernel/cgroup/cgroup.c"
    pattern = (
        r"\tcgrp->freezer\.e_freeze = parent->freezer\.e_freeze;\n"
        r"\tif \(cgrp->freezer\.e_freeze\) \{.*?\n\t\}\n"
    )
    blocks = re.findall(pattern, cgroup_file.read_text(), re.S)
    assert len(blocks) == 1
    block = blocks[0]
    harness = r"""
#include <assert.h>
enum { CGRP_FREEZE, CGRP_FROZEN };
struct cgroup { struct { int e_freeze; } freezer; unsigned long flags; };
static void set_bit(int bit, unsigned long *flags) { *flags |= 1UL << bit; }
static int task_must_freeze(const struct cgroup *c) {
    return !!(c->flags & (1UL << CGRP_FREEZE));
}
static void inherit(struct cgroup *cgrp, struct cgroup *parent) {
""" + block + r"""
}
int main(void) {
    for (int inherited = 0; inherited < 3; inherited++) {
        struct cgroup parent = { .freezer.e_freeze = inherited };
        struct cgroup child = {0};
        inherit(&child, &parent);
        assert(child.freezer.e_freeze == inherited);
        assert(task_must_freeze(&child) == !!inherited);
        assert(!!(child.flags & (1UL << CGRP_FROZEN)) == !!inherited);
    }
    return 0;
}
"""
    c_file = tmp / "freezer-inherit.c"
    c_file.write_text(harness)
    exe = tmp / "freezer-inherit"
    run(["cc", "-std=c99", "-Wall", "-Wextra", "-Werror", str(c_file), "-o", str(exe)])
    run([str(exe)])

    # Simulate a previously staged faulty backport and ensure replay repairs it.
    old = (
        "\tcgrp->freezer.e_freeze = parent->freezer.e_freeze;\n"
        "\tif (cgrp->freezer.e_freeze)\n"
        "\t\tset_bit(CGRP_FROZEN, &cgrp->flags);\n"
    )
    cgroup_file.write_text(cgroup_file.read_text().replace(block, old, 1))
    run(["bash", str(script)], env=env)
    assert re.findall(pattern, cgroup_file.read_text(), re.S) == [block]
    assert "freezer_inherit_flags=freeze+frozen\n" in (tree / "cgroup-v2-freezer-proof.txt").read_text()


def bbr_kconfig_choice(tmp):
    # Compile the shipped parser, avoiding a dependency on host flex/bison.
    source = tmp / "kconfig-src"
    shutil.copytree(ROOT / "scripts/kconfig", source)
    for name in ("zconf.tab.c", "zconf.lex.c"):
        shutil.copyfile(source / (name + "_shipped"), source / name)
    conf = tmp / "conf"
    run(["cc", "-D_GNU_SOURCE", "-I", str(source),
         str(source / "conf.c"), str(source / "zconf.tab.c"), "-o", str(conf)])

    tcp = (ROOT / "net/ipv4/Kconfig").read_text()
    choice_start = tcp.index('choice\n\tprompt "Default TCP congestion control"')
    choice_end = tcp.index("endchoice", choice_start) + len("endchoice")
    derived_start = tcp.index("config DEFAULT_TCP_CONG\n")
    derived_end = tcp.index("\nconfig TCP_MD5SIG", derived_start)
    choice = tcp[choice_start:choice_end]
    algorithms = sorted(set(re.findall(r"if (TCP_CONG_\w+)=y", choice)))
    kconfig = tmp / "Kconfig"
    kconfig.write_text(
        "".join(f'config {name}\n\tbool "{name}"\n\tdefault y\n\n' for name in algorithms)
        + choice + "\n\n" + tcp[derived_start:derived_end] + "\n"
    )
    out = tmp / "bbr-out"
    out.mkdir()
    config = out / ".config"
    config.write_text('CONFIG_DEFAULT_CUBIC=y\nCONFIG_DEFAULT_TCP_CONG="cubic"\n')
    env = dict(os.environ, KCONFIG_CONFIG=str(config), OUT_DIR=str(out))
    run([str(conf), "--olddefconfig", str(kconfig)], cwd=tmp, env=env)

    # Demonstrate the old bug against the real Kconfig choice/derived string.
    run(["bash", str(ROOT / "scripts/config"), "--file", str(config),
         "--set-str", "DEFAULT_TCP_CONG", "bbr"])
    run([str(conf), "--olddefconfig", str(kconfig)], cwd=tmp, env=env)
    assert 'CONFIG_DEFAULT_TCP_CONG="cubic"' in config.read_text()

    text = (SCRIPTS / "run28-extra-features.sh").read_text()
    helpers = text[text.index("enable_opt() {"):text.index("echo '===== STAGE NETWORK CONFIGURATION")]
    run(["bash", "-eu"], cwd=ROOT, env=env, input=helpers + "\nselect_bbr_default\n")
    for _ in range(2):
        run([str(conf), "--olddefconfig", str(kconfig)], cwd=tmp, env=env)
        resolved = config.read_text()
        assert "CONFIG_DEFAULT_BBR=y\n" in resolved
        assert 'CONFIG_DEFAULT_TCP_CONG="bbr"\n' in resolved
        assert "CONFIG_DEFAULT_CUBIC=y\n" not in resolved


def compatibility_label(tmp):
    tree = tmp / "label"
    out = tree / "out"
    out.mkdir(parents=True)
    original = (ROOT / "Makefile").read_text()
    original = re.sub(r"^SUBLEVEL = \d+$", "SUBLEVEL = 186", original, flags=re.M)
    (tree / "Makefile").write_text(original)
    previous = "kernel_version=4.14.186\napplied_files=12\nconflicts=2\n"
    (tree / "kernel-version-proof.txt").write_text(previous)
    env = dict(os.environ, KERNEL_DIR=str(tree), GITHUB_WORKSPACE=str(tree), OUT_DIR=str(out))
    script = SCRIPTS / "apply-kernel-414357.sh"
    for _ in range(2):
        run(["bash", str(script)], env=env)
        proof = (tree / "kernel-version-proof.txt").read_text()
        assert "release_label_only=yes\n" in proof
        assert "full_4.14.357_backport=no\n" in proof
        assert "previous_makefile_version=4.14.186\n" in proof
        assert "applied_files=" not in proof and "conflicts=" not in proof
        assert (tree / "kernel-414186-proof.txt").read_text() == previous
        assert (out / "include/config/kernel.release").read_text() == "4.14.357-perf+\n"


def package_metadata(tmp):
    tree = tmp / "package"
    work = tree / "work"
    work.mkdir(parents=True)
    header = tree / "include/linux/susfs.h"
    header.parent.mkdir(parents=True)
    header.write_text('#define SUSFS_VERSION "v2.4.0-pchm30"\n')
    release = tree / "out/include/config/kernel.release"
    release.parent.mkdir(parents=True)
    release.write_text("4.14.357-perf+\n")
    (tree / "kernel-version-proof.txt").write_text(
        "release_label_only=yes\nfull_4.14.357_backport=no\n"
    )
    ksu = tree / "KernelSU"
    run(["git", "init", "-q", str(ksu)])
    run(["git", "-c", "user.name=Run152 regression",
         "-c", "user.email=regression@example.invalid",
         "commit", "-q", "--allow-empty", "-m", "fixture"], cwd=ksu)
    sha = run(["git", "rev-parse", "HEAD"], cwd=ksu).strip()
    image = tree / "Image"
    image.write_bytes(b"Run152 metadata regression image\n")
    text = (SCRIPTS / "package-pchm30-run17-ak3.sh").read_text()
    (work / "anykernel.sh").write_text(heredoc(text, "AK") + "\n")
    env = dict(os.environ, GITHUB_WORKSPACE=str(tree), OUT_DIR=str(tree / "out"), RUN152_WORKFLOW_REF="b" * 40,
               GITHUB_SHA="a" * 40, GITHUB_RUN_ID="123", GITHUB_RUN_NUMBER="2")
    run(["python3", "-", str(work), str(image), "c" * 40],
        cwd=tree, env=env, input=heredoc(text, "PY_METADATA"))
    metadata = json.loads((work / "BUILD-INFO.json").read_text())
    assert metadata["bakasu_commit"] == sha
    assert metadata["build_source_commit"] == "a" * 40
    assert metadata["image_sha256"] == hashlib.sha256(image.read_bytes()).hexdigest()
    assert metadata["susfs_version"] == "v2.4.0-pchm30"
    assert metadata["release_label_only"] is True
    assert metadata["full_4_14_357_backport"] is False
    ak = (work / "anykernel.sh").read_text()
    assert "Run152 BakaSU " + sha[:8] in ak
    assert "do.devicecheck=1" in ak and "device.name1=PCHM30" in ak
    assert "device.name2=OP4A54" in ak and "BLOCK=boot;" in ak
    assert "IS_SLOT_DEVICE=0;" in ak and "dump_boot;\nwrite_boot;" in ak
    assert "SUSFS 2.3" not in ak and "__PCHM30_BUILD_LABEL__" not in ak
    run(["bash", "-n", str(work / "anykernel.sh")])


def main():
    global ROOT, SCRIPTS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel-dir", type=Path, default=ROOT,
                        help="kernel source tree used by the regression fixtures")
    parser.add_argument("--scripts-dir", type=Path,
                        help="directory containing the four Run152 shell scripts")
    args = parser.parse_args()
    ROOT = args.kernel_dir.resolve()
    SCRIPTS = (args.scripts_dir or ROOT / ".github/scripts").resolve()
    syntax_checks()
    with tempfile.TemporaryDirectory(prefix="run152-build-regression-") as directory:
        tmp = Path(directory)
        freezer_inheritance(tmp)
        bbr_kconfig_choice(tmp)
        compatibility_label(tmp)
        package_metadata(tmp)
    print("PASS: freezer inheritance/replay, real Kconfig BBR resolution, label provenance and package metadata")


if __name__ == "__main__":
    main()
