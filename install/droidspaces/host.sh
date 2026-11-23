#!/system/bin/sh
# Android-side helper of droidspacesd.service (docs/containers.md). The unit is HostExec, so this is
# run by /system/bin/sh outside the env, with AOHP_ROOTFS pointing at the env's root.
#   save   before the daemon starts: refuse when another daemon owns the socket, and note the host
#          settings a container start changes (IP forwarding, nosuid on /data)
#   stop   before the daemon stops: stop the containers that still run, remove the bridge and put
#          the noted settings back
R=${AOHP_ROOTFS:?AOHP_ROOTFS is not set}
DS=$R/usr/local/bin/droidspaces
ST=$R/var/lib/droidspaces/.host-state
# One value per boot, so settings noted before a reboot are never put back after it.
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$boot" ] || boot=$(getprop ro.boottime.init 2>/dev/null)
data_nosuid() { if grep '^[^ ]* /data ' /proc/mounts | grep -qv nosuid; then echo 0; else echo 1; fi; }
noted() { sed -n "s/^$1=//p" "$ST" 2>/dev/null | head -n 1; }

case "${1:-}" in
save)
  if grep -q '@droidspaces$' /proc/net/unix 2>/dev/null; then
    echo "a Droidspaces daemon is already listening on @droidspaces (the system one, persist.aohp.droidspaces=1, or another env): not starting a second"
    exit 1
  fi
  mkdir -p "$R/var/lib/droidspaces"
  if [ -n "$boot" ] && [ "$(noted boot)" = "$boot" ]; then
    echo "host settings already noted for this boot"
    exit 0
  fi
  {
    echo "boot=$boot"
    echo "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)"
    echo "v6_forwarding=$(cat /proc/sys/net/ipv6/conf/all/forwarding)"
    echo "data_nosuid=$(data_nosuid)"
  } > "$ST"
  echo "noted host settings: $(tr '\n' ' ' < "$ST")"
  ;;
stop)
  for n in $("$DS" --json show 2>/dev/null | tr ',{[' '\n\n\n' | sed -n 's/^"name":"\([^"]*\)".*/\1/p'); do
    echo "stopping container $n"
    "$DS" --name="$n" stop 2>&1 | tail -n 2
  done
  if [ -z "$boot" ] || [ "$(noted boot)" != "$boot" ]; then
    echo "no host settings noted for this boot: left as they are"
    exit 0
  fi
  ip link del ds-br0 2>/dev/null && echo "removed bridge ds-br0"
  v=$(noted ip_forward)
  if [ -n "$v" ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "$v" ]; then
    echo "$v" > /proc/sys/net/ipv4/ip_forward && echo "ip_forward back to $v"
  fi
  v=$(noted v6_forwarding)
  if [ -n "$v" ] && [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" != "$v" ]; then
    echo "$v" > /proc/sys/net/ipv6/conf/all/forwarding && echo "IPv6 forwarding back to $v"
  fi
  if [ "$(noted data_nosuid)" = 1 ] && [ "$(data_nosuid)" = 0 ]; then
    mount -o remount,nosuid /data && echo "/data is nosuid again"
  fi
  rm -f "$ST"
  ;;
*)
  echo "usage: $0 save|stop" >&2
  exit 2
  ;;
esac
exit 0
