# RunnerBar

macOS menu bar controller for GitHub self-hosted runners on this Mac.

## Model

RunnerBar is repo-aware and runner-directory-aware. Add one entry per repository runner in:

```bash
~/.runnerbar/config.json
```

Each runner should have its own directory, for example:

```text
~/actions-runners/my-repo
~/actions-runners/other-repo
```

## Runner modes — `service` vs `gui`

Each runner entry takes an optional `"mode"`:

| mode | how it runs | use when |
|------|-------------|----------|
| `"service"` (default) | GitHub's `svc.sh` LaunchAgent | normal CI; robust & independent of RunnerBar |
| `"gui"` | RunnerBar launches `./run.sh` as its **own child process** | jobs that drive the **iOS Simulator / UI** (Maestro, `xcrun simctl`, dev-client) |

Why `gui` matters: RunnerBar is a menu-bar app, so it runs in the logged-in **GUI (Aqua) session**. A child process it spawns inherits that session. A `svc.sh` LaunchAgent instead runs in a **background launchd session with no GUI** — there, Simulator apps mis-initialize (e.g. React Native New Architecture TurboModules fail to register → the app crashes with `'RNGoogleSignin' could not be found`), so simulator smoke/E2E jobs always fail. Running the runner as a RunnerBar child fixes this.

```jsonc
{
  "id": "my-repo",
  "runnerName": "macbook-ci-runner",
  "runnerPath": "/Users/you/actions-runners/my-repo",
  "labels": ["my-repo-runner"],
  "replicas": 4,
  "mode": "gui"          // all 4 replicas run as RunnerBar children in the GUI session
}
```

Trade-off & requirements for `gui` mode:
- The runner is tied to RunnerBar's lifecycle — it **stops when RunnerBar quits** (RunnerBar stops them cleanly via SIGINT on exit). For unattended operation, enable **auto-login** so RunnerBar (its login agent) starts in the GUI session after a reboot.
- Keep the Mac awake and **don't let the screen lock** (a locked Aqua session blocks Simulator UI). RunnerBar already manages the AC power policy from the dashboard.
- Replicas are supported: every replica of a `gui` runner is launched as its own child (per-instance log at `<runnerPath>/_diag/runnerbar-gui.log`).

## Setup

```bash
cp config/config.example.json ~/.runnerbar/config.json
swift run RunnerBar
```

## Headless registration (multi-repo onboarding)

`scripts/register-repo-runner.sh` performs the same steps as
`Register New GitHub Runner...` non-interactively — useful when onboarding
several repositories or when an agent/SSH session drives the setup:

```bash
scripts/register-repo-runner.sh \
  --repo owner/name \
  --labels <repo>-runner \
  --replicas 3 \
  --mode service        # or gui for jobs that need the iOS Simulator
```

It downloads the latest macOS arm64 runner, registers one instance per
replica (directories `<dir>`, `<dir>-2`, …), writes each instance's `.env`
with a Homebrew-aware `PATH` (LaunchAgent sessions otherwise get launchd's
minimal PATH and steps cannot find `gh`, `rg`, …), installs `svc.sh`
LaunchAgents in `service` mode, and merges the entry into
`~/.runnerbar/config.json`. If RunnerBar is running while the script runs,
restart it so it reloads the config.

To have workflows pick runners per environment instead of per workflow, point
`runs-on` at a repo variable, e.g. `runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}`,
and set `CI_RUNNER` to the registered label to move jobs onto this Mac.

## Dedicated runner machine

To put the runners on a second Mac instead of this one:

1. Copy `.build/RunnerBar.app` (built by `scripts/build-app.sh`) to that Mac —
   or clone this repo there and build locally. Unsigned app: allow it in
   System Settings → Privacy & Security on first launch.
2. On that Mac, `gh auth login` with an account that can admin the target
   repos, then either launch RunnerBar and use
   `Register New GitHub Runner...`, or copy
   `scripts/register-repo-runner.sh` and run it per repo — it only needs
   `gh`, `curl`, and `/usr/bin/python3`.
3. Keep the Mac on AC, disable display sleep while jobs run, and enable
   auto-login + the RunnerBar login agent (`scripts/install-login-agent.sh`)
   if it must survive reboots — `gui`-mode runners and the dashboard die with
   the login session otherwise.
4. Set the repo's runner variable (e.g. `CI_RUNNER`) to the registered label —
   jobs then route to the new machine without touching workflows again.

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
      "id": "my-repo",
      "displayName": "My Project",
      "owner": "your-org",
      "repo": "my-repo",
      "runnerName": "macbook-ci-runner",
      "runnerPath": "/Users/you/actions-runners/my-repo",
      "labels": ["my-repo-runner"],
      "replicas": 1
    }
  ]
}
```

### Replicas

Set `"replicas": N` on a runner entry (or use **Scale Up / Scale Down** in the runner submenu) to run N parallel instances of the same runner sharing the same labels. RunnerBar derives instance directories by suffix:

```
/Users/you/actions-runners/my-repo      # instance #1
/Users/you/actions-runners/my-repo-2    # instance #2
/Users/you/actions-runners/my-repo-3    # instance #3
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
