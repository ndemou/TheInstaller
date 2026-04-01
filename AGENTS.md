# Agent Notes

This file captures project-specific learnings from prior sessions that are useful to remember next time and are not already fully laid out in the main docs.

## Working Style

- Prefer TDD for behavior fixes:
  add a regression test first, observe failure, fix, rerun, then commit.
- When a user asks to preserve "what we learned", update this file.

## Output Expectations

- Normal non-verbose success/no-op runs are expected to end with one concise status line only.
- Current intended lines are:
  - `<Program> updated to v<Version>`
  - `<Program> already at the latest version (v<Version>)`
  - `Skipped checking for updates (already checked recently)`
  - `Not checking for updates (local/offline installation)`

## GitHub Source Behavior

- `owner/repo` GitHub installs must avoid unnecessary repeat API calls within the one-hour cooldown window.
- A second run shortly after a GitHub-backed run should not hit `api.github.com` again if the cached zip is still usable.
- GitHub latest-release resolution now works with either:
  - exactly one uploaded `.zip` release asset
  - no uploaded `.zip` assets, in which case TI falls back to the release tag source archive
- Multiple uploaded `.zip` assets are still treated as an error.

## Release / Manual Verification Notes

- The public repo used for live verification is:
  `https://github.com/ndemou/TheInstaller`
- TI release `v0.0.1` had no uploaded zip asset; GitHub-source installs only worked after source-archive fallback was added.
- Push `main` before creating a release if the new release is meant to include the latest local fixes.

## Host / Handoff Notes

- The machine is using PowerShell 7 (`pwsh`), not Windows PowerShell.
- Do not assume `$PSHOME\\powershell.exe` exists; use host discovery logic.
- `-TargetPath` runs involve an outer wrapper process and a target-local run.
- Internal staged deployment must use the current installer logic as the runner, not the packaged `install.ps1`, otherwise newer behavior can regress when installing older packages.

## Known Remaining Cleanup

- Duplicate error output on `-TargetPath` failures is still noisy because both the inner failing run and the outer handoff wrapper report errors.
- This is a known improvement area, not yet fixed.
