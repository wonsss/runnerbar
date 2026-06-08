#!/usr/bin/env bash
set -euo pipefail

PROMPT_FILE="${1:-}"
OUT="${2:-ai-analysis.md}"
CONFIG="${RUNNERBAR_CONFIG:-$HOME/.runnerbar/config.json}"

if [ -z "$PROMPT_FILE" ] || [ ! -f "$PROMPT_FILE" ]; then
  echo "Usage: $0 <prompt-file> [output-file]" >&2
  exit 2
fi

providers="$(
  /usr/bin/python3 - "$CONFIG" <<'PY'
import json
import sys

config_path = sys.argv[1]
try:
    with open(config_path, "r", encoding="utf-8") as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}

order = config.get("aiProviderFallbackOrder") or []
default = config.get("defaultAIProvider") or "codex"
merged = []
for item in [default, *order, "codex", "claude"]:
    if item in ("codex", "claude") and item not in merged:
        merged.append(item)
print(" ".join(merged))
PY
)"

is_limit_error() {
  local file="$1"
  grep -Eiq 'rate.?limit|usage.?limit|quota|too many requests|exceeded|429|limit reached' "$file"
}

run_provider() {
  local provider="$1"
  local prompt
  prompt="$(cat "$PROMPT_FILE")"

  case "$provider" in
    codex)
      codex exec "$prompt"
      ;;
    claude)
      claude -p "$prompt" --max-turns 1
      ;;
    *)
      echo "Unsupported AI provider: $provider" >&2
      return 2
      ;;
  esac
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

for provider in $providers; do
  attempt="$tmp_dir/$provider.out"
  error="$tmp_dir/$provider.err"
  if run_provider "$provider" >"$attempt" 2>"$error"; then
    {
      echo "_AI provider: $provider_"
      echo
      cat "$attempt"
    } > "$OUT"
    exit 0
  fi

  if ! is_limit_error "$error" && ! is_limit_error "$attempt"; then
    {
      echo "_AI provider failed: $provider_"
      echo
      echo '```text'
      sed -n '1,80p' "$error"
      echo '```'
    } > "$OUT"
    exit 1
  fi
done

{
  echo "*AI analysis failed*"
  echo
  echo "All configured AI providers appear to be rate-limited or unavailable."
} > "$OUT"
exit 1
