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
- See current queued/in-progress GitHub Actions requests per runner.
- Cancel active workflow runs from the dashboard.
- See recent local runner service events from the runner log.
- See current AC sleep policy in the dashboard.
- Apply the recommended AC power policy from the app with a macOS administrator prompt.
- Switch the app between English and Korean from the Settings menu.
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

This updates global RunnerBar settings such as refresh interval and saves them to `~/.runnerbar/config.json`.
