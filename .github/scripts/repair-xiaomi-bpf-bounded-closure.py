#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
hdr = root / "include/linux/bpf_verifier.h"
vc = root / "kernel/bpf/verifier.c"


def rep(text, old, new, label, count=1):
    found = text.count(old)
    if found != count:
        raise SystemExit(f"{label}: expected {count} exact anchors, found {found}")
    return text.replace(old, new, count)


h = hdr.read_text()
h = rep(
    h,
    "\tREG_LIVE_READ, /* reg was read, so we're sensitive to initial value */\n"
    "\tREG_LIVE_WRITTEN, /* reg was written first, screening off later reads */\n"
    "};",
    "\tREG_LIVE_READ, /* reg was read, so we're sensitive to initial value */\n"
    "\tREG_LIVE_WRITTEN, /* reg was written first, screening off later reads */\n"
    "\tREG_LIVE_DONE = 4, /* liveness won't be updating this register anymore */\n"
    "};",
    "liveness enum",
)
h = rep(
    h,
    "\tu64 umin_value; /* minimum possible (u64)value */\n"
    "\tu64 umax_value; /* maximum possible (u64)value */\n"
    "\t/* Inside the callee two registers can be both PTR_TO_STACK like",
    "\tu64 umin_value; /* minimum possible (u64)value */\n"
    "\tu64 umax_value; /* maximum possible (u64)value */\n"
    "\t/* parentage chain for liveness checking */\n"
    "\tstruct bpf_reg_state *parent;\n"
    "\t/* Inside the callee two registers can be both PTR_TO_STACK like",
    "reg parent",
)
h = rep(
    h,
    "struct bpf_func_state {\n"
    "\tstruct bpf_reg_state regs[MAX_BPF_REG];\n"
    "\tstruct bpf_verifier_state *parent;\n",
    "struct bpf_func_state {\n"
    "\tstruct bpf_reg_state regs[MAX_BPF_REG];\n",
    "remove obsolete func parent",
)
h = rep(
    h,
    "\tstruct bpf_insn_aux_data *insn_aux_data; /* array of per-insn state */\n\n"
    "\tstruct bpf_verifier_log log;",
    "\tstruct bpf_insn_aux_data *insn_aux_data; /* array of per-insn state */\n"
    "\tconst struct bpf_line_info *prev_linfo;\n\n"
    "\tstruct bpf_verifier_log log;",
    "prev linfo",
)
hdr.write_text(h)

s = vc.read_text()
s = rep(
    s,
    "#include <linux/sort.h>\n",
    "#include <linux/sort.h>\n#include <linux/ctype.h>\n",
    "ctype include",
)
s = rep(
    s,
    "#define BPF_COMPLEXITY_LIMIT_STACK\t1024\n",
    "#define BPF_COMPLEXITY_LIMIT_STACK\t1024\n"
    "#define BPF_COMPLEXITY_LIMIT_STATES\t64\n",
    "complexity states",
)

verbose_anchor = """__printf(2, 3) static void verbose(void *private_data, const char *fmt, ...)
{
\tstruct bpf_verifier_env *env = private_data;
\tva_list args;

\tif (!bpf_verifier_log_needed(&env->log))
\t\treturn;

\tva_start(args, fmt);
\tbpf_verifier_vlog(&env->log, fmt, args);
\tva_end(args);
}
"""
verbose_new = verbose_anchor + """
static const struct bpf_line_info *find_linfo(const struct bpf_verifier_env *env,
\t\t\t\t\t      u32 insn_off)
{
\tconst struct bpf_line_info *linfo;
\tconst struct bpf_prog *prog = env->prog;
\tu32 i, nr_linfo = prog->aux->nr_linfo;

\tif (!nr_linfo || insn_off >= prog->len)
\t\treturn NULL;
\tlinfo = prog->aux->linfo;
\tfor (i = 1; i < nr_linfo; i++)
\t\tif (insn_off < linfo[i].insn_off)
\t\t\tbreak;
\treturn &linfo[i - 1];
}

static const char *ltrim(const char *str)
{
\twhile (isspace(*str))
\t\tstr++;
\treturn str;
}

__printf(3, 4) static void verbose_linfo(struct bpf_verifier_env *env,
\t\t\t\t\t u32 insn_off,
\t\t\t\t\t const char *prefix_fmt, ...)
{
\tconst struct bpf_line_info *linfo;

\tif (!bpf_verifier_log_needed(&env->log))
\t\treturn;
\tlinfo = find_linfo(env, insn_off);
\tif (!linfo || linfo == env->prev_linfo)
\t\treturn;
\tif (prefix_fmt) {
\t\tva_list args;
\t\tva_start(args, prefix_fmt);
\t\tbpf_verifier_vlog(&env->log, prefix_fmt, args);
\t\tva_end(args);
\t}
\tverbose(env, "%s\\n", ltrim(btf_name_by_offset(env->prog->aux->btf,
\t\t\t\t\t\t      linfo->line_off)));
\tenv->prev_linfo = linfo;
}
"""
s = rep(s, verbose_anchor, verbose_new, "verbose linfo helper")

s = rep(
    s,
    "\tfor (i = 0; i < MAX_BPF_REG; i++) {\n"
    "\t\tmark_reg_not_init(env, regs, i);\n"
    "\t\tregs[i].live = REG_LIVE_NONE;\n"
    "\t}\n",
    "\tfor (i = 0; i < MAX_BPF_REG; i++) {\n"
    "\t\tmark_reg_not_init(env, regs, i);\n"
    "\t\tregs[i].live = REG_LIVE_NONE;\n"
    "\t\tregs[i].parent = NULL;\n"
    "\t}\n",
    "init reg parents",
)

start = s.index("struct bpf_verifier_state *skip_callee(")
end = s.index("static bool is_spillable_regtype", start)
new_liveness = """/* Parentage chain of this register (or stack slot) takes care of
 * callee-saved registers, stack-slot allocation time and call/return copies.
 */
static int mark_reg_read(struct bpf_verifier_env *env,
\t\t\t const struct bpf_reg_state *state,
\t\t\t struct bpf_reg_state *parent)
{
\tbool writes = parent == state->parent;

\twhile (parent) {
\t\tif (writes && state->live & REG_LIVE_WRITTEN)
\t\t\tbreak;
\t\tif (parent->live & REG_LIVE_DONE) {
\t\t\tverbose(env, "verifier BUG type %s var_off %lld off %d\\n",
\t\t\t\treg_type_str[parent->type],
\t\t\t\tparent->var_off.value, parent->off);
\t\t\treturn -EFAULT;
\t\t}
\t\tif (parent->live & REG_LIVE_READ)
\t\t\tbreak;
\t\tparent->live |= REG_LIVE_READ;
\t\tstate = parent;
\t\tparent = state->parent;
\t\twrites = true;
\t}
\treturn 0;
}

static int check_reg_arg(struct bpf_verifier_env *env, u32 regno,
\t\t\t enum reg_arg_type t)
{
\tstruct bpf_verifier_state *vstate = env->cur_state;
\tstruct bpf_func_state *state = vstate->frame[vstate->curframe];
\tstruct bpf_reg_state *regs = state->regs;

\tif (regno >= MAX_BPF_REG) {
\t\tverbose(env, "R%d is invalid\\n", regno);
\t\treturn -EINVAL;
\t}

\tif (t == SRC_OP) {
\t\tif (regs[regno].type == NOT_INIT) {
\t\t\tverbose(env, "R%d !read_ok\\n", regno);
\t\t\treturn -EACCES;
\t\t}
\t\tif (regno != BPF_REG_FP)
\t\t\treturn mark_reg_read(env, &regs[regno], regs[regno].parent);
\t} else {
\t\tif (regno == BPF_REG_FP) {
\t\t\tverbose(env, "frame pointer is read only\\n");
\t\t\treturn -EACCES;
\t\t}
\t\tregs[regno].live |= REG_LIVE_WRITTEN;
\t\tif (t == DST_OP)
\t\t\tmark_reg_unknown(env, regs, regno);
\t}
\treturn 0;
}

"""
s = s[:start] + new_liveness + s[end:]

s = rep(
    s,
    "\t} else {\n"
    "\t\t/* regular write of data into stack */\n"
    "\t\tstate->stack[spi].spilled_ptr = (struct bpf_reg_state) {};\n\n"
    "\t\tfor (i = 0; i < size; i++)",
    "\t} else {\n"
    "\t\t/* regular write destroys spilled value but preserves parentage */\n"
    "\t\tstate->stack[spi].spilled_ptr.type = NOT_INIT;\n"
    "\t\tif (size == BPF_REG_SIZE)\n"
    "\t\t\tstate->stack[spi].spilled_ptr.live |= REG_LIVE_WRITTEN;\n\n"
    "\t\tfor (i = 0; i < size; i++)",
    "stack write parentage",
)

comment_start = s.index(
    "/* registers of every function are unique and mark_reg_read() propagates"
)
read_start = s.index("static int check_stack_read", comment_start)
s = s[:comment_start] + s[read_start:]
s = rep(
    s,
    "\t\t\tmark_stack_slot_read(env, vstate, vstate->parent, spi,\n"
    "\t\t\t\t\t     reg_state->frameno);",
    "\t\t\tmark_reg_read(env, &reg_state->stack[spi].spilled_ptr,\n"
    "\t\t\t\t      reg_state->stack[spi].spilled_ptr.parent);",
    "stack spill read",
)

p0 = s.index("/* A write screens off any subsequent reads; but write marks come from the")
p1 = s.index("static bool states_maybe_looping", p0)
new_prop = """/* Propagate liveness through the per-register parent chains. */
static int propagate_liveness(struct bpf_verifier_env *env,
\t\t\t      const struct bpf_verifier_state *vstate,
\t\t\t      struct bpf_verifier_state *vparent)
{
\tstruct bpf_func_state *state, *parent;
\tint i, frame, err;

\tif (vparent->curframe != vstate->curframe) {
\t\tWARN(1, "propagate_live: parent frame %d current frame %d\\n",
\t\t     vparent->curframe, vstate->curframe);
\t\treturn -EFAULT;
\t}
\tBUILD_BUG_ON(BPF_REG_FP + 1 != MAX_BPF_REG);
\tfor (frame = 0; frame <= vstate->curframe; frame++) {
\t\tstate = vstate->frame[frame];
\t\tparent = vparent->frame[frame];
\t\tfor (i = frame < vstate->curframe ? BPF_REG_6 : 0;
\t\t     i < BPF_REG_FP; i++) {
\t\t\tif (!(state->regs[i].live & REG_LIVE_READ) ||
\t\t\t    (parent->regs[i].live & REG_LIVE_READ))
\t\t\t\tcontinue;
\t\t\terr = mark_reg_read(env, &state->regs[i], &parent->regs[i]);
\t\t\tif (err)
\t\t\t\treturn err;
\t\t}
\t\tfor (i = 0; i < state->allocated_stack / BPF_REG_SIZE &&
\t\t\t    i < parent->allocated_stack / BPF_REG_SIZE; i++) {
\t\t\tif (!(state->stack[i].spilled_ptr.live & REG_LIVE_READ) ||
\t\t\t    (parent->stack[i].spilled_ptr.live & REG_LIVE_READ))
\t\t\t\tcontinue;
\t\t\terr = mark_reg_read(env, &state->stack[i].spilled_ptr,
\t\t\t\t\t    &parent->stack[i].spilled_ptr);
\t\t\tif (err)
\t\t\t\treturn err;
\t\t}
\t}
\treturn 0;
}

"""
s = s[:p0] + new_prop + s[p1:]

s = rep(
    s,
    "\tfor (j = 0; j <= cur->curframe; j++) {\n"
    "\t\tstruct bpf_func_state *frame = cur->frame[j];\n"
    "\t\tfor (i = 0; i < frame->allocated_stack / BPF_REG_SIZE; i++)\n"
    "\t\t\tif (frame->stack[i].slot_type[0] == STACK_SPILL)\n"
    "\t\t\t\tframe->stack[i].spilled_ptr.live = REG_LIVE_NONE;\n"
    "\t}\n",
    "\tfor (j = 0; j <= cur->curframe; j++) {\n"
    "\t\tstruct bpf_func_state *frame = cur->frame[j];\n"
    "\t\tstruct bpf_func_state *newframe = new->frame[j];\n\n"
    "\t\tfor (i = 0; i < frame->allocated_stack / BPF_REG_SIZE; i++) {\n"
    "\t\t\tframe->stack[i].spilled_ptr.live = REG_LIVE_NONE;\n"
    "\t\t\tframe->stack[i].spilled_ptr.parent =\n"
    "\t\t\t\t&newframe->stack[i].spilled_ptr;\n"
    "\t\t}\n"
    "\t}\n",
    "stack parent checkpoint",
)

ld_abs_fixup = """\t\tif (BPF_CLASS(insn->code) == BPF_LD &&
\t\t    (BPF_MODE(insn->code) == BPF_ABS ||
\t\t     BPF_MODE(insn->code) == BPF_IND)) {
\t\t\tcnt = env->ops->gen_ld_abs(insn, insn_buf);
\t\t\tif (cnt == 0 || cnt >= ARRAY_SIZE(insn_buf)) {
\t\t\t\tverbose(env, "bpf verifier is misconfigured\\n");
\t\t\t\treturn -EINVAL;
\t\t\t}

\t\t\tnew_prog = bpf_patch_insn_data(env, i + delta, insn_buf, cnt);
\t\t\tif (!new_prog)
\t\t\t\treturn -ENOMEM;

\t\t\tdelta    += cnt - 1;
\t\t\tenv->prog = prog = new_prog;
\t\t\tinsn      = new_prog->insnsi + i + delta;
\t\t\tcontinue;
\t\t}

"""
s = rep(
    s,
    ld_abs_fixup,
    "",
    "remove dangling native ld_abs fixup",
)

vc.write_text(s)
print("[PASS] repaired Xiaomi bounded-loop prerequisite closure")
