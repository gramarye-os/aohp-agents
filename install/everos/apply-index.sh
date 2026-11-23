#!/bin/bash
# /root/everos/apply-index.sh: switch this phone to the store commit and the index delivered by the
# sending host (docs/everos.md): the index waits in /root/everos/index-next, the commit was pushed
# into the store repo as branch "shipped". Nothing here uses the network. EverOS is down only for
# the switch, about 2 seconds.
# EverOS runs here with EVEROS_CASCADE__ENABLED=false (phone.env): it never indexes, it only
# searches the index it is given.
cd /root/everos || exit 1
exec 9> /root/everos/.apply.lock
flock -n 9 || { echo "another apply is running"; exit 0; }
log() { echo "$(date "+%F %T") $*" | tee -a /root/everos/apply.log; }
up() { systemctl start everos > /dev/null 2>&1; }
N=index-next
[ -f $N/STORE_COMMIT ] || { echo "no new index waiting"; exit 0; }
want=$(cat $N/STORE_COMMIT)
if [ "$want" = "$(cat INDEX_STORE_COMMIT 2>/dev/null)" ]; then rm -rf $N; echo "index already at ${want:0:7}"; exit 0; fi
( cd $N && sha256sum --quiet -c SHA256SUMS ) || { log "index-next is incomplete or damaged; waiting for the next copy"; exit 1; }
grep -q "^EVEROS_CASCADE__ENABLED=false" phone.env || log "warning: indexing is not switched off in phone.env"
git -C root cat-file -e "$want^{commit}" 2>/dev/null || { log "store commit ${want:0:7} was not delivered; not switching"; exit 1; }
first=; git -C root rev-parse -q --verify HEAD > /dev/null || first=1
if [ -z "$first" ]; then
  [ -z "$(git -C root status --porcelain)" ] || { log "store has local changes; not switching"; exit 1; }
  git -C root merge-base --is-ancestor HEAD "$want" || { log "store is not behind ${want:0:7}; not switching"; exit 1; }
fi
# from here EverOS is down
t0=$(date +%s%N)
systemctl stop everos > /dev/null 2>&1
if [ -n "$first" ]; then git -C root reset -q --hard "$want"; else git -C root merge -q --ff-only "$want"; fi
if [ "$(git -C root rev-parse HEAD 2>/dev/null)" != "$want" ]; then log "store update failed; starting with the old index"; up; exit 1; fi
rm -rf index.prev
if [ -d root/.index ]; then mv root/.index index.prev; fi
if ! mv $N root/.index; then log "index switch failed"; if [ ! -d root/.index ] && [ -d index.prev ]; then mv index.prev root/.index; fi; up; exit 1; fi
rm -f root/.index/STORE_COMMIT root/.index/SHA256SUMS
# recorded file times must match this checkout, or a server with indexing on would index everything again
EverOS/.venv/bin/python align-mtimes.py /root/everos/root > /root/everos/align.out 2>&1 || log "align-mtimes: $(tail -1 /root/everos/align.out)"
up
c=000; for i in $(seq 1 120); do c=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8014/health); [ "$c" = 200 ] && break; sleep 0.5; done
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
if [ "$c" != 200 ]; then
  log "EverOS did not come up on index ${want:0:7} (health $c)"
  if [ -d index.prev ]; then
    log "going back to the previous index"
    systemctl stop everos > /dev/null 2>&1; rm -rf index.bad; mv root/.index index.bad; mv index.prev root/.index; up
  fi
  exit 1
fi
echo "$want" > INDEX_STORE_COMMIT
log "index and store now at ${want:0:7}; EverOS was down ${ms} ms"
