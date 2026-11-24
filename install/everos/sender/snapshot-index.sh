#!/bin/bash
# ~/everos/snapshot-index.sh on the writing host: copy the index for the phones.
# Run after commit.sh. EverOS is stopped only for the local copy (under a second),
# so the copy is consistent. The result is ~/everos/index-snapshot with
#   STORE_COMMIT  the store commit this index belongs to
#   SHA256SUMS    of every index file, for the receiver to check
cd ~/everos || exit 1
head=$(git -C root rev-parse HEAD) || exit 1
if [ "$(cat index-snapshot/STORE_COMMIT 2>/dev/null)" = "$head" ] && [ -f index-snapshot/SHA256SUMS ]; then
  echo "index snapshot already at ${head:0:7}"; exit 0
fi
# ship-index.sh holds this lock while it sends the snapshot
exec 8> index-snapshot.lock; flock -w 3600 8 || { echo "the snapshot is still being sent"; exit 1; }
rm -rf index-snapshot.tmp
t0=$(date +%s.%N)
systemctl --user stop everos
dirty=$(git -C root status --porcelain | wc -l)
rc=1; [ "$dirty" = 0 ] && { cp -a root/.index index-snapshot.tmp; rc=$?; }
systemctl --user start everos
t1=$(date +%s.%N)
if [ "$dirty" != 0 ]; then echo "store has $dirty uncommitted changes, no snapshot"; rm -rf index-snapshot.tmp; exit 1; fi
if [ $rc != 0 ]; then echo "index copy failed rc=$rc"; rm -rf index-snapshot.tmp; exit 1; fi
echo "$head" > index-snapshot.tmp/STORE_COMMIT
( cd index-snapshot.tmp && find . -type f ! -name SHA256SUMS ! -name STORE_COMMIT -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS )
rm -rf index-snapshot.old
[ -d index-snapshot ] && mv index-snapshot index-snapshot.old
mv index-snapshot.tmp index-snapshot && rm -rf index-snapshot.old
# the first health request right after start is refused; poll, and do not stop on it
c=000; for i in $(seq 1 60); do c=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8014/health); [ "$c" = 200 ] && break; sleep 0.5; done
echo "index snapshot ${head:0:7}: $(du -sh index-snapshot | cut -f1), $(wc -l < index-snapshot/SHA256SUMS) files, everos down $(echo "$t1 - $t0" | bc) s, health $c"
[ "$c" = 200 ]
