#!/usr/bin/env python3
from pathlib import Path

p = Path("kernel/bpf/verifier.c")
s = p.read_text()

START = "<<<<<<< HEAD\n"
MID = "=======\n"
END = ">>>>>>> "

out = []
pos = 0
blocks = 0
first_shape = 0

while True:
    a = s.find(START, pos)
    if a < 0:
        out.append(s[pos:])
        break

    b = s.find(MID, a + len(START))
    c = s.find(END, b + len(MID))
    if b < 0 or c < 0:
        raise SystemExit("malformed 79362 conflict markers")
    e = s.find("\n", c)
    if e < 0:
        raise SystemExit("unterminated 79362 conflict marker")
    e += 1

    ours = s[a + len(START):b]
    theirs = s[b + len(MID):c]
    out.append(s[pos:a])
    blocks += 1

    # This first conflict is NOT a logging change.  The donor parent already
    # carried a newer speculative-pointer sanitizer (REASON_STACK,
    # sanitize_err(), sanitize_check_bounds()) that the OPPO/A15 result does
    # not carry.  Importing that donor-only pre-state here would mix two
    # sanitizer ABIs.  Keep OPPO's existing -EFAULT contract; the rest of
    # 79362 can still migrate the verifier logger into env.
    if (
        "return !ret ? -EFAULT : 0;" in ours
        and "return !ret ? REASON_STACK : 0;" in theirs
        and "static int sanitize_err(" in theirs
        and "static int sanitize_check_bounds(" in theirs
    ):
        if first_shape:
            raise SystemExit("multiple 79362 sanitizer-prestate conflicts found")
        first_shape = 1
        chosen = ours
    else:
        # The other known conflicts are OPPO policy differences overlapped by
        # 79362's API migration.  Preserve OPPO's policy/allow_ptr_leaks
        # behavior, then adapt only the logger/register helper call API.
        if not any(
            token in ours
            for token in (
                'verbose("',
                "mark_reg_unknown(regs,",
                "mark_reg_known_zero(regs,",
                "mark_reg_not_init(regs,",
            )
        ):
            raise SystemExit(
                "unexpected 79362 non-sanitizer conflict; refusing broad resolution:\n"
                + ours[:1200]
            )
        chosen = ours

    out.append(chosen)
    pos = e

if blocks != 8:
    raise SystemExit(f"expected exactly 8 verifier conflicts for 79362, got {blocks}")
if first_shape != 1:
    raise SystemExit("expected 79362 sanitizer-prestate conflict was not found")

s = "".join(out)

# 79362 changes verbose() and register-state helper APIs to carry env.  OPPO
# has a few extra lines inside the conflicting policy blocks which the donor
# patch cannot rewrite automatically.  Migrate those exact legacy call forms.
replacements = {
    'verbose("': 'verbose(env, "',
    "mark_reg_unknown(regs,": "mark_reg_unknown(env, regs,",
    "mark_reg_known_zero(regs,": "mark_reg_known_zero(env, regs,",
    "mark_reg_not_init(regs,": "mark_reg_not_init(env, regs,",
}
for old, new in replacements.items():
    s = s.replace(old, new)

# Normalize whitespace because the failed merge exposed one donor-side line
# with trailing whitespace.  Do not otherwise reformat the file.
s = "\n".join(line.rstrip() for line in s.split("\n"))

for marker in ("<<<<<<<", "=======", ">>>>>>>"):
    if marker in s:
        raise SystemExit(f"conflict marker remains after 79362 resolution: {marker}")

# Fail closed if any legacy API form survived.  A later compile error should
# represent a real semantic dependency, not a half-migrated logger call.
for old in replacements:
    if old in s:
        raise SystemExit(f"legacy verifier API remains after 79362 resolution: {old}")

# Guard the two key policy decisions made by this resolver.
if "return !ret ? -EFAULT : 0;" not in s:
    raise SystemExit("OPPO speculative-verification return contract was lost")
if "return !ret ? REASON_STACK : 0;" in s:
    raise SystemExit("donor-only REASON_STACK sanitizer ABI was unexpectedly grafted")
if "static int sanitize_err(" in s or "static int sanitize_check_bounds(" in s:
    raise SystemExit("donor-only sanitizer pre-state was unexpectedly grafted")

p.write_text(s)
print(
    "[PASS] 79362 resolver: preserved OPPO verifier policy/sanitizer contract "
    "and migrated conflicting calls to env logger API"
)
