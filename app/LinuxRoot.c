//
//  LinuxRoot.c
//  libiSHLinux
//
//  Created by Theodore Dubois on 12/29/21.
//

#include <linux/init.h>
#include <linux/syscalls.h>
#include <linux/init_syscalls.h>
#include <linux/fs.h>
#include <linux/stat.h>
#include <linux/errname.h>
#include <linux/device.h>
#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/string.h>
#include <uapi/linux/mount.h>
#include "LinuxInterop.h"

void FsInitialize(void);

/*
 * Debug helper — panic() embeds the message into the crash report that
 * the device generates, so we can read it even without working syslog.
 * pr_notice writes into the kernel log buffer (readable via dmesg once
 * userspace is up) but is invisible at boot without a registered console.
 */
#define dbg_fmt(fmt, ...) \
    pr_notice("ish_rootfs: " fmt, ##__VA_ARGS__)

#define fail_panic(fmt, ...) \
    panic("ish_rootfs: " fmt, ##__VA_ARGS__)

/*
 * Stat a path and panic with a descriptive message if it fails.
 * Returns 0 on success (stat filled), -errno on failure (unreachable — panics).
 */
static __init int verify_path(const char *path, const char *label,
                              const char *hostfs_path)
{
    struct kstat st;
    int err = init_stat(path, &st, 0);
    if (err < 0) {
        fail_panic("%s stat(%s) failed after hostfs mount: %s (err=%d); "
                   "hostfs_path=%s", label, path, errname(err), err,
                   hostfs_path ? hostfs_path : "NULL");
    }
    dbg_fmt("%s stat(%s) ok: mode=0%o size=%lld\n",
            label, path, st.mode, st.size);
    return 0;
}

static __init int ish_rootfs(void) {
    ReportExecTrace("root.mount.enter", 1);
    rootfs_mounted = true;

    dbg_fmt("starting\n");

    int err = init_mkdir("/root", 0700);
    if (err < 0 && err != -EEXIST) {
        fail_panic("init_mkdir(/root) failed: %s (err=%d)\n", errname(err), err);
        return err; /* unreachable */
    }
    dbg_fmt("init_mkdir(/root) ok\n");

    const char *hostfs_path = DefaultRootPath();
    dbg_fmt("hostfs_path=%s\n", hostfs_path ? hostfs_path : "NULL");

    if (hostfs_path == NULL || hostfs_path[0] == '\0') {
        fail_panic("DefaultRootPath() returned NULL or empty\n");
    }

    /* Host-backed files do not expose Linux security.capability semantics.
     * Mount nosuid so exec skips file-capability/setid credential elevation;
     * ordinary guest execute mode remains enforced by HostFS/VFS. */
    err = do_mount(NULL, "/root", "hostfs", MS_SILENT | MS_NOSUID,
                   (void *)hostfs_path);
    ReportExecTrace("root.mount.hostfs", err);
    if (err < 0) {
        fail_panic("do_mount(hostfs) from '%s' failed: %s (err=%d)\n",
                   hostfs_path, errname(err), err);
    }
    dbg_fmt("hostfs mounted\n");

    err = init_chdir("/root");
    ReportExecTrace("root.mount.chdir", err);
    dbg_fmt("chdir /root\n");

    /* Paths are absolute from / — hostfs is mounted at /root */
    verify_path("/root/sbin", "dir", hostfs_path);
    verify_path("/root/sbin/init", "init", hostfs_path);
    verify_path("/root/bin", "dir", hostfs_path);
    verify_path("/root/bin/sh", "shell", hostfs_path);

    err = devtmpfs_mount();
    ReportExecTrace("root.mount.devtmpfs", err);
    err = do_mount("proc", "proc", "proc", MS_SILENT, NULL);
    ReportExecTrace("root.mount.proc", err);
    if (err < 0) {
        pr_warn("ish_rootfs: procfs mount failed: %s\n", errname(err));
    }

    err = do_mount(".", "/", NULL, MS_MOVE, NULL);
    ReportExecTrace("root.mount.move", err);
    err = init_chroot(".");
    ReportExecTrace("root.mount.chroot", err);

    dbg_fmt("calling FsInitialize\n");
    FsInitialize();
    dbg_fmt("done\n");
    return 0;
}

rootfs_initcall(ish_rootfs);
