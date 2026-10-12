# Security Policy

## Scope

RunnerBar orchestrates GitHub Actions **self-hosted runners** on your Mac and
drives privileged local operations (LaunchAgent install, `pmset` with admin
rights, subprocesses under your login session). Please treat anything that
could leak a runner registration token, `gh` credentials, or enable command
injection via user-controlled config values as security-sensitive.

## Reporting a vulnerability

Please do **not** open a public issue for security problems. Instead, use
GitHub's private reporting channel:

- [Report a vulnerability](../../security/advisories/new) via GitHub Security
  Advisories, or
- contact the maintainer via the email on their GitHub profile.

Include reproduction steps and which input you control (config field, repo
name, label, webhook payload, …). You will get an acknowledgement as soon as
possible; this is a hobby project, so please be patient.

## Notes for users

- Registration/remove tokens are requested via `gh api` and passed only to the
  official `config.sh` — they are never written to `config.json`.
- `slackWebhookURL` in `~/.runnerbar/config.json` is a secret anyone can post
  to; keep the file private (it lives outside this repo).
- Self-hosted runners execute arbitrary workflow code with your user's
  privileges. Only register runners for repositories you trust.
