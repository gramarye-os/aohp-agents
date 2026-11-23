#!/bin/bash
# Build an AOHP agent-container rootfs template with rootless podman.
#   usage: template/build-template.sh <debian|fedora|arch> <arm64|amd64>
#          VARIANT=gpu template/build-template.sh debian arm64     (graphics stack + kgsl Mesa, see README)
#   output: template/dist/<distro>[-<variant>]-<arch>.tar.gz (+ .txt build info), SHA256SUMS updated
# Env overrides: NODE_VERSION, OPENCLAW_VERSION, AOHP_AGENTS_REF (branch/tag of this repo cloned into the image),
#   AOHP_AGENTS_REPO, AOHP_REF / AOHP_REPO (aohp CLI + skills source), ARCH_ARM64_IMAGE (Arch Linux ARM base),
#   ARCH_AMD64_IMAGE, FEDORA_IMAGE, DIST (output dir), KEEP_IMAGE=1 (do not rmi the built image).
#
# Constraints from aohp-containerd's tar extractor (AOSP system/core/aohp-containerd/tar_gz_extract.cpp):
#   - handles regular files, dirs, symlinks, GNU long names; SKIPS hardlinks and device nodes  -> tar --hard-dereference,
#     and dev/ proc/ sys/ run/ are shipped empty (containerd mounts them)
#   - inflates the whole tarball into memory on the device                                   -> keep the rootfs lean
#   - no chown (everything ends up root-owned); containerd has no user namespace             -> --numeric-owner, owner 0
# arm64 builds run under qemu-user-static binfmt (npm install of OpenClaw takes several minutes there).
set -euo pipefail
DISTRO=${1:?distro (debian|fedora|arch)}
ARCH=${2:?arch (arm64|amd64)}
HERE=$(cd "$(dirname "$0")" && pwd)
DIST=${DIST:-$HERE/dist}
NODE_VERSION=${NODE_VERSION:-v24.21.0}
OPENCLAW_VERSION=${OPENCLAW_VERSION:-2026.10.33}
AOHP_AGENTS_REF=${AOHP_AGENTS_REF:-main}
AOHP_AGENTS_REPO=${AOHP_AGENTS_REPO:-https://github.com/gramarye-os/aohp-agents.git}
AOHP_REF=${AOHP_REF:-feat/units}
AOHP_REPO=${AOHP_REPO:-https://github.com/gramarye-os/aohp.git}
ARCH_ARM64_IMAGE=${ARCH_ARM64_IMAGE:-docker.io/menci/archlinuxarm:base-devel}
ARCH_AMD64_IMAGE=${ARCH_AMD64_IMAGE:-docker.io/library/archlinux:base-devel}
FEDORA_IMAGE=${FEDORA_IMAGE:-registry.fedoraproject.org/fedora:44}
# Tessera: the agent files come from the commit pinned in install/tessera.pin (with the Droidspaces CLI);
# the GPU variant also unpacks this Mesa.
TESSERA_REF=${TESSERA_REF:-$(sed -n 's/^TESSERA_REF=//p' "$HERE/../install/tessera.pin")}
MESA_URL=${MESA_URL:-https://github.com/gramarye-os/tessera-linux/releases/download/v0.7.0-gramarye.1/mesa-kgsl_27.0.0-devel-g6939216a65_debian_trixie_arm64.tar.gz}
MESA_SHA256=${MESA_SHA256:-8a294f395e48ccca6c12f0fe4f12c9dfaed74fbb7cb4bab99d2473fe90be8bc3}
VARIANT=${VARIANT:-}
case $DISTRO in debian|fedora|arch) ;; *) echo "unknown distro $DISTRO" >&2; exit 2;; esac
case $ARCH in arm64|amd64) ;; *) echo "unknown arch $ARCH" >&2; exit 2;; esac
case $VARIANT in
  '') ;;
  gpu) [ "$DISTRO-$ARCH" = debian-arm64 ] || { echo "VARIANT=gpu is for debian arm64 only" >&2; exit 2; } ;;
  *) echo "unknown variant $VARIANT" >&2; exit 2;;
esac
NAME=$DISTRO${VARIANT:+-$VARIANT}
PLATFORM=linux/$ARCH
BUILDPLATFORM=linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
TAG=localhost/aohp-template-$NAME:$ARCH
CLI_TAG=localhost/aohp-cli:$(echo "$AOHP_REF" | tr '/' '-')
OUT=$DIST/$NAME-$ARCH.tar.gz
log(){ echo "[$(date +%T)] $*"; }
T0=$(date +%s)
mkdir -p "$DIST"

log "aohp CLI builder image $CLI_TAG ($AOHP_REPO @ $AOHP_REF)"
podman build --platform "$BUILDPLATFORM" -t "$CLI_TAG" -f "$HERE/aohp-cli.Dockerfile" \
  --build-arg AOHP_REPO="$AOHP_REPO" --build-arg AOHP_REF="$AOHP_REF" "$HERE" > "$DIST/aohp-cli.build.log" 2>&1 || { tail -30 "$DIST/aohp-cli.build.log"; exit 1; }

extra=()
case $DISTRO in
  arch)   if [ "$ARCH" = arm64 ]; then extra+=(--build-arg ARCH_IMAGE="$ARCH_ARM64_IMAGE"); else extra+=(--build-arg ARCH_IMAGE="$ARCH_AMD64_IMAGE"); fi ;;
  fedora) extra+=(--build-arg FEDORA_IMAGE="$FEDORA_IMAGE") ;;
  debian) extra+=(--build-arg TESSERA_REF="$TESSERA_REF")
          [ "$VARIANT" != gpu ] || extra+=(--build-arg GPU=1 --build-arg MESA_URL="$MESA_URL" --build-arg MESA_SHA256="$MESA_SHA256") ;;
esac
log "podman build $TAG for $PLATFORM"
podman build --platform "$PLATFORM" -t "$TAG" -f "$HERE/$DISTRO/Dockerfile" \
  --build-arg BUILDPLATFORM="$BUILDPLATFORM" --build-arg AOHP_CLI_IMAGE="$CLI_TAG" \
  --build-arg NODE_VERSION="$NODE_VERSION" --build-arg OPENCLAW_VERSION="$OPENCLAW_VERSION" \
  --build-arg AOHP_AGENTS_REPO="$AOHP_AGENTS_REPO" --build-arg AOHP_AGENTS_REF="$AOHP_AGENTS_REF" \
  "${extra[@]}" "$HERE"
T1=$(date +%s)
log "image built in $((T1-T0)) s"

# Export: mount the image's rootfs inside the rootless user namespace (uid 0 there == container root) and tar straight
# from it (the container layer is writable: resolv.conf/hostname are injected there first). Hard links are dereferenced,
# dev/proc/sys/run are emptied, sockets/fifos dropped, owner forced to 0:0.
CID=$(podman create --platform "$PLATFORM" "$TAG" /bin/true)
trap 'podman rm -f "$CID" >/dev/null 2>&1 || true' EXIT
log "export $CID -> $OUT"
podman unshare bash -c '
  set -euo pipefail
  CID=$1; OUT=$2; INFO=$3
  M=$(podman mount "$CID")
  cd "$M"
  # DNS for the chroot on the device (containerd does not write one; podman bind-mounts resolv.conf during build, so
  # it cannot be set from the Dockerfile). Also the hostname, in case the base image mounted that too.
  rm -f etc/resolv.conf; printf "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" > etc/resolv.conf; chmod 644 etc/resolv.conf
  [ -L etc/hostname ] && rm -f etc/hostname; echo aohp-dev > etc/hostname
  HL=$(find . -xdev -type f -links +1 | wc -l)
  SPECIAL=$(find . -xdev \( -type b -o -type c -o -type p -o -type s \) | wc -l)
  DU=$(du -sm . | cut -f1)
  echo "uncompressed_mb=$DU hardlinked_files=$HL special_files=$SPECIAL" > "$INFO"
  echo "[export] uncompressed $DU MB, $HL hardlinked files (dereferenced), $SPECIAL special files (dropped)"
  tar --format=gnu --hard-dereference --numeric-owner --owner=0 --group=0 \
      --exclude=./dev/* --exclude=./proc/* --exclude=./sys/* --exclude=./run/* \
      -czf "$OUT" . 2> >(grep -v "socket ignored" >&2 || true)
  cd /; podman umount "$CID" >/dev/null
' _ "$CID" "$OUT" "$OUT.info"
podman rm -f "$CID" >/dev/null; trap - EXIT
T2=$(date +%s)

# Sanity: the tar must contain only regular files, dirs and symlinks — no hardlinks (h) or devices (b/c) or fifos (p).
BAD=$(tar -tvzf "$OUT" | awk '{t=substr($1,1,1); if (t!="-" && t!="d" && t!="l") print}' | head -5)
[ -z "$BAD" ] || { echo "non-regular entries in $OUT:"; echo "$BAD"; exit 1; }
SIZE=$(stat -c %s "$OUT")
SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
VERS=$(podman run --rm --platform "$PLATFORM" "$TAG" bash -c '. /etc/os-release; echo "$PRETTY_NAME | glibc $(ldd --version | head -1 | grep -oE "[0-9]+\.[0-9]+$") | $(gcc --version | head -1) | node $(node -v) | $(python3 -V) | openclaw $(NODE_OPTIONS=--jitless openclaw --version 2>/dev/null | tail -1) | libc $(readelf -n $(ldd /bin/sh | grep -oE "/[^ ]*libc.so.6") | grep -oE "OS: Linux, ABI: [0-9.]+" || true)"' 2>/dev/null || echo "?")
{
  echo "distro=$DISTRO arch=$ARCH platform=$PLATFORM${VARIANT:+ variant=$VARIANT}"
  echo "built=$(date -Is) build_s=$((T1-T0)) export_s=$((T2-T1)) total_s=$((T2-T0))"
  echo "compressed_bytes=$SIZE sha256=$SHA"
  cat "$OUT.info"
  echo "versions=$VERS"
  echo "node=$NODE_VERSION openclaw=$OPENCLAW_VERSION aohp_agents_ref=$AOHP_AGENTS_REF aohp_ref=$AOHP_REF"
  [ "$DISTRO" != debian ] || echo "tessera_ref=$TESSERA_REF${VARIANT:+ mesa_sha256=$MESA_SHA256}"
} > "$DIST/$NAME-$ARCH.txt"
rm -f "$OUT.info"
( cd "$DIST" && { [ -f SHA256SUMS ] && grep -v " $NAME-$ARCH.tar.gz$" SHA256SUMS || true; echo "$SHA  $NAME-$ARCH.tar.gz"; } | sort -k2 > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS )
[ "${KEEP_IMAGE:-0}" = 1 ] || podman rmi -f "$TAG" >/dev/null 2>&1 || true
log "done: $OUT $(( SIZE / 1048576 )) MB compressed, sha256 $SHA"
cat "$DIST/$NAME-$ARCH.txt"
log "TEMPLATE-BUILD-DONE $NAME $ARCH rc=0"
