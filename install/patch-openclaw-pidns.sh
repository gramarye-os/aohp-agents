#!/bin/bash
# patch-openclaw-pidns.sh — make OpenClaw >= 2026.11 start inside an AOHP container.
#
# Why: since 2026.11 the gateway proves it owns its state by reading /proc/self/ns/pid
# (gateway-lock-payload readGatewayLockProcessNamespace). The AOHP container has no namespace
# links under /proc/self/ns, the read throws, the "current namespace" becomes null, and
# classifyGatewayOwnerProcessNamespace then treats every previous owner lease as "unknown" while its
# heartbeat is < 90 s old — doctor --fix and the gateway itself refuse with
# "cannot verify Gateway ownership from this process (different PID namespace)". With RestartSec=5
# the heartbeat never goes stale: the gateway crash-loops (status=78, start-limit-hit).
# Fix: fall back to a constant inode "0" when the stat fails, so same host + same boot id compares
# as the same namespace and the normal PID liveness rules apply. Idempotent; keeps <file>.aohp-orig.
# Run after every openclaw install/upgrade (install/openclaw.sh calls it). Proven on the Pixel 6,
# 2026.11.2, 2026-11-08: 10 dist copies patched, gateway up and reachable on the LAN within 10 s.
set -uo pipefail
D=${1:-/usr/local/lib/node_modules/openclaw/dist}
[ -d "$D" ] || { echo "patch-openclaw-pidns: no dist at $D" >&2; exit 1; }
n=0
for f in $(grep -rl 'statSync("/proc/self/ns/pid"' "$D" 2>/dev/null); do
  grep -q 'catch { return "0"; }' "$f" && continue
  [ -f "$f.aohp-orig" ] || cp -a "$f" "$f.aohp-orig"
  python3 - "$f" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
pat=re.compile(r'(\w+(?:\$\d+)?)\.statSync\("/proc/self/ns/pid", \{ bigint: true \}\)\.ino\.toString\(\)')
new,cnt=pat.subn(lambda m: '(() => { try { return %s.statSync("/proc/self/ns/pid", { bigint: true }).ino.toString(); } catch { return "0"; } })()' % m.group(1), s)
if cnt: open(p,"w").write(new)
PY
  n=$((n+1))
done
echo "patch-openclaw-pidns: patched $n file(s) under $D"
