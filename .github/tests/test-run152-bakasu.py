#!/usr/bin/env python3
"""Check the staged BakaSU integration without booting or building a kernel.

Run after run29-manager-handshake.sh with --kernel-dir pointing at the staged
4.14 tree. These checks use the pinned BakaSU Git objects, its real make fragment,
and its real no-preinit header; they do not require network access.
"""

import argparse
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


class BakaSUIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.kernel = KERNEL_DIR
        cls.repo = cls.kernel / "KernelSU"
        cls.source = cls.repo / "kernel"
        if not cls.source.is_dir():
            raise AssertionError("expected the pinned BakaSU KernelSU/kernel layout")

    def evaluate_codegen(self, temporary):
        """Evaluate real Kbuild inputs with headers present, never a kernel build."""
        headers = temporary / "usr" / "include" / "linux"
        headers.mkdir(parents=True)
        (headers / "unistd.h").write_text("/* make probe only */\n")
        makefile = temporary / "audit.mk"
        makefile.write_text(
            ".DEFAULT_GOAL := audit\n"
            "VERSION := 4\nPATCHLEVEL := 14\nARCH := arm64\nCONFIG_COMPAT := y\n"
            f"srctree := {self.kernel}\nobjtree := {temporary}\nobj := {temporary}/obj\n"
            f"KSU_SRC := {self.source}\nCC := cc\nLD := ld\n"
            "kernelsu-objs := core/init.o supercall/dispatch.o feature/sucompat.o\n"
            "include $(KSU_SRC)/tools/code_generation/code_generation.mk\n"
            "$(info AUDIT_CCFLAGS=$(ccflags-y))\n"
            "$(info AUDIT_OBJECTS=$(kernelsu-objs))\n"
            "$(info AUDIT_TARGETS=$(targets))\n"
            "$(info AUDIT_INCLUDES=$(MAKEFILE_LIST))\n"
            ".PHONY: audit\naudit:\n\t@:\n"
        )
        result = run("make", "--no-print-directory", "-f", str(makefile), "audit")
        return dict(
            line.split("=", 1)
            for line in result.stdout.splitlines()
            if line.startswith("AUDIT_")
        )

    def test_preinit_objects_and_generator_are_not_built(self):
        with tempfile.TemporaryDirectory(prefix="pchm30-bakasu-make-") as directory:
            values = self.evaluate_codegen(Path(directory))
        self.assertIn("-DKSU_NO_PREINIT", shlex.split(values["AUDIT_CCFLAGS"]))
        self.assertNotIn("preinit/", values["AUDIT_OBJECTS"])
        self.assertNotIn("preinit/", values["AUDIT_TARGETS"])
        self.assertNotIn("preinit_runner.mk", values["AUDIT_INCLUDES"])
        self.assertIn("syscall_no.mk", values["AUDIT_INCLUDES"])
        self.assertIn("supercall/dispatch.o", values["AUDIT_OBJECTS"])

    def test_compiled_upstream_stub_reports_no_preinit(self):
        with tempfile.TemporaryDirectory(prefix="pchm30-bakasu-stub-") as directory:
            temporary = Path(directory)
            values = self.evaluate_codegen(temporary)
            no_preinit_flags = [
                flag for flag in shlex.split(values["AUDIT_CCFLAGS"])
                if flag.startswith("-DKSU_NO_PREINIT")
            ]
            self.assertEqual(no_preinit_flags, ["-DKSU_NO_PREINIT"])
            headers = temporary / "headers"
            (headers / "linux").mkdir(parents=True)
            (headers / "asm").mkdir()
            (headers / "linux/types.h").write_text("#include <stdbool.h>\n")
            (headers / "asm/ptrace.h").write_text("/* unused by disabled stubs */\n")
            program = temporary / "capability.c"
            program.write_text(
                "struct filename;\nstruct user_arg_ptr;\n"
                '#include "preinit/preinit.h"\n'
                "int main(void) {\n"
                "    ksu_preinit_init();\n"
                "    if (ksu_preinit_enabled_param()) return 1;\n"
                "    ksu_preinit_release();\n"
                "    ksu_preinit_exit();\n"
                "    return 0;\n"
                "}\n"
            )
            executable = temporary / "capability"
            run(
                "cc", "-std=c11", "-Wall", "-Werror", "-DCONFIG_KSU_SUSFS=1",
                *no_preinit_flags, "-I", str(headers), "-I", str(self.source),
                str(program), "-o", str(executable),
            )
            run(str(executable))

    def test_descriptor_ownership_matches_pinned_upstream(self):
        # Compare against the upstream Git objects, not hand-written fixtures.
        # The manager handshake and unrelated FD providers must remain intact.
        for relative in (
            "sulog/fd.c",
            "preinit/preinit.c",
            "infra/su_mount_ns.c",
            "infra/file_wrapper.c",
            "supercall/supercall.c",
        ):
            with self.subTest(file=relative):
                upstream = run(
                    "git", "-C", str(self.repo), "show", f"HEAD:kernel/{relative}"
                ).stdout
                self.assertEqual((self.source / relative).read_text(), upstream)

    def test_actual_reboot_hook_and_manager_authentication_remain(self):
        reboot = (self.kernel / "kernel/reboot.c").read_text()
        self.assertIn("ksu_handle_sys_reboot(magic1, magic2, cmd, &arg)", reboot)
        manager = (self.source / "manager/apk_sign.c").read_text()
        self.assertIn("{ EXPECTED_SIZE_BAKASU, EXPECTED_HASH_BAKASU }", manager)
        self.assertIn("{ EXPECTED_SIZE, EXPECTED_HASH }", manager)
        self.assertIn("{ EXPECTED_SIZE_CUSTOM_V1, EXPECTED_HASH_CUSTOM_V1 }", manager)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel-dir", type=Path, required=True)
    arguments, unittest_arguments = parser.parse_known_args()
    KERNEL_DIR = arguments.kernel_dir.resolve()
    unittest.main(argv=[__file__, *unittest_arguments], verbosity=2)
