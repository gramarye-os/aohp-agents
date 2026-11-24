#!/bin/bash
# EverOS on a phone: a local, read-only copy of a memory store that another host writes (docs/everos.md).
# Run by aohp-update. Does nothing unless the config carries ~/.openclaw/aohp/everos. Installs the EverOS
# code (same commit as the writing host), its Python environment, the embedding model and server unit,
# the EverOS unit and the script that takes a delivered index. The store itself and its index are not
# fetched here: the sending host delivers them (install/everos/sender/ship-index.sh).
set -euo pipefail; INSTALLER=everos; . "$(dirname "$0")/_lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
OC_DIR=${OPENCLAW_HOME:-$HOME/.openclaw}
[ -f "$OC_DIR/aohp/everos" ] || exit 0
[ -z "${AOHP_STAGE:-}${TESSERA_STAGE:-}" ] || exit 0   # template build: nothing to set up
[ "$(uname -m)" = aarch64 ] || { log "not arm64: skipped"; exit 0; }
. "$HERE/everos.pin"
E=/root/everos; SYS=/etc/aohp/system; MODELS=/opt/llm/models
mkdir -p "$E" "$MODELS" /usr/local/lib/aohp

# ---- tools the delivery needs ---------------------------------------------------------------------
if ! command -v rsync >/dev/null; then
  log "installing rsync"
  apt-get update -qq >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync >/dev/null 2>&1 || log "WARNING: rsync not installed; the index cannot be delivered"
fi

# ---- the code and its Python environment ----------------------------------------------------------
if [ "$(git -C "$E/EverOS" rev-parse HEAD 2>/dev/null)" != "$EVEROS_REF" ]; then
  log "EverOS ${EVEROS_REF:0:7}"
  [ -d "$E/EverOS/.git" ] || git clone -q "$EVEROS_REPO" "$E/EverOS"
  git -C "$E/EverOS" cat-file -e "$EVEROS_REF^{commit}" 2>/dev/null || git -C "$E/EverOS" fetch -q origin
  git -C "$E/EverOS" checkout -q --detach "$EVEROS_REF"
fi
if [ "$(cat "$E/EverOS/.venv/.aohp-ref" 2>/dev/null)" != "$EVEROS_REF" ]; then
  log "Python environment (about ten minutes the first time)"
  [ -x "$E/.uv/bin/uv" ] || { python3 -m venv "$E/.uv" && "$E/.uv/bin/pip" install -q uv; }
  ( cd "$E/EverOS" && "$E/.uv/bin/uv" sync --frozen --no-dev -q )
  [ -x "$E/EverOS/.venv/bin/everos" ] || { log "the environment has no everos command"; exit 1; }
  echo "$EVEROS_REF" > "$E/EverOS/.venv/.aohp-ref"
fi

# ---- the embedding model --------------------------------------------------------------------------
if [ "$(stat -c %s "$MODELS/$EMBED_FILE" 2>/dev/null)" != "$EMBED_BYTES" ]; then
  log "downloading $EMBED_FILE ($((EMBED_BYTES / 1048576)) MB)"
  if [ "$(stat -c %s "$MODELS/$EMBED_FILE.part" 2>/dev/null)" != "$EMBED_BYTES" ]; then
    curl -fL -C - --retry 3 -sS -o "$MODELS/$EMBED_FILE.part" "$EMBED_URL"
  fi
  [ "$(sha256sum "$MODELS/$EMBED_FILE.part" | cut -d' ' -f1)" = "$EMBED_SHA256" ] || { rm -f "$MODELS/$EMBED_FILE.part"; log "$EMBED_FILE: checksum does not match, file removed"; exit 1; }
  mv "$MODELS/$EMBED_FILE.part" "$MODELS/$EMBED_FILE"
fi

# ---- the token-counting encoding ------------------------------------------------------------------
# EverOS loads tiktoken's o200k_base at every start and otherwise downloads it into /tmp. With a copy
# kept here (phone.env points TIKTOKEN_CACHE_DIR at it) it starts without the network.
T="$E/tiktoken-cache/$TIKTOKEN_FILE"
if [ "$(sha256sum "$T" 2>/dev/null | cut -d' ' -f1)" != "$TIKTOKEN_SHA256" ]; then
  mkdir -p "$E/tiktoken-cache"
  cp "/tmp/data-gym-cache/$TIKTOKEN_FILE" "$T.part" 2>/dev/null || curl -fL --retry 3 -sS -o "$T.part" "$TIKTOKEN_URL" || true
  if [ "$(sha256sum "$T.part" 2>/dev/null | cut -d' ' -f1)" = "$TIKTOKEN_SHA256" ]; then
    mv "$T.part" "$T"; log "token-counting encoding stored"
  else
    rm -f "$T.part"; log "WARNING: token-counting encoding not stored; EverOS will need the network when it starts"
  fi
fi

# ---- scripts, settings, the place the store is delivered to ---------------------------------------
install -m 755 "$HERE/everos/llama-run.sh" /usr/local/lib/aohp/llama-run.sh
install -m 755 "$HERE/everos/apply-index.sh" "$E/apply-index.sh"
install -m 644 "$HERE/everos/align-mtimes.py" "$E/align-mtimes.py"
[ -f "$E/phone.env" ] || install -m 644 "$HERE/everos/phone.env" "$E/phone.env"   # yours to edit afterwards
grep -q '^TIKTOKEN_CACHE_DIR=' "$E/phone.env" || echo "TIKTOKEN_CACHE_DIR=$E/tiktoken-cache" >> "$E/phone.env"
[ -d "$E/root/.git" ] || git init -q -b main "$E/root"

# ---- units ----------------------------------------------------------------------------------------
changed=
for n in everos-embed.service everos.service; do
  if [ -e "$SYS/$n.local" ]; then log "$n: kept local copy"; continue; fi
  cmp -s "$HERE/everos/$n" "$SYS/$n" || { install -D -m 644 "$HERE/everos/$n" "$SYS/$n"; changed=1; log "$n installed"; }
done
[ -z "$changed" ] || systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable everos-embed everos >/dev/null 2>&1 || true
if [ ! -f /etc/aohp/llm.json ]; then
  log "the embedding server needs the Driver's llama-server staged: run aohp-llm setup, then aohp-update again"
else
  curl -fsS -m 3 http://127.0.0.1:8025/health >/dev/null 2>&1 || systemctl start everos-embed >/dev/null 2>&1 || log "WARNING: everos-embed did not start (journalctl -u everos-embed)"
fi
if [ -f "$E/root/everos.toml" ]; then
  curl -fsS -m 3 http://127.0.0.1:8014/health >/dev/null 2>&1 || systemctl start everos >/dev/null 2>&1 || log "WARNING: everos did not start (journalctl -u everos)"
  log "store at $(git -C "$E/root" log -1 --format='%h %s' 2>/dev/null | cut -c1-60), index $(cut -c1-7 "$E/INDEX_STORE_COMMIT" 2>/dev/null || echo none)"
else
  log "ready; waiting for the first delivery of the store and its index"
fi
