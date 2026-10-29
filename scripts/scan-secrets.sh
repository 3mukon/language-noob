#!/bin/bash
set -euo pipefail
script_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:?Expected staged, history, stdin or availability}
repo=${2:-.}
if ! command -v gitleaks >/dev/null 2>&1; then
  echo 'SECRET_SCAN: scanner missing; install Gitleaks 8.30.1 and rerun guardrail acceptance.' >&2
  exit 1
fi
if [[ "$mode" == availability ]]; then exit 0; fi
report=$(mktemp 2>/dev/null || mktemp /tmp/language-noob-scan.XXXXXX)
trap 'rm -f "$report"' EXIT
args=(--config "$script_root/.gitleaks.toml" --gitleaks-ignore-path /dev/null --ignore-gitleaks-allow --redact --no-banner --log-level error --report-format template --report-template "$script_root/scripts/scanner-report.tmpl" --report-path "$report")
status=0
case "$mode" in
  staged) gitleaks git "$repo" --pre-commit --staged "${args[@]}" >/dev/null 2>&1 || status=$? ;;
  history) gitleaks git "$repo" --log-opts="${3:---all}" "${args[@]}" >/dev/null 2>&1 || status=$? ;;
  stdin) gitleaks stdin "${args[@]}" >/dev/null 2>&1 || status=$? ;;
  *) echo 'SECRET_SCAN: unsupported scan mode' >&2; exit 1 ;;
esac
if (( status != 0 )); then
  if [[ -s "$report" && "$status" == 1 ]]; then cat "$report" >&2; fi
  echo "SECRET_SCAN: $mode blocked (sensitive values and names withheld); repair content or scanner before retrying." >&2
  exit 1
fi
