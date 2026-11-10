#!/usr/bin/env bash
# Backport the final OpenELA 4.14.356 -> 4.14.357 source fixes in groups.
# This deliberately excludes release metadata and does not advance SUBLEVEL.
set -Eeuo pipefail
cd "${KERNEL_DIR:-$GITHUB_WORKSPACE/$KERNEL_REL}"
report="$GITHUB_WORKSPACE/openela-report"
mkdir -p "$report"
rm -f -- "$GITHUB_WORKSPACE/kernel-version-proof.txt"
base=a76b6a6556353484f6f29572989cd37b6cff90cc
target=1e6347375d088ecc896aabb067131d0f9e3c0575
timeout 300 git fetch --no-tags --depth=1 https://github.com/openela/kernel-lts.git \
    refs/tags/v4.14.356-openela:refs/openela-ci/4.14.356 \
    refs/tags/v4.14.357-openela:refs/openela-ci/4.14.357
test "$(git rev-parse 'refs/openela-ci/4.14.356^{commit}')" = "$base"
test "$(git rev-parse 'refs/openela-ci/4.14.357^{commit}')" = "$target"
printf 'scope=4.14.356-to-4.14.357-source-fixes\nbase=%s\ntarget=%s\n' "$base" "$target" > "$report/point-release.txt"
printf 'group\tstatus\n' > "$report/fixes.tsv"

apply_group() {
    local name=$1
    shift
    local patch="$report/$name.patch"
    local status
    git diff --binary --no-renames "$base" "$target" -- "$@" > "$patch"
    test -s "$patch"
    if git apply --reverse --check "$patch" > "$report/$name.log" 2>&1; then
        status=already-present
    elif git apply --check "$patch" >> "$report/$name.log" 2>&1; then
        git apply "$patch" >> "$report/$name.log" 2>&1
        status=applied
    elif git apply --3way --check "$patch" >> "$report/$name.log" 2>&1; then
        git apply --3way "$patch" >> "$report/$name.log" 2>&1
        status=applied-three-way
    else
        status=deferred-conflict
    fi
    printf '%s\t%s\n' "$name" "$status" | tee -a "$report/fixes.tsv"
}

apply_group clock-devres drivers/clk/clk-devres.c
apply_group ocfs2-quota fs/ocfs2/quota_global.c fs/ocfs2/quota_local.c
apply_group ip-fragments include/linux/skbuff.h net/core/sock_destructor.h \
    net/ipv4/inet_fragment.c net/ipv4/ip_fragment.c net/ipv6/netfilter/nf_conntrack_reasm.c
apply_group ima security/integrity/ima/ima_api.c security/integrity/ima/ima_template_lib.c

grep -Eq $'\t(applied|applied-three-way|already-present)$' "$report/fixes.tsv"
git diff --stat --ignore-submodules=all HEAD -- \
    drivers/clk/clk-devres.c fs/ocfs2 include/linux/skbuff.h net/core/sock_destructor.h \
    net/ipv4/inet_fragment.c net/ipv4/ip_fragment.c net/ipv6/netfilter/nf_conntrack_reasm.c \
    security/integrity/ima > "$report/applied-stat.txt"
! grep -Fxq 'SUBLEVEL = 357' Makefile
