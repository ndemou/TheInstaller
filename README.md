# 

This tool installs and updates a software using a single zip package and a single installer script, `install.ps1`. 

TI, can install from a local zip file, a direct URI, a GitHub repository’s latest stable release zip asset or source archive, or, by default, from the last Internet source that was previously used. 

To reduce unnecessary network traffic and avoid rate limits, it remembers source metadata, reuses previously downloaded packages when appropriate, and normally checks for updates at most once per hour unless forced. Before deploying anything, the tool stages the package in a temporary area and validates it. Files are then copied without deleting extra local files. 

The tool also manages its own lifecycle. If the staged package contains a newer installer, the currently running installer hands off execution to that staged installer, which performs the actual installation and replaces the original installer only after all other deployment work has completed successfully.

Operationally, the tool maintains logs, persistent state, and a cache of recently installed zip packages, and it is designed to handle common failure cases such as interrupted downloads, corrupt zips, temporary source outages, repeated runs, and partial staging failures without damaging the existing installation.


# TI (The Installer)

TI (“The Installer”) is a PowerShell 5 installer/updater for software distributed as a single zip package plus a single installer script. TI only manages the boring common part of an installer: downloading, and copying the files. You need to provide an additional custom `post-install.ps1` to deal with everything that is custom for your software.

Its purpose is simple: take a zip file, validate it, deploy its contents safely and repeatably and fire-up `post-install.ps` at the end.

TI supports:

* local zip installs
* HTTP/HTTPS zip installs
* GitHub latest-release zip-asset installs
* reinstall from cached package
* self-update of the installer itself
* post-install hooks
* logs, state, zip cache, and file backups

---

## What TI does

TI installs or updates a PowerShell codebase into a target `bin` folder.

A TI package is one zip file that contains exactly one package folder named like:

`<NAME>-<NUMERICAL_VERSION>`

Example:

`MyTool-3.0.2`

Inside that folder are the exact files and subfolders that should land under `bin`, including `install.ps1` itself.

TI validates the package before deployment, stages it, prefers to hand off execution to the newer staged installer when present, copies changed files into `bin`, backs up replaced files, writes `bin\VERSION`, optionally runs `post-install.ps1`, records success state, and maintains logs and cache files beside the target tree.

TI never deletes extra local files from `bin`.

---

## Requirements

* Windows PowerShell 5.1
* install target must be a folder named `bin`
* target `bin` must already exist if `-TargetPath` is used
* package must be a valid TI zip

---

## Main features

* Single public `-Source` parameter for local zip paths, URIs, and GitHub repos
* Default reuse of the last remembered Internet source
* One-hour requery cooldown for Internet-backed sources
* Cached zip reuse when appropriate
* `-Reinstall` support
* Safe staging and validation before deployment
* Syntax validation for packaged PowerShell code
* Replace only when content differs
* Backup of replaced files
* Installer self-update support
* Optional `post-install.ps1`
* Detailed log, summary log, state file, and zip cache retention

---

## Usage

### Install into the current `bin`

```powershell
.\install.ps1 -Source 'C:\path\to\package.zip'
.\install.ps1 -Source 'https://example.org/package.zip'
.\install.ps1 -Source 'owner/repo'
```

### Reuse the last remembered Internet source

```powershell
.\install.ps1
```

This only works if a previous successful run used an Internet-backed source such as an HTTP/HTTPS zip or GitHub repo.

### Force a reinstall

```powershell
.\install.ps1 -Reinstall
.\install.ps1 -Source 'owner/repo' -Reinstall
```

### Force requery of the remote source

```powershell
.\install.ps1 -ForceRequery
.\install.ps1 -Source 'https://example.org/package.zip' -ForceRequery
```

### Install into another existing `bin` folder

```powershell
.\install.ps1 -TargetPath 'C:\some\dir\asp\bin' -Source 'owner/repo'
```

Preferred flow for `-TargetPath`:

1. copy the current `install.ps1` into the target `bin`
2. invoke that target-local `install.ps1` with the same public parameters
3. perform the installation from there

---

## Public parameters

### `-Source <string>`

A single public source parameter that accepts one of:

* local zip path
  Example: `C:\path\to\package.zip`
* HTTP/HTTPS zip URI
  Example: `https://example.org/package.zip`
* GitHub repo identifier
  Example: `owner/repo`

If omitted, TI reuses the last remembered Internet source.

Notes:

* only Internet-backed sources are remembered
* a local zip source does not replace the remembered Internet source
* GitHub access is anonymous only
* for GitHub, TI uses the latest stable release only
* prereleases are ignored
* if the release contains exactly one zip asset, TI uses it
* if the release contains no zip assets, TI falls back to the release tag source archive
* if a GitHub release contains multiple zip assets, TI fails

### `-TargetPath <path-to-existing-bin-folder>`

Selects an existing target `bin` folder instead of the current one.

### `-Reinstall`

Forces reinstall even if TI believes the installed version/package is already current.

When using the remembered Internet source, `-Reinstall` should reuse the cached zip when appropriate.

### `-ForceRequery`

Bypasses the normal one-hour cooldown and forces TI to requery the Internet-backed source.

### `-Verbose`

Shows detailed operational messages on the console in addition to the detailed log file.

---

## Source behavior

## Local zip source

When `-Source` points to a local zip file:

* TI uses that zip directly
* TI does not update the remembered Internet source
* TI validates, stages, and installs from that zip

## URI source

When `-Source` is an HTTP/HTTPS zip URI:

* TI stores enough metadata to avoid unnecessary re-downloads
* TI only checks for updates once every hour unless `-ForceRequery` is used
* if the server does not provide reliable freshness metadata, TI re-downloads after cooldown
* TI reuses already downloaded cached zip when appropriate

## GitHub source

When `-Source` is `owner/repo`:

* TI queries the latest stable GitHub release
* TI prefers exactly one uploaded zip asset
* if no zip asset exists, TI falls back to the latest release tag source archive
* TI downloads that asset anonymously
* TI stores enough metadata to avoid unnecessary re-downloads
* TI respects the same one-hour cooldown unless `-ForceRequery` is used

## Remembered Internet source

If `-Source` is omitted:

* TI reuses the last successful Internet-backed source
* TI may reuse the already cached zip when appropriate
* local zip installs do not change this remembered source

---

## Package format

A valid TI zip must follow these rules.

### Top-level structure

The zip may contain junk files at top level, but it must contain exactly one top-level folder.

That folder must be named:

`<NAME>-<NUMERICAL_VERSION>`

Example:

`MyTool-3.0.2`

### Package contents

Inside that package folder are the exact files and subfolders that should land under `bin`.

Requirements:

* the package must contain at least one `.ps1` file
* the package must contain `install.ps1`
* all included PowerShell code must be syntax-valid
* there is no manifest file requirement
* the version is taken from the package folder name

### VERSION file

After a successful deployment, TI writes:

`bin\VERSION`

Contents:

* just the version text
* nothing else

TI does not trust `bin\VERSION` alone for update decisions. State, cache, and hashes are authoritative.

---

## Example package layout

```text
MyTool-1.4.0.zip
├─ ignored-file-at-top-level.txt
└─ MyTool-1.4.0
   ├─ install.ps1
   ├─ post-install.ps1
   ├─ tool.ps1
   ├─ MyModule.psm1
   ├─ MyModule.psd1
   └─ lib
      ├─ helper.ps1
      └─ other.ps1
```

The contents under `MyTool-1.4.0` are what get deployed into `bin`.

---

## Validation

Before TI deploys anything into the target `bin`, it validates the staged package.

Validation includes:

* zip is readable
* package structure is valid
* exactly one top-level folder exists
* package folder name matches versioned naming convention
* package contains at least one `.ps1`
* package contains `install.ps1`
* packaged PowerShell code is syntax-valid

Relevant PowerShell artifacts include at least:

* `.ps1`
* `.psm1`
* other PowerShell code files included by the package

If validation fails, the install fails before deployment.

---

## Deployment behavior

TI deploys the staged package into the target `bin`.

Rules:

* TI does not delete extra local files
* TI only replaces a file when content differs
* before replacing an existing differing file, TI creates a backup in `..\temp`

Difference test:

1. compare file sizes
2. if sizes differ, replace
3. if sizes are equal, compare SHA256 hashes
4. replace only if hashes differ

`bin\VERSION` is written near the end, after all non-installer file copies succeed.

`install.ps1` is replaced last.

---

## Backups of replaced files

When TI replaces an existing file in `bin`, it first creates a backup of the existing file under `..\temp`.

Backup format:

```text
..\temp\<ORIGINAL-FILE.EXT>.install.ps1.<YYYY-MM-DD-hh.mm.ss>.bak
```

Example:

```text
..\temp\tool.ps1.install.ps1.2026-03-22-10.14.33.bak
```

Notes:

* only files that are actually being replaced get backups
* backups live in `..\temp`
* cleanup removes backups older than one month

---

## Zip cache

TI keeps the last 4 unique installed zips under `..\temp`.

Cache format:

```text
..\temp\install.ps1-v<VERSION>-<ZIP_HASH>-YYYY-MM-DD-hh.mm.ss.zip
```

Example:

```text
..\temp\install.ps1-v3.0.2-a752f19c-2026-03-22-10.14.33.zip
```

Notes:

* uniqueness is by SHA256 hash
* only the first 8 hex characters are used in names and logs
* TI keeps only the last 4 unique cached zips

---

## State

TI stores its state in:

```text
..\state\install.ps1-state.json
```

The installer creates `..\state` if needed.

This state is used to support:

* remembered Internet source behavior
* requery cooldown
* cached zip reuse
* current/install decision logic
* resilience across runs

TI trusts state, cache, and hashes over `bin\VERSION`.

---

## Logging

TI logs beside the target tree and creates the folders if needed.

### Detailed log

Per-run detailed log:

```text
..\log\install.ps1-detailed-YYYY-MM-DD-hh.mm.ss.log
```

Purpose:

* full operational trace
* useful for diagnosis
* also shown on console with `-Verbose`

### Summary log

Yearly summary log:

```text
..\log\install.ps1-summary-YYYY.log
```

Purpose:

* plain-text install history
* concise successful-install entries
* basic identifiers such as:

  * zip file name
  * URI / source identity
  * version
  * zip hash

---

## Post-install hook

If this file exists after deployment:

```text
bin\post-install.ps1
```

TI executes it.

Rules:

* it runs from the target `bin` folder
* it runs after all file copies succeed, including the final `install.ps1` copy
* it runs before success state and summary log are committed
* if it fails, the installer run fails

Use this hook only for final deployment tasks that must happen after files are in place.

---

## Self-update and handoff

TI supports self-update of the installer itself.

Behavior:

* TI stages and validates the incoming package first
* if the staged package contains a newer or different `install.ps1`, TI prefers to run that staged installer
* the current installer invokes the staged `install.ps1` using internal handoff parameters such as `-InternalStageRun` and `-StageRoot`
* the current installer then terminates
* the staged installer performs the deployment
* if deployment succeeds, the original `bin\install.ps1` is replaced last

This design allows the newer installer logic from the package to perform the real installation while still protecting the current target from premature self-replacement.

---

## Operational folders beside the target tree

TI may create and use these sibling folders relative to the target `bin`:

```text
..\log
..\temp
..\state
```

Typical contents:

* `..\log`
  detailed log and yearly summary log
* `..\temp`
  staged work, cached zips, replaced-file backups
* `..\state`
  installer state JSON

---

## Robustness goals

TI is designed to handle common and boring failures cleanly.

Examples:

* first run
* repeated runs
* concurrent runs
* temporarily unavailable URI or GitHub
* interrupted download
* interrupted extraction
* corrupt zip
* invalid package structure
* syntax-invalid PowerShell files
* remote source cooldown and cache reuse
* preservation of prior good state/cache when a network attempt fails

TI validates as much as possible before deployment and commits success state only after deployment and post-install actions succeed.

---

## Developer how-to

If you want to use TI as the installer for your own PowerShell project:

1. Keep your install target as a folder named `bin`.

2. Build one zip that contains exactly one top-level folder named `<NAME>-<NUMERICAL_VERSION>`.

3. Put inside that folder the exact files and subfolders that should land under `bin`.

4. Include `install.ps1` inside that package folder.

5. Ensure the package contains at least one `.ps1` file and that all included PowerShell code is syntax-valid.

6. Optionally include `post-install.ps1` at the package root if you need a final hook after deployment.

7. Distribute either:

   * the zip file together with `install.ps1`, or
   * just `install.ps1` plus a reachable source via `-Source`

8. To install into the current `bin`, run:

   ```powershell
   .\install.ps1 -Source <zip-or-remote-source>
   ```

9. To install into another existing `bin`, run:

   ```powershell
   .\install.ps1 -TargetPath <path-to-existing-bin> -Source <zip-or-remote-source>
   ```

10. Expect operational artifacts beside that target tree:

    * `..\log`
    * `..\temp`
    * `..\state`

---

## Examples

### Install from a local zip

```powershell
.\install.ps1 -Source 'C:\Releases\MyTool-1.4.0.zip'
```

### Install from a website

```powershell
.\install.ps1 -Source 'https://example.org/releases/MyTool-1.4.0.zip'
```

### Install from GitHub latest stable release

```powershell
.\install.ps1 -Source 'owner/repo'
```

### Reuse the last remembered Internet source

```powershell
.\install.ps1
```

### Reinstall from cached remembered source

```powershell
.\install.ps1 -Reinstall
```

### Install into another existing `bin`

```powershell
.\install.ps1 -TargetPath 'C:\some\dir\mytool\bin' -Source 'owner/repo'
```

### Force a remote requery

```powershell
.\install.ps1 -Source 'owner/repo' -ForceRequery
```

---

## Non-goals

TI does not currently aim to:

* delete extra files from the target `bin`
* provide rollback as a finished feature
* use `bin\VERSION` as the sole source of truth
* support PowerShell 7-only syntax or APIs

---

## Conventions

Hash convention:

* SHA256
* display form uses the first 8 hex characters

Date convention:

* `YYYY-MM-DD`

---

## Project summary

TI is a conservative installer for PowerShell code:

* package once as a zip
* validate before deploy
* stage before touching target
* replace only when different
* back up what you overwrite
* keep a short zip cache
* remember remote source state
* update the installer safely
* run an optional final hook
* log what happened

That makes it a practical fit for PowerShell toolchains that need repeatable installs without introducing a larger packaging system.
