#!/bin/bash
# Tessera's side of an env: the agent the Tessera app talks to, and the Droidspaces CLI the agent
# starts container apps with. Run by aohp-update in an env that has the agent, and by the template
# build (TESSERA_STAGE=1: files and the enabled unit only, nothing started).
# What is installed is pinned in install/tessera.pin; TESSERA_REF in the environment overrides it.
# The env's token and pairing (/etc/tessera) are kept. The agent is restarted only when one of its
# files changed, because a restart ends the Tessera sessions that are open.
set -euo pipefail; INSTALLER=tessera; . "$(dirname "$0")/_lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
ref_env=${TESSERA_REF:-}
. "$HERE/tessera.pin"
[ -z "$ref_env" ] || TESSERA_REF=$ref_env
STAGE=${TESSERA_STAGE:-}
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT

# ---- the agent ----------------------------------------------------------------------------------
mkdir -p "$d/agent"
for f in agent.py enter.sh setup.sh v4l_links.py install.sh tessera-agent.service; do
  curl -fsSL --retry 3 -o "$d/agent/$f" "https://raw.githubusercontent.com/$TESSERA_REPO/$TESSERA_REF/gramarye/$f"
done
python3 - "$d/agent/agent.py" <<'PY'
import sys
compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')   # a syntax check that writes no cache file
PY
changed=
for f in agent.py enter.sh setup.sh v4l_links.py; do cmp -s "$d/agent/$f" "/opt/tessera/$f" || changed="$changed $f"; done
if [ -n "$STAGE" ]; then
  TESSERA_STAGE=1 sh "$d/agent/install.sh" >/dev/null
  log "agent staged ($TESSERA_REF)"
elif [ -n "$changed" ]; then
  # A second env on a phone runs its agent on a port of its own: kept.
  port=$(sed -n 's/^Environment=TESSERA_PORT=\([0-9]*\)$/\1/p' /etc/aohp/system/tessera-agent.service 2>/dev/null | head -1)
  TESSERA_PORT=${port:-7377} sh "$d/agent/install.sh" >/dev/null
  log "agent updated to ${TESSERA_REF:0:7} (changed:$changed) and restarted; open Tessera sessions were ended"
else
  log "agent ${TESSERA_REF:0:7} present"
fi
echo "$TESSERA_REF" > /opt/tessera/.source-commit

# ---- the Droidspaces CLI ------------------------------------------------------------------------
# The phone image has the same binary, but on Android's side, where an env cannot run it.
if [ "$(uname -m)" != aarch64 ]; then
  log "droidspaces: the pinned binary is arm64, skipped on $(uname -m)"
elif [ "$(sha256sum /usr/local/bin/droidspaces 2>/dev/null | cut -d' ' -f1)" = "$DROIDSPACES_SHA256" ]; then
  log "droidspaces $DROIDSPACES_TAG present"
else
  curl -fsSL --retry 3 -o "$d/ds.tar.gz" "https://github.com/$DROIDSPACES_REPO/releases/download/$DROIDSPACES_TAG/$DROIDSPACES_ASSET"
  echo "$DROIDSPACES_ASSET_SHA256  $d/ds.tar.gz" | sha256sum -c - >/dev/null
  tar -xzf "$d/ds.tar.gz" -C "$d" "$DROIDSPACES_MEMBER"
  echo "$DROIDSPACES_SHA256  $d/$DROIDSPACES_MEMBER" | sha256sum -c - >/dev/null
  install -m 755 "$d/$DROIDSPACES_MEMBER" /usr/local/bin/droidspaces
  log "droidspaces $DROIDSPACES_TAG -> /usr/local/bin/droidspaces"
fi
