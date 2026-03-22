# Installer Execution Flow

This note explains why TI sometimes runs as an "outer" installer and sometimes as an "inner" installer, and why `-TargetPath` failures can currently appear twice.

## The three execution modes

TI effectively has three execution modes:

1. Public direct run
   Example:
   `.\install.ps1 -Source C:\pkg.zip`

   In this mode, the script runs directly in the target `bin` folder and does the full install flow itself.

2. Public `-TargetPath` handoff run
   Example:
   `.\install.ps1 -TargetPath C:\it\app\bin -Source owner/repo`

   In this mode, the script is launched from somewhere else, copies itself to the target `bin\install.ps1`, and then starts a second PowerShell process that runs from the target location. The first process is just a wrapper/handoff process.

3. Internal staged run
   This is not a public mode. The installer uses `-InternalStageRun -StageRoot <path>` internally after it has already downloaded or selected a zip, extracted it to a temporary stage, validated it, and prepared a source-context file.

## Why `-TargetPath` exists

The installer is designed so the actual install work happens from the destination `bin` folder.

That matters because:

- all relative operational folders are target-local:
  `..\log`
  `..\state`
  `..\temp`
- the installed `install.ps1` should live in the target `bin`
- post-install logic should run in the target environment

So when you pass `-TargetPath`, TI does not install "from here into there" in one process. Instead, it:

1. validates that `-TargetPath` exists and ends in `bin`
2. copies the current installer script to `<TargetPath>\install.ps1`
3. launches that target copy as a new PowerShell process with the same public arguments

That target copy is the one that performs source resolution, download/reuse decisions, staging, deployment, and state updates.

## Why staging exists

Once the target-local public run resolves a zip, it does not deploy directly from the zip into `bin`.

Instead it:

1. extracts the zip to a temporary stage folder under `..\temp`
2. validates the staged package structure
3. validates PowerShell syntax
4. writes `install.ps1-source-context.json` into the stage root
5. launches the staged package's `install.ps1` with `-InternalStageRun`

That internal staged run re-validates the staged package before mutating `bin`.

This design gives TI a cleaner boundary:

- public run:
  choose source, download/reuse zip, create stage, validate before handoff
- internal staged run:
  copy files into `bin`, write `VERSION`, cache zip, run `post-install.ps1`, commit state and summary

## Why there can be multiple processes

For a `-TargetPath` install from a GitHub source, there can be up to three script executions involved:

1. outer wrapper run
   Started from the original path you typed in the shell.

2. target-local public run
   Started from `<TargetPath>\install.ps1`.

3. target-local internal staged run
   Started from the staged package's `install.ps1` with `-InternalStageRun`.

Not every install needs all three, but `-TargetPath` plus a normal package deployment commonly uses all of them.

## Where duplicate errors come from

Today, each process has its own top-level `catch` block that does:

1. `Write-Log -Level ERROR -Message $msg`
2. `throw`

That means a failure can be reported by more than one layer.

Example with `-TargetPath`:

1. the target-local public run fails for the real reason
   Example:
   `GitHub latest stable release for ndemou/TheInstaller must contain exactly one .zip asset; found 0.`

2. that process exits with code `1`

3. the outer wrapper sees the failed child process and throws:
   `Target-path installer handoff failed with exit code 1.`

4. the outer wrapper's own top-level `catch` logs and throws again

So the console can show:

- the inner/root cause error
- the outer wrapper error
- PowerShell exception formatting for both

This is why `-TargetPath` failures currently feel noisy and duplicated.

## What the source-context file does

`install.ps1-source-context.json` lives in the stage root and carries the install decision into the internal staged run.

It includes values such as:

- target `bin` path
- selected source kind and source value
- chosen zip path
- computed zip hash
- run id

The internal staged run reads that file so it knows:

- which target `bin` it is mutating
- which staged zip it is associated with
- what source metadata should be written into state/summary

## GitHub release assets vs GitHub source archives

These are not the same thing.

TI prefers a GitHub release to contain exactly one attached `.zip` asset.

Current selection order:

1. if the latest stable release has exactly one uploaded `.zip` asset, TI uses it
2. if the latest stable release has no `.zip` assets, TI falls back to the release tag source archive
3. if the latest stable release has more than one `.zip` asset, TI fails because source selection would be ambiguous

This is different from GitHub's auto-generated tag archive URLs such as:

- `https://github.com/<owner>/<repo>/archive/refs/tags/v0.0.1.zip`

That URL is just a source snapshot archive for the tag. It is not a release asset, and it does not appear in the release `assets` array. TI can now use that archive as a fallback when the release has no uploaded `.zip` assets.

## Current consequence for `ndemou/TheInstaller`

Before the fallback change, this was the situation:

- release `v0.0.1` exists
- it has no attached `.zip` assets
- the tag archive URL exists even though it is not a release asset

That was why `-Source ndemou/TheInstaller` used to fail.

## Possible future simplifications

Two obvious improvements are:

1. reduce duplicate error output for wrapper/handoff failures
2. optionally support GitHub release source archives in addition to uploaded zip assets

The current implementation now supports source-archive fallback, but duplicate error output is still not simplified yet.
