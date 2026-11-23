#!/system/bin/sh
# Android-side helper (units with HostExec=yes): run the Driver's llama-server with the given arguments
# from where the Driver staged it for this env. The place differs per phone and Driver install; the Driver
# writes it to /etc/aohp/llm.json when the local model is configured (aohp-llm setup).
R=${AOHP_ROOTFS:?AOHP_ROOTFS is not set}
J=$R/etc/aohp/llm.json
[ -f "$J" ] || { echo "no /etc/aohp/llm.json: set up the local model first (aohp-llm setup), that stages llama-server"; exit 1; }
S=$(sed -n 's/.*"stageDir"[^"]*"\([^"]*\)".*/\1/p' "$J" | sed 's#\\/#/#g' | head -n 1)
[ -n "$S" ] && [ -x "$S/libllama-server.so" ] || { echo "llama-server is not staged in '$S' (systemctl start llama-server once)"; exit 1; }
export LD_LIBRARY_PATH=$S
exec "$S/libllama-server.so" "$@"
