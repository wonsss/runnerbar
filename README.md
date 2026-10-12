# RunnerBar

[![build](https://github.com/wonsss/runnerbar/actions/workflows/build.yml/badge.svg)](https://github.com/wonsss/runnerbar/actions/workflows/build.yml)

macOS menu bar controller for **GitHub self-hosted runners** on your Mac.

RunnerBar watches the runner services and GitHub-side status for each
repository you register, lets you start/stop/restart them, auto-recovers them
when they go offline or jobs hang in the queue, and keeps an eye on machine
health (disk, colima/Docker, AC power policy).

<!-- TODO: add a screenshot of the dashboard popover, e.g. docs/screenshot.png -->

## Features

- **Per-repo runner dashboard** — online/busy status from `gh api`, local
  `svc.sh` service state, queued/in-progress workflow runs, and recent runner
  log events. Cancel active runs inline.
- **Two runner modes** — `service` (GitHub `svc.sh` LaunchAgent) and `gui`
  (runner spawned as a RunnerBar child in the login session — required for
  jobs that drive the iOS Simulator or other UI; see below).
- **Replicas** — scale one repo entry to N parallel runner instances sharing
  the same labels, each in its own directory with its own LaunchAgent.
- **Watchdog** — detects offline runners and queued-job hangs (jobs whose
  labels match no online runner), restarts with exponential backoff, and
  notifies (macOS notification + optional Slack webhook) only when recovery
  fails.
- **Machine health** — disk-free gauge with warning threshold, colima/Docker
  status, and a cleanup sheet (`_work` dirs, `docker system prune`,
  `supabase stop`, unavailable simulators).
- **Power policy** — apply a runner-friendly AC power policy or restore
  macOS defaults from the app (administrator prompt).
- **AI provider health** — selectable default provider and fallback order
  (`codex`, `claude`) with login/quota-aware health checks.
- **Headless CLI** — `runnerbar add` (interactive) and `runnerbar register`
  for scripted multi-repo onboarding over SSH.
- English/Korean UI.

## Requirements

- macOS 14 (Sonoma) or later on **Apple Silicon** — runner registration
  downloads the macOS arm64 runner.
- A Swift 6.1+ toolchain (Xcode 16+ recommended) to build from source.
- [GitHub CLI](https://cli.github.com) (`gh`), authenticated with access to
  the target repositories: `gh auth login`.
- Optional, only if you use the related features: colima/Docker, supabase
  CLI, `codex` and/or `claude` CLIs.

## Install & run

Build from source:

```bash
git clone https://github.com/wonsss/runnerbar.git
cd runnerbar
scripts/build-app.sh        # builds .build/RunnerBar.app
open .build/RunnerBar.app
```

Or run it straight from the package without bundling:

```bash
swift run RunnerBar
```

The app is **unsigned**. On first launch, approve it via
System Settings → Privacy & Security → "Open Anyway", or right-click the app
and choose Open.

To start RunnerBar automatically at login (needed for `gui`-mode runners to
survive reboots together with macOS auto-login):

```bash
scripts/install-login-agent.sh      # installs ~/Library/LaunchAgents/io.github.wonsss.runnerbar.plist
scripts/uninstall-login-agent.sh    # removes it
```

## Quick start

1. Register runners for your repositories — either from the menu
   (**RunnerBar → Register New GitHub Runner...**) or headless:

   ```bash
   ./runnerbar add                          # interactive; run inside the repo's checkout
   ./runnerbar register --repo owner/name --replicas 3 --mode service
   ```

   Registration downloads the latest official macOS arm64 runner, configures
   each instance, installs its `svc.sh` LaunchAgent (service mode), and merges
   the entry into `~/.runnerbar/config.json`.

2. Point workflows at the runner labels, e.g. `runs-on: [my-repo-runner]` —
   or route them through a repo variable like
   `runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}` and set `CI_RUNNER` to
   your label to move jobs onto this Mac without touching workflows.

3. Open the RunnerBar menu item to monitor and control everything.

## `runnerbar` CLI

The `runnerbar` script at the repo root is the headless administration path:

```bash
./runnerbar add                      # interactive registration (infers repo
                                     # from the git remote of your cwd)
./runnerbar register --repo o/n ...  # non-interactive; see scripts/register-repo-runner.sh -h
./runnerbar list                     # config entries + live GitHub online status
./runnerbar config                   # print ~/.runnerbar/config.json
```

`RUNNERBAR_CONFIG` overrides the config path for all commands and scripts.

## Configuration

One entry per repository runner lives in `~/.runnerbar/config.json` (copy
`config/config.example.json` as a starting point). Each runner needs its own
directory:

```text
~/actions-runners/my-repo
~/actions-runners/other-repo
```

In-app editing: **RunnerBar → Config Settings...** exposes refresh interval,
disk warning threshold, Slack webhook, and the watchdog toggle.
**Add Existing Runner Config...** adds an already-registered runner;
the GitHub runner name shown in repo settings is the `runnerName` value.

The full schema (all fields optional except `runners`):

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

> Keep `~/.runnerbar/config.json` private — `slackWebhookURL` is a secret
> anyone can post to, and the file lists your runner names/paths.

## Runner modes — `service` vs `gui`

Each runner entry takes an optional `"mode"`:

| mode | how it runs | use when |
|------|-------------|----------|
| `"service"` (default) | GitHub's `svc.sh` LaunchAgent | normal CI; robust & independent of RunnerBar |
| `"gui"` | RunnerBar launches `./run.sh` as its **own child process** | jobs that drive the **iOS Simulator / UI** (Maestro, `xcrun simctl`, dev-client) |

Why `gui` matters: RunnerBar is a menu-bar app, so it runs in the logged-in
**GUI (Aqua) session**. A child process it spawns inherits that session. A
`svc.sh` LaunchAgent instead runs in a **background launchd session with no
GUI** — there, Simulator apps mis-initialize (e.g. React Native New
Architecture TurboModules fail to register → the app crashes with
`'RNGoogleSignin' could not be found`), so simulator smoke/E2E jobs always
fail. Running the runner as a RunnerBar child fixes this.

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

- The runner is tied to RunnerBar's lifecycle — it **stops when RunnerBar
  quits** (RunnerBar stops them cleanly via SIGINT on exit). For unattended
  operation, enable **auto-login** so RunnerBar (its login agent) starts in
  the GUI session after a reboot.
- Keep the Mac awake and **don't let the screen lock** (a locked Aqua session
  blocks Simulator UI). RunnerBar already manages the AC power policy from
  the dashboard.
- Replicas are supported: every replica of a `gui` runner is launched as its
  own child (per-instance log at `<runnerPath>/_diag/runnerbar-gui.log`).

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

## Registering more repositories

In-app: **RunnerBar → Register New GitHub Runner...** will:

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

## Replicas

Set `"replicas": N` on a runner entry (or use **Scale Up / Scale Down** in the
runner submenu) to run N parallel instances of the same runner sharing the
same labels. RunnerBar derives instance directories by suffix:

```text
/Users/you/actions-runners/my-repo      # instance #1
/Users/you/actions-runners/my-repo-2    # instance #2
/Users/you/actions-runners/my-repo-3    # instance #3
```

Runner names are derived the same way (`<runnerName>-2`, `<runnerName>-3`).
Each replica is registered with its own GitHub runner record and LaunchAgent.
The dashboard groups replicas under a single Label Group card showing
`online / total` and `busy`.

## Watchdog

The watchdog runs on each refresh tick. It detects:

1. **Offline runner** — a configured runner instance whose local service is
   not `Started` or whose GitHub status is not `online`.
2. **Queue hang** — a repo has GitHub Actions jobs `queued` whose `labels`
   match no currently online runner instance in that repo.

When either condition is detected, the watchdog tries `svc.sh restart` (and
optionally `colima start`) for each affected instance with exponential
backoff (`recoveryBaseDelaySeconds * 2^(attempt-1)`). Only after
`recoveryAttempts` consecutive failures does it raise a macOS notification
and POST to the Slack webhook. All attempts and outcomes are visible in the
dashboard's **Watchdog Log** card.

## Machine Health

The dashboard's **Machine Health** card shows:

- **Disk** free GB / total GB and a progress bar. Turns red when free % is
  below `diskWarnThresholdPercent`.
- **Colima** running/stopped/not-installed, with Start/Stop buttons.
- **Docker** running/stopped status.
- **Clean Up...** opens a sheet that can run, in any combination: clean each
  stopped instance's `_work/_temp`, `_work/_tool`, and `node_modules`;
  `docker system prune -af --volumes`; `supabase stop`;
  `xcrun simctl delete unavailable`.

## AI providers

Choose via **RunnerBar → Settings → AI Provider**. Supported providers:

- Codex: `codex exec`
- Claude Code: `claude -p --max-turns 1`

RunnerBar saves the selected provider and fallback order to
`~/.runnerbar/config.json`. CI scripts can use the helper below to run the
first available provider and fall back when a provider returns a rate-limit
or quota error:

```bash
scripts/run-ai-analysis.sh prompt.md analysis.md
```

## Development

```bash
swift build          # debug build
swift run RunnerBar  # run from the repo
scripts/build-app.sh # release .app bundle (unsigned)
```

The codebase is a single SwiftPM executable target — no external
dependencies:

| path | role |
|------|------|
| `Sources/RunnerBar/AppDelegate.swift` | menu bar UI, dashboard window, forms, timers |
| `Sources/RunnerBar/Monitor.swift` | `svc.sh`/`gh api`/`pmset` calls, registration & removal scripts, machine health |
| `Sources/RunnerBar/GUIRunnerSupervisor.swift` | `gui` mode child-process lifecycle |
| `Sources/RunnerBar/Watchdog.swift` | offline/hang detection, recovery, Slack + notification alerts |
| `Sources/RunnerBar/DashboardCards.swift` | SwiftUI dashboard cards |
| `Sources/RunnerBar/Config.swift`, `Models.swift` | config schema & domain models |
| `Sources/RunnerBar/Shell.swift` | single subprocess runner (`Shell.run` / `Shell.runScript` / `Shell.quote`) |
| `Sources/RunnerBar/Localization.swift` | English/Korean strings |
| `runnerbar`, `scripts/` | headless registration & helper scripts |
| `config/config.example.json` | starter config |

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

- Runner registration/remove tokens are fetched via `gh api` and passed only
  to `config.sh` — never persisted to `config.json`.
- Self-hosted runners run arbitrary workflow code with your privileges; only
  register runners for repositories you trust.
- To report a vulnerability, see [SECURITY.md](SECURITY.md) — please don't
  open public issues for security problems.

## License

[MIT](LICENSE)
