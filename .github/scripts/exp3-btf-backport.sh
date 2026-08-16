#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee "$GITHUB_WORKSPACE/btf-exp3-backport.log") 2>&1

git remote remove aosp-common 2>/dev/null || true
git remote add aosp-common https://github.com/aosp-mirror/kernel_common.git

fetch_delta() {
  local commit="$1" path="$2" out="$3" parent
  git fetch --no-tags --depth=2 aosp-common "$commit"
  test "$(git rev-parse FETCH_HEAD)" = "$commit"
  parent="$(git rev-parse "${commit}^")"
  git diff --binary "$parent" "$commit" -- "$path" > "$out"
  test -s "$out"
}

# The OPPO/Aresin 4.14 tree has local BTF UAPI edits around the tail of btf.h,
# so the upstream 2019 patch cannot be applied as one context-sensitive hunk.
# Apply the semantic UAPI delta idempotently instead of accepting a conflicted
# three-way patch. This preserves all vendor-local declarations.
fetch_delta "$UPSTREAM_BTF_UAPI" include/uapi/linux/btf.h /tmp/btf-var-uapi.patch
python3 - <<'PY'
from pathlib import Path
import re
p = Path('include/uapi/linux/btf.h')
s = p.read_text()
orig = s

if 'BTF_KIND_VAR' not in s:
    pat = r'(#define\s+BTF_KIND_FUNC_PROTO\s+13[^\n]*\n)'
    repl = (r'\1'
            '#define BTF_KIND_VAR\t\t14\t/* Variable\t*/\n'
            '#define BTF_KIND_DATASEC\t15\t/* Section\t*/\n')
    s, n = re.subn(pat, repl, s, count=1)
    if n != 1:
        raise SystemExit('cannot locate BTF_KIND_FUNC_PROTO anchor')

s, nmax = re.subn(r'^#define\s+BTF_KIND_MAX\s+13\s*$',
                  '#define BTF_KIND_MAX\t\tBTF_KIND_DATASEC',
                  s, count=1, flags=re.M)
s, nnr = re.subn(r'^#define\s+NR_BTF_KINDS\s+14\s*$',
                 '#define NR_BTF_KINDS\t\t(BTF_KIND_MAX + 1)',
                 s, count=1, flags=re.M)
if 'BTF_KIND_MAX' in s and 'BTF_KIND_DATASEC' not in next((ln for ln in s.splitlines() if ln.startswith('#define BTF_KIND_MAX')), ''):
    raise SystemExit('unexpected BTF_KIND_MAX form; refusing unsafe rewrite')

if 'struct btf_var {' not in s:
    block = '''\nenum {\n\tBTF_VAR_STATIC = 0,\n\tBTF_VAR_GLOBAL_ALLOCATED,\n};\n\n/* BTF_KIND_VAR is followed by a single "struct btf_var". */\nstruct btf_var {\n\t__u32\tlinkage;\n};\n\n/* BTF_KIND_DATASEC contains one or more variable section records. */\nstruct btf_var_secinfo {\n\t__u32\ttype;\n\t__u32\toffset;\n\t__u32\tsize;\n};\n\n'''
    marker = '#endif /* _UAPI__LINUX_BTF_H__ */'
    if marker not in s:
        raise SystemExit('cannot locate btf.h endif anchor')
    s = s.replace(marker, block + marker, 1)

if s == orig:
    print('[INFO] UAPI already contains VAR/DATASEC semantic delta')
else:
    p.write_text(s)
    print('[PASS] applied context-safe UAPI VAR/DATASEC semantic delta')
PY

grep -Eq 'BTF_KIND_VAR[^0-9]*14' include/uapi/linux/btf.h
grep -Eq 'BTF_KIND_DATASEC[^0-9]*15' include/uapi/linux/btf.h
grep -Eq 'BTF_KIND_MAX.*BTF_KIND_DATASEC|BTF_KIND_MAX[^0-9]*15' include/uapi/linux/btf.h
grep -q 'struct btf_var {' include/uapi/linux/btf.h
grep -q 'struct btf_var_secinfo {' include/uapi/linux/btf.h

# Kernel-side delta is a different file. Try exact upstream context first and
# then the index-aware 3-way fallback. Abort on any conflict; never keep a
# partially merged verifier implementation.
fetch_delta "$UPSTREAM_BTF_KERNEL" kernel/bpf/btf.c /tmp/btf-var-kernel.patch
echo "===== APPLY $UPSTREAM_BTF_KERNEL :: kernel/bpf/btf.c ====="
if git apply --check /tmp/btf-var-kernel.patch; then
  git apply /tmp/btf-var-kernel.patch
else
  echo '[INFO] kernel direct apply needs merge context; trying git apply --3way'
  if ! git apply --3way /tmp/btf-var-kernel.patch; then
    git diff -- kernel/bpf/btf.c || true
    echo '[ERROR] kernel-side VAR/DATASEC delta conflicts with this 4.14 tree'
    exit 42
  fi
fi

grep -q 'static int btf_var_resolve' kernel/bpf/btf.c
grep -q 'static int btf_datasec_resolve' kernel/bpf/btf.c
grep -q '\[BTF_KIND_VAR\].*= &var_ops' kernel/bpf/btf.c
grep -q '\[BTF_KIND_DATASEC\].*= &datasec_ops' kernel/bpf/btf.c
git diff --check
echo '[PASS] BTF VAR/DATASEC UAPI + kernel verifier support applied cleanly'
