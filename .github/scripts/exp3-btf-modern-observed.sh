#!/usr/bin/env bash
set -Eeuo pipefail

echo '===== EXP3: FIX OBSERVED MODERN BTF METADATA ====='

python3 - <<'PY'
from pathlib import Path
import re

u = Path('include/uapi/linux/btf.h')
s = u.read_text()

# Modern BTF uses five kind bits. Run12 proved info=0x11000000 (kind 17)
# was truncated by the legacy 0x0f mask and reported as kind 1.
s = re.sub(r'#define\s+BTF_INFO_KIND\(info\)\s+\(\(\(info\)\s*>>\s*24\)\s*&\s*0x0f\)',
           '#define BTF_INFO_KIND(info) (((info) >> 24) & 0x1f)', s)

if 'BTF_KIND_FLOAT' not in s:
    s = re.sub(r'(#define\s+BTF_KIND_DATASEC\s+15[^\n]*\n)',
               r'\1#define BTF_KIND_FLOAT\t\t16\t/* Floating point */\n'
               r'#define BTF_KIND_DECL_TAG\t17\t/* Decl Tag */\n', s, count=1)

# This experiment deliberately raises the verifier ceiling only through the
# highest kind actually observed on the device. Unknown later kinds still fail
# closed instead of being silently accepted without semantics.
s = re.sub(r'^#define\s+BTF_KIND_MAX\s+.*$',
           '#define BTF_KIND_MAX\t\tBTF_KIND_DECL_TAG', s, count=1, flags=re.M)
s = re.sub(r'^#define\s+NR_BTF_KINDS\s+.*$',
           '#define NR_BTF_KINDS\t\t(BTF_KIND_MAX + 1)', s, count=1, flags=re.M)

if 'enum btf_func_linkage' not in s:
    anchor = re.search(r'enum\s*\{\s*BTF_VAR_STATIC\s*=\s*0,.*?\};', s, re.S)
    if not anchor:
        raise SystemExit('BTF VAR linkage enum anchor missing')
    block = anchor.group(0)
    if 'BTF_VAR_GLOBAL_EXTERN' not in block:
        block2 = re.sub(r'(BTF_VAR_GLOBAL_ALLOCATED\s*(?:=\s*1)?\s*,?)',
                        r'\1\n\tBTF_VAR_GLOBAL_EXTERN = 2,', block, count=1)
        s = s[:anchor.start()] + block2 + s[anchor.end():]
        anchor_end = anchor.start() + len(block2)
    else:
        anchor_end = anchor.end()
    s = s[:anchor_end] + '''\n\nenum btf_func_linkage {\n\tBTF_FUNC_STATIC = 0,\n\tBTF_FUNC_GLOBAL = 1,\n\tBTF_FUNC_EXTERN = 2,\n};\n''' + s[anchor_end:]

if 'struct btf_decl_tag {' not in s:
    marker = '#endif /* _UAPI__LINUX_BTF_H__ */'
    if marker not in s:
        raise SystemExit('btf.h endif anchor missing')
    s = s.replace(marker, '''\n/* BTF_KIND_DECL_TAG carries one component index after struct btf_type. */\nstruct btf_decl_tag {\n\t__s32 component_idx;\n};\n\n''' + marker, 1)

u.write_text(s)

p = Path('kernel/bpf/btf.c')
s = p.read_text()

s = s.replace('#define BTF_INFO_MASK 0x8f00ffff', '#define BTF_INFO_MASK 0x9f00ffff')

# Keep verifier log arrays index-safe for kinds 16/17.
if '[BTF_KIND_FLOAT]' not in s:
    s = s.replace('\t[BTF_KIND_DATASEC]\t= "DATASEC",\n',
                  '\t[BTF_KIND_DATASEC]\t= "DATASEC",\n'
                  '\t[BTF_KIND_FLOAT]\t= "FLOAT",\n'
                  '\t[BTF_KIND_DECL_TAG]\t= "DECL_TAG",\n', 1)

# BTF_KIND_FUNC vlen is linkage in modern BTF. Run12 repeatedly showed
# kind=12 info=0x0c000001, i.e. global linkage=1. Legacy 4.14 rejects any vlen.
start = s.find('static s32 btf_func_check_meta(')
end = s.find('\nstatic ', start + 1)
if start < 0 or end < 0:
    raise SystemExit('btf_func_check_meta not found')
func = s[start:end]
func2, n = re.subn(r'if \(btf_type_vlen\(t\)\)\s*\{',
                   'if (btf_type_vlen(t) > BTF_FUNC_GLOBAL) {', func, count=1)
if n != 1 and 'BTF_FUNC_GLOBAL' not in func:
    raise SystemExit('legacy FUNC vlen check not found')
s = s[:start] + func2 + s[end:]

# We only need DECL_TAG annotations to be structurally parsed; they carry no
# runtime map layout. FLOAT is likewise a fixed-size leaf. Special-case them
# in pass #1 so legacy kind_ops is never dereferenced for these newer kinds.
needle = '''\tif (!btf_name_offset_valid(env->btf, t->name_off)) {\n\t\tbtf_verifier_log(env, "[%u] Invalid name_offset:%u",\n\t\t\t\t env->log_type_id, t->name_off);\n\t\treturn -EINVAL;\n\t}\n\n'''
if needle not in s:
    # Vendor tree may have slightly different spacing; anchor after the name
    # offset check's closing brace by locating the next check_meta call.
    idx = s.find('var_meta_size = btf_type_ops(t)->check_meta')
    if idx < 0:
        raise SystemExit('btf_check_meta ops call not found')
    insert_at = idx
else:
    insert_at = s.index(needle) + len(needle)

special = '''\t/* Android 16 BTF compatibility: newer leaf/annotation kinds. */\n\tif (BTF_INFO_KIND(t->info) == BTF_KIND_FLOAT) {\n\t\tif (BTF_INFO_VLEN(t->info) || BTF_INFO_KFLAG(t->info) ||\n\t\t    (t->size != 2 && t->size != 4 && t->size != 8 &&\n\t\t     t->size != 12 && t->size != 16))\n\t\t\treturn -EINVAL;\n\t\treturn sizeof(*t);\n\t}\n\tif (BTF_INFO_KIND(t->info) == BTF_KIND_DECL_TAG) {\n\t\tif (BTF_INFO_VLEN(t->info) || BTF_INFO_KFLAG(t->info) ||\n\t\t    !t->name_off || meta_left < sizeof(struct btf_decl_tag))\n\t\t\treturn -EINVAL;\n\t\treturn sizeof(*t) + sizeof(struct btf_decl_tag);\n\t}\n\n'''
if 'Android 16 BTF compatibility: newer leaf/annotation kinds.' not in s:
    s = s[:insert_at] + special + s[insert_at:]

p.write_text(s)
PY

grep -Eq 'BTF_INFO_KIND.*0x1f' include/uapi/linux/btf.h
grep -Eq 'BTF_KIND_FLOAT[^0-9]*16' include/uapi/linux/btf.h
grep -Eq 'BTF_KIND_DECL_TAG[^0-9]*17' include/uapi/linux/btf.h
grep -q 'BTF_FUNC_GLOBAL = 1' include/uapi/linux/btf.h
grep -q 'struct btf_decl_tag {' include/uapi/linux/btf.h
grep -q 'BTF_INFO_MASK 0x9f00ffff' kernel/bpf/btf.c
grep -q 'btf_type_vlen(t) > BTF_FUNC_GLOBAL' kernel/bpf/btf.c
grep -q 'Android 16 BTF compatibility: newer leaf/annotation kinds.' kernel/bpf/btf.c
git diff --check

echo '[PASS] Run12-observed modern BTF kind/linkage metadata compatibility applied'
