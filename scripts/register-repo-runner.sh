#!/usr/bin/env bash
# register-repo-runner.sh — headless equivalent of RunnerBar's
# "Register New GitHub Runner..." dialog, for onboarding another repository
# without clicking through the app.
#
#   scripts/register-repo-runner.sh --repo owner/name [options]
#
# Options:
#   --name NAME        Base runner name          (default: <repo>-runner)
#   --labels CSV       Extra labels              (default: <repo>-runner)
#   --dir PATH         Base runner directory     (default: ~/actions-runners/<repo>)
#   --replicas N       Parallel instances        (default: 1)
#   --mode MODE        service | gui             (default: service)
#
# service mode installs per-instance LaunchAgents via svc.sh; gui mode only
# configures the runners — RunnerBar itself spawns ./run.sh as its child
# (required for jobs that drive the iOS Simulator).
#
# Each instance also gets an .env file pinning a usable PATH — LaunchAgent
# sessions start with launchd's minimal PATH (/usr/bin:/bin:...) so steps
# cannot find Homebrew tools (gh, rg, ...) without it.

set -euo pipefail

REPO=""
NAME=""
LABELS=""
BASE_DIR=""
REPLICAS=1
MODE="service"
CONFIG_PATH="${RUNNERBAR_CONFIG:-$HOME/.runnerbar/config.json}"

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="${2:?--repo needs owner/name}"; shift 2 ;;
    --name)     NAME="${2:?--name needs a value}"; shift 2 ;;
    --labels)   LABELS="${2:?--labels needs a value}"; shift 2 ;;
    --dir)      BASE_DIR="${2:?--dir needs a path}"; shift 2 ;;
    --replicas) REPLICAS="${2:?--replicas needs a number}"; shift 2 ;;
    --mode)     MODE="${2:?--mode needs service|gui}"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *)          die "unknown option: $1" ;;
  esac
done

case "$REPO" in */*) ;; *) die "--repo must be owner/name" ;; esac
case "$MODE" in service|gui) ;; *) die "--mode must be service or gui" ;; esac
[ "$REPLICAS" -ge 1 ] 2>/dev/null || die "--replicas must be >= 1"
command -v gh >/dev/null || die "gh CLI required"
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run gh auth login"

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"
NAME="${NAME:-${REPO_NAME}-runner}"
LABELS="${LABELS:-${REPO_NAME}-runner}"
BASE_DIR="${BASE_DIR:-$HOME/actions-runners/$REPO_NAME}"

echo "==> $REPO: $REPLICAS instance(s) of '$NAME' [$LABELS] mode=$MODE"
BASE_NAME="$NAME"

for i in $(seq 1 "$REPLICAS"); do
  if [ "$i" -eq 1 ]; then
    DIR="$BASE_DIR"; RNAME="$NAME"
  else
    DIR="${BASE_DIR}-${i}"; RNAME="${NAME}-${i}"
  fi

  echo "--- instance $i: $DIR (runner '$RNAME')"
  mkdir -p "$DIR"
  cd "$DIR"

  if [ ! -x ./config.sh ]; then
    if [ -n "$(find . -mindepth 1 -maxdepth 1 -not -name '*.tar.gz' | head -n 1)" ]; then
      die "$DIR is not empty and has no config.sh"
    fi
    TAG="$(gh api repos/actions/runner/releases/latest --jq .tag_name)"
    ASSET="$(gh api repos/actions/runner/releases/latest \
      --jq '.assets[] | select(.name | test("osx-arm64.*tar.gz$")) | .name' | head -n 1)"
    [ -n "$TAG" ] && [ -n "$ASSET" ] || die "could not resolve latest macOS arm64 runner release"
    echo "    downloading $ASSET ($TAG)"
    gh release download "$TAG" --repo actions/runner --pattern "$ASSET" --clobber
    tar xzf "$ASSET"
  fi

  # LaunchAgent (svc.sh) runners inherit launchd's minimal PATH — pin one that
  # covers Homebrew and standard dirs so workflow steps can find gh/rg/etc.
  # NOTE: AGENT_TOOLSDIRECTORY/RUNNER_TOOL_CACHE/PNPM_HOME do NOT work here —
  # the runner exports its own reserved values for every job, overriding .env.
  # Toolcache relocation must go through the LaunchAgent plist (below).
  cat > .env <<ENV
PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ENV

  if [ ! -f .runner ]; then
    TOKEN="$(gh api -X POST "repos/$OWNER/$REPO_NAME/actions/runners/registration-token" --jq .token)"
    ./config.sh \
      --url "https://github.com/$OWNER/$REPO_NAME" \
      --token "$TOKEN" \
      --name "$RNAME" \
      --labels "$LABELS" \
      --work _work \
      --unattended
  else
    echo "    already configured (.runner exists) — skipping config.sh"
  fi

  # 등록된 러너의 실제 이름은 .runner의 agentName이 정본이다 — --name 기본값과
  # 기존 등록이 어긋나도 서비스·config를 실제 이름으로 맞춘다. (BOM 주의)
  ACTUAL_NAME="$(/usr/bin/python3 -c \
    'import json; print(json.load(open(".runner", encoding="utf-8-sig"))["agentName"])' \
    2>/dev/null || true)"
  [ -z "$ACTUAL_NAME" ] && ACTUAL_NAME="$RNAME"
  if [ "$i" -eq 1 ]; then
    BASE_NAME="$ACTUAL_NAME"
  fi

  if [ "$MODE" = "service" ]; then
    PLIST="$HOME/Library/LaunchAgents/actions.runner.$OWNER-$REPO_NAME.$ACTUAL_NAME.plist"
    if [ -f "$PLIST" ]; then
      echo "    service already installed ($ACTUAL_NAME) — skipping svc.sh install"
    else
      ./svc.sh install
    fi
    # 로그인 항목 표시명은 ProgramArguments[0]의 파일명이다 — runsvc.sh 그대로면
    # 러너가 전부 같은 이름으로 보이므로 <repo>-runner-<i>.sh 래퍼로 가리킨다.
    SVC_WRAPPER="$DIR/${REPO_NAME}-runner-${i}.sh"
    printf '#!/bin/bash\nexec "$(dirname "$0")/runsvc.sh"\n' > "$SVC_WRAPPER"
    chmod +x "$SVC_WRAPPER"
    # setup-python 계열의 toolcache는 러너가 잡마다 자기 기본값(hosted 이미지의
    # /Users/runner/...)을 강제로 export하므로 .env/step env로 못 바꾼다 —
    # 리스너 프로세스의 환경, 즉 LaunchAgent plist에 RUNNER_TOOL_CACHE를 박는다.
    if [ -f "$PLIST" ]; then
      plutil -replace ProgramArguments.0 -string "$SVC_WRAPPER" "$PLIST"
      plutil -insert EnvironmentVariables.RUNNER_TOOL_CACHE -string "$HOME/actions-runners/_toolcache" "$PLIST" 2>/dev/null \
        || plutil -replace EnvironmentVariables.RUNNER_TOOL_CACHE -string "$HOME/actions-runners/_toolcache" "$PLIST"
      plutil -insert EnvironmentVariables.AGENT_TOOLSDIRECTORY -string "$HOME/actions-runners/_toolcache" "$PLIST" 2>/dev/null \
        || plutil -replace EnvironmentVariables.AGENT_TOOLSDIRECTORY -string "$HOME/actions-runners/_toolcache" "$PLIST"
    else
      echo "    warning: LaunchAgent plist not found at $PLIST — toolcache will use runner default" >&2
    fi
    mkdir -p "$HOME/actions-runners/_toolcache"
    ./svc.sh start
    ./svc.sh status
  fi
done

# Merge the entry into ~/.runnerbar/config.json so the app manages it too.
/usr/bin/python3 - "$CONFIG_PATH" "$REPO_NAME" "$OWNER" "$BASE_NAME" "$BASE_DIR" "$LABELS" "$REPLICAS" "$MODE" <<'PY'
import json, sys

path, repo, owner, name, base_dir, labels, replicas, mode = sys.argv[1:9]
entry = {
    "id": repo,
    "displayName": repo,
    "owner": owner,
    "repo": repo,
    "runnerName": name,
    "runnerPath": base_dir,
    "labels": [l.strip() for l in labels.split(",") if l.strip()],
    "replicas": int(replicas),
    "mode": mode,
}
try:
    with open(path, "r", encoding="utf-8") as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}
runners = [r for r in config.get("runners", []) if r.get("id") != repo]
runners.append(entry)
config["runners"] = runners
# 앱의 필수 키 — 없으면 구버전 디코드가 실패해 설정 전체를 무시한다.
config.setdefault("refreshIntervalSeconds", 20)
import os
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2, ensure_ascii=False, sort_keys=True)
    f.write("\n")
print(f"updated {path}: entry '{repo}'")
PY

echo
echo "Done. Workflows can target these runners with runs-on labels: $LABELS"
if [ "$MODE" = "gui" ]; then
  echo "gui mode: runners start only while RunnerBar is running."
fi
