#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$root/scripts/check-foundation.py" "$root/docs"
python3 "$root/scripts/check-public.py" "$root"
python3 "$root/scripts/check-tooling.py" "$root"
sh "$root/scripts/check-app.sh"
echo 'PASS: foundation documents and tooling'
echo 'PASS: application build/tests'
