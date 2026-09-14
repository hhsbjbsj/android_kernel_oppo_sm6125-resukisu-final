#!/usr/bin/env python3
"""Idempotent isolated overlay of Xiaomi BPF combo features on 4.14.

Applies on top of the successful MAP_FREEZE EXP1 tree without replacing
kernel/bpf/. Features:
  * BPF_MAP_LOOKUP_AND_DELETE_ELEM = 21 + queue/stack maps
  * BPF_BTF_GET_NEXT_ID = 23
  * BPF_JMP32
  * boot-safe legacy back-edge rejection until the full bounded-loop verifier lands
"""

from pathlib import Path
import re
import shutil
import sys


ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()


def read(rel: str) -> str:
    return (ROOT / rel).read_text()


def write(rel: str, text: str) -> None:
    path = ROOT / rel
    if path.read_text() != text:
        path.write_text(text)
        print(f"[patch] {rel}")
    else:
        print(f"[skip]  {rel}")


def once(haystack: str, needle: str, insert: str) -> str:
    if insert.strip() in haystack:
        return haystack
    if needle not in haystack:
        raise SystemExit(f"anchor not found: {needle!r}")
    return haystack.replace(needle, insert, 1)


uapi_path = "include/uapi/linux/bpf.h"
uapi = read(uapi_path)

if "BPF_JMP32" not in uapi:
    uapi = once(
        uapi,
        "#define BPF_ALU64\t0x07\t/* alu mode in double word width */\n",
        "#define BPF_JMP32\t0x06\t/* jmp mode in word width */\n"
        "#define BPF_ALU64\t0x07\t/* alu mode in double word width */\n",
    )

if "BPF_MAP_LOOKUP_AND_DELETE_ELEM" not in uapi:
    if "BPF_MAP_FREEZE = 22" in uapi:
        uapi = uapi.replace(
            "\t/* Keep the upstream UAPI number; commands 20 and 21 are not backported. */\n"
            "\tBPF_MAP_FREEZE = 22,\n",
            "\tBPF_MAP_LOOKUP_AND_DELETE_ELEM = 21,\n"
            "\tBPF_MAP_FREEZE = 22,\n"
            "\tBPF_BTF_GET_NEXT_ID = 23,\n",
            1,
        )
        if "BPF_MAP_LOOKUP_AND_DELETE_ELEM" not in uapi:
            uapi = uapi.replace(
                "\tBPF_MAP_FREEZE = 22,\n",
                "\tBPF_MAP_LOOKUP_AND_DELETE_ELEM = 21,\n"
                "\tBPF_MAP_FREEZE = 22,\n"
                "\tBPF_BTF_GET_NEXT_ID = 23,\n",
                1,
            )
    else:
        raise SystemExit("BPF_MAP_FREEZE = 22 missing; combo requires EXP1 first")
elif "BPF_BTF_GET_NEXT_ID" not in uapi:
    uapi = once(
        uapi,
        "\tBPF_MAP_FREEZE = 22,\n",
        "\tBPF_MAP_FREEZE = 22,\n\tBPF_BTF_GET_NEXT_ID = 23,\n",
    )

if "BPF_MAP_TYPE_QUEUE" not in uapi:
    for last in (
        "\tBPF_MAP_TYPE_SOCKHASH,\n",
        "\tBPF_MAP_TYPE_SOCKHASH = 18,\n",
        "\tBPF_MAP_TYPE_CPUMAP,\n",
        "\tBPF_MAP_TYPE_SOCKMAP,\n",
    ):
        if last in uapi:
            uapi = uapi.replace(
                last,
                last + "\tBPF_MAP_TYPE_QUEUE,\n\tBPF_MAP_TYPE_STACK,\n",
                1,
            )
            break
    else:
        raise SystemExit("cannot locate map type enum tail")

write(uapi_path, uapi)

kh_path = "include/linux/bpf.h"
kh = read(kh_path)
if "map_push_elem" not in kh:
    kh = once(
        kh,
        "\tint (*map_delete_elem)(struct bpf_map *map, void *key);\n",
        "\tint (*map_delete_elem)(struct bpf_map *map, void *key);\n"
        "\tint (*map_push_elem)(struct bpf_map *map, void *value, u64 flags);\n"
        "\tint (*map_pop_elem)(struct bpf_map *map, void *value);\n"
        "\tint (*map_peek_elem)(struct bpf_map *map, void *value);\n",
    )
write(kh_path, kh)

types_path = "include/linux/bpf_types.h"
types = read(types_path)
if "BPF_MAP_TYPE_QUEUE" not in types:
    types += (
        "BPF_MAP_TYPE(BPF_MAP_TYPE_QUEUE, queue_map_ops)\n"
        "BPF_MAP_TYPE(BPF_MAP_TYPE_STACK, queue_stack_map_ops)\n"
    )
    write(types_path, types)
else:
    print("[skip]  include/linux/bpf_types.h")

mk_path = "kernel/bpf/Makefile"
mk = read(mk_path)
if "queue_stack_maps.o" not in mk:
    mk = once(
        mk,
        "obj-$(CONFIG_BPF_SYSCALL) += hashtab.o",
        "obj-$(CONFIG_BPF_SYSCALL) += queue_stack_maps.o\n"
        "obj-$(CONFIG_BPF_SYSCALL) += hashtab.o",
    )
    write(mk_path, mk)
else:
    print("[skip]  kernel/bpf/Makefile")

src = Path(__file__).resolve().parent.parent / "patches" / "bpf-xiaomi-queue-stack-maps.c"
cands = [
    src,
    Path(sys.argv[2]) if len(sys.argv) > 2 else None,
    Path.cwd() / "bpf-xiaomi-queue-stack-maps.c",
]
src = next((c for c in cands if c and c.is_file()), None)
if src is None:
    raise SystemExit("queue/stack source not found")
dst = ROOT / "kernel/bpf/queue_stack_maps.c"
if (not dst.is_file()) or dst.read_text() != src.read_text():
    shutil.copyfile(src, dst)
    print("[patch] kernel/bpf/queue_stack_maps.c")
else:
    print("[skip]  kernel/bpf/queue_stack_maps.c")

sc_path = "kernel/bpf/syscall.c"
sc = read(sc_path)

HANDLER = """
#define BPF_MAP_LOOKUP_AND_DELETE_ELEM_LAST_FIELD flags

static int map_lookup_and_delete_elem(union bpf_attr *attr)
{
	void __user *ukey = u64_to_user_ptr(attr->key);
	void __user *uvalue = u64_to_user_ptr(attr->value);
	int ufd = attr->map_fd;
	struct bpf_map *map;
	struct fd f;
	void *key, *value;
	int err;

	if (CHECK_ATTR(BPF_MAP_LOOKUP_AND_DELETE_ELEM))
		return -EINVAL;

	f = fdget(ufd);
	map = __bpf_map_get(f);
	if (IS_ERR(map))
		return PTR_ERR(map);

	if (!(map_get_sys_perms(map, f) & FMODE_CAN_READ) ||
	    !(map_get_sys_perms(map, f) & FMODE_CAN_WRITE)) {
		err = -EPERM;
		goto err_put;
	}

	value = kmalloc(map->value_size, GFP_USER);
	if (!value) {
		err = -ENOMEM;
		goto err_put;
	}

	if (map->ops->map_pop_elem && map->key_size == 0) {
		err = map->ops->map_pop_elem(map, value);
		if (!err && copy_to_user(uvalue, value, map->value_size))
			err = -EFAULT;
		kfree(value);
		goto err_put;
	}

	key = memdup_user(ukey, map->key_size);
	if (IS_ERR(key)) {
		err = PTR_ERR(key);
		kfree(value);
		goto err_put;
	}

	rcu_read_lock();
	{
		void *ptr = map->ops->map_lookup_elem(map, key);

		if (ptr) {
			memcpy(value, ptr, map->value_size);
			err = map->ops->map_delete_elem(map, key);
		} else {
			err = -ENOENT;
		}
	}
	rcu_read_unlock();
	if (!err && copy_to_user(uvalue, value, map->value_size))
		err = -EFAULT;
	kfree(value);
	kfree(key);
err_put:
	fdput(f);
	return err;
}

#define BPF_BTF_GET_NEXT_ID_LAST_FIELD next_id

static int bpf_btf_get_next_id(const union bpf_attr *attr)
{
	if (!capable(CAP_SYS_ADMIN))
		return -EPERM;
	/* Isolated 4.14: command number is reserved; no public BTF idr. */
	return -ENOENT;
}

"""

if "static int map_lookup_and_delete_elem" not in sc:
    sc = once(
        sc,
        "static const struct bpf_prog_ops",
        HANDLER + "static const struct bpf_prog_ops",
    )

if "case BPF_MAP_LOOKUP_AND_DELETE_ELEM:" not in sc:
    sc = once(
        sc,
        "\tcase BPF_MAP_FREEZE:\n\t\terr = map_freeze(&attr);\n\t\tbreak;\n",
        "\tcase BPF_MAP_LOOKUP_AND_DELETE_ELEM:\n"
        "\t\terr = map_lookup_and_delete_elem(&attr);\n"
        "\t\tbreak;\n"
        "\tcase BPF_MAP_FREEZE:\n\t\terr = map_freeze(&attr);\n\t\tbreak;\n"
        "\tcase BPF_BTF_GET_NEXT_ID:\n"
        "\t\terr = bpf_btf_get_next_id(&attr);\n"
        "\t\tbreak;\n",
    )
elif "case BPF_BTF_GET_NEXT_ID:" not in sc:
    sc = once(
        sc,
        "\tcase BPF_MAP_FREEZE:\n\t\terr = map_freeze(&attr);\n\t\tbreak;\n",
        "\tcase BPF_MAP_FREEZE:\n\t\terr = map_freeze(&attr);\n\t\tbreak;\n"
        "\tcase BPF_BTF_GET_NEXT_ID:\n"
        "\t\terr = bpf_btf_get_next_id(&attr);\n"
        "\t\tbreak;\n",
    )

write(sc_path, sc)

ver_path = "kernel/bpf/verifier.c"
ver = read(ver_path)

if "class == BPF_JMP || class == BPF_JMP32" not in ver:
    ver = ver.replace(
        "if (BPF_CLASS(insns[t].code) == BPF_JMP) {",
        "if (BPF_CLASS(insns[t].code) == BPF_JMP ||\n"
        "\t    BPF_CLASS(insns[t].code) == BPF_JMP32) {",
        1,
    )
    ver = ver.replace(
        "} else if (class == BPF_JMP) {",
        "} else if (class == BPF_JMP || class == BPF_JMP32) {",
    )

if "bounded-loop back-edge" in ver:
    # Boot safety: the former shortcut only removed CFG rejection.  It did
    # not backport the verifier state-parent/branch accounting required by
    # upstream bounded loops, so repair already-overlaid trees as well.
    ver = ver.replace(
        "\t\t/* Isolated 4.14 bounded-loop accept: keep exploring. */\n",
        "",
        1,
    )
    ver = ver.replace(
        "bounded-loop back-edge from insn %d to %d",
        "back-edge from insn %d to %d",
        1,
    )
    ver = ver.replace(
        "\t\tinsn_state[t] = DISCOVERED | e;\n",
        "\t\treturn -EINVAL;\n",
        1,
    )
    if "bounded-loop back-edge" in ver:
        raise SystemExit("failed to remove unsafe bounded-loop shortcut")

write(ver_path, ver)

core_path = "kernel/bpf/core.c"
core = read(core_path)

table_add = (
    "\t\t/* 32-bit jumps */\n"
    "\t\t[BPF_JMP32 | BPF_JEQ | BPF_X] = &&JMP32_JEQ_X,\n"
    "\t\t[BPF_JMP32 | BPF_JEQ | BPF_K] = &&JMP32_JEQ_K,\n"
    "\t\t[BPF_JMP32 | BPF_JNE | BPF_X] = &&JMP32_JNE_X,\n"
    "\t\t[BPF_JMP32 | BPF_JNE | BPF_K] = &&JMP32_JNE_K,\n"
    "\t\t[BPF_JMP32 | BPF_JGT | BPF_X] = &&JMP32_JGT_X,\n"
    "\t\t[BPF_JMP32 | BPF_JGT | BPF_K] = &&JMP32_JGT_K,\n"
    "\t\t[BPF_JMP32 | BPF_JLT | BPF_X] = &&JMP32_JLT_X,\n"
    "\t\t[BPF_JMP32 | BPF_JLT | BPF_K] = &&JMP32_JLT_K,\n"
    "\t\t[BPF_JMP32 | BPF_JGE | BPF_X] = &&JMP32_JGE_X,\n"
    "\t\t[BPF_JMP32 | BPF_JGE | BPF_K] = &&JMP32_JGE_K,\n"
    "\t\t[BPF_JMP32 | BPF_JLE | BPF_X] = &&JMP32_JLE_X,\n"
    "\t\t[BPF_JMP32 | BPF_JLE | BPF_K] = &&JMP32_JLE_K,\n"
    "\t\t[BPF_JMP32 | BPF_JSGT | BPF_X] = &&JMP32_JSGT_X,\n"
    "\t\t[BPF_JMP32 | BPF_JSGT | BPF_K] = &&JMP32_JSGT_K,\n"
    "\t\t[BPF_JMP32 | BPF_JSLT | BPF_X] = &&JMP32_JSLT_X,\n"
    "\t\t[BPF_JMP32 | BPF_JSLT | BPF_K] = &&JMP32_JSLT_K,\n"
    "\t\t[BPF_JMP32 | BPF_JSGE | BPF_X] = &&JMP32_JSGE_X,\n"
    "\t\t[BPF_JMP32 | BPF_JSGE | BPF_K] = &&JMP32_JSGE_K,\n"
    "\t\t[BPF_JMP32 | BPF_JSLE | BPF_X] = &&JMP32_JSLE_X,\n"
    "\t\t[BPF_JMP32 | BPF_JSLE | BPF_K] = &&JMP32_JSLE_K,\n"
    "\t\t[BPF_JMP32 | BPF_JSET | BPF_X] = &&JMP32_JSET_X,\n"
    "\t\t[BPF_JMP32 | BPF_JSET | BPF_K] = &&JMP32_JSET_K,\n"
)
if "JMP32_JEQ_X" not in core:
    core = once(
        core,
        "\t\t[BPF_JMP | BPF_EXIT] = &&JMP_EXIT,\n",
        "\t\t[BPF_JMP | BPF_EXIT] = &&JMP_EXIT,\n" + table_add,
    )

impl = """
	JMP32_JEQ_X:
		if ((u32)DST == (u32)SRC) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JEQ_K:
		if ((u32)DST == (u32)IMM) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JNE_X:
		if ((u32)DST != (u32)SRC) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JNE_K:
		if ((u32)DST != (u32)IMM) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JGT_X:
		if ((u32)DST > (u32)SRC) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JGT_K:
		if ((u32)DST > (u32)IMM) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JLT_X:
		if ((u32)DST < (u32)SRC) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JLT_K:
		if ((u32)DST < (u32)IMM) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JGE_X:
		if ((u32)DST >= (u32)SRC) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JGE_K:
		if ((u32)DST >= (u32)IMM) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JLE_X:
		if ((u32)DST <= (u32)SRC) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JLE_K:
		if ((u32)DST <= (u32)IMM) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JSGT_X:
		if ((s32)DST > (s32)SRC) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JSGT_K:
		if ((s32)DST > (s32)IMM) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JSLT_X:
		if ((s32)DST < (s32)SRC) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JSLT_K:
		if ((s32)DST < (s32)IMM) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JSGE_X:
		if ((s32)DST >= (s32)SRC) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JSGE_K:
		if ((s32)DST >= (s32)IMM) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JSLE_X:
		if ((s32)DST <= (s32)SRC) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JSLE_K:
		if ((s32)DST <= (s32)IMM) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JSET_X:
		if ((u32)DST & (u32)SRC) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
	JMP32_JSET_K:
		if ((u32)DST & (u32)IMM) {
			insn += insn->off;
			CONT_JMP;
		}
		CONT;
"""
if "JMP32_JSET_K:" not in core:
    core = once(core, "\tJMP_JEQ_X:\n", impl + "\tJMP_JEQ_X:\n")

write(core_path, core)
print("[PASS] Xiaomi BPF combo overlay applied")
