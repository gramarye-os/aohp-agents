# Flatpak in an env

Real Flatpak, with bubblewrap's sandbox, runs inside an AOHP container: the env's kernel side
(user, mount, PID, network and IPC namespaces, seccomp, overlayfs) is all there. Two things had to
be added: SELinux rules in the ROM and a few services in the env.

## Set up

    /opt/aohp-agents/install/flatpak.sh          # once per env, as root; Debian/apt envs
    aohp-flatpak install flathub org.kde.kcalc
    aohp-flatpak run org.kde.kcalc               # window on $DISPLAY, default :0 (x11.service)

`aohp-flatpak` runs `flatpak --user` as the env's non-root Flatpak user (name in
`/etc/aohp/flatpak-user`) with `HOME`, `XDG_RUNTIME_DIR=/run/user/<uid>` and, for `run`, a session
bus. Apps and runtimes live in that user's `~/.local/share/flatpak` (KCalc + the KDE 6.11 runtime:
2.6 GB).

## What the ROM needs

sepolicy round 14, `system/sepolicy` 56c8b4be5 (first image: dodge cred47). bubblewrap does these,
and none of the denials shows up as an avc:

| bubblewrap step | message without the rule | rule |
|---|---|---|
| reads `/proc/sys/kernel/overflowuid`, `overflowgid` | `Can't read /proc/sys/kernel/overflowuid: Permission denied` | own type `proc_overflowuid`, read |
| `--disable-userns` writes `/proc/sys/user/max_user_namespaces` | `cannot open /proc/sys/user/max_user_namespaces` | own type `proc_max_user_namespaces`, rw |
| read-only bind of `/sdcard` (D-Bus proxy sandbox binds every top-level dir) | `Can't bind mount /sdcard on /sdcard: Unable to remount destination` | `fuse:filesystem remount` |
| read-only bind of `/proc/self/ns/user` on `/run/.userns` | same, for `/newroot/run/.userns` | `unlabeled:filesystem remount` (nsfs has no label) |
| `dri` device grant binds `/dev/udmabuf` when it exists | `Can't get type of source /dev/udmabuf` | `udmabuf_device:chr_file getattr` |
| xdg-document-portal mounts FUSE on `/run/user/<uid>/doc` | `fuse: failed to open /dev/fuse` (apps still start) | `fuse_device` rw, `fuse:filesystem { mount unmount }`, plus `/dev/fuse 0666` from ueventd (below) |

On an older image `install/flatpak.sh` still works and says so; `aohp-flatpak run` stops at the
first row.

Verified on dodge cred47 (2026-11-14) with no shim: KCalc from Flathub runs with the `dri` grant,
`unshare -U` inside the sandbox is refused, and no new avc appears for the container domain.

## What the env needs (what install/flatpak.sh does)

- **A system bus that answers.** Flatpak queries AccountsService for parental controls at install
  and on every launch. No bus: "Could not connect". Bus refusing the call: "Not allowed to query
  parental controls data for user N". The env's bus runs as root from
  `/etc/aohp/dbus-system.conf`, a copy of the stock `system.conf` without the messagebus user; the
  copy must name `/usr/share/dbus-1/system.d` absolutely or no service policy is loaded.
- **polkit and accounts-daemon as units.** D-Bus activation needs the setuid launch helper, which
  only accepts the messagebus user ("The permission of the setuid helper is not correct"), and
  accounts-daemon will not start without polkit.
- **A non-root user** with `/run/user/<uid>` (and `/run/user` searchable: a root `mkdir -p` leaves
  it 700 and dconf then fails).

## File chooser (portals)

A sandboxed app without direct folder access opens files through xdg-desktop-portal, which hands
the chosen file to the sandbox on a FUSE mount, `/run/user/<uid>/doc`. Three things make that work:

- **`/dev/fuse` openable by the user.** Stock Android has no ueventd rule for it, so it is `0600 root`;
  libfuse opens the device itself and falls back to the setuid `fusermount3` only when `mount()` is
  refused, not when the open is. `system/core` 0bd6c493d2 adds `/dev/fuse 0666 root root` (first image:
  dodge cred48). The env's `/dev` is a bind of the host's, so this is the host node; SELinux still
  limits opening it to a few system daemons and the container domain.
- **A capability bounding set in the user session.** `fusermount3` is setuid root and needs
  CAP_SYS_ADMIN; `aohp-flatpak` drops the inheritable set but keeps the bounding set.
- **A backend.** `xdg-desktop-portal-gtk`; with no desktop configured xdg-desktop-portal falls back
  to it and offers `FileChooser` version 4.

Checked on dodge cred47 with a temporary `chmod 0666 /dev/fuse`: the document portal runs as uid 1000
and mounts `/run/user/1000/doc`.

## Limits

- **GPU:** Flathub runtimes ship a Mesa without the KGSL backend, and the `dri` grant exposes
  `/dev/dri`, not `/dev/kgsl-3d0`. Apps render in software until a Turnip build is supplied as a
  runtime GL extension.
- **Display:** X11 through the env's X server. No Wayland compositor is provided.
- **uids are Android's.** The env has no user namespace of its own, so uid 1000 in the env is
  Android's system uid as far as file ownership goes (SELinux still confines it to the container
  domain). Network follows Android's rules per uid: 1000 and 6000 reach the network, 30000 does not.
