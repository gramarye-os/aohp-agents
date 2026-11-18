#!/bin/sh
# Tessera layer of a template: the agent that Tessera (the Android launcher for Linux apps) talks to,
# and for the GPU variant the graphics libraries plus a Mesa built for Adreno GPUs through Android's
# kgsl device. Run after agent-layer.sh, before cleanup.sh.
#   TESSERA_REF      commit of TESSERA_REPO the agent files are taken from (required)
#   GPU=1            also install the graphics stack and the Mesa tarball (Debian arm64 only)
#   MESA_URL, MESA_SHA256   the Mesa tarball and its pin (required with GPU=1)
# The agent's token is NOT made here: it must differ per phone. The agent's unit makes it on first
# start (setup.sh in the Tessera repository).
set -eu
TESSERA_REPO=${TESSERA_REPO:-gramarye-os/tessera-linux}
TESSERA_REF=${TESSERA_REF:?commit of $TESSERA_REPO}
GPU=${GPU:-0}

d=$(mktemp -d)
for f in agent.py enter.sh setup.sh v4l_links.py install.sh tessera-agent.service; do
  curl -fsSL --retry 3 -o "$d/$f" "https://raw.githubusercontent.com/$TESSERA_REPO/$TESSERA_REF/gramarye/$f"
done
TESSERA_STAGE=1 sh "$d/install.sh"
echo "$TESSERA_REF" > /opt/tessera/.source-commit
rm -rf "$d"
test -L /etc/aohp/system/aohp.target.wants/tessera-agent.service
test ! -e /etc/tessera/token
python3 -m py_compile /opt/tessera/agent.py

[ "$GPU" = 1 ] || { echo "[tessera] agent staged ($TESSERA_REF), no graphics stack"; exit 0; }

MESA_URL=${MESA_URL:?Mesa tarball URL}
MESA_SHA256=${MESA_SHA256:?Mesa tarball sha256}
command -v apt-get >/dev/null || { echo "GPU=1 is for the Debian template only" >&2; exit 1; }
[ "$(dpkg --print-architecture)" = arm64 ] || { echo "the Mesa tarball is arm64 only" >&2; exit 1; }
# Debian's own Mesa brings every library ours links against; ours is then unpacked over it.
# mesa-vulkan-drivers is left out on purpose: the tarball has the one Vulkan driver a phone can use.
apt-get update
apt-get install -y --no-install-recommends \
  libgl1 libglx-mesa0 libgl1-mesa-dri libegl1 libegl-mesa0 libgles2 libgbm1 libvulkan1 \
  xauth x11-utils x11-xserver-utils x11-xkb-utils xterm dbus-x11 fonts-dejavu-core mesa-utils vulkan-tools \
  matchbox-window-manager python3-xlib xsettingsd at-spi2-core python3-pyatspi pulseaudio
# The last line is what Tessera starts with every X app when it finds it: matchbox keeps the one app
# full screen (without it a window opens at its own size in a corner), python3-xlib is its window
# list, xsettingsd its theme, at-spi its text input, pulseaudio its sound (without it apps are
# silent). Tessera does not install these in a gramarye env.
apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
curl -fL --retry 3 -o /tmp/mesa.tar.gz "$MESA_URL"
echo "$MESA_SHA256  /tmp/mesa.tar.gz" | sha256sum -c -
tar xzf /tmp/mesa.tar.gz -C /
rm -f /tmp/mesa.tar.gz
ldconfig
# An apt upgrade of these would put Debian's files back over ours.
apt-mark hold libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgbm1 mesa-libgallium >/dev/null
# Chromium, when the user installs it (Debian's wrapper reads /etc/chromium.d/*), draws through
# Vulkan. Through its OpenGL path on Tessera's X server, Chromium 150+ leaves every fullscreen
# (a video's, a page's) by itself 1.5 s after entering it; through ANGLE's Vulkan backend on
# Turnip it does not, and compositing stays on the GPU.
mkdir -p /etc/chromium.d
cat > /etc/chromium.d/gramarye-vulkan <<'EOF'
# Gramarye env: draw through Vulkan (Turnip) instead of OpenGL, or fullscreen drops out after 1.5 s.
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --use-angle=vulkan"
EOF
test -s /usr/share/tessera/mesa
L=/usr/lib/aarch64-linux-gnu
for so in $L/libvulkan_freedreno.so $L/libGLX_mesa.so.0 $L/libEGL_mesa.so.0 $L/libgbm.so.1 $L/dri/libdril_dri.so; do
  if ldd "$so" | grep -q "not found"; then echo "missing libraries for $so:" >&2; ldd "$so" | grep "not found" >&2; exit 1; fi
done
grep -q /dev/kgsl-3d0 $L/libvulkan_freedreno.so
echo "[tessera] agent staged ($TESSERA_REF), Mesa $(tr '\n' ' ' < /usr/share/tessera/mesa)"
