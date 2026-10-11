#!/usr/bin/env bash
# add-runner.sh — interactive wrapper around register-repo-runner.sh.
#
#   scripts/add-runner.sh                 # fully interactive
#   scripts/add-runner.sh --repo o/n -y   # flags preset defaults, -y skips confirm
#   (run inside a git checkout: repo defaults to its GitHub remote)
#
# Registering for a NEW repository = run this inside that repo's checkout,
# press Enter through the defaults, done. Extra flags are passed straight
# through to register-repo-runner.sh for non-interactive use.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTER="$ROOT/scripts/register-repo-runner.sh"
die() { echo "error: $*" >&2; exit 1; }
[ -x "$REGISTER" ] || die "register-repo-runner.sh not found at $REGISTER"
command -v gh >/dev/null || die "gh CLI required"
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run gh auth login"

REPO="" LABELS="" REPLICAS="" MODE="" DIR="" ASSUME_YES=""
PASSTHRU=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="${2:?}"; shift 2 ;;
    --labels)   LABELS="${2:?}"; shift 2 ;;
    --replicas) REPLICAS="${2:?}"; shift 2 ;;
    --mode)     MODE="${2:?}"; shift 2 ;;
    --dir)      DIR="${2:?}"; shift 2 ;;
    -y|--yes)   ASSUME_YES=1; shift ;;
    -h|--help)  sed -n '2,10p' "$0"; exit 0 ;;
    *)          PASSTHRU+=("$1"); shift ;;
  esac
done

prompt() { # prompt <var> <question> <default>
  local var="$1" q="$2" def="$3" input=""
  if [ -t 0 ]; then
    if [ -n "$def" ]; then
      printf "%s [%s]: " "$q" "$def" >&2
    else
      printf "%s: " "$q" >&2
    fi
    read -r input || true
  fi
  printf -v "$var" '%s' "${input:-$def}"
}

# Infer repo from the git remote of the current directory when possible.
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
prompt REPO "Repository (owner/name)" "$REPO"
case "$REPO" in */*) ;; *) die "--repo must be owner/name" ;; esac
REPO_NAME="${REPO##*/}"

prompt LABELS "Runner labels (comma-separated)" "${LABELS:-${REPO_NAME}-runner}"
prompt REPLICAS "Parallel replicas" "${REPLICAS:-3}"
prompt MODE "Mode (service=launchd background / gui=RunnerBar child, for Simulator jobs)" "${MODE:-service}"
prompt DIR "Runner base directory" "${DIR:-$HOME/actions-runners/$REPO_NAME}"

cat >&2 <<EOF

==> $REPO
    replicas : $REPLICAS
    labels   : $LABELS
    mode     : $MODE
    dir      : $DIR
EOF

if [ -z "$ASSUME_YES" ] && [ -t 0 ]; then
  printf "Proceed? [Y/n]: " >&2
  read -r confirm || true
  case "${confirm:-y}" in y|Y|"") ;; *) echo "aborted" >&2; exit 1 ;; esac
fi

exec "$REGISTER" \
  --repo "$REPO" \
  --labels "$LABELS" \
  --replicas "$REPLICAS" \
  --mode "$MODE" \
  --dir "$DIR" \
  ${PASSTHRU[@]+"${PASSTHRU[@]}"}
