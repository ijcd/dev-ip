#!/usr/bin/env bash
# Layer-3 acceptance — RUN INSIDE a fresh Apple-silicon macOS VM (e.g. a Tart
# clone), NOT in CI on this project. Verifies the real loopback+pf+resolver path.
set -euo pipefail
DEVIP="${DEVIP:-$(cd "$(dirname "$0")/../.." && pwd)/bin/dev-ip}"

echo "== 1. clean provision =="
sudo "$DEVIP" provision

echo "== 2. doctor (per-component report) =="
"$DEVIP" doctor | tee /tmp/dev-ip-doctor.txt
grep -q "all checks passed" /tmp/dev-ip-doctor.txt || { echo "FAIL: doctor checks failed"; exit 1; }

echo "== 3. real routing: alloc + bind + curl the hairpin =="
IP="$("$DEVIP" ip accept-test)"
python3 -m http.server 8080 --bind "$IP" &
SRV=$!; sleep 1
curl -fsS "http://accept-test.devip:8080/" >/dev/null && echo "  hairpin OK ($IP)"
kill "$SRV" 2>/dev/null || true
"$DEVIP" free accept-test

echo "== 4. idempotence: second provision makes no changes =="
sudo "$DEVIP" provision | tee /tmp/dev-ip-run2.txt
grep -Eq 'would:|write |bootstrap' /tmp/dev-ip-run2.txt && { echo "FAIL: run 2 mutated"; exit 1; } || echo "  idempotent OK"

echo "== 5. deprovision leaves no residue =="
sudo "$DEVIP" deprovision
test ! -f /etc/resolver/devip || { echo "FAIL: resolver residue"; exit 1; }
echo "  resolver gone OK"
echo "ACCEPTANCE PASSED"
