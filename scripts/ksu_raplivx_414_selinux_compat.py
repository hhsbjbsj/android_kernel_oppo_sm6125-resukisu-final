#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
KERNEL_MAKEFILE = ROOT / "Makefile"
KSUD = ROOT / "drivers/kernelsu/ksud.c"
SEPOLICY = ROOT / "drivers/kernelsu/selinux/sepolicy.c"
MARKER = "PCHM30_RAPLIVX_SELINUX_414_COMPAT"


def die(msg: str) -> None:
    raise SystemExit(f"[KSU SELinux 4.14 compat] {msg}")


def replace_once(text: str, old: str, new: str, desc: str) -> str:
    count = text.count(old)
    if count != 1:
        die(f"expected exactly one {desc} anchor, found {count}")
    return text.replace(old, new, 1)


def regex_once(text: str, pattern: str, replacement: str, desc: str) -> str:
    # A replacement string passed directly to re.sub() interprets backslash
    # escapes a second time.  Use a callable so C literals such as "\\n"
    # remain two source characters instead of becoming a physical newline.
    out, count = re.subn(pattern, lambda _m: replacement, text,
                         count=1, flags=re.S)
    if count != 1:
        die(f"expected exactly one {desc} block, found {count}")
    return out


mk = KERNEL_MAKEFILE.read_text(errors="surrogateescape")
version = re.search(r"^VERSION\s*=\s*(\d+)\s*$", mk, re.M)
patchlevel = re.search(r"^PATCHLEVEL\s*=\s*(\d+)\s*$", mk, re.M)
if not version or not patchlevel:
    die("cannot determine kernel VERSION/PATCHLEVEL")
if (int(version.group(1)), int(patchlevel.group(1))) != (4, 14):
    sys.exit(0)

for target in (KSUD, SEPOLICY):
    if not target.exists():
        die(f"missing transient RapliVx source: {target}")

# Match the neighboring SukiSU old-kernel policy: optional SELinux hiding is
# not worth pulling modern AVC internals into 4.14.  Keep the core KernelSU
# rules/credential setup, but do not run RapliVx's AVC spoof/hide late init.
ksud = KSUD.read_text(errors="surrogateescape")
if MARKER not in ksud:
    ksud = replace_once(
        ksud,
        "    ksu_avc_spoof_late_init();\n",
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
        "    ksu_avc_spoof_late_init();\n"
        "#else\n"
        f"    /* {MARKER}: optional AVC spoof/hide disabled on Linux 4.14. */\n"
        "#endif\n",
        "RapliVx AVC spoof late-init",
    )
    KSUD.write_text(ksud, errors="surrogateescape")

text = SEPOLICY.read_text(errors="surrogateescape")
if MARKER in text:
    sys.exit(0)

# RapliVx already carries the correct <5.9 symtab compatibility macros.  They
# MUST survive this adapter; Run #21 accidentally deleted them because the old
# filename-transition regexp started at the forward declaration.
symtab_compat = (
    "#define symtab_search(s, name) hashtab_search((s)->table, name)\n"
    "#define symtab_insert(s, name, datum) hashtab_insert((s)->table, name, datum)\n"
)
if symtab_compat not in text:
    die("pinned RapliVx <5.9 symtab compatibility block missing before patch")

# policydb on this OPPO 4.14 tree uses struct filename_trans (including stype),
# a pointer hashtab, and flex_array-backed type maps.  Do not fabricate newer
# filename_trans_key/type_val_to_struct layouts in public kernel headers.
if "#include <linux/flex_array.h>\n" not in text:
    text = replace_once(
        text,
        "#include <linux/gfp.h>\n",
        "#include <linux/gfp.h>\n#include <linux/flex_array.h>\n",
        "flex_array include",
    )

# Require the IMPLEMENTATION signature including its opening brace.  The
# forward declaration ends in ';' and therefore cannot be consumed.
old_filename_trans = (
    r"static bool add_filename_trans\(struct policydb \*db, const char \*s,\n"
    r"\s*const char \*t, const char \*c, const char \*d,\n"
    r"\s*const char \*o\)\n"
    r"\{.*?\n\}\n\n(?=static bool add_genfscon)"
)
new_filename_trans = f'''static bool add_filename_trans(struct policydb *db, const char *s,
                               const char *t, const char *c, const char *d,
                               const char *o)
{{
    struct type_datum *src, *tgt, *def;
    struct class_datum *cls;
    struct filename_trans key;
    struct filename_trans_datum *trans;
    struct filename_trans *new_key;

    src = symtab_search(&db->p_types, s);
    if (!src) {{
        pr_warn("source type %s does not exist\\n", s);
        return false;
    }}
    tgt = symtab_search(&db->p_types, t);
    if (!tgt) {{
        pr_warn("target type %s does not exist\\n", t);
        return false;
    }}
    cls = symtab_search(&db->p_classes, c);
    if (!cls) {{
        pr_warn("class %s does not exist\\n", c);
        return false;
    }}
    def = symtab_search(&db->p_types, d);
    if (!def) {{
        pr_warn("default type %s does not exist\\n", d);
        return false;
    }}

    memset(&key, 0, sizeof(key));
    key.stype = src->value;
    key.ttype = tgt->value;
    key.tclass = cls->value;
    key.name = (char *)o;

    trans = hashtab_search(db->filename_trans, &key);
    if (trans) {{
        trans->otype = def->value;
        return ebitmap_set_bit(&db->filename_trans_ttypes,
                               tgt->value - 1, 1) == 0;
    }}

    trans = kcalloc(1, sizeof(*trans), GFP_KERNEL);
    if (!trans)
        return false;
    new_key = kmalloc(sizeof(*new_key), GFP_KERNEL);
    if (!new_key) {{
        kfree(trans);
        return false;
    }}
    *new_key = key;
    new_key->name = kstrdup(key.name, GFP_KERNEL);
    if (!new_key->name) {{
        kfree(new_key);
        kfree(trans);
        return false;
    }}
    trans->otype = def->value;
    if (hashtab_insert(db->filename_trans, new_key, trans)) {{
        kfree((char *)new_key->name);
        kfree(new_key);
        kfree(trans);
        return false;
    }}

    /* {MARKER}: filename_trans_ttypes indexes the parent target type. */
    return ebitmap_set_bit(&db->filename_trans_ttypes,
                           tgt->value - 1, 1) == 0;
}}

'''
text = regex_once(text, old_filename_trans, new_filename_trans,
                  "4.14 add_filename_trans implementation")

old_add_type = r"static bool add_type\(struct policydb \*db, const char \*type_name, bool attr\)\n\{.*?\n\}\n\n(?=static bool set_type_state)"
new_add_type = f'''static bool add_type(struct policydb *db, const char *type_name, bool attr)
{{
    struct type_datum *type = symtab_search(&db->p_types, type_name);
    struct flex_array *new_type_attr_map_array;
    struct flex_array *new_type_val_to_struct_array;
    struct flex_array *new_val_to_name_types;
    struct flex_array *old_fa;
    char *key;
    void *old_elem;
    u32 value;
    int i;

    if (type) {{
        pr_warn("Type %s already exists\\n", type_name);
        return true;
    }}

    value = ++db->p_types.nprim;
    type = kzalloc(sizeof(*type), GFP_KERNEL);
    if (!type)
        return false;
    type->primary = 1;
    type->value = value;
    type->attribute = attr;

    key = kstrdup(type_name, GFP_KERNEL);
    if (!key) {{
        kfree(type);
        return false;
    }}
    if (symtab_insert(&db->p_types, key, type)) {{
        kfree(key);
        kfree(type);
        return false;
    }}

    new_type_attr_map_array = flex_array_alloc(
        sizeof(struct ebitmap), value, GFP_KERNEL | __GFP_ZERO);
    new_type_val_to_struct_array = flex_array_alloc(
        sizeof(struct type_datum *), value, GFP_KERNEL | __GFP_ZERO);
    new_val_to_name_types = flex_array_alloc(
        sizeof(char *), value, GFP_KERNEL | __GFP_ZERO);
    if (!new_type_attr_map_array || !new_type_val_to_struct_array ||
        !new_val_to_name_types)
        return false;

    if (flex_array_prealloc(new_type_attr_map_array, 0, value,
                            GFP_KERNEL | __GFP_ZERO) ||
        flex_array_prealloc(new_type_val_to_struct_array, 0, value,
                            GFP_KERNEL | __GFP_ZERO) ||
        flex_array_prealloc(new_val_to_name_types, 0, value,
                            GFP_KERNEL | __GFP_ZERO))
        return false;

    for (i = 0; i < value - 1; i++) {{
        old_elem = flex_array_get(db->type_attr_map_array, i);
        if (old_elem && flex_array_put(new_type_attr_map_array, i, old_elem,
                                       GFP_KERNEL | __GFP_ZERO))
            return false;

        old_elem = flex_array_get_ptr(db->type_val_to_struct_array, i);
        if (old_elem && flex_array_put_ptr(new_type_val_to_struct_array, i,
                                           old_elem,
                                           GFP_KERNEL | __GFP_ZERO))
            return false;

        old_elem = flex_array_get_ptr(db->sym_val_to_name[SYM_TYPES], i);
        if (old_elem && flex_array_put_ptr(new_val_to_name_types, i, old_elem,
                                           GFP_KERNEL | __GFP_ZERO))
            return false;
    }}

    old_fa = db->type_attr_map_array;
    db->type_attr_map_array = new_type_attr_map_array;
    if (old_fa)
        flex_array_free(old_fa);
    ebitmap_init(flex_array_get(db->type_attr_map_array, value - 1));
    if (ebitmap_set_bit(flex_array_get(db->type_attr_map_array, value - 1),
                        value - 1, 1))
        return false;

    old_fa = db->type_val_to_struct_array;
    db->type_val_to_struct_array = new_type_val_to_struct_array;
    if (old_fa)
        flex_array_free(old_fa);
    if (flex_array_put_ptr(db->type_val_to_struct_array, value - 1, type,
                           GFP_KERNEL | __GFP_ZERO))
        return false;

    old_fa = db->sym_val_to_name[SYM_TYPES];
    db->sym_val_to_name[SYM_TYPES] = new_val_to_name_types;
    if (old_fa)
        flex_array_free(old_fa);
    if (flex_array_put_ptr(db->sym_val_to_name[SYM_TYPES], value - 1, key,
                           GFP_KERNEL | __GFP_ZERO))
        return false;

    for (i = 0; i < db->p_roles.nprim; ++i) {{
        if (ebitmap_set_bit(&db->role_val_to_struct[i]->types,
                            value - 1, 1))
            return false;
    }}

    /* {MARKER}: Linux 4.14 policydb maps are flex_array-backed. */
    return true;
}}

'''
text = regex_once(text, old_add_type, new_add_type, "4.14 add_type")

old_add_attr = r"static void add_typeattribute_raw\(struct policydb \*db, struct type_datum \*type,\n\s*struct type_datum \*attr\)\n\{.*?\n\}\n\n(?=static bool add_typeattribute)"
new_add_attr = f'''static void add_typeattribute_raw(struct policydb *db, struct type_datum *type,
                                  struct type_datum *attr)
{{
    struct ebitmap *sattr =
        flex_array_get(db->type_attr_map_array, type->value - 1);
    struct hashtab_node *node;
    struct constraint_node *n;
    struct constraint_expr *e;

    if (!sattr)
        return;
    ebitmap_set_bit(sattr, attr->value - 1, 1);

    ksu_hashtab_for_each(db->p_classes.table, node)
    {{
        struct class_datum *cls = (struct class_datum *)node->datum;
        for (n = cls->constraints; n; n = n->next) {{
            for (e = n->expr; e; e = e->next) {{
                if (e->expr_type == CEXPR_NAMES && e->type_names &&
                    ebitmap_get_bit(&e->type_names->types,
                                    attr->value - 1)) {{
                    ebitmap_set_bit(&e->names, type->value - 1, 1);
                }}
            }}
        }}
    }};

    /* {MARKER}: no direct-index ebitmap array exists on this 4.14 tree. */
}}

'''
text = regex_once(text, old_add_attr, new_add_attr,
                  "4.14 add_typeattribute_raw")

# Fail closed if the adapter ever removes RapliVx's own old-kernel symbol
# compatibility again, or if any exact modern policydb members from Run #20
# survive inside the generated 4.14 source.
if symtab_compat not in text:
    die("adapter removed pinned RapliVx <5.9 symtab compatibility block")
for forbidden in (
    "policydb_filenametr_search(db, &key)",
    "trans->stypes",
    "trans->next",
    "db->compat_filename_trans_count",
    "db->type_val_to_struct =",
    "db->type_val_to_struct[",
    "&db->type_attr_map_array[type->value - 1]",
):
    if forbidden in text:
        die(f"unsupported modern policydb token remains: {forbidden}")

# A literal backslash-n must remain in the C source.  This directly guards the
# Run #21 regression where re.sub converted it to a physical newline.
if 'pr_warn("source type %s does not exist\\n", s);' not in text:
    die("C newline escape was corrupted while patching sepolicy.c")

text = text.replace(
    "#define KSU_SUPPORT_ADD_TYPE\n",
    f"#define KSU_SUPPORT_ADD_TYPE\n/* {MARKER} */\n",
    1,
)
SEPOLICY.write_text(text, errors="surrogateescape")
