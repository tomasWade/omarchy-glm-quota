#!/usr/bin/env python3
# glm-quota-secio — secure file I/O helper for the glm-quota plugin.
#
# Every operation is check-and-use fused on file descriptors: each path is
# resolved one component at a time with O_NOFOLLOW|O_DIRECTORY, the pinned
# directory descriptor is retained for all later operations, and every file
# is fstat(2)-verified after being opened (never before). A pathname swap
# between a check and a use therefore has nothing left to race with: the
# check and the use are the same open(2) on the same descriptor.
#
# Subcommands (exit codes are the contract with bin/glm-quota):
#   read-key <path>            0 = key on stdout | 1 = missing/empty
#                              2 = unsafe (symlink, perms, owner, charset)
#   read-cache <dir> <name>    0 = "<mtime_seconds>\n<body>" on stdout
#                              3 = absent | 4 = present but unusable
#                              2 = directory failed verification
#   write-cache <dir> <name>   0 = published | 1 = failed
#                              2 = directory failed verification
#                              (the report JSON arrives on stdin)

import os
import re
import secrets
import sys
from stat import S_ISDIR, S_ISREG

O_PATH = getattr(os, "O_PATH", 0)
KEY_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
MAX_CACHE_BYTES = 65536
MAX_REPORT_BYTES = 1 << 20


def fail(code, msg=""):
    if msg:
        print("glm-quota-secio: " + msg, file=sys.stderr)
    sys.exit(code)


def walk_dir(path, create=False):
    """Resolve a directory path component-by-component with O_NOFOLLOW and
    return a pinned O_PATH descriptor for it. Symlinked components fail with
    ELOOP or ENOTDIR instead of being followed."""
    fd = os.open("/" if os.path.isabs(path) else ".",
                 O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for comp in (c for c in path.split("/") if c):
            while True:
                try:
                    nfd = os.open(comp, O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW,
                                  dir_fd=fd)
                    break
                except FileNotFoundError:
                    if not create:
                        raise
                    try:
                        os.mkdir(comp, 0o700, dir_fd=fd)
                    except FileExistsError:
                        pass
            os.close(fd)
            fd = nfd
    except BaseException:
        os.close(fd)
        raise
    return fd


def verified_dir(path, create=False):
    """Pinned directory descriptor that also passed the ownership/mode
    policy: real directory, owned by the current user, no group/other write
    bits. Returns None when the policy check fails."""
    df = walk_dir(path, create=create)
    try:
        st = os.fstat(df)
        if not S_ISDIR(st.st_mode) or st.st_uid != os.geteuid() \
                or (st.st_mode & 0o022):
            return None
    except BaseException:
        os.close(df)
        raise
    return df


def read_all(fd, cap):
    chunks = []
    total = 0
    while True:
        b = os.read(fd, 65536)
        if not b:
            return b"".join(chunks)
        total += len(b)
        if total > cap:
            raise OverflowError
        chunks.append(b)


def read_key(path):
    parent, name = os.path.split(path)
    if not name:
        fail(1)
    try:
        df = verified_dir(parent)
    except OSError:
        fail(2, "key directory unreachable")
    if df is None:
        fail(2, "key directory failed verification")
    try:
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=df)
        except FileNotFoundError:
            fail(1)
        except OSError:
            fail(2, "key path rejected (symlink or special file)")
        try:
            st = os.fstat(fd)
            if not S_ISREG(st.st_mode) or st.st_uid != os.geteuid() \
                    or (st.st_mode & 0o077) or st.st_size > 4096:
                fail(2, "key file failed fstat policy")
            try:
                data = read_all(fd, 4096)
            except OverflowError:
                fail(2, "key file too large")
        finally:
            os.close(fd)
    finally:
        os.close(df)
    line = data.split(b"\n", 1)[0].decode("ascii", "replace").strip()
    if not line:
        fail(1)
    if not KEY_RE.fullmatch(line):
        fail(2, "key charset rejected")
    sys.stdout.write(line)
    sys.exit(0)


def read_cache(cdir, name):
    try:
        df = verified_dir(cdir)
    except OSError:
        fail(3, "cache directory unreachable")
    if df is None:
        fail(2, "cache directory failed verification")
    try:
        try:
            # O_NONBLOCK so a planted FIFO cannot hang the open; regular
            # files are unaffected by it.
            fd = os.open(name,
                         os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=df)
        except FileNotFoundError:
            fail(3)
        except OSError:
            fail(4, "cache path rejected (symlink or special file)")
        try:
            st = os.fstat(fd)
            if not S_ISREG(st.st_mode) or st.st_size > MAX_CACHE_BYTES:
                fail(4, "cache failed fstat policy")
            try:
                body = read_all(fd, MAX_CACHE_BYTES)
            except OverflowError:
                fail(4, "cache exceeded byte cap")
        finally:
            os.close(fd)
    finally:
        os.close(df)
    sys.stdout.buffer.write(str(int(st.st_mtime)).encode() + b"\n" + body)
    sys.exit(0)


def write_cache(cdir, name):
    try:
        report = sys.stdin.buffer.read(MAX_REPORT_BYTES + 1)
    except OSError:
        fail(1, "could not read report")
    if not report or len(report) > MAX_REPORT_BYTES:
        fail(1, "report payload rejected")
    try:
        df = verified_dir(cdir, create=True)
    except OSError:
        fail(1, "cache directory create failed")
    if df is None:
        fail(2, "cache directory failed verification")
    tmp = ".glm-quota." + secrets.token_hex(8)
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=df)
        try:
            view = memoryview(report)
            while view:
                n = os.write(fd, view)
                view = view[n:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(tmp, name, src_dir_fd=df, dst_dir_fd=df)
    except OSError:
        try:
            os.unlink(tmp, dir_fd=df)
        except OSError:
            pass
        fail(1, "cache publish failed")
    finally:
        os.close(df)
    sys.exit(0)


def main():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "read-key":
        read_key(a[1])
    if len(a) == 3 and a[0] == "read-cache":
        read_cache(a[1], a[2])
    if len(a) == 3 and a[0] == "write-cache":
        write_cache(a[1], a[2])
    fail(9, "usage: read-key PATH | read-cache DIR NAME | write-cache DIR NAME")


if __name__ == "__main__":
    main()
