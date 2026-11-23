# Containers in an env (Droidspaces)

An env can run full Linux containers of its own with [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS):
each has its own PID 1 (systemd), its own network address and, if wanted, the GPU. This needs a phone
image with the container policy of 2026-11-23 or later (the "ds6" images); arm64 only.

## Quick start

```
aohp-container create deb1        # copy the env's Debian template, about 2 GB
systemctl start ds-deb1           # starts the daemon too
droidspaces --name=deb1 enter     # a root shell in it
systemctl stop droidspacesd       # stop every container, put the phone's settings back
```

To start a container with the env (and so at boot): `systemctl enable droidspacesd ds-deb1`.
Nothing is enabled by default.

## The pieces

| piece | what it is |
|---|---|
| `droidspacesd.service` | The Droidspaces daemon. A `HostExec=` unit: it runs on the Android side, from the env's own copy of the binary (`/usr/local/bin/droidspaces`), in the env's SELinux domain. Installed by `install/tessera.sh`. |
| `ds-<name>.service` | One unit per container, written by `aohp-container`. Start = `droidspaces ... start`, stop = `droidspaces --name=<name> stop`. It requires the daemon unit. |
| `aohp-container` | `create`, `unit`, `list`, `remove`. |
| `/var/lib/droidspaces/<name>/rootfs` | The container's files, inside the env. |
| `/usr/local/lib/aohp/droidspaces-host.sh` | Android-side helper of the daemon unit (below). |

The `droidspaces` command talks to the daemon over the socket `@droidspaces`. Only one daemon can
own that socket on a phone: if the image's system daemon is on (`persist.aohp.droidspaces=1`) or
another env runs one, `droidspacesd.service` refuses to start and says so in its log
(`journalctl -u droidspacesd`).

## What `aohp-container create` does to the copy

The template is built to be an env, not a system with its own init. In the copy:

- `/usr/sbin/init` points at systemd, the hostname is set, the machine id is emptied;
- aohp's `systemctl` and `journalctl` stand-ins are removed from `/usr/local/bin` (they would hide
  the real ones);
- ssh host keys are made (the template ships without, so every system has its own);
- with `--net nat` (the default): `eth0` gets its address by DHCP from Droidspaces, through
  systemd-networkd;
- `dbus` is installed, which logind needs. This needs the network; if it fails the command says
  so and the container still works, without logind.

Options: `--net nat|host|none`, `--no-gpu`, `--hostname NAME`. When the env has Tessera's agent,
its files and X socket directory are bound into the container, so Tessera can start apps "in" it.

## What a container changes on the phone, and how it is undone

Starting a container in NAT mode makes Droidspaces turn on IP forwarding (IPv4 and IPv6), create
the bridge `ds-br0` and remount `/data` without `nosuid`. Droidspaces does not undo this when the
container stops. The daemon unit does:

- before the daemon starts, the helper notes the current settings in `/var/lib/droidspaces/.host-state`;
- `systemctl stop droidspacesd` first stops the container units, then any container started by
  hand, then removes the bridge and puts the noted settings back.

A reboot also resets all of it. Stopping only a container (`systemctl stop ds-<name>`) leaves the
settings as they are, because other containers may still run.

## Limits

- The copy is a full Debian with the env's tools in it, not a minimal system.
- `PrivateUsers=` in a unit inside the container fails: user namespaces are off unless the
  container is started with `--allow-sandboxing`.
- A container does not start by itself unless its unit is enabled.
