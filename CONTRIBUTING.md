# Contributing to RunnerBar

Thanks for your interest in contributing! RunnerBar is a small personal-scale
project — contributions are welcome, but please keep the scope tight.

## Ways to contribute

- **Bug reports** — open an issue with reproduction steps, your macOS version,
  and what you expected vs. what happened.
- **Feature requests** — open an issue describing the use case first. For
  anything beyond a small change, please discuss before writing code.
- **Pull requests** — small, focused PRs are easiest to review.

## Development setup

Requirements:

- macOS 14+ on Apple Silicon
- A Swift 6.1+ toolchain (Xcode 16+ or `xcode-select --install` plus a recent
  Swift toolchain)
- [GitHub CLI](https://cli.github.com) (`gh`), authenticated (`gh auth login`),
  for any feature that talks to the GitHub API

Build and run:

```bash
swift build          # debug build
swift run RunnerBar  # run the menu bar app from the repo
scripts/build-app.sh # release .app bundle at .build/RunnerBar.app
```

Tests: the package currently has no test target. If you add non-trivial pure
logic (parsing, validation, config handling), adding a `Tests/` target is a
welcome contribution.

## Code conventions

- Swift 6 concurrency: UI state stays on `@MainActor`; anything that shells
  out or does I/O runs off the main actor (`nonisolated` helpers /
  `DispatchQueue.global` / `Task.detached`) and reports back on the main actor.
- **Never interpolate into shell strings.** Use `Shell.run` with an argument
  array. If a `Shell.runScript` call is unavoidable, pass every variable
  through `Shell.quote` first.
- `do shell script ... with administrator privileges` may only wrap constant
  strings — never user input.
- Keep user-facing strings in `Localization.swift` for both `en` and `ko`.
- Comments and identifiers are in English.
- No new third-party dependencies without prior discussion — the project is
  intentionally dependency-free.

## Commit / PR style

- Conventional-ish commit subjects (`feat:`, `fix:`, `chore:`…) are welcome
  but not enforced.
- Keep PRs small and self-describing: what changed, why, and how you tested
  it (a screenshot of the dashboard/menu helps for UI changes).

## Security

Do not open public issues for vulnerabilities that expose secrets, tokens, or
runner credentials — see [SECURITY.md](SECURITY.md).
