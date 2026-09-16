#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/.github/scripts/normalize-btf-var-datasec-patch.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/in.patch" <<'EOF'
@@ -185,6 +185,16 @@
 	     i++, member++)
 
+#define for_each_vsi(i, struct_type, member) foo
+
 static DEFINE_IDR(btf_idr);
 static DEFINE_SPINLOCK(btf_idr_lock);
+static DEFINE_IDR(not_context_added);
-static DEFINE_SPINLOCK(not_context_removed);
EOF

python3 "$HELPER" "$TMP/in.patch" "$TMP/out.patch"

grep -Fxq ' DEFINE_IDR(btf_idr);' "$TMP/out.patch"
grep -Fxq ' DEFINE_SPINLOCK(btf_idr_lock);' "$TMP/out.patch"
! grep -Fxq ' static DEFINE_IDR(btf_idr);' "$TMP/out.patch"
! grep -Fxq ' static DEFINE_SPINLOCK(btf_idr_lock);' "$TMP/out.patch"
grep -Fxq '+static DEFINE_IDR(not_context_added);' "$TMP/out.patch"
grep -Fxq -- '-static DEFINE_SPINLOCK(not_context_removed);' "$TMP/out.patch"
grep -Fq '#define for_each_vsi' "$TMP/out.patch"

echo '[PASS] BTF VAR/DATASEC patch normalizer rewrites only the two expected context lines'
