# RunnerBar

macOS menu bar controller for GitHub self-hosted runners on this Mac.

## Model

RunnerBar is repo-aware and runner-directory-aware. Add one entry per repository runner in:

```bash
~/.runnerbar/config.json
```

Each runner should have its own directory, for example:

```text
~/actions-runners/reading-crew
~/actions-runners/other-repo
```

## Setup

```bash
cp config/config.example.json ~/.runnerbar/config.json
swift run RunnerBar
```

## Build App Bundle

```bash
scripts/build-app.sh
open .build/RunnerBar.app
```

## Controls

- Open a live dashboard for all configured repository runners.
- See current queued/in-progress GitHub Actions requests per runner, with the assigned runner name shown inline.
- Cancel active workflow runs from the dashboard.
- See recent local runner service events from the runner log.
- See current AC sleep policy in the dashboard.
- Apply the recommended AC power policy from the app with a macOS administrator prompt.
- Restore the default AC power policy from the app.
- Switch the app between English and Korean from the Settings menu.
- Select the default AI provider and fallback order for CI analysis.
- **Watchdog (P0)**: detect offline runners and queue hangs (queued jobs whose labels match no online runner), auto-restart with exponential backoff, then notify (macOS notification + optional Slack webhook) only when recovery fails.
- **Replicas (P1)**: scale a single repo runner entry to N parallel instances sharing the same labels, via `Scale Up / Scale Down` in the runner submenu. Each replica gets its own directory and LaunchAgent.
- **Machine Health (P2)**: live colima/Docker indicator, disk-free % gauge with threshold warning, and a one-click cleanup sheet (runner `_work`, `docker system prune`, `supabase stop`, simulator caches).

## AI Providers

Choose:

```text
RunnerBar -> Settings -> AI Provider
```

Supported providers:

- Codex: `codex exec`
- Claude Code: `claude -p --max-turns 1`

RunnerBar saves the selected provider and fallback order to `~/.runnerbar/config.json`.
CI scripts can use the helper below to run the first available provider and fall back
when a provider returns a rate-limit or quota error:

```bash
scripts/run-ai-analysis.sh prompt.md analysis.md
```
- Register a new GitHub repository runner from the menu bar app.
- Add repository runners from the menu bar app.
- Start, stop, and restart each configured runner service.
- Start, stop, and restart all configured runners at once.
- Refresh GitHub online and busy state through `gh api`.
- Show local LaunchAgent service state through `svc.sh status`.
- Warn when AC power sleep is not disabled.

## Registering More Repositories

Choose:

```text
RunnerBar -> Register New GitHub Runner...
```

RunnerBar will:

1. Create the local runner directory.
2. Download the latest official macOS arm64 GitHub Actions runner.
3. Request a repository registration token through `gh api`.
4. Run `config.sh` with the supplied runner name and labels.
5. Install and start the user LaunchAgent service with `svc.sh`.
6. Save the runner to `~/.runnerbar/config.json`.

Prerequisites:

- `gh auth status` must be logged in with access to the target repository.
- The runner path must be empty or contain only a downloaded runner tarball.
- Use restrictive labels per repo so workflows can target the intended runner.

## Adding Existing Runner Configs

Register each GitHub runner first, using a separate directory per repository. Then choose:

```text
RunnerBar -> Add Existing Runner Config...
```

Required fields:

- Owner: GitHub owner or organization. Defaults to the current `gh` login when registering a new runner.
- Repo: repository name.
- Runner name: exact self-hosted runner name shown in GitHub settings. New registration can leave this empty to auto-generate it.
- Runner path: local directory that contains `svc.sh`. New registration can use a parent path ending in `/`; RunnerBar appends the repo name.
- Labels: comma-separated labels used by workflows. New registration can leave this empty to use `<repo>-runner`.

## Config Settings

Choose:

```text
RunnerBar -> Config Settings...
```

This updates global RunnerBar settings and saves them to `~/.runnerbar/config.json`. The dialog exposes:

- **Refresh sec** — polling interval (≥ 5).
- **Disk warn %** — free-disk threshold below which the dashboard turns the disk gauge red.
- **Slack webhook URL** — optional. When set, RunnerBar posts to it when the watchdog exhausts all recovery attempts.
- **Watchdog enabled** — turn the offline/hang detector on or off.

The full schema (all fields are optional except `runners`):

```json
{
  "language": "en",
  "refreshIntervalSeconds": 20,
  "defaultAIProvider": "codex",
  "aiProviderFallbackOrder": ["codex", "claude"],
  "slackWebhookURL": null,
  "diskWarnThresholdPercent": 15,
  "watchdog": {
    "enabled": true,
    "recoveryAttempts": 3,
    "recoveryBaseDelaySeconds": 8,
    "autoStartColima": true
  },
  "runners": [
    {
      "id": "reading-crew",
      "displayName": "Reading Crew",
      "owner": "wonsss",
      "repo": "reading-crew",
      "runnerName": "macbook-air-ai-analyzer",
      "runnerPath": "/Users/marco/actions-runner-readingcrew",
      "labels": ["readingcrew-ai-analyzer"],
      "replicas": 1
    }
  ]
}
```

### Replicas

Set `"replicas": N` on a runner entry (or use **Scale Up / Scale Down** in the runner submenu) to run N parallel instances of the same runner sharing the same labels. RunnerBar derives instance directories by suffix:

```
/Users/marco/actions-runner-readingcrew      # instance #1
/Users/marco/actions-runner-readingcrew-2    # instance #2
/Users/marco/actions-runner-readingcrew-3    # instance #3
```

Runner names are derived the same way (`<runnerName>-2`, `<runnerName>-3`). Each replica is registered with its own GitHub runner record and LaunchAgent. The dashboard groups replicas under a single Label Group card showing `online / total` and `busy`.

### Watchdog

The watchdog runs on each refresh tick. It detects:

1. **Offline runner** — a configured runner instance whose local service is not `Started` or whose GitHub status is not `online`.
2. **Queue hang** — a repo has GitHub Actions jobs `queued` whose `labels` match no currently online runner instance in that repo.

When either condition is detected, the watchdog tries `svc.sh restart` (and optionally `colima start`) for each affected instance with exponential backoff (`recoveryBaseDelaySeconds * 2^(attempt-1)`). Only after `recoveryAttempts` consecutive failures does it raise a macOS notification and POST to the Slack webhook. All attempts and outcomes are visible in the dashboard's **Watchdog Log** card.

### Machine Health

The dashboard's **Machine Health** card shows:

- **Disk** free GB / total GB and a progress bar. Turns red when free % is below `diskWarnThresholdPercent`.
- **Colima** running/stopped/not-installed, with Start/Stop buttons.
- **Docker** running/stopped status.
- **Clean Up...** opens a sheet that can run, in any combination: clean each stopped instance's `_work/_temp`, `_work/_tool`, and `node_modules`; `docker system prune -af --volumes`; `supabase stop`; `xcrun simctl delete unavailable`.
