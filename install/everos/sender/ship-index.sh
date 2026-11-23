#!/bin/bash
# ship-index.sh [phone ssh name...]: run on the host that reaches both the writing EverOS server and the
# phones (docs/everos.md). Copies the server's index snapshot and the store commit it belongs to to each
# phone, so that a phone never embeds the store itself (that heated one to the external-display cut-off)
# and holds no credential for the server. Safe to run again: a phone that has the commit is skipped; one
# that cannot be reached gets it on a later run.
#   SERVER  ssh name of the writing host; it has <dir>/index-snapshot with STORE_COMMIT and SHA256SUMS
#   MIRROR  a local clone of the store that is at (or past) that commit
SERVER=${EVEROS_SERVER:-dyna}; SNAP=${EVEROS_SNAPSHOT:-everos/index-snapshot}
D=${EVEROS_SYNC_DIR:-$HOME/.openclaw/everos-sync}; MIRROR=${EVEROS_MIRROR:-$HOME/.openclaw/everos-mirror}
S=$D/index-snapshot
SSH="ssh -o BatchMode=yes -o ConnectTimeout=15"
[ $# -gt 0 ] || set -- oneplus13-wg
mkdir -p "$S" "$D/build"
rsync -a --delete --partial --timeout=120 -e "$SSH" "$SERVER:$SNAP/" "$S/" || { echo "cannot fetch the snapshot from $SERVER"; exit 1; }
want=$(cat "$S/STORE_COMMIT") || exit 1
( cd "$S" && sha256sum --quiet -c SHA256SUMS ) || { echo "snapshot here fails its checksums"; exit 1; }
git -C "$MIRROR" cat-file -e "$want^{commit}" 2>/dev/null || git -C "$MIRROR" pull -q --ff-only
git -C "$MIRROR" cat-file -e "$want^{commit}" 2>/dev/null || { echo "the store mirror does not have commit ${want:0:7}"; exit 1; }
rc=0
for h in "$@"; do
  have=$($SSH "$h" "test -d /root/everos/root/.git && { cat /root/everos/INDEX_STORE_COMMIT 2>/dev/null; echo; } || echo NOT-INSTALLED") || { echo "$h: unreachable, will get it on a later run"; rc=1; continue; }
  have=$(echo "$have" | head -n 1)
  if [ "$have" = NOT-INSTALLED ]; then echo "$h: EverOS is not set up there (aohp/everos in its config, then aohp-update)"; rc=1; continue; fi
  if [ "$have" = "$want" ]; then echo "$h: index already at ${want:0:7}"; continue; fi
  # the store commit, into a branch of its own; the phone merges it when it switches
  if ! GIT_SSH_COMMAND="$SSH" git -C "$MIRROR" push -q --force "$h:/root/everos/root" "$want:refs/heads/shipped" > "$D/build/push-$h.log" 2>&1; then
    echo "$h: store push failed: $(tail -1 "$D/build/push-$h.log")"; rc=1; continue
  fi
  # --copy-dest: files the phone already has in its live index are taken from there, so only the new
  # files cross the network.
  if ! rsync -az --delete --partial --timeout=120 --no-owner --no-group --stats -e "$SSH" \
       --copy-dest=/root/everos/root/.index "$S/" "$h:/root/everos/index-next/" > "$D/build/ship-$h.log" 2>&1; then
    echo "$h: copy failed: $(tail -1 "$D/build/ship-$h.log")"; rc=1; continue
  fi
  echo "$h: $(grep -E "^Total transferred file size|^Total bytes sent" "$D/build/ship-$h.log" | tr "\n" " ")"
  $SSH "$h" "bash /root/everos/apply-index.sh" || { echo "$h: apply failed"; rc=1; }
done
exit $rc
