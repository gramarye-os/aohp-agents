#!/bin/bash
# ship-index.sh [phone ssh name...]: deliver the EverOS store and its index to the phones (docs/everos.md).
# Runs on the writing host itself, or on any host that reaches both it and the phones. For each phone the
# store commit and the writing host's index snapshot are copied over and the phone switches to them, so
# a phone never embeds the store itself (that heated one to the external-display cut-off) and holds no
# credential for the writing host. Safe to run again: a phone that has the commit is skipped; one that
# cannot be reached gets it on a later run.
# Settings come from the environment, or from ship.conf beside this script (see ship.conf.example):
#   EVEROS_SERVER    "local" on the writing host, else its ssh name
#   EVEROS_SNAPSHOT  the snapshot folder on the writing host (snapshot-index.sh makes it)
#   EVEROS_STORE     the store repo here: the store itself on the writing host, else a clone of it
#   EVEROS_SHIP_DIR  folder for the logs and, away from the writing host, the copy of the snapshot
#   EVEROS_PHONES    ssh names of the phones, used when none are given as arguments
#   EVEROS_SHIP_KEY  private key file the phones accept; empty: whatever ssh uses by default
# Exit status: 0 every phone has the index, 2 a phone could not be reached, 1 anything else.
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$here/ship.conf" ] && . "$here/ship.conf"
SERVER=${EVEROS_SERVER:-dyna}
D=${EVEROS_SHIP_DIR:-$HOME/.openclaw/everos-sync}; STORE=${EVEROS_STORE:-$HOME/.openclaw/everos-mirror}
SSH_SERVER="ssh -o BatchMode=yes -o ConnectTimeout=15"
SSH=$SSH_SERVER
if [ -n "$EVEROS_SHIP_KEY" ]; then
  [ -r "$EVEROS_SHIP_KEY" ] || { echo "cannot read the key file $EVEROS_SHIP_KEY"; exit 1; }
  SSH="$SSH -i $EVEROS_SHIP_KEY -o IdentitiesOnly=yes"
fi
[ $# -gt 0 ] || set -- ${EVEROS_PHONES:-oneplus13-wg}
mkdir -p "$D/build"
if [ "$SERVER" = local ]; then
  S=${EVEROS_SNAPSHOT:-$HOME/everos/index-snapshot}
  # snapshot-index.sh takes the same lock, so the snapshot is not replaced while it is being sent
  exec 8> "$S.lock"; flock -w 3600 8 || { echo "the snapshot is still locked"; exit 1; }
else
  S=$D/index-snapshot; mkdir -p "$S"
  rsync -a --delete --partial --timeout=120 -e "$SSH_SERVER" "$SERVER:${EVEROS_SNAPSHOT:-everos/index-snapshot}/" "$S/" || { echo "cannot fetch the snapshot from $SERVER"; exit 1; }
fi
want=$(cat "$S/STORE_COMMIT" 2>/dev/null); [ -n "$want" ] || { echo "no index snapshot in $S"; exit 1; }
( cd "$S" && sha256sum --quiet -c SHA256SUMS ) || { echo "snapshot here fails its checksums"; exit 1; }
if [ "$SERVER" != local ]; then git -C "$STORE" cat-file -e "$want^{commit}" 2>/dev/null || git -C "$STORE" pull -q --ff-only; fi
git -C "$STORE" cat-file -e "$want^{commit}" 2>/dev/null || { echo "the store in $STORE does not have commit ${want:0:7}"; exit 1; }
rc=0
for h in "$@"; do
  have=$($SSH "$h" "test -d /root/everos/root/.git && { cat /root/everos/INDEX_STORE_COMMIT 2>/dev/null; echo; } || echo NOT-INSTALLED") || { echo "$h: cannot log in, will get it on a later run"; [ $rc = 0 ] && rc=2; continue; }
  have=$(echo "$have" | head -n 1)
  if [ "$have" = NOT-INSTALLED ]; then echo "$h: EverOS is not set up there (aohp/everos in its config, then aohp-update)"; rc=1; continue; fi
  if [ "$have" = "$want" ]; then echo "$h: index already at ${want:0:7}"; continue; fi
  # the store commit, into a branch of its own; the phone merges it when it switches
  if ! GIT_SSH_COMMAND="$SSH" git -C "$STORE" push -q --force "$h:/root/everos/root" "$want:refs/heads/shipped" > "$D/build/push-$h.log" 2>&1; then
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
