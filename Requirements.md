# Requirements

## Purpose

Create a PowerShell 5.1 installer/updater script for PowerShell code:

* script name: `install.ps1`
* it is meant to run from a folder named `bin`
* installation target is the current `bin` folder
* alternatively, `-TargetPath <path-to-existing-bin-folder>` may be used to select an existing `bin` folder as the installation target
* package format is one zip file
* the zip contains the full payload and also contains `install.ps1` itself
* everything is driven by just:

  * the zip file
  * the installer/updater script

## Supported update sources

The script must support updating from a single public `-Source` parameter:

* `-Source "C:\path\to\zip.zip"`
* `-Source "https://...\....zip"`
* `-Source "GitHubowner/repo"`
* no source argument = reuse the last used Internet source

Notes:

* “last used Internet source” means only Internet-backed `-Source` values (URI or GitHub)
* a local zip `-Source` value must **not** update that remembered Internet source
* GitHub access is anonymous only
* for GitHub, use the latest **stable** release only, not prereleases
* for `-Source "owner/repo"`, download the latest release **zip asset**
* if a GitHub release has multiple zip assets: hard error

## Default / remembered Internet source behavior

Without a `-Source` argument, the installer uses the last used Internet source.

That remembered source must also store enough metadata to:

* avoid unnecessary re-downloads
* reuse already downloaded cached zip when appropriate

For URI/GitHub sources:

* only check for a new release/update once every hour
* unless `-ForceRequery` is used
* if the URI server does not provide reliable freshness metadata, re-download after cooldown
* for GitHub/URI, the script should be careful not to hit download/query limits

## Reinstall behavior

There must be a `-Reinstall` switch.

Meaning:

* it forces reinstall even if the version appears unchanged
* when using default remembered Internet source and `-Reinstall`, reuse the cached zip if appropriate

## Invocation rules

The installer expects to be run from a folder named `bin`.

* if not, it stops
* exception: internal staged/handoff execution can bypass that check as needed
* exception: if `-TargetPath` is used, that existing `bin` folder becomes the installation target
* when `-TargetPath` is used, the preferred flow is:

  * copy the current `install.ps1` to the target `bin` folder
  * invoke that target-local `install.ps1` with the same public parameters
  * perform the installation from there

## Logging

The installer must log under `..\log` and create the folder if missing.

### Detailed log

Per-run detailed log file:

* `..\log\install.ps1-detailed-YYYY-MM-DD-hh.mm.ss.log`

Requirements:

* detailed operational logging
* also visible on console with `-Verbose`

### Summary log

Yearly summary log file:

* `..\log\install.ps1-summary-YYYY.log`

Requirements:

* plain text format
* contains the most basic info about when a new installation happened
* includes identifiers such as:

  * zip file name
  * URIs
  * version
  * hash of zip file

## Caching

The installer must keep the last 4 **unique** installed zips cached under `..\temp`.

Naming format:

* `..\temp\install.ps1-v<VERSION>-<ZIP_HASH>-YYYY-MM-DD-hh.mm.ss.zip`

Notes:

* uniqueness is by SHA256 zip hash
* only 8 hex characters of the SHA256 are used when you refer to hashes
* example: `a752f19c`

The installer may create `..\temp` if missing.

## Backups of replaced files

When installation replaces an existing file inside `bin` because the incoming file from the installation zip is different, the installer must keep a backup of the pre-existing file under `..\temp`.

Backup naming format:

* `..\temp\<ORIGINAL-FILE.EXT>.install.ps1.<YYYY-MM-DD-hh.mm.ss>.bak`

Notes:

* backups are for existing `bin` files that are actually being replaced
* backups are kept in `..\temp`
* cleanup must delete backups older than one month

## State

The installer must store state in `..\state\install.ps1-state.json`.

The installer may create `..\state` if missing.

The stored state must be trusted over `bin\VERSION` for update/skip decisions.

## Zip/package format

Valid zip structure rules:

* zip may contain junk files at top level
* but must contain exactly one top-level **folder**
* that folder name is:

  * `<NAME>-<NUMERICAL_VERSION>`
  * example: `GetComputerHealth-3.0.2`
* inside that folder are all files/folders exactly as they should land under `bin`
* a valid zip must contain at least one `.ps1` file inside that package folder
* zip must always contain `install.ps1`
* no manifest file exists
* the numerical version from the folder name is the package version
* that version must be written to:

  * `bin\VERSION`
* `bin\VERSION` must contain only the version text and nothing else

## Validation requirements

All PowerShell scripts/modules/etc in the zip must pass basic syntax-ok checks before deployment.

That includes PowerShell code files such as:

* `.ps1`
* `.psm1`
* and any other relevant PowerShell code artifacts included in the package

## Deployment behavior

When deploying files from the zip:

* do **not** delete extra local files
* overwrite only when content differs
* before overwriting an existing differing file in `bin`, create a backup in `..\temp`
* difference test:

  * first compare size
  * if size differs, replace
  * if size is the same, compare hash
  * replace only if hash differs

`bin\VERSION` should be written near the end, after all non-installer file copies succeed.

## Post-install hook

If `bin\post-install.ps1` exists after deployment, the installer must execute it.

Requirements:

* it is executed from the target `bin` folder
* it runs after all file copies succeed, including the final `install.ps1` copy
* it runs before success state and summary log are committed
* if it fails, the installer run fails

## Robustness / common failure modes

The script should be robust and explicitly handle common failure modes and corner cases, including:

* first run
* two runs in a row / concurrency concerns
* temporarily unavailable URI/GitHub
* interrupted download
* interrupted / partial extraction
* corrupt zip
* invalid package structure
* syntax-invalid PowerShell files
* reuse of cached zip where appropriate
* preserving prior good state/cache when network/update attempt fails

## Self-update / handoff behavior

The installer must prefer to run the new installer version found inside the zip, but only after staging and validation.

Required behavior:

* the installer should only replace itself **after everything else succeeds**
* but it should always prefer to run a new version found in the zip

Approved example method:

* current installer downloads/extracts/validates zip into a temp staging folder
* current installer invokes the freshly downloaded `install.ps1` from that staged folder with internal parameters such as `-InternalStageRun` and `-StageRoot`
* current installer then terminates
* the staged/new installer performs the full installation
* if all goes well, the staged/new installer replaces the original `bin\install.ps1` last

## Hash conventions

Whenever hashes are referred to:

* they are SHA256
* only 8 hex characters are used for display/naming

## Naming corrections you requested

* use the public `-Source` parameter for local zip paths, URIs, and GitHub repos
* date format is `YYYY-MM-DD`

## Trust rules

For deciding whether something is current / unchanged:

* trust state/cache/hash
* do **not** trust `bin\VERSION` alone

## Platform/version constraint

* code must target **Windows PowerShell 5.1**

## Developer how-to

For a developer who wants to use `install.ps1` as the installer for their own PowerShell code:

1. Keep your install target as a folder named `bin`.
2. Build one zip that contains exactly one top-level folder named `<NAME>-<NUMERICAL_VERSION>`.
3. Put inside that folder the exact files and subfolders that should land under `bin`.
4. Include `install.ps1` inside that package folder.
5. Ensure the package contains at least one `.ps1` file and that all included PowerShell code is syntax-valid.
6. Optionally include `post-install.ps1` at the package root if you need a final hook after deployment.
7. Distribute either:
   * the zip file together with `install.ps1`, or
   * just `install.ps1` plus a reachable source (`-Source` local zip, URI zip, or GitHub repo)
8. To install into the current `bin`, run `.\install.ps1 -Source <zip-or-remote-source>`.
9. To install into another existing `bin`, run `.\install.ps1 -TargetPath <path-to-existing-bin> -Source <zip-or-remote-source>`.
10. Expect operational artifacts beside that target tree:
   * `..\log`
   * `..\temp`
   * `..\state`
