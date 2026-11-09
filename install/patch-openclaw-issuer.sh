#!/bin/bash
# patch-openclaw-issuer.sh — bind QR/device-key browser pairings to the shared-auth generation.
# Upstream fix: https://github.com/openclaw/openclaw/pull/195660 (drop this once a release contains it).
# Without it a Control UI paired through the Driver's QR (or a device-key pairing approved on the
# gateway) gets a token with no issuer, which the gateway refuses as legacy-browser-token on the first
# reconnect after a restart: the browser loses its pairing every time the gateway restarts.
# Idempotent; keeps <file>.aohp-orig2. Proven on the Pixel 6, 2026.11.2, 2026-11-08.
set -uo pipefail
D=${1:-/usr/local/lib/node_modules/openclaw/dist}
[ -d "$D" ] || { echo "patch-openclaw-issuer: no dist at $D" >&2; exit 1; }
python3 - "$D" <<'PY'
import re,glob,sys
D=sys.argv[1]; changed=0; seen=0
for f in glob.glob(D+"/**/*.mjs", recursive=True):
    s=open(f).read()
    if "issueGatewayConnectDeviceTokens(params)" not in s: continue
    seen+=1
    if "issuerGeneration" in s and "requiredSharedGatewaySessionGeneration: context" in s: continue
    old_re = re.compile(r'const sharedGatewayAuthIssuer = sessionSharedGatewaySessionGeneration && \(deviceTokenSharedGatewaySessionGeneration !== void 0 \|\| sessionUsesSharedGatewayAuth && \(isBrowserOperatorUi \|\| isWebchat\)\) \? \{\s*kind: "shared-gateway-auth",\s*generation: sessionSharedGatewaySessionGeneration\s*\} : void 0;')
    new = ('const isBrowserRelated = isBrowserOperatorUi || isWebchat;\n'
           '\tconst sessionBoundGeneration = sessionSharedGatewaySessionGeneration && (deviceTokenSharedGatewaySessionGeneration !== void 0 || sessionUsesSharedGatewayAuth && isBrowserRelated) ? sessionSharedGatewaySessionGeneration : void 0;\n'
           '\tconst issuerGeneration = sessionBoundGeneration ?? (isBrowserRelated ? params.requiredSharedGatewaySessionGeneration : void 0);\n'
           '\tconst sharedGatewayAuthIssuer = issuerGeneration ? { kind: "shared-gateway-auth", generation: issuerGeneration } : void 0;')
    s2,n1 = old_re.subn(new, s)
    call_re = re.compile(r'(await issueGatewayConnectDeviceTokens\(\{\s*state: \{[\s\S]*?\},\s*scopes,\s*hasApprovedDeviceBaseline: hasServerApprovedDeviceTokenBaseline,\s*isIssuanceCurrent: isConnectAuthorizationCurrent)(\s*\}\))')
    s3,n2 = call_re.subn(r'\1,\n\t\trequiredSharedGatewaySessionGeneration: context.handler.getRequiredSharedGatewaySessionGeneration?.()\2', s2)
    if n1 and n2:
        open(f+".aohp-orig2","w").write(s); open(f,"w").write(s3); changed+=1
    else:
        print("patch-openclaw-issuer: pattern not found in", f.split("/dist/")[1], "(upstream changed? check PR 195660)", file=sys.stderr)
print("patch-openclaw-issuer: patched %d of %d candidate file(s) under %s" % (changed, seen, D))
PY
