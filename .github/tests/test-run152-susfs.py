#!/usr/bin/env python3
"""Exercise extracted 4.14 lifetime paths with host API mocks, not a boot test."""

import argparse
from pathlib import Path
import re
import resource
import subprocess
import tempfile
import unittest


def function(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


def macro(text, name):
    lines = text.splitlines()
    index = next(i for i, line in enumerate(lines) if line.startswith("#define " + name + "("))
    selected = [lines[index]]
    while selected[-1].endswith("\\"):
        index += 1
        selected.append(lines[index])
    return "\n".join(selected)


class LifetimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.susfs = (KERNEL_DIR / "fs/susfs.c").read_text()
        cls.namei = (KERNEL_DIR / "fs/namei.c").read_text()

    def compile_and_run(self, source):
        with tempfile.TemporaryDirectory(prefix="pchm30-lifetime-") as directory:
            program = Path(directory) / "check.c"
            binary = Path(directory) / "check"
            program.write_text(source)
            subprocess.run([
                "cc", "-O1", "-g", "-fsanitize=undefined",
                "-fno-sanitize-recover=all", str(program), "-o", str(binary)
            ], check=True)
            subprocess.run([str(binary)], check=True)

    def test_both_bitmap_publishers_accept_initial_null(self):
        header = (KERNEL_DIR / "include/linux/rcupdate.h").read_text()
        blocks = []
        for name in ("void susfs_set_priority_uid_filter(",
                     "static int susfs_priority_app_strings_worker("):
            body = function(self.susfs, name)
            guarded = re.findall(r"\tif \(old_bitmap\)\n\t\tkfree_rcu\(old_bitmap, rcu\);", body)
            self.assertEqual(len(guarded), 1, name)
            blocks.append(guarded[0])
        structure = re.search(r"struct susfs_priority_uid_filter_bitmap \{.*?\n\};",
                              self.susfs, re.S).group()
        source = r'''
#include <stddef.h>
#include <assert.h>
#include <stdlib.h>
typedef void (*rcu_callback_t)(void *);
struct rcu_head { struct rcu_head *next; rcu_callback_t func; };
#define SUSFS_PRIORITY_UID_FILTER_BITMAP_LEN 157
#define BUILD_BUG_ON(x) _Static_assert(!(x), "bad RCU offset")
static int queued;
static void kfree_call_rcu(struct rcu_head *head, rcu_callback_t func)
{
    assert(head);
    head->func = func;
    head->next = NULL;
    queued++;
}
'''
        source += "\n".join(macro(header, n) for n in
                            ("__is_kfree_rcu_offset", "__kfree_rcu", "kfree_rcu"))
        source += "\n" + structure + "\n"
        for number, block in enumerate(blocks):
            source += f"static void publish{number}(struct susfs_priority_uid_filter_bitmap *old_bitmap) {{\n{block}\n}}\n"
        source += r'''
int main(void)
{
    struct susfs_priority_uid_filter_bitmap old = {0};
    publish0(NULL); publish1(NULL);
    assert(queued == 0);
    publish0(&old); publish1(&old);
    assert(queued == 2);
    return 0;
}
'''
        self.compile_and_run(source)

    def test_regular_open_success_and_error_ownership(self):
        actual = function(self.namei, "static struct file *path_openat(")
        do_last = function(self.namei, "static int do_last(")
        opening = do_last[do_last.index("\tBUG_ON(*opened & FILE_OPENED);"):
                          do_last.index("\nopened:")]
        source = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#define CONFIG_KSU_SUSFS_OPEN_REDIRECT 1
#define FILE_OPENED 1
#define LOOKUP_OPEN 2
#define LOOKUP_CREATE 4
#define LOOKUP_EXCL 8
#define LOOKUP_RCU 16
#define __O_TMPFILE 32
#define O_PATH 64
#define EOPENSTALE 518
#define unlikely(x) (x)
#define ERR_PTR(e) ((void *)(intptr_t)(e))
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define ERR_CAST(p) ((void *)(p))
#define IS_ERR(p) ((uintptr_t)(void *)(p) >= (uintptr_t)-4095)
#define BUG_ON(x) assert(!(x))
struct inode { int redirected; };
struct dentry { struct inode *d_inode; };
struct path { struct dentry *dentry; };
struct filename { const char *name; };
struct nameidata { int dfd; unsigned flags; struct filename *name; struct path path; };
struct open_flags { int open_flag; };
struct file { int f_flags, allocated, is_open; struct inode *inode; };
static struct inode inode = {1};
static struct dentry dentry = {&inode};
static struct filename fake = {"/replacement"};
static struct file files[2];
static int mode, allocations, closes, drops, names, walk_calls, last_calls, path_calls;
#define SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK(i) ((i)->redirected)
static struct inode *file_inode(struct file *f) { assert(f->is_open); return f->inode; }
static struct file *get_empty_filp(void)
{
    int i = allocations++;
    assert(i < 2);
    if (i == 1 && mode == 2) return ERR_PTR(-ENOMEM);
    files[i].allocated = 1;
    return &files[i];
}
static void fput(struct file *f)
{
    assert(f->allocated && f->is_open);
    f->allocated = f->is_open = 0;
    closes++;
}
static void put_filp(struct file *f)
{
    assert(f->allocated && !f->is_open);
    f->allocated = 0;
    drops++;
}
static int do_tmpfile(struct nameidata *n, unsigned f, const struct open_flags *o, struct file *p, int *s) { abort(); }
static int do_o_path(struct nameidata *n, unsigned f, struct file *p) { abort(); }
static const char *path_init(struct nameidata *n, unsigned f)
{
    path_calls++;
    n->flags = f;
    if (path_calls == 2 && mode == 3) return ERR_PTR(-ENOENT);
    return n->name->name;
}
static int link_path_walk(const char *s, struct nameidata *n)
{
    walk_calls++;
    if (path_calls == 2 && mode == 4) return -ENOENT;
    if (path_calls == 2 && mode == 6 && walk_calls == 3) assert(!strcmp(s, "/symlink-target"));
    return 0;
}
static const char *trailing_symlink(struct nameidata *n) { return "/symlink-target"; }
static struct filename *susfs_open_redirect_spoof_do_sys_openat(struct inode *i) { return &fake; }
static void terminate_walk(struct nameidata *n) { n->path.dentry = NULL; }
static void restore_nameidata(void) {}
static void set_nameidata(struct nameidata *n, int dfd, struct filename *f) { n->dfd = dfd; n->name = f; }
static void putname(struct filename *n) { assert(n == &fake); names++; }
static void global_filetable_add(struct file *f) { assert(f->allocated && f->is_open); }
static void *current_cred(void) { return NULL; }
static int vfs_open(struct path *p, struct file *f, void *c)
{
    assert(f->allocated && !f->is_open);
    if (f == &files[1] && mode == 5) return -EACCES;
    f->is_open = 1; f->inode = &inode;
    return 0;
}
static int do_last(struct nameidata *nd, struct file *file, const struct open_flags *op, int *opened)
{
    int error;
    last_calls++;
    nd->path.dentry = &dentry;
    if (last_calls == 2 && mode == 6) return 1;
'''
        source += opening + r'''
out:
    return error;
}
'''
        source += actual + r'''
int main(void)
{
    for (mode = 0; mode <= 6; mode++) {
        struct filename original = {"/original"};
        struct nameidata nd = {.dfd = -100, .name = &original};
        struct open_flags op = {.open_flag = 0x1000};
        struct file *result;
        memset(files, 0, sizeof(files));
        allocations = closes = drops = names = walk_calls = last_calls = path_calls = 0;
        inode.redirected = mode != 0;
        result = path_openat(&nd, &op, LOOKUP_OPEN | LOOKUP_RCU);
        assert(nd.name == &original);
        if (mode == 0) {
            assert(result == &files[0] && allocations == 1 && closes == 0 && names == 0);
            fput(result);
        } else if (mode == 1 || mode == 6) {
            assert(result == &files[1] && allocations == 2 && closes == 1 && names == 1);
            assert(result->f_flags == op.open_flag && drops == 0);
            fput(result);
        } else {
            int expected = mode == 2 ? -ENOMEM : mode == 5 ? -EACCES : -ENOENT;
            assert(IS_ERR(result) && PTR_ERR(result) == expected);
            assert(closes == 1 && names == 1 && drops == (mode == 2 ? 0 : 1));
        }
        assert(!files[0].allocated && !files[1].allocated);
    }
    return 0;
}
'''
        self.compile_and_run(source)

    def test_fsnotify_failure_and_cleanup_references(self):
        source = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#define KERNEL_VERSION(a,b,c) (((a)<<16)+((b)<<8)+(c))
#define LINUX_VERSION_CODE KERNEL_VERSION(4,14,255)
#define GFP_KERNEL 0
#define LOOKUP_FOLLOW 1
#define SUSFS_LOGI(...) ((void)0)
#define SUSFS_LOGE(...) ((void)0)
#define xchg(p,v) ({ __typeof__(*(p)) old = *(p); *(p) = (v); old; })
typedef unsigned int u32;
struct work_struct {};
struct inode { int refs; };
struct dentry { struct inode *inode; };
struct path { void *mnt; struct dentry *dentry; };
struct fsnotify_mark;
struct fsnotify_ops { int (*handle_event)(void); void (*free_mark)(struct fsnotify_mark *); };
struct fsnotify_group { const struct fsnotify_ops *ops; int refs; struct fsnotify_mark *mark; };
struct fsnotify_mark { struct fsnotify_group *group; unsigned mask; int refs; };
struct watch_dir { const char *path; struct inode *inode; struct path kpath; struct fsnotify_mark *mark; unsigned mask; };
static struct fsnotify_group *g;
static struct watch_dir g_watch;
static int susfs_sdcard_watch_lock, susfs_is_sdcard_android_data_not_decrypted;
static int fail_add, frees, groups_freed, path_refs;
static struct inode backing;
static struct dentry dentry = {&backing};
static void mutex_lock(int *p) { assert(!*p); *p = 1; }
static void mutex_unlock(int *p) { assert(*p); *p = 0; }
static int static_key_enabled(int *p) { return *p; }
static void static_branch_disable(int *p) { *p = 0; }
static void *kzalloc(size_t n, int flags) { return calloc(1, n); }
static void kfree(void *p) { assert(p); frees++; free(p); }
static void put_group(struct fsnotify_group *p) { if (!--p->refs) { groups_freed++; free(p); } }
static void fsnotify_init_mark(struct fsnotify_mark *m, struct fsnotify_group *p)
{ m->refs = 1; m->group = p; p->refs++; }
static int fsnotify_add_mark(struct fsnotify_mark *m, struct inode *i, void *v, int flags)
{ if (fail_add) return -ENOMEM; m->refs++; m->group->mark = m; return 0; }
static void fsnotify_put_mark(struct fsnotify_mark *m)
{
    assert(m->refs > 0);
    if (!--m->refs) {
        struct fsnotify_group *p = m->group;
        assert(p->ops->free_mark);
        p->ops->free_mark(m);
        put_group(p);
    }
}
static void fsnotify_destroy_group(struct fsnotify_group *p)
{ if (p->mark) { fsnotify_put_mark(p->mark); p->mark = NULL; } put_group(p); }
static void ihold(struct inode *i) { i->refs++; }
static void iput(struct inode *i) { assert(i->refs > 0); i->refs--; }
static struct inode *d_backing_inode(struct dentry *d) { return d->inode; }
static int kern_path(const char *name, unsigned flags, struct path *p)
{ p->mnt = &backing; p->dentry = &dentry; path_refs++; return 0; }
static void path_put(struct path *p) { assert(p->mnt && path_refs > 0); path_refs--; }
static int susfs_handle_sdcard_inode_event(void) { return 0; }
'''
        source += function(self.susfs, "static void m_free(struct fsnotify_mark *m)\n{") + "\n"
        source += re.search(r"static const struct fsnotify_ops fsnotify_ops = \{.*?\n\};",
                            self.susfs, re.S).group() + "\n"
        # Choose the definition rather than the forward declaration.
        start = self.susfs.index("static int add_mark_on_inode(", self.susfs.index("static const struct fsnotify_ops"))
        source += function(self.susfs[start:], "static int add_mark_on_inode(") + "\n"
        source += function(self.susfs, "static int watch_one_dir(") + "\n"
        source += function(self.susfs, "static void susfs_sdcard_cleanup_fn(") + "\n"
        source += r'''
int main(void)
{
    int scenario;
    for (scenario = 0; scenario < 2; scenario++) {
        int ret;
        g = calloc(1, sizeof(*g));
        g->ops = &fsnotify_ops; g->refs = 1;
        memset(&g_watch, 0, sizeof(g_watch));
        g_watch.path = "/data/media/0";
        fail_add = scenario;
        ret = watch_one_dir(&g_watch);
        assert(ret == (fail_add ? -ENOMEM : 0));
        if (fail_add) assert(!g_watch.kpath.mnt && !g_watch.inode && !g_watch.mark);
        susfs_sdcard_cleanup_fn(NULL);
        susfs_sdcard_cleanup_fn(NULL);
        assert(!g && !g_watch.mark && !g_watch.inode && !g_watch.kpath.mnt);
        assert(backing.refs == 0 && path_refs == 0 && !susfs_sdcard_watch_lock);
        assert(frees == scenario + 1 && groups_freed == scenario + 1);
    }
    return 0;
}
'''
        self.compile_and_run(source)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel-dir", type=Path, required=True)
    arguments, remaining = parser.parse_known_args()
    KERNEL_DIR = arguments.kernel_dir.resolve()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    unittest.main(argv=[__file__, *remaining], verbosity=2)
