#!/bin/bash
# Flatpak in this container: packages, a system bus that answers, polkit + AccountsService units,
# a non-root user, Flathub, and the aohp-flatpak launcher. Idempotent. Debian/apt only for now.
#
#   /opt/aohp-agents/install/flatpak.sh [user]     # default: first user with uid 1000-9999, else creates "user"
#
# Why each piece (found on a OnePlus 13 env, 2026-11-14; details in docs/flatpak.md):
#  - Flatpak asks org.freedesktop.Accounts on the SYSTEM bus (parental controls) at install and on
#    every launch and fails hard when the bus is missing or the call is refused.
#  - The env's system bus runs as root (the env cannot drop to messagebus), so D-Bus activation
#    through the setuid launch helper never works: polkitd and accounts-daemon are units here.
#  - A copy of system.conf outside /usr/share/dbus-1 must name the policy directory absolutely;
#    a relative <includedir> loads no service policy and the bus rejects every call.
#  - bubblewrap needs the ROM's sepolicy round 14 (system/sepolicy 56c8b4be5); older images stop at
#    "Can't read /proc/sys/kernel/overflowuid".
set -euo pipefail
SRC=${AOHP_AGENTS_DIR:-/opt/aohp-agents}
SYS=/etc/aohp/system
log() { echo "[flatpak] $*"; }

command -v apt-get >/dev/null || { echo "[flatpak] only Debian/apt containers are handled so far" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "[flatpak] run as root" >&2; exit 1; }

PKGS="flatpak dbus-daemon dbus-bin dbus-system-bus-common polkitd accountsservice xdg-desktop-portal ca-certificates"
MISSING=""
for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"; done
if [ -n "$MISSING" ]; then
  log "installing:$MISSING"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends $MISSING
fi

# system bus config: stock minus the messagebus user, policy directory made absolute
mkdir -p /etc/aohp
sed -e '/<user>messagebus<\/user>/d' \
    -e 's#<includedir>system.d</includedir>#<includedir>/usr/share/dbus-1/system.d</includedir>#' \
    /usr/share/dbus-1/system.conf > /etc/aohp/dbus-system.conf.new
BUS_CHANGED=0
if ! cmp -s /etc/aohp/dbus-system.conf.new /etc/aohp/dbus-system.conf 2>/dev/null; then
  [ -e /etc/aohp/dbus-system.conf ] && cp -p /etc/aohp/dbus-system.conf "/etc/aohp/dbus-system.conf.bak-$(date +%Y%m%d)"
  mv /etc/aohp/dbus-system.conf.new /etc/aohp/dbus-system.conf; BUS_CHANGED=1; log "wrote /etc/aohp/dbus-system.conf"
else
  rm -f /etc/aohp/dbus-system.conf.new
fi

# units (a <name>.local marker keeps a hand-edited copy, as in units.sh; an existing dbus-system.service is kept)
mkdir -p "$SYS/aohp.target.wants"
for f in "$SRC"/install/flatpak/*.service; do
  n=$(basename "$f")
  if [ -e "$SYS/$n.local" ]; then log "$n: kept local copy"; continue; fi
  if [ "$n" = dbus-system.service ] && [ -e "$SYS/$n" ]; then log "$n: already present, kept"; continue; fi
  install -m 644 "$f" "$SYS/$n"
done
install -m 755 "$SRC/bin/aohp-flatpak" /usr/local/bin/aohp-flatpak

# the user Flatpak apps run as
U=${1:-}
[ -n "$U" ] || U=$(awk -F: '$3>=1000 && $3<10000 {print $1; exit}' /etc/passwd)
if [ -z "$U" ]; then U=user; fi
if ! id "$U" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$U" >/dev/null; log "created user $U (uid $(id -u "$U"))"
fi
echo "$U" > /etc/aohp/flatpak-user

if command -v systemctl >/dev/null && [ -e /etc/aohp/env-name ]; then
  systemctl daemon-reload >/dev/null 2>&1 || true
  for u in dbus-system polkit accounts-daemon; do systemctl enable --now "$u" >/dev/null 2>&1 || log "could not start $u (see: systemctl status $u)"; done
  if [ "$BUS_CHANGED" = 1 ]; then pkill -HUP -x dbus-daemon 2>/dev/null || true; fi
  sleep 2
  for u in dbus-system polkit accounts-daemon; do log "$u: $(systemctl is-active "$u" 2>&1 | head -1)"; done
else
  log "no unit manager here (template build?): units installed, not started"
fi

if [ -S /run/dbus/system_bus_socket ]; then
  aohp-flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo && log "flathub remote ready for $U"
fi
if ! cat /proc/sys/kernel/overflowuid >/dev/null 2>&1; then
  log "NOTE: this ROM's SELinux policy predates Flatpak support; 'aohp-flatpak run' will stop in bubblewrap until the image is updated"
fi
log "done. Try: aohp-flatpak install flathub org.kde.kcalc && aohp-flatpak run org.kde.kcalc"
