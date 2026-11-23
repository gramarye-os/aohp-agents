#!/bin/bash
# The local model of an env (docs/llm.md). Run by aohp-update. Does nothing unless the config carries
# ~/.openclaw/aohp/llm (written by `aohp-llm setup`): then the model file, the Driver's llama-server
# unit and the gateway's "local" provider are put back when one of them is missing, as after a wipe.
set -euo pipefail; INSTALLER=llm; . "$(dirname "$0")/_lib.sh"
CONF=${OPENCLAW_HOME:-$HOME/.openclaw}/aohp/llm
[ -f "$CONF" ] || exit 0
[ -z "${AOHP_STAGE:-}${TESSERA_STAGE:-}" ] || exit 0   # template build: there is no Driver to talk to
command -v aohp >/dev/null || { log "no aohp CLI here: skipped"; exit 0; }
log "$(grep -vE '^\s*(#|$)' "$CONF" | head -n 1)"
/usr/local/bin/aohp-llm apply
