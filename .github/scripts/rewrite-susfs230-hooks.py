#!/usr/bin/env python3
"""Rewrite SM6125 4.14 manual hooks to official SUSFS 2.3 logic.

Runs AFTER apply-resukisu-hooks.py. Mirrors simonpunk da34bba1 / f3087ec1
and JackA1ltman NonGKI susfs_inline_hook_patches.sh.
"""
from pathlib import Path


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f'{label}: expected block not found')
    return text.replace(old, new, 1)


def ensure_include(text, needle, include_line):
    if needle in text:
        return text
    if include_line in text:
        return text
    if '#include "internal.h"' in text:
        return text.replace('#include "internal.h"',
                            '#include "internal.h"\n' + include_line, 1)
    return include_line + '\n' + text
