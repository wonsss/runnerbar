# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Prepared the repository for open-source release: neutralized personal
  paths and service-specific defaults, set bundle ID to
  `io.github.wonsss.runnerbar`, and use the system time zone for dashboard
  timestamps.

## [0.1.0] - 2026-10-11

Initial public release.

### Added

- Menu bar dashboard for repo-scoped GitHub self-hosted runners: online/busy
  status, queued and in-progress runs, and per-runner service control
  (start/stop/restart, individually or all at once).
- `service` mode (GitHub `svc.sh` LaunchAgent) and `gui` mode (runner spawned
  as a RunnerBar child in the login session, for jobs that drive the iOS
  Simulator).
- Runner registration from the app ("Register New GitHub Runner...") and
  headless scripts: `runnerbar add` (interactive) and
  `runnerbar register` / `scripts/register-repo-runner.sh` (non-interactive).
- Replicas: scale one repo entry to N parallel runner instances sharing
  labels, each with its own directory and LaunchAgent.
- Watchdog: detects offline runners and queued-job hangs, auto-restarts with
  exponential backoff, notifies via macOS notification and optional Slack
  webhook only when recovery fails.
- Machine Health card: disk-free gauge with warning threshold, colima/Docker
  status, and a cleanup sheet (`_work` dirs, `docker system prune`,
  `supabase stop`, unavailable simulators).
- AC power policy controls (apply runner-friendly policy / restore defaults)
  via a macOS administrator prompt.
- AI provider health checks with selectable provider and fallback order
  (`codex`, `claude`), plus `scripts/run-ai-analysis.sh` for CI-side analysis
  with rate-limit fallback.
- English/Korean UI localization.
- Login agent install/uninstall scripts for starting RunnerBar at login.
