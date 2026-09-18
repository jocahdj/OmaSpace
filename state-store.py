"""Linux no-follow state operations; invoked with python3 -I -S."""

import os
import secrets
import stat
import sys

LIMIT = 1024 * 1024


def open_hierarchy(path):
    parts = path.split("/")[1:]
    if not path.startswith("/") or any(p in (".", "..") for p in parts):
        raise ValueError("Invalid state path")
    parts = [p for p in parts if p]
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    parent = None
    for index, part in enumerate(parts):
        try:
            os.mkdir(part, 0o700, dir_fd=fd)
        except FileExistsError:
            pass
        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=fd)
        info = os.fstat(child)
        leaf = index == len(parts) - 1
        if info.st_uid not in ((os.geteuid(),) if leaf else (0, os.geteuid())):
            raise ValueError("State path owned by another user: " + part)
        if info.st_mode & 0o022:
            raise ValueError("Group/other-writable state path: " + part)
        if leaf:
            os.fchmod(child, 0o700)
            parent = fd
        else:
            os.close(fd)
        fd = child
    if parent is None:
        raise ValueError("Invalid state hierarchy")
    return fd, parent


def read_state(fd, name):
    try:
        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return 2
    if not stat.S_ISREG(info.st_mode):
        return 1
    # NONBLOCK also prevents a replacement FIFO from hanging the open.
    source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                     dir_fd=fd)
    try:
        actual = os.fstat(source)
        if (not stat.S_ISREG(actual.st_mode)
                or (actual.st_dev, actual.st_ino) != (info.st_dev, info.st_ino)
                or actual.st_uid != os.geteuid() or actual.st_nlink != 1
                or actual.st_mode & 0o022 or actual.st_size > LIMIT):
            return 1
        with os.fdopen(source, "rb", closefd=False) as stream:
            data = stream.read(LIMIT + 1)
        if len(data) > LIMIT or b"\0" in data:
            return 1
        sys.stdout.buffer.write(data)
        return 0
    finally:
        os.close(source)


def write_state(fd, name):
    data = sys.stdin.buffer.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ValueError("State exceeds 1 MiB")
    temporary = ".layouts." + secrets.token_hex(16)
    target = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                     | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    try:
        with os.fdopen(target, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, name, src_dir_fd=fd, dst_dir_fd=fd)
        os.fsync(fd)
    finally:
        try:
            os.unlink(temporary, dir_fd=fd)
        except FileNotFoundError:
            pass


def main():
    action = sys.argv[1]
    if action == "start":
        fd, parent = open_hierarchy(sys.argv[2])
        os.set_inheritable(fd, True)
        os.set_inheritable(parent, True)
        allow = {key: os.environ[key] for key in (
            "HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR",
            "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS",
            "WAYLAND_DISPLAY") if key in os.environ}
        allow.update(PATH="/usr/bin", LC_ALL="C.UTF-8")
        os.execve("/bin/bash", ["/bin/bash", "--noprofile", "--norc", "-p",
                  "--", sys.argv[3], "--state-fds", str(fd), str(parent),
                  *sys.argv[4:]], allow)
        return 0
    fd, name = int(sys.argv[2]), sys.argv[3]
    if action == "read":
        return read_state(fd, name)
    if action == "write":
        write_state(fd, name)
        return 0
    raise ValueError("Unknown state operation")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print("OmaSpace state: " + str(error), file=sys.stderr)
        sys.exit(1)
