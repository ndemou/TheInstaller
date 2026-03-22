<#
.SYNOPSIS
Installs or updates PowerShell code into the current `bin` folder.

.DESCRIPTION
Resolves a source zip (local file, URI, or GitHub release), stages and validates it,
then performs an internal staged deployment pass to atomically update files.
This script must be run from inside a bin directory. If they don't exist it will
create `..\state`, `..\temp`, `..\log`. If `post-install.ps1` exists in the
target `bin` folder after deployment, it is executed as the final deployment step
before success state and summary are committed.

.PARAMETER Source
Source selector. Supported forms:
- Path to a local zip file
- GitHub repo (`owner/repo`, `github:owner/repo`, `github.com/owner/repo`, or a GitHub URL)
- URL to a zip file

.PARAMETER ForceRequery
Forces fresh source resolution for internet-backed selectors.

.PARAMETER Reinstall
Reinstalls even if the resolved package hash matches installed state.

.PARAMETER TargetPath
Path to an existing target `bin` folder. When used, this script copies itself to that
folder and invokes the target-local `install.ps1` with the same public parameters.

.PARAMETER DevMode
Only useful for development. After extracting the zip to the stage folder, replaces staged 
`install.ps1` with the currently running script before handoff. This allows in-progress 
installer changes to run through the full staged flow during development.

.NOTES
Architecture and execution model:
- Purpose: install/update code into the current `bin` tree safely.
- Modes:
  - outer mode: resolves source, stages zip, validates package, launches internal pass
  - internal mode (`-InternalStageRun`): performs file deployment and final state/summary commit
- Deployment model: staged two-phase handoff so installer self-update is safe.
- Commit point: installer copy is intentionally the final file write in deployment.
- Owned artifacts:
  - state: `state\\install.ps1-state.json`
  - logs: `log\\install.ps1-detailed-*.log`, `log\\install.ps1-summary-YYYY.log`
  - cache/temp: `temp\\install.ps1-v*.zip`, stage/download folders
- Deliberately not done:
  - no rollback transaction across all files
  - no trust in `bin\\VERSION` as install truth; state is authoritative
#>
[CmdletBinding()]
param(
  [string]$Source,
  [switch]$ForceRequery,
  [switch]$Reinstall,
  [string]$TargetPath,
  [switch]$DevMode,

  [Parameter(DontShow = $true)][switch]$InternalStageRun,
  [Parameter(DontShow = $true)][switch]$SkipMutexAcquire,
  [Parameter(DontShow = $true)][string]$StageRoot
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    throw ('Path exists as a file, not a directory: {0}' -f $Path)
  }

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-TextFileUtf8NoBom {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )

  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Read-TextFileUtf8 {
  param([Parameter(Mandatory = $true)][string]$Path)

  $enc = New-Object System.Text.UTF8Encoding($false)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $text = $enc.GetString($bytes)

  if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
    $text = $text.Substring(1)
  }

  $text
}

function Add-TextLineUtf8NoBom {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Line
  )

  $dir = Split-Path -Parent $Path
  if ($dir) {
    Ensure-Directory -Path $dir
  }

  $enc = New-Object System.Text.UTF8Encoding($false)
  $text = $Line + [Environment]::NewLine
  [System.IO.File]::AppendAllText($Path, $text, $enc)
}

function Get-StringSha256Hex {
  param([Parameter(Mandatory = $true)][string]$Text)

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha.ComputeHash($bytes)
    (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
  }
  finally {
    $sha.Dispose()
  }
}

function Get-FileSha256Hex {
  param([Parameter(Mandatory = $true)][string]$Path)
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-ShortHash {
  param([Parameter(Mandatory = $true)][string]$Hash)
  $Hash.Substring(0,8).ToLowerInvariant()
}

function Get-SafeTempLeafName {
  param([Parameter(Mandatory = $true)][string]$Text)
  (($Text -replace '[^\p{L}\p{Nd}\._-]', '_').Trim('_'))
}

function New-AtomicTempPath {
  param([Parameter(Mandatory = $true)][string]$DestinationPath)

  # Temp files intentionally live beside the destination so ACL inheritance matches final writes.
  # The '~TI' prefix is relied on by stale-temp cleanup logic.
  $destFull = [System.IO.Path]::GetFullPath($DestinationPath)
  $destDir = Split-Path -Parent $destFull
  Ensure-Directory -Path $destDir

  $hash8 = Get-ShortHash -Hash (Get-StringSha256Hex -Text $destFull.ToLowerInvariant())
  $guid8 = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
  Join-Path $destDir ('~TI{0}{1}.tmp' -f $hash8, $guid8)
}

function New-InstallBackupPath {
  param(
    [Parameter(Mandatory = $true)][string]$OriginalPath,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  Ensure-Directory -Path $TempDir

  $leaf = [System.IO.Path]::GetFileName($OriginalPath)
  if ([string]::IsNullOrWhiteSpace($leaf)) {
    throw ('Could not determine backup file name from path: {0}' -f $OriginalPath)
  }

  for ($attempt = 0; $attempt -lt 5; $attempt++) {
    $timestamp = Get-Date -Format 'yyyy-MM-dd-HH.mm.ss'
    $backupPath = Join-Path $TempDir ('{0}.install.ps1.{1}.bak' -f $leaf, $timestamp)
    if (-not (Test-Path -LiteralPath $backupPath)) {
      return $backupPath
    }

    Start-Sleep -Milliseconds 1100
  }

  throw ('Could not allocate a unique backup path for {0} in {1}.' -f $OriginalPath, $TempDir)
}

function Write-Log {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
  )

  $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

  $hasDetailedLogPath = $false
  try {
    $hasDetailedLogPath = -not [string]::IsNullOrWhiteSpace($script:DetailedLogPath)
  }
  catch {}

  if ($hasDetailedLogPath) {
    Add-TextLineUtf8NoBom -Path $script:DetailedLogPath -Line $line
  }

  if ($Level -eq 'ERROR') {
    Write-Error -Message $Message -ErrorAction Continue
  }
  elseif ($Level -eq 'WARN') {
    Write-Warning $Message
  }
  else {
    Write-Verbose $line
  }
}

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
    [Parameter(Mandatory = $true)][string]$ActionDescription,
    [int]$MaxAttempts = 6,
    [int]$DelayMilliseconds = 250
  )

  $attempt = 0
  while ($true) {
    $attempt++
    try {
      & $ScriptBlock
      return
    }
    catch {
      if ($attempt -ge $MaxAttempts) {
        throw
      }

      Write-Log -Level WARN -Message ('{0} failed on attempt {1}/{2}: {3}' -f $ActionDescription, $attempt, $MaxAttempts, $_.Exception.Message)
      Start-Sleep -Milliseconds $DelayMilliseconds
    }
  }
}

function Move-FileIntoPlaceAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$TempPath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  # Guarantees on success: destination contains temp content and temp is consumed.
  # Partial effects on failure are acceptable because caller retries and higher-level
  # ordering keeps installer self-update as the final committed file operation.
  Invoke-WithRetry -ActionDescription ('Place file {0}' -f $DestinationPath) -ScriptBlock {
    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
      try {
        [System.IO.File]::Replace($TempPath, $DestinationPath, $null, $false)
      }
      catch [System.ArgumentException] {
        Remove-Item -LiteralPath $DestinationPath -Force
        [System.IO.File]::Move($TempPath, $DestinationPath)
      }
    }
    else {
      [System.IO.File]::Move($TempPath, $DestinationPath)
    }
  }
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  $raw = Read-TextFileUtf8 -Path $Path
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }

  $raw | ConvertFrom-Json
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Object
  )

  $json = $Object | ConvertTo-Json -Depth 12
  $dir = Split-Path -Parent $Path
  Ensure-Directory -Path $dir

  $tempPath = New-AtomicTempPath -DestinationPath $Path
  try {
    Write-TextFileUtf8NoBom -Path $tempPath -Text $json
    Move-FileIntoPlaceAtomic -TempPath $tempPath -DestinationPath $Path
  }
  finally {
    if (Test-Path -LiteralPath $tempPath) {
      try { Remove-Item -LiteralPath $tempPath -Force } catch {}
    }
  }
}

function Normalize-InstallerState {
  param([Parameter(Mandatory = $true)]$State)

  # State schema (SchemaVersion=2):
  # - LastSuccessfulInstall: authoritative installed package/hash/source snapshot
  # - RememberedInternetSource: remembered remote source + cached zip metadata
  # - InternetSourceQueryHistory: recent query attempts used for cooldown/rate safety
  # Compatibility expectation: normalize missing/extra fields without failing installs.
  function Convert-StateScalarToStableString {
    param($Value)

    if ($null -eq $Value) {
      return $null
    }

    if ($Value -is [DateTime]) {
      return $Value.ToUniversalTime().ToString('o')
    }

    [string]$Value
  }

  function Normalize-QueryHistoryEntries {
    param($Entries)

    $normalizedHistory = @()
    foreach ($entry in @($Entries)) {
      if (-not $entry) { continue }
      $normalizedHistory += [ordered]@{
        Kind = Convert-StateScalarToStableString $entry.Kind
        Value = Convert-StateScalarToStableString $entry.Value
        LastAttemptUtc = Convert-StateScalarToStableString $entry.LastAttemptUtc
      }
    }

    @($normalizedHistory)
  }

  function Normalize-RememberedInternetSource {
    param($Source)

    if (-not $Source) {
      return $null
    }

    [ordered]@{
      Kind = Convert-StateScalarToStableString $Source.Kind
      Value = Convert-StateScalarToStableString $Source.Value
      Display = Convert-StateScalarToStableString $Source.Display
      LastCheckedUtc = Convert-StateScalarToStableString $Source.LastCheckedUtc
      Metadata = $Source.Metadata
      CachedZipPath = Convert-StateScalarToStableString $Source.CachedZipPath
      CachedZipHash = Convert-StateScalarToStableString $Source.CachedZipHash
      CachedZipHash8 = Convert-StateScalarToStableString $Source.CachedZipHash8
      CachedPackageVersion = Convert-StateScalarToStableString $Source.CachedPackageVersion
    }
  }

  $lastSuccessfulInstall = $null
  $rememberedInternetSource = $null
  $history = @()

  if ($State -is [System.Collections.IDictionary]) {
    if ($State.Contains('LastSuccessfulInstall')) {
      $lastSuccessfulInstall = $State['LastSuccessfulInstall']
    }
    if ($State.Contains('RememberedInternetSource')) {
      $rememberedInternetSource = Normalize-RememberedInternetSource $State['RememberedInternetSource']
    }
    if ($State.Contains('InternetSourceQueryHistory') -and $State['InternetSourceQueryHistory']) {
      $history = Normalize-QueryHistoryEntries $State['InternetSourceQueryHistory']
    }
  }
  else {
    $lastSuccessfulInstall = $State.LastSuccessfulInstall
    $rememberedInternetSource = Normalize-RememberedInternetSource $State.RememberedInternetSource
    if ($State -and $State.PSObject.Properties.Name -contains 'InternetSourceQueryHistory' -and $State.InternetSourceQueryHistory) {
      $history = Normalize-QueryHistoryEntries $State.InternetSourceQueryHistory
    }
  }

  ([ordered]@{
      SchemaVersion = 2
      LastSuccessfulInstall = $lastSuccessfulInstall
      RememberedInternetSource = $rememberedInternetSource
      InternetSourceQueryHistory = $history
    })
}

function Read-InstallerState {
  param([Parameter(Mandatory = $true)][string]$Path)

  try {
    $state = Read-JsonFile -Path $Path
    if ($state) {
      return (Normalize-InstallerState -State $state)
    }
  }
  catch {
    Write-Log -Level WARN -Message ('State file is unreadable; ignoring it: {0}' -f $_.Exception.Message)
  }

  ([ordered]@{
      SchemaVersion = 2
      LastSuccessfulInstall = $null
      RememberedInternetSource = $null
      InternetSourceQueryHistory = @()
    })
}

function Save-InstallerState {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$State
  )

  $normalized = Normalize-InstallerState -State $State
  Write-JsonFile -Path $Path -Object $normalized
}

function Get-InternetSourceKey {
  param(
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Value
  )

  ('{0}|{1}' -f $Kind.ToLowerInvariant(), $Value.ToLowerInvariant())
}

function Get-InternetSourceQueryEntry {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Value
  )

  $key = Get-InternetSourceKey -Kind $Kind -Value $Value
  foreach ($entry in @($State.InternetSourceQueryHistory)) {
    if ($entry) {
      $entryKey = Get-InternetSourceKey -Kind ([string]$entry.Kind) -Value ([string]$entry.Value)
      if ($entryKey -eq $key) {
        return $entry
      }
    }
  }

  $null
}

function Set-InternetSourceAttemptState {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string]$AttemptUtc
  )

  $key = Get-InternetSourceKey -Kind $Kind -Value $Value
  $history = @()

  foreach ($entry in @($State.InternetSourceQueryHistory)) {
    if (-not $entry) { continue }
    $entryKey = Get-InternetSourceKey -Kind ([string]$entry.Kind) -Value ([string]$entry.Value)
    if ($entryKey -ne $key) {
      $history += [ordered]@{
        Kind = [string]$entry.Kind
        Value = [string]$entry.Value
        LastAttemptUtc = [string]$entry.LastAttemptUtc
      }
    }
  }

  $history += [ordered]@{
    Kind = $Kind
    Value = $Value
    LastAttemptUtc = $AttemptUtc
  }

  if ($history.Count -gt 24) {
    $history = @($history[($history.Count - 24)..($history.Count - 1)])
  }

  ([ordered]@{
      SchemaVersion = 2
      LastSuccessfulInstall = $State.LastSuccessfulInstall
      RememberedInternetSource = $State.RememberedInternetSource
      InternetSourceQueryHistory = $history
    })
}

function Get-TargetBinPath {
  if ($InternalStageRun) {
    return $null
  }

  if (-not [string]::IsNullOrWhiteSpace($TargetPath)) {
    $resolved = [System.IO.Path]::GetFullPath($TargetPath)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
      throw ('-TargetPath must point to an existing directory: {0}' -f $TargetPath)
    }

    $leaf = Split-Path -Leaf $resolved
    if ($leaf -ine 'bin') {
      throw ('-TargetPath must point to an existing folder named "bin": {0}' -f $TargetPath)
    }

    return $resolved
  }

  $cwd = (Get-Location).Path
  $leaf = Split-Path -Leaf $cwd
  if ($leaf -ine 'bin') {
    throw 'This installer must be run from a folder named "bin".'
  }

  ([System.IO.Path]::GetFullPath($cwd))
}

function Get-PublicInvocationArgs {
  param([Parameter(Mandatory = $true)][string]$ResolvedTargetPath)

  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')

  if ([string]::IsNullOrWhiteSpace($ResolvedTargetPath)) {
    throw 'Get-PublicInvocationArgs requires a resolved target path.'
  }

  $args += (Join-Path $ResolvedTargetPath 'install.ps1')

  if ($Source) {
    $args += @('-Source', $Source)
  }

  if ($ForceRequery) {
    $args += '-ForceRequery'
  }

  if ($Reinstall) {
    $args += '-Reinstall'
  }

  if ($DevMode) {
    $args += '-DevMode'
  }

  if ($VerbosePreference -eq 'Continue') {
    $args += '-Verbose'
  }

  $args
}

function New-InstallerRunId {
  (Get-Date -Format 'yyyy-MM-dd-HH.mm.ss')
}

function Get-RunIdFromSourceContextPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    return $null
  }

  try {
    $context = Read-JsonFile -Path $fullPath
    if ($context -and $context.RunId -and (-not [string]::IsNullOrWhiteSpace([string]$context.RunId))) {
      return [string]$context.RunId
    }
  }
  catch {}

  $null
}

function Get-TargetBinPathFromSourceContextPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    return $null
  }

  try {
    $context = Read-JsonFile -Path $fullPath
    if ($context -and $context.TargetBinPath -and (-not [string]::IsNullOrWhiteSpace([string]$context.TargetBinPath))) {
      return [System.IO.Path]::GetFullPath([string]$context.TargetBinPath)
    }
  }
  catch {}

  $null
}

function Get-SourceContextPathForStageRoot {
  param([Parameter(Mandatory = $true)][string]$StageRoot)
  Join-Path ([System.IO.Path]::GetFullPath($StageRoot)) 'install.ps1-source-context.json'
}

function Invoke-TargetPathHandoff {
  param([Parameter(Mandatory = $true)][string]$ResolvedTargetPath)

  if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or (-not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf))) {
    throw '-TargetPath requires a valid current script path ($PSCommandPath) so the installer can copy itself to the target bin folder.'
  }

  $targetInstallerPath = Join-Path $ResolvedTargetPath 'install.ps1'
  if ([System.IO.Path]::GetFullPath($PSCommandPath) -ne [System.IO.Path]::GetFullPath($targetInstallerPath)) {
    Copy-FileAtomic -SourcePath $PSCommandPath -DestinationPath $targetInstallerPath
  }

  $powershellExe = Get-PowerShellHostPath
  $handoffArgs = Get-PublicInvocationArgs -ResolvedTargetPath $ResolvedTargetPath
  $handoffExitCode = 0
  Push-Location -LiteralPath $ResolvedTargetPath
  try {
    & $powershellExe @handoffArgs
    $handoffExitCode = $LASTEXITCODE
  }
  finally {
    Pop-Location
  }

  if ($handoffExitCode -ne 0) {
    throw ('Target-path installer handoff failed with exit code {0}.' -f $handoffExitCode)
  }
}

function Write-StatusLine {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ValidateSet('LightGreen','DarkGray')][string]$Color = 'DarkGray'
  )

  $esc = [char]27
  $colorCode = if ($Color -eq 'LightGreen') { '92' } else { '90' }
  Write-Host ('{0}[{1}m{2}{0}[0m' -f $esc, $colorCode, $Message)
}

function Get-PowerShellHostPath {
  $pwshPath = Join-Path $PSHOME 'pwsh.exe'
  if (Test-Path -LiteralPath $pwshPath -PathType Leaf) {
    return $pwshPath
  }

  $windowsPowerShellPath = Join-Path $PSHOME 'powershell.exe'
  if (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf) {
    return $windowsPowerShellPath
  }

  try {
    $selfPath = (Get-Process -Id $PID -ErrorAction Stop).Path
    if (-not [string]::IsNullOrWhiteSpace($selfPath) -and (Test-Path -LiteralPath $selfPath -PathType Leaf)) {
      return $selfPath
    }
  }
  catch {}

  throw 'Could not determine a PowerShell host executable path.'
}

function Get-InstallDisplayName {
  param($State)

  if ($State -and $State.LastSuccessfulInstall -and $State.LastSuccessfulInstall.PackageName) {
    return [string]$State.LastSuccessfulInstall.PackageName
  }

  'Program'
}

function Get-InstallDisplayVersion {
  param($State)

  if ($State -and $State.LastSuccessfulInstall -and $State.LastSuccessfulInstall.PackageVersion) {
    return [string]$State.LastSuccessfulInstall.PackageVersion
  }

  $null
}

function Invoke-PostInstallScriptIfPresent {
  param([Parameter(Mandatory = $true)][string]$BinPath)

  $postInstallPath = Join-Path $BinPath 'post-install.ps1'
  if (-not (Test-Path -LiteralPath $postInstallPath -PathType Leaf)) {
    return
  }

  $powershellExe = Get-PowerShellHostPath
  $args = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $postInstallPath
  )

  if ($VerbosePreference -eq 'Continue') {
    $args += '-Verbose'
  }

  Write-Log -Message ('Running post-install script: {0}' -f $postInstallPath)

  $exitCode = 0
  Push-Location -LiteralPath $BinPath
  try {
    & $powershellExe @args
    $exitCode = $LASTEXITCODE
  }
  finally {
    Pop-Location
  }

  if ($exitCode -ne 0) {
    throw ('post-install.ps1 failed with exit code {0}.' -f $exitCode)
  }

  Write-Log -Message 'Completed post-install script successfully.'
}

function Initialize-Paths {
  param([Parameter(Mandatory = $true)][string]$BinPath)

  $root = Split-Path -Parent $BinPath

  $script:BinPath = $BinPath
  $script:RootPath = $root
  $script:LogDir = Join-Path $root 'log'
  $script:TempDir = Join-Path $root 'temp'
  $script:StateDir = Join-Path $root 'state'

  Ensure-Directory -Path $script:LogDir
  Ensure-Directory -Path $script:TempDir
  Ensure-Directory -Path $script:StateDir

  if ([string]::IsNullOrWhiteSpace($script:RunId)) {
    $script:RunId = New-InstallerRunId
  }

  $script:DetailedLogPath = Join-Path $script:LogDir ('install.ps1-detailed-{0}.log' -f $script:RunId)
  $script:SummaryLogPath = Join-Path $script:LogDir ('install.ps1-summary-{0}.log' -f (Get-Date -Format 'yyyy'))
  $script:StatePath = Join-Path $script:StateDir 'install.ps1-state.json'
}

function Get-MutexName {
  param([Parameter(Mandatory = $true)][string]$BinPath)
  $hash8 = Get-ShortHash -Hash (Get-StringSha256Hex -Text $BinPath.ToLowerInvariant())
  # Scope lock per target bin tree; independent bins should not block each other.
  # Local\\ is intentional to avoid global-machine lock contention across unrelated installs.
  'Local\install.ps1-{0}' -f $hash8
}

function Enter-InstallMutex {
  param(
    [Parameter(Mandatory = $true)][string]$BinPath,
    [int]$WaitTimeoutSec = 0
  )

  $name = Get-MutexName -BinPath $BinPath
  $mutex = New-Object System.Threading.Mutex($false, $name)
  $acquired = $false

  try {
    if ($WaitTimeoutSec -lt 0) {
      $acquired = $mutex.WaitOne()
    }
    else {
      $acquired = $mutex.WaitOne(([TimeSpan]::FromSeconds($WaitTimeoutSec)), $false)
    }

    if (-not $acquired) {
      throw 'Another install.ps1 instance is already running for this bin folder.'
    }

    $mutex
  }
  catch [System.Threading.AbandonedMutexException] {
    Write-Log -Level WARN -Message 'Recovered an abandoned installer mutex.'
    $mutex
  }
  catch {
    if ($mutex) {
      $mutex.Dispose()
    }
    throw
  }
}

function Exit-InstallMutex {
  param($Mutex)

  if ($Mutex) {
    try { $Mutex.ReleaseMutex() } catch {}
    try { $Mutex.Dispose() } catch {}
  }
}

function Get-WebStatusCodeFromError {
  param([Parameter(Mandatory = $true)]$ErrorRecord)

  if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Response) {
    try {
      return [int]$ErrorRecord.Exception.Response.StatusCode
    }
    catch {}
  }

  $null
}

function Invoke-WebRequestFast {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [string]$Method = 'Get',
    [hashtable]$Headers,
    [string]$OutFile,
    [int]$TimeoutSec = 120
  )

  $oldProgressPreference = $global:ProgressPreference
  $global:ProgressPreference = 'SilentlyContinue'
  try {
    if ($OutFile) {
      Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method $Method -Headers $Headers -OutFile $OutFile -TimeoutSec $TimeoutSec
    }
    else {
      Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method $Method -Headers $Headers -TimeoutSec $TimeoutSec
    }
  }
  finally {
    $global:ProgressPreference = $oldProgressPreference
  }
}

function Test-FileMatchesHash {
  param(
    [string]$Path,
    [string]$ExpectedHash
  )

  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { return $false }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

  try {
    ((Get-FileSha256Hex -Path $Path) -eq $ExpectedHash.ToLowerInvariant())
  }
  catch {
    Write-Log -Level WARN -Message ('Could not hash file {0}: {1}' -f $Path, $_.Exception.Message)
    $false
  }
}

function Test-RememberedCachedZipUsable {
  param($RememberedInternetSource)

  if (-not $RememberedInternetSource) { return $false }
  Test-FileMatchesHash -Path ([string]$RememberedInternetSource.CachedZipPath) -ExpectedHash ([string]$RememberedInternetSource.CachedZipHash)
}

function Test-CanSafelyFallbackToRememberedZip {
  param($RememberedInternetSource)

  if (-not $RememberedInternetSource) { return $false }
  Test-RememberedCachedZipUsable -RememberedInternetSource $RememberedInternetSource
}

function Get-UriFreshnessInfo {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    $PreviousMetadata
  )

  $headers = @{}
  if ($PreviousMetadata) {
    if ($PreviousMetadata.ETag) {
      $headers['If-None-Match'] = [string]$PreviousMetadata.ETag
    }
    elseif ($PreviousMetadata.LastModified) {
      $headers['If-Modified-Since'] = [string]$PreviousMetadata.LastModified
    }
  }

  try {
    $resp = Invoke-WebRequestFast -Uri $Uri -Method Head -Headers $headers
    $etag = $resp.Headers['ETag']
    $lastModified = $resp.Headers['Last-Modified']
    $contentLength = $resp.Headers['Content-Length']

    ([ordered]@{
        QueryUri = $Uri
        NotModified = $false
        HeadSucceeded = $true
        IsReliable = ([bool]$etag -or [bool]$lastModified)
        ETag = $etag
        LastModified = $lastModified
        ContentLength = $contentLength
      })
  }
  catch {
    $code = Get-WebStatusCodeFromError -ErrorRecord $_

    if ($code -eq 304) {
      return ([ordered]@{
          QueryUri = $Uri
          NotModified = $true
          HeadSucceeded = $true
          IsReliable = $true
          ETag = if ($PreviousMetadata) { [string]$PreviousMetadata.ETag } else { $null }
          LastModified = if ($PreviousMetadata) { [string]$PreviousMetadata.LastModified } else { $null }
          ContentLength = if ($PreviousMetadata) { [string]$PreviousMetadata.ContentLength } else { $null }
        })
    }

    if (($code -eq 405) -or ($code -eq 501) -or ($code -eq 403)) {
      Write-Log -Level WARN -Message ('HEAD could not be used reliably for {0}; treating freshness metadata as unreliable.' -f $Uri)
      return ([ordered]@{
          QueryUri = $Uri
          NotModified = $false
          HeadSucceeded = $false
          IsReliable = $false
          ETag = $null
          LastModified = $null
          ContentLength = $null
        })
    }

    throw
  }
}

function Get-GitHubLatestZipAssetInfo {
  param(
    [Parameter(Mandatory = $true)][string]$Repo,
    $PreviousMetadata
  )

  if ($Repo -notmatch '^[^/\s]+/[^/\s]+$') {
    throw '-Source (GitHub) must be in the form "owner/repo".'
  }

  $uri = 'https://api.github.com/repos/{0}/releases/latest' -f $Repo
  $headers = @{
    'User-Agent' = 'install.ps1'
    'Accept'     = 'application/vnd.github+json'
  }

  if ($PreviousMetadata -and $PreviousMetadata.ETag) {
    $headers['If-None-Match'] = [string]$PreviousMetadata.ETag
  }

  try {
    $resp = Invoke-WebRequestFast -Uri $uri -Method Get -Headers $headers
  }
  catch {
    $code = Get-WebStatusCodeFromError -ErrorRecord $_
    if ($code -eq 304) {
      return ([ordered]@{
          Repo = $Repo
          QueryUri = $uri
          NotModified = $true
          ETag = if ($PreviousMetadata) { [string]$PreviousMetadata.ETag } else { $null }
        })
    }
    throw
  }

  $obj = $resp.Content | ConvertFrom-Json

  if ($obj.draft -or $obj.prerelease) {
    throw ('GitHub latest release for {0} is not a stable release.' -f $Repo)
  }

  # Prefer exactly one uploaded zip asset. If there are none, fall back to the
  # GitHub-generated tag source archive for the latest stable release.
  $zipAssets = @($obj.assets | Where-Object { $_.name -match '(?i)\.zip$' })
  if ($zipAssets.Count -gt 1) {
    throw ('GitHub latest stable release for {0} must contain exactly one .zip asset; found {1}.' -f $Repo, $zipAssets.Count)
  }

  $asset = $null
  if ($zipAssets.Count -eq 1) {
    $asset = $zipAssets[0]
  }

  $releaseTag = [string]$obj.tag_name
  $downloadUri = $null
  $assetId = $null
  $assetName = $null
  $assetSize = $null
  $assetUpdatedUtc = $null
  $metadataKey = $null

  if ($asset) {
    $downloadUri = [string]$asset.browser_download_url
    $assetId = [string]$asset.id
    $assetName = [string]$asset.name
    $assetSize = [string]$asset.size
    $assetUpdatedUtc = [string]$asset.updated_at
    $metadataKey = '{0}|{1}|{2}|{3}' -f $obj.id, $asset.id, $asset.updated_at, $asset.size
  }
  else {
    $repoName = ($Repo -split '/')[1]
    $downloadUri = 'https://github.com/{0}/archive/refs/tags/{1}.zip' -f $Repo, $releaseTag
    $assetName = '{0}-{1}-source.zip' -f $repoName, $releaseTag
    $assetUpdatedUtc = [string]$obj.published_at
    $metadataKey = '{0}|source-archive|{1}|{2}' -f $obj.id, $releaseTag, $obj.published_at
  }

  ([ordered]@{
      Repo = $Repo
      QueryUri = $uri
      NotModified = $false
      ETag = $resp.Headers['ETag']
      ReleaseId = [string]$obj.id
      ReleaseTag = $releaseTag
      ReleasePublishedUtc = [string]$obj.published_at
      AssetId = $assetId
      AssetName = $assetName
      AssetSize = $assetSize
      AssetUpdatedUtc = $assetUpdatedUtc
      DownloadUri = $downloadUri
      MetadataKey = $metadataKey
    })
}

function Download-File {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [hashtable]$Headers
  )

  if (Test-Path -LiteralPath $DestinationPath) {
    Remove-Item -LiteralPath $DestinationPath -Force
  }

  try {
    Invoke-WebRequestFast -Uri $Uri -Method Get -Headers $Headers -OutFile $DestinationPath | Out-Null
  }
  catch {
    if (Test-Path -LiteralPath $DestinationPath) {
      try { Remove-Item -LiteralPath $DestinationPath -Force } catch {}
    }
    throw
  }

  if (-not (Test-Path -LiteralPath $DestinationPath)) {
    throw ('Download did not produce a file: {0}' -f $Uri)
  }

  $item = Get-Item -LiteralPath $DestinationPath
  if ($item.Length -le 0) {
    throw ('Downloaded file is empty: {0}' -f $Uri)
  }
}

function Get-NewDownloadPath {
  param([Parameter(Mandatory = $true)][string]$TempDir)
  Join-Path $TempDir ('install.ps1-download-{0}-{1}.zip' -f (Get-Date -Format 'yyyy-MM-dd-HH.mm.ss'), ([guid]::NewGuid().ToString('N').Substring(0,8)))
}

function Get-NewStagePath {
  param([Parameter(Mandatory = $true)][string]$TempDir)
  Join-Path $TempDir ('install.ps1-stage-{0}-{1}' -f (Get-Date -Format 'yyyy-MM-dd-HH.mm.ss'), ([guid]::NewGuid().ToString('N').Substring(0,8)))
}

function Remove-StaleInstallerArtifacts {
  param(
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$BinPath,
    [int]$MaxAgeHours = 48,
    [int]$MaxBackupAgeDays = 30
  )

  # Best-effort hygiene only. Cleanup failures must not block install/update.
  $cutoff = (Get-Date).AddHours(-1 * $MaxAgeHours)
  $backupCutoff = (Get-Date).AddDays(-1 * $MaxBackupAgeDays)

  if (Test-Path -LiteralPath $TempDir -PathType Container) {
    $staleStageDirs = @(Get-ChildItem -LiteralPath $TempDir -Directory -Filter 'install.ps1-stage-*' -ErrorAction SilentlyContinue)
    foreach ($dir in $staleStageDirs) {
      if ($dir.LastWriteTime -lt $cutoff) {
        try {
          Remove-Item -LiteralPath $dir.FullName -Recurse -Force
          Write-Log -Message ('Removed stale stage folder: {0}' -f $dir.FullName)
        }
        catch {
          Write-Log -Level WARN -Message ('Could not remove stale stage folder {0}: {1}' -f $dir.FullName, $_.Exception.Message)
        }
      }
    }

    $staleDownloadZips = @(Get-ChildItem -LiteralPath $TempDir -File -Filter 'install.ps1-download-*.zip' -ErrorAction SilentlyContinue)
    foreach ($file in $staleDownloadZips) {
      if ($file.LastWriteTime -lt $cutoff) {
        try {
          Remove-Item -LiteralPath $file.FullName -Force
          Write-Log -Message ('Removed stale temporary downloaded zip: {0}' -f $file.FullName)
        }
        catch {
          Write-Log -Level WARN -Message ('Could not remove stale temporary downloaded zip {0}: {1}' -f $file.FullName, $_.Exception.Message)
        }
      }
    }

    $staleBackups = @(Get-ChildItem -LiteralPath $TempDir -File -Filter '*.install.ps1.*.bak' -ErrorAction SilentlyContinue)
    foreach ($file in $staleBackups) {
      if ($file.LastWriteTime -lt $backupCutoff) {
        try {
          Remove-Item -LiteralPath $file.FullName -Force
          Write-Log -Message ('Removed old install backup: {0}' -f $file.FullName)
        }
        catch {
          Write-Log -Level WARN -Message ('Could not remove old install backup {0}: {1}' -f $file.FullName, $_.Exception.Message)
        }
      }
    }
  }

  if (Test-Path -LiteralPath $BinPath -PathType Container) {
    $staleBinTemps = @(Get-ChildItem -LiteralPath $BinPath -Recurse -File -Filter '~TI*.tmp' -ErrorAction SilentlyContinue)
    foreach ($file in $staleBinTemps) {
      if ($file.LastWriteTime -lt $cutoff) {
        try {
          Remove-Item -LiteralPath $file.FullName -Force
          Write-Log -Message ('Removed stale atomic temp file from bin tree: {0}' -f $file.FullName)
        }
        catch {
          Write-Log -Level WARN -Message ('Could not remove stale atomic temp file {0}: {1}' -f $file.FullName, $_.Exception.Message)
        }
      }
    }
  }
}

function Compare-UriFreshness {
  param(
    $OldMetadata,
    $NewMetadata
  )

  if (-not $OldMetadata) { return $false }
  if (-not $NewMetadata) { return $false }
  if (-not $OldMetadata.IsReliable) { return $false }
  if (-not $NewMetadata.IsReliable) { return $false }

  if ($OldMetadata.ETag -and $NewMetadata.ETag) {
    return ($OldMetadata.ETag -eq $NewMetadata.ETag)
  }

  if ($OldMetadata.LastModified -and $NewMetadata.LastModified) {
    if ($OldMetadata.ContentLength -and $NewMetadata.ContentLength) {
      return (($OldMetadata.LastModified -eq $NewMetadata.LastModified) -and ($OldMetadata.ContentLength -eq $NewMetadata.ContentLength))
    }
    return ($OldMetadata.LastModified -eq $NewMetadata.LastModified)
  }

  $false
}

function Get-CachedZipByHash {
  param(
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$Hash
  )

  $hash8 = Get-ShortHash -Hash $Hash
  $pattern = 'install.ps1-v*-{0}-*.zip' -f $hash8
  $candidates = @(Get-ChildItem -LiteralPath $TempDir -File -Filter $pattern -ErrorAction SilentlyContinue)

  foreach ($candidate in $candidates) {
    try {
      $candidateHash = Get-FileSha256Hex -Path $candidate.FullName
      if ($candidateHash -eq $Hash) {
        return $candidate.FullName
      }
    }
    catch {
      Write-Log -Level WARN -Message ('Could not hash cached zip {0}: {1}' -f $candidate.FullName, $_.Exception.Message)
    }
  }

  $null
}

function Prune-CachedInstalledZips {
  param([Parameter(Mandatory = $true)][string]$TempDir)

  $files = @(Get-ChildItem -LiteralPath $TempDir -File -Filter 'install.ps1-v*.zip' -ErrorAction SilentlyContinue)
  if ($files.Count -le 0) {
    return
  }

  $entries = @()
  foreach ($file in $files) {
    try {
      $entries += [pscustomobject]@{
        File = $file
        Hash = (Get-FileSha256Hex -Path $file.FullName)
      }
    }
    catch {
      Write-Log -Level WARN -Message ('Could not hash cached zip during prune: {0}' -f $file.FullName)
    }
  }

  if ($entries.Count -le 0) {
    return
  }

  $keepers = @()
  foreach ($group in ($entries | Group-Object -Property Hash)) {
    $ordered = @($group.Group | Sort-Object { $_.File.LastWriteTimeUtc } -Descending)
    $keepers += $ordered[0]
    if ($ordered.Count -gt 1) {
      foreach ($dup in $ordered[1..($ordered.Count - 1)]) {
        try {
          Remove-Item -LiteralPath $dup.File.FullName -Force
          Write-Log -Message ('Removed duplicate cached zip: {0}' -f $dup.File.FullName)
        }
        catch {
          Write-Log -Level WARN -Message ('Could not remove duplicate cached zip {0}: {1}' -f $dup.File.FullName, $_.Exception.Message)
        }
      }
    }
  }

  $keepersOrdered = @($keepers | Sort-Object { $_.File.LastWriteTimeUtc } -Descending)
  if ($keepersOrdered.Count -le 4) {
    return
  }

  foreach ($extra in $keepersOrdered[4..($keepersOrdered.Count - 1)]) {
    try {
      Remove-Item -LiteralPath $extra.File.FullName -Force
      Write-Log -Message ('Pruned old cached zip: {0}' -f $extra.File.FullName)
    }
    catch {
      Write-Log -Level WARN -Message ('Could not prune cached zip {0}: {1}' -f $extra.File.FullName, $_.Exception.Message)
    }
  }
}

function Ensure-CachedInstalledZip {
  param(
    [Parameter(Mandatory = $true)][string]$SourceZipPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$PackageVersion,
    [Parameter(Mandatory = $true)][string]$ZipHash
  )

  $existing = Get-CachedZipByHash -TempDir $TempDir -Hash $ZipHash
  if ($existing) {
    $item = Get-Item -LiteralPath $existing
    $item.LastWriteTime = Get-Date
    return $existing
  }

  $destName = 'install.ps1-v{0}-{1}-{2}.zip' -f $PackageVersion, (Get-ShortHash -Hash $ZipHash), (Get-Date -Format 'yyyy-MM-dd-HH.mm.ss')
  $destPath = Join-Path $TempDir $destName
  $tempPath = New-AtomicTempPath -DestinationPath $destPath

  try {
    Invoke-WithRetry -ActionDescription ('Create cached zip {0}' -f $destPath) -ScriptBlock {
      Copy-Item -LiteralPath $SourceZipPath -Destination $tempPath -Force
    }
    Move-FileIntoPlaceAtomic -TempPath $tempPath -DestinationPath $destPath
    return $destPath
  }
  finally {
    if (Test-Path -LiteralPath $tempPath) {
      try { Remove-Item -LiteralPath $tempPath -Force } catch {}
    }
  }
}

function Get-StableZipPathForState {
  param(
    [string]$PreferredPath,
    [string]$FallbackPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$Hash
  )

  if (Test-FileMatchesHash -Path $PreferredPath -ExpectedHash $Hash) {
    $name = [System.IO.Path]::GetFileName($PreferredPath)
    if ($name -like 'install.ps1-v*.zip') {
      return ([System.IO.Path]::GetFullPath($PreferredPath))
    }
  }

  if (Test-FileMatchesHash -Path $FallbackPath -ExpectedHash $Hash) {
    return ([System.IO.Path]::GetFullPath($FallbackPath))
  }

  $cachePath = Get-CachedZipByHash -TempDir $TempDir -Hash $Hash
  if ($cachePath) {
    return ([System.IO.Path]::GetFullPath($cachePath))
  }

  $null
}

function Get-SourceZipNameForSummary {
  param([Parameter(Mandatory = $true)]$SourceContext)

  if ($SourceContext.SourceKind -eq 'GitHub') {
    if ($SourceContext.RememberedInternetSource -and
        $SourceContext.RememberedInternetSource.Metadata -and
        $SourceContext.RememberedInternetSource.Metadata.AssetName) {
      return [string]$SourceContext.RememberedInternetSource.Metadata.AssetName
    }
  }

  if ($SourceContext.SourceKind -eq 'Uri') {
    if ($SourceContext.SourceValue) {
      try {
        $uri = New-Object System.Uri([string]$SourceContext.SourceValue)
        $leaf = [System.IO.Path]::GetFileName($uri.AbsolutePath)
        if (-not [string]::IsNullOrWhiteSpace($leaf)) {
          return $leaf
        }
      }
      catch {}
    }
  }

  if ($SourceContext.Candidate -and $SourceContext.Candidate.ZipName) {
    return [string]$SourceContext.Candidate.ZipName
  }

  $null
}

function Resolve-SourcePlan {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)][string]$StatePath,
    [string]$Source,
    [switch]$ForceRequery,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  # Intent: classify source and produce a deterministic acquisition plan.
  # Side effects: may update query-attempt state before remote checks.
  # Invariant: local zip sources must not update RememberedInternetSource.
  $script:SourceCheckDisposition = 'Checked'
  $requestedKind = $null
  $requestedValue = $null

  if ($Source) {
    $sourceTrim = ([string]$Source).Trim()
    if ([string]::IsNullOrWhiteSpace($sourceTrim)) {
      throw 'If specified, -Source cannot be empty.'
    }

    if (Test-Path -LiteralPath $sourceTrim) {
      if (-not (Test-Path -LiteralPath $sourceTrim -PathType Leaf)) {
        throw ('Source is not a file: {0}' -f $sourceTrim)
      }

      $resolved = Resolve-Path -LiteralPath $sourceTrim
      $zipPath = $resolved.Path
      $script:SourceCheckDisposition = 'LocalOffline'

      return ([ordered]@{
          ZipPath = $zipPath
          IsTemporaryZip = $false
          StateAfterResolution = $State
          SourceContext = [ordered]@{
            SourceKind = 'Zip'
            SourceValue = $zipPath
            SourceDisplay = $zipPath
            RememberedInternetSource = $null
            Candidate = [ordered]@{
              ZipPath = $zipPath
              ZipName = [System.IO.Path]::GetFileName($zipPath)
              ZipHash = $null
              ZipHash8 = $null
              PackageName = $null
              PackageVersion = $null
            }
          }
        })
    }

    $absoluteUri = $null
    $isHttpUri = [System.Uri]::TryCreate($sourceTrim, [System.UriKind]::Absolute, [ref]$absoluteUri) -and
      (($absoluteUri.Scheme -eq 'http') -or ($absoluteUri.Scheme -eq 'https'))

    if ($isHttpUri) {
      if ($absoluteUri.Host -match '(^|\.)github\.com$') {
        $parts = @($absoluteUri.AbsolutePath.Trim('/') -split '/')
        if ($parts.Count -ge 2 -and $parts[0] -and $parts[1]) {
          $requestedKind = 'GitHub'
          $requestedValue = ('{0}/{1}' -f $parts[0], $parts[1])
        }
      }

      if (-not $requestedKind) {
        $requestedKind = 'Uri'
        $requestedValue = $sourceTrim
      }
    }
    elseif ($sourceTrim -match '^(?i)github:(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)$') {
      $requestedKind = 'GitHub'
      $requestedValue = ('{0}/{1}' -f $Matches['owner'], $Matches['repo'])
    }
    elseif ($sourceTrim -match '^(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)$') {
      $requestedKind = 'GitHub'
      $requestedValue = ('{0}/{1}' -f $Matches['owner'], $Matches['repo'])
    }
    elseif ($sourceTrim -match '^(?i)github\.com/(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)$') {
      $requestedKind = 'GitHub'
      $requestedValue = ('{0}/{1}' -f $Matches['owner'], $Matches['repo'])
    }
    else {
      throw ('Could not determine source type from -Source value: {0}. Use a local zip path, an http(s) zip URL, or a GitHub repo in owner/repo form.' -f $sourceTrim)
    }
  }
  else {
    if (-not $State.RememberedInternetSource) {
      throw 'No source was specified and no remembered Internet source exists.'
    }
    $requestedKind = [string]$State.RememberedInternetSource.Kind
    $requestedValue = [string]$State.RememberedInternetSource.Value
  }

  $prev = $null
  if ($State.RememberedInternetSource) {
    if (($State.RememberedInternetSource.Kind -eq $requestedKind) -and ($State.RememberedInternetSource.Value -eq $requestedValue)) {
      $prev = $State.RememberedInternetSource
    }
  }

  $cooldownActive = $false
  $queryEntry = Get-InternetSourceQueryEntry -State $State -Kind $requestedKind -Value $requestedValue
  if ($queryEntry -and $queryEntry.LastAttemptUtc -and (-not $ForceRequery)) {
    try {
      $age = [DateTime]::UtcNow - ([DateTime]::Parse([string]$queryEntry.LastAttemptUtc).ToUniversalTime())
      if ($age.TotalMinutes -lt 60) {
        $cooldownActive = $true
      }
    }
    catch {}
  }

  # Cooldown applies to query attempts, not only successful queries.
  if ($cooldownActive) {
    if (Test-RememberedCachedZipUsable -RememberedInternetSource $prev) {
      $script:SourceCheckDisposition = 'AlreadyCheckedRecently'
      Write-Log -Message ('Reusing cached zip for {0} during the one-hour cooldown.' -f $requestedValue)

      return ([ordered]@{
          ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
          IsTemporaryZip = $false
          StateAfterResolution = $State
          SourceContext = [ordered]@{
            SourceKind = $requestedKind
            SourceValue = $requestedValue
            SourceDisplay = $(if ($requestedKind -eq 'GitHub') { 'github:{0}' -f $requestedValue } else { $requestedValue })
            RememberedInternetSource = $prev
            Candidate = [ordered]@{
              ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
              ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
              ZipHash = $null
              ZipHash8 = $null
              PackageName = $null
              PackageVersion = $null
            }
          }
        })
    }

    throw ('Remote source {0} was already checked less than one hour ago and no usable cached zip is available. Use -ForceRequery to override.' -f $requestedValue)
  }

  # Record attempt before remote calls so repeated failures are also throttled.
  $stateAfterAttempt = Set-InternetSourceAttemptState -State $State -Kind $requestedKind -Value $requestedValue -AttemptUtc ([DateTime]::UtcNow.ToString('o'))
  Save-InstallerState -Path $StatePath -State $stateAfterAttempt
  $State = $stateAfterAttempt

  if ($requestedKind -eq 'GitHub') {
    Write-Log -Message ('Querying GitHub latest stable release for {0}.' -f $requestedValue)

    $prevMeta = $null
    if ($prev) { $prevMeta = $prev.Metadata }

    try {
      $info = Get-GitHubLatestZipAssetInfo -Repo $requestedValue -PreviousMetadata $prevMeta
    }
    catch {
      if (Test-CanSafelyFallbackToRememberedZip -RememberedInternetSource $prev) {
        Write-Log -Level WARN -Message ('GitHub query failed; reusing previously cached zip for {0}: {1}' -f $requestedValue, $_.Exception.Message)

        return ([ordered]@{
            ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
            IsTemporaryZip = $false
            StateAfterResolution = $State
            SourceContext = [ordered]@{
              SourceKind = 'GitHub'
              SourceValue = $requestedValue
              SourceDisplay = ('github:{0}' -f $requestedValue)
              RememberedInternetSource = $prev
              Candidate = [ordered]@{
                ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
                ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
                ZipHash = $null
                ZipHash8 = $null
                PackageName = $null
                PackageVersion = $null
              }
            }
          })
      }

      throw
    }

    if ($info.NotModified) {
      if (Test-RememberedCachedZipUsable -RememberedInternetSource $prev) {
        Write-Log -Message ('GitHub release metadata returned not modified; reusing cached zip {0}.' -f $prev.CachedZipPath)

        return ([ordered]@{
            ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
            IsTemporaryZip = $false
            StateAfterResolution = $State
            SourceContext = [ordered]@{
              SourceKind = 'GitHub'
              SourceValue = $requestedValue
              SourceDisplay = ('github:{0}' -f $requestedValue)
              RememberedInternetSource = $prev
              Candidate = [ordered]@{
                ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
                ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
                ZipHash = $null
                ZipHash8 = $null
                PackageName = $null
                PackageVersion = $null
              }
            }
          })
      }

      Write-Log -Level WARN -Message 'GitHub returned not modified but the cached zip is missing or does not match its stored hash; querying metadata again without ETag.'
      $info = Get-GitHubLatestZipAssetInfo -Repo $requestedValue -PreviousMetadata $null
    }

    $remember = [ordered]@{
      Kind = 'GitHub'
      Value = $requestedValue
      Display = ('github:{0}' -f $requestedValue)
      LastCheckedUtc = [DateTime]::UtcNow.ToString('o')
      Metadata = [ordered]@{
        QueryUri = $info.QueryUri
        ETag = $info.ETag
        ReleaseId = $info.ReleaseId
        ReleaseTag = $info.ReleaseTag
        ReleasePublishedUtc = $info.ReleasePublishedUtc
        AssetId = $info.AssetId
        AssetName = $info.AssetName
        AssetSize = $info.AssetSize
        AssetUpdatedUtc = $info.AssetUpdatedUtc
        DownloadUri = $info.DownloadUri
        MetadataKey = $info.MetadataKey
      }
      CachedZipPath = $null
      CachedZipHash = $null
      CachedZipHash8 = $null
      CachedPackageVersion = $null
    }

    if ($prev -and $prev.Metadata -and ($prev.Metadata.MetadataKey -eq $info.MetadataKey) -and (Test-RememberedCachedZipUsable -RememberedInternetSource $prev)) {
      Write-Log -Message ('GitHub release asset is unchanged; reusing cached zip {0}.' -f $prev.CachedZipPath)
      $remember.CachedZipPath = [string]$prev.CachedZipPath
      $remember.CachedZipHash = [string]$prev.CachedZipHash
      $remember.CachedZipHash8 = [string]$prev.CachedZipHash8
      $remember.CachedPackageVersion = [string]$prev.CachedPackageVersion

      return ([ordered]@{
          ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
          IsTemporaryZip = $false
          StateAfterResolution = $State
          SourceContext = [ordered]@{
            SourceKind = 'GitHub'
            SourceValue = $requestedValue
            SourceDisplay = ('github:{0}' -f $requestedValue)
            RememberedInternetSource = $remember
            Candidate = [ordered]@{
              ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
              ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
              ZipHash = $null
              ZipHash8 = $null
              PackageName = $null
              PackageVersion = $null
            }
          }
        })
    }

    $downloadPath = Get-NewDownloadPath -TempDir $TempDir
    Write-Log -Message ('Downloading GitHub asset {0}.' -f $info.DownloadUri)
    Download-File -Uri $info.DownloadUri -DestinationPath $downloadPath -Headers @{ 'User-Agent' = 'install.ps1' }

    return ([ordered]@{
        ZipPath = $downloadPath
        IsTemporaryZip = $true
        StateAfterResolution = $State
        SourceContext = [ordered]@{
          SourceKind = 'GitHub'
          SourceValue = $requestedValue
          SourceDisplay = ('github:{0}' -f $requestedValue)
          RememberedInternetSource = $remember
          Candidate = [ordered]@{
            ZipPath = $downloadPath
            ZipName = [System.IO.Path]::GetFileName($downloadPath)
            ZipHash = $null
            ZipHash8 = $null
            PackageName = $null
            PackageVersion = $null
          }
        }
      })
  }

  if ($requestedKind -eq 'Uri') {
    Write-Log -Message ('Querying URI freshness for {0}.' -f $requestedValue)

    $prevMeta = $null
    if ($prev) { $prevMeta = $prev.Metadata }

    try {
      $fresh = Get-UriFreshnessInfo -Uri $requestedValue -PreviousMetadata $prevMeta
    }
    catch {
      if (Test-CanSafelyFallbackToRememberedZip -RememberedInternetSource $prev) {
        Write-Log -Level WARN -Message ('URI freshness query failed; reusing previously cached zip for {0}: {1}' -f $requestedValue, $_.Exception.Message)

        return ([ordered]@{
            ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
            IsTemporaryZip = $false
            StateAfterResolution = $State
            SourceContext = [ordered]@{
              SourceKind = 'Uri'
              SourceValue = $requestedValue
              SourceDisplay = $requestedValue
              RememberedInternetSource = $prev
              Candidate = [ordered]@{
                ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
                ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
                ZipHash = $null
                ZipHash8 = $null
                PackageName = $null
                PackageVersion = $null
              }
            }
          })
      }

      throw
    }

    if ($fresh.NotModified) {
      if (Test-RememberedCachedZipUsable -RememberedInternetSource $prev) {
        Write-Log -Message ('URI source returned not modified; reusing cached zip {0}.' -f $prev.CachedZipPath)

        return ([ordered]@{
            ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
            IsTemporaryZip = $false
            StateAfterResolution = $State
            SourceContext = [ordered]@{
              SourceKind = 'Uri'
              SourceValue = $requestedValue
              SourceDisplay = $requestedValue
              RememberedInternetSource = $prev
              Candidate = [ordered]@{
                ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
                ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
                ZipHash = $null
                ZipHash8 = $null
                PackageName = $null
                PackageVersion = $null
              }
            }
          })
      }

      Write-Log -Level WARN -Message 'URI source returned not modified but the cached zip is missing or does not match its stored hash; querying freshness again without validators.'
      $fresh = Get-UriFreshnessInfo -Uri $requestedValue -PreviousMetadata $null
    }

    $remember = [ordered]@{
      Kind = 'Uri'
      Value = $requestedValue
      Display = $requestedValue
      LastCheckedUtc = [DateTime]::UtcNow.ToString('o')
      Metadata = [ordered]@{
        QueryUri = $fresh.QueryUri
        HeadSucceeded = $fresh.HeadSucceeded
        IsReliable = $fresh.IsReliable
        ETag = $fresh.ETag
        LastModified = $fresh.LastModified
        ContentLength = $fresh.ContentLength
      }
      CachedZipPath = $null
      CachedZipHash = $null
      CachedZipHash8 = $null
      CachedPackageVersion = $null
    }

    if ($fresh.IsReliable -and $prev -and (Compare-UriFreshness -OldMetadata $prev.Metadata -NewMetadata $fresh) -and (Test-RememberedCachedZipUsable -RememberedInternetSource $prev)) {
      Write-Log -Message ('URI freshness metadata is unchanged; reusing cached zip {0}.' -f $prev.CachedZipPath)
      $remember.CachedZipPath = [string]$prev.CachedZipPath
      $remember.CachedZipHash = [string]$prev.CachedZipHash
      $remember.CachedZipHash8 = [string]$prev.CachedZipHash8
      $remember.CachedPackageVersion = [string]$prev.CachedPackageVersion

      return ([ordered]@{
          ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
          IsTemporaryZip = $false
          SourceContext = [ordered]@{
            SourceKind = 'Uri'
            SourceValue = $requestedValue
            SourceDisplay = $requestedValue
            RememberedInternetSource = $remember
            Candidate = [ordered]@{
              ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
              ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
              ZipHash = $null
              ZipHash8 = $null
              PackageName = $null
              PackageVersion = $null
            }
          }
        })
    }

    # Unreliable HEAD/metadata means we cannot safely infer unchanged content.
    # After cooldown, force a re-download instead of trusting validators.
    if (-not $fresh.IsReliable) {
      Write-Log -Message ('URI source has no reliable freshness metadata; re-downloading after cooldown.')
    }

    $downloadPath = Get-NewDownloadPath -TempDir $TempDir
    Write-Log -Message ('Downloading URI source {0}.' -f $requestedValue)
    Download-File -Uri $requestedValue -DestinationPath $downloadPath

    return ([ordered]@{
        ZipPath = $downloadPath
        IsTemporaryZip = $true
        StateAfterResolution = $State
        SourceContext = [ordered]@{
          SourceKind = 'Uri'
          SourceValue = $requestedValue
          SourceDisplay = $requestedValue
          RememberedInternetSource = $remember
          Candidate = [ordered]@{
            ZipPath = $downloadPath
            ZipName = [System.IO.Path]::GetFileName($downloadPath)
            ZipHash = $null
            ZipHash8 = $null
            PackageName = $null
            PackageVersion = $null
          }
        }
      })
  }

  throw ('Unsupported source kind: {0}' -f $requestedKind)
}

function Expand-ZipToStage {
  param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$StageRoot
  )

  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem

  if (Test-Path -LiteralPath $StageRoot) {
    Remove-Item -LiteralPath $StageRoot -Recurse -Force
  }
  Ensure-Directory -Path $StageRoot

  $stageFull = [System.IO.Path]::GetFullPath($StageRoot)
  if (-not $stageFull.EndsWith('\')) {
    $stageFull = $stageFull + '\'
  }

  $archive = $null
  try {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

    foreach ($entry in $archive.Entries) {
      $destPath = Join-Path $StageRoot $entry.FullName
      $fullDestPath = [System.IO.Path]::GetFullPath($destPath)

      if (-not $fullDestPath.StartsWith($stageFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Zip contains an invalid entry path: {0}' -f $entry.FullName)
      }

      if ([string]::IsNullOrEmpty($entry.Name)) {
        Ensure-Directory -Path $fullDestPath
        continue
      }

      Ensure-Directory -Path (Split-Path -Parent $fullDestPath)
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $fullDestPath, $true)
    }
  }
  finally {
    if ($archive) {
      $archive.Dispose()
    }
  }
}

function Get-PowerShellCodeFiles {
  param([Parameter(Mandatory = $true)][string]$PackageRoot)

  $extensions = @('.ps1','.psm1','.psd1','.pssc','.psrc')
  @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() })
}

function Test-PowerShellSyntaxFiles {
  param(
    [Parameter(Mandatory = $true)][string]$PackageRoot
  )

  $codeFiles = Get-PowerShellCodeFiles -PackageRoot $PackageRoot
  $errorsFound = @()

  foreach ($file in $codeFiles) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null

    if ($parseErrors -and $parseErrors.Count -gt 0) {
      foreach ($parseError in $parseErrors) {
        $errorsFound += ('{0}({1},{2}): {3}' -f $file.FullName, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
      }
    }
  }

  ([ordered]@{
      FilesChecked = $codeFiles.Count
      Errors = $errorsFound
    })
}

function Test-StagedPackage {
  param([Parameter(Mandatory = $true)][string]$StageRoot)

  $topDirs = @(Get-ChildItem -LiteralPath $StageRoot -Force | Where-Object { $_.PSIsContainer })
  if ($topDirs.Count -ne 1) {
    throw ('Zip must contain exactly one top-level folder; found {0}.' -f $topDirs.Count)
  }

  $packageRoot = $topDirs[0].FullName
  $folderName = $topDirs[0].Name

  if ($folderName -notmatch '^(?<Name>.+)-(?<Version>\d+(?:\.\d+)*)$') {
    throw ('Top-level folder name must be <NAME>-<NUMERICAL_VERSION>; found "{0}".' -f $folderName)
  }

  $packageName = $Matches['Name']
  $packageVersion = $Matches['Version']

  $ps1Files = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Filter '*.ps1')
  if ($ps1Files.Count -lt 1) {
    throw 'Package must contain at least one .ps1 file.'
  }

  $stagedInstaller = Join-Path $packageRoot 'install.ps1'
  if (-not (Test-Path -LiteralPath $stagedInstaller -PathType Leaf)) {
    throw 'Package must contain install.ps1 at package root.'
  }

  $syntax = Test-PowerShellSyntaxFiles -PackageRoot $packageRoot
  if ($syntax.Errors.Count -gt 0) {
    $msg = "Package contains PowerShell syntax errors:`r`n" + ($syntax.Errors -join "`r`n")
    throw $msg
  }

  ([ordered]@{
      PackageRoot = $packageRoot
      PackageName = $packageName
      PackageVersion = $packageVersion
      InstallerPath = $stagedInstaller
      SyntaxFilesChecked = $syntax.FilesChecked
    })
}

function Test-FilesDifferent {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
    return $true
  }

  $src = Get-Item -LiteralPath $SourcePath
  $dst = Get-Item -LiteralPath $DestinationPath

  if ($src.Length -ne $dst.Length) {
    return $true
  }

  $srcHash = Get-FileSha256Hex -Path $SourcePath
  $dstHash = Get-FileSha256Hex -Path $DestinationPath

  ($srcHash -ne $dstHash)
}

function Copy-FileAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  $destDir = Split-Path -Parent $DestinationPath
  Ensure-Directory -Path $destDir

  $tempPath = New-AtomicTempPath -DestinationPath $DestinationPath
  try {
    Invoke-WithRetry -ActionDescription ('Stage temp file for {0}' -f $DestinationPath) -ScriptBlock {
      Copy-Item -LiteralPath $SourcePath -Destination $tempPath -Force
    }
    Move-FileIntoPlaceAtomic -TempPath $tempPath -DestinationPath $DestinationPath
  }
  finally {
    if (Test-Path -LiteralPath $tempPath) {
      try { Remove-Item -LiteralPath $tempPath -Force } catch {}
    }
  }
}

function Backup-ExistingFileToTemp {
  param(
    [Parameter(Mandatory = $true)][string]$ExistingPath,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  if (-not (Test-Path -LiteralPath $ExistingPath -PathType Leaf)) {
    return $null
  }

  $backupPath = New-InstallBackupPath -OriginalPath $ExistingPath -TempDir $TempDir
  Copy-FileAtomic -SourcePath $ExistingPath -DestinationPath $backupPath
  $backupPath
}

function Write-VersionFile {
  param(
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [Parameter(Mandatory = $true)][string]$Version
  )

  $destDir = Split-Path -Parent $DestinationPath
  Ensure-Directory -Path $destDir

  $tempPath = New-AtomicTempPath -DestinationPath $DestinationPath
  try {
    Write-TextFileUtf8NoBom -Path $tempPath -Text $Version
    Move-FileIntoPlaceAtomic -TempPath $tempPath -DestinationPath $DestinationPath
  }
  finally {
    if (Test-Path -LiteralPath $tempPath) {
      try { Remove-Item -LiteralPath $tempPath -Force } catch {}
    }
  }
}

function Build-StateAfterNoOp {
  param(
    [Parameter(Mandatory = $true)]$OldState,
    [Parameter(Mandatory = $true)]$SourceContext,
    [Parameter(Mandatory = $true)][string]$ZipHash,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  # No-op updates should only refresh remembered-source/cache metadata.
  # LastSuccessfulInstall remains authoritative and unchanged here.
  $remembered = $OldState.RememberedInternetSource

  if ($SourceContext.RememberedInternetSource) {
    $stableZipPath = Get-StableZipPathForState `
      -PreferredPath $SourceContext.Candidate.ZipPath `
      -FallbackPath ([string]$OldState.LastSuccessfulInstall.InstalledZipPath) `
      -TempDir $TempDir `
      -Hash $ZipHash

    if (-not $stableZipPath) {
      $candidateZipPath = $null
      $packageVersion = $null

      if ($SourceContext.Candidate -and $SourceContext.Candidate.ZipPath) {
        $candidateZipPath = [string]$SourceContext.Candidate.ZipPath
      }

      if ($OldState.LastSuccessfulInstall -and $OldState.LastSuccessfulInstall.PackageVersion) {
        $packageVersion = [string]$OldState.LastSuccessfulInstall.PackageVersion
      }

      if ($candidateZipPath -and $packageVersion -and (Test-FileMatchesHash -Path $candidateZipPath -ExpectedHash $ZipHash)) {
        try {
          $stableZipPath = Ensure-CachedInstalledZip `
            -SourceZipPath $candidateZipPath `
            -TempDir $TempDir `
            -PackageVersion $packageVersion `
            -ZipHash $ZipHash

          Prune-CachedInstalledZips -TempDir $TempDir
          Write-Log -Message ('Promoted source zip into cache during no-op state update: {0}' -f $stableZipPath)
        }
        catch {
          Write-Log -Level WARN -Message ('Could not promote source zip into cache during no-op state update: {0}' -f $_.Exception.Message)
        }
      }
    }

    $remembered = [ordered]@{
      Kind = [string]$SourceContext.RememberedInternetSource.Kind
      Value = [string]$SourceContext.RememberedInternetSource.Value
      Display = [string]$SourceContext.RememberedInternetSource.Display
      LastCheckedUtc = [string]$SourceContext.RememberedInternetSource.LastCheckedUtc
      Metadata = $SourceContext.RememberedInternetSource.Metadata
      CachedZipPath = $stableZipPath
      CachedZipHash = if ($stableZipPath) { $ZipHash } else { $null }
      CachedZipHash8 = if ($stableZipPath) { Get-ShortHash -Hash $ZipHash } else { $null }
      CachedPackageVersion = if ($stableZipPath -and $OldState.LastSuccessfulInstall) { [string]$OldState.LastSuccessfulInstall.PackageVersion } else { $null }
    }
  }

  ([ordered]@{
      SchemaVersion = 2
      LastSuccessfulInstall = $OldState.LastSuccessfulInstall
      RememberedInternetSource = $remembered
      InternetSourceQueryHistory = @($OldState.InternetSourceQueryHistory)
    })
}

function Build-StateAfterSuccess {
  param(
    [Parameter(Mandatory = $true)]$OldState,
    [Parameter(Mandatory = $true)]$SourceContext,
    [Parameter(Mandatory = $true)][string]$CacheZipPath,
    [Parameter(Mandatory = $true)][string]$ZipHash,
    [Parameter(Mandatory = $true)][string]$PackageVersion,
    [Parameter(Mandatory = $true)][string]$PackageName
  )

  # This becomes the authoritative installed snapshot for future no-op checks.
  $installed = [ordered]@{
    InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
    PackageName = $PackageName
    PackageVersion = $PackageVersion
    InstalledZipHash = $ZipHash
    InstalledZipHash8 = (Get-ShortHash -Hash $ZipHash)
    InstalledZipPath = $CacheZipPath
    InstalledZipName = [System.IO.Path]::GetFileName($CacheZipPath)
    SourceKind = [string]$SourceContext.SourceKind
    SourceValue = [string]$SourceContext.SourceValue
    SourceDisplay = [string]$SourceContext.SourceDisplay
  }

  $remembered = $OldState.RememberedInternetSource

  if ($SourceContext.RememberedInternetSource) {
    $remembered = [ordered]@{
      Kind = [string]$SourceContext.RememberedInternetSource.Kind
      Value = [string]$SourceContext.RememberedInternetSource.Value
      Display = [string]$SourceContext.RememberedInternetSource.Display
      LastCheckedUtc = [string]$SourceContext.RememberedInternetSource.LastCheckedUtc
      Metadata = $SourceContext.RememberedInternetSource.Metadata
      CachedZipPath = $CacheZipPath
      CachedZipHash = $ZipHash
      CachedZipHash8 = (Get-ShortHash -Hash $ZipHash)
      CachedPackageVersion = $PackageVersion
    }
  }

  ([ordered]@{
      SchemaVersion = 2
      LastSuccessfulInstall = $installed
      RememberedInternetSource = $remembered
      InternetSourceQueryHistory = @($OldState.InternetSourceQueryHistory)
    })
}

function Invoke-StagedDeployment {
  param(
    [Parameter(Mandatory = $true)][string]$BinPath,
    [Parameter(Mandatory = $true)][string]$StageRoot,
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    throw ('Stage root does not exist: {0}' -f $StageRoot)
  }

  $sourceContextPath = Get-SourceContextPathForStageRoot -StageRoot $StageRoot
  $sourceContext = Read-JsonFile -Path $sourceContextPath
  if (-not $sourceContext) {
    throw ('Source context file is missing or invalid: {0}' -f $sourceContextPath)
  }

  $stagedZipPath = $null
  if ($sourceContext.Candidate -and $sourceContext.Candidate.ZipPath) {
    $stagedZipPath = [System.IO.Path]::GetFullPath([string]$sourceContext.Candidate.ZipPath)
  }

  if ([string]::IsNullOrWhiteSpace($stagedZipPath) -or (-not (Test-Path -LiteralPath $stagedZipPath -PathType Leaf))) {
    throw ('Source context does not reference an existing staged zip file: {0}' -f $sourceContextPath)
  }

  # Validate staged content again in internal mode before any bin mutation.
  # Do not move this later in the function.
  $validated = Test-StagedPackage -StageRoot $StageRoot

  $allDirs = @(Get-ChildItem -LiteralPath $validated.PackageRoot -Recurse -Directory | Sort-Object FullName)
  foreach ($dir in $allDirs) {
    $relative = $dir.FullName.Substring($validated.PackageRoot.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relative)) {
      continue
    }
    $destDir = Join-Path $BinPath $relative
    if (-not (Test-Path -LiteralPath $destDir)) {
      Ensure-Directory -Path $destDir
      Write-Log -Message ('Created directory: {0}' -f $relative)
    }
  }

  $filesCopied = 0
  $filesSkipped = 0

  $allFiles = @(Get-ChildItem -LiteralPath $validated.PackageRoot -Recurse -File | Sort-Object FullName)

  foreach ($file in $allFiles) {
    $relative = $file.FullName.Substring($validated.PackageRoot.Length).TrimStart('\')
    if ($relative -ieq 'install.ps1') { continue }
    if ($relative -ieq 'VERSION') { continue }

    $destPath = Join-Path $BinPath $relative
    if (Test-FilesDifferent -SourcePath $file.FullName -DestinationPath $destPath) {
      if (Test-Path -LiteralPath $destPath -PathType Leaf) {
        $backupPath = Backup-ExistingFileToTemp -ExistingPath $destPath -TempDir $TempDir
        Write-Log -Message ('Backed up existing file before replace: {0} -> {1}' -f $relative, $backupPath)
      }

      Copy-FileAtomic -SourcePath $file.FullName -DestinationPath $destPath
      Write-Log -Message ('Copied file: {0}' -f $relative)
      $filesCopied++
    }
    else {
      Write-Log -Message ('Unchanged file: {0}' -f $relative)
      $filesSkipped++
    }
  }

  # VERSION is written near the end; state remains the source of truth.
  $versionPath = Join-Path $BinPath 'VERSION'
  Write-VersionFile -DestinationPath $versionPath -Version $validated.PackageVersion
  Write-Log -Message ('Wrote VERSION file: {0}' -f $validated.PackageVersion)

  $zipHash = [string]$sourceContext.Candidate.ZipHash
  $cacheZipPath = Ensure-CachedInstalledZip -SourceZipPath $stagedZipPath -TempDir $TempDir -PackageVersion $validated.PackageVersion -ZipHash $zipHash
  Write-Log -Message ('Cached installed zip: {0}' -f $cacheZipPath)

  Prune-CachedInstalledZips -TempDir $TempDir

  # Final committed file step: installer copy must remain last among payload writes.
  # Do not move earlier; this protects recovery behavior after mid-flight failures.
  $installerSource = Join-Path $validated.PackageRoot 'install.ps1'
  $installerDest = Join-Path $BinPath 'install.ps1'
  if (Test-FilesDifferent -SourcePath $installerSource -DestinationPath $installerDest) {
    if (Test-Path -LiteralPath $installerDest -PathType Leaf) {
      $installerBackupPath = Backup-ExistingFileToTemp -ExistingPath $installerDest -TempDir $TempDir
      Write-Log -Message ('Backed up existing file before replace: install.ps1 -> {0}' -f $installerBackupPath)
    }

    Copy-FileAtomic -SourcePath $installerSource -DestinationPath $installerDest
    Write-Log -Message 'Copied installer as final committed step: install.ps1'
    $filesCopied++
  }
  else {
    Write-Log -Message 'Installer unchanged; final committed step completed.'
    $filesSkipped++
  }

  Invoke-PostInstallScriptIfPresent -BinPath $BinPath

  $oldState = Read-InstallerState -Path $StatePath
  $newState = Build-StateAfterSuccess `
    -OldState $oldState `
    -SourceContext $sourceContext `
    -CacheZipPath $cacheZipPath `
    -ZipHash $zipHash `
    -PackageVersion $validated.PackageVersion `
    -PackageName $validated.PackageName

  # State and summary are committed only after final file commit succeeds.
  Save-InstallerState -Path $StatePath -State $newState

  $sourceZipName = Get-SourceZipNameForSummary -SourceContext $sourceContext
  $cachedZipName = [System.IO.Path]::GetFileName($cacheZipPath)

  $summary = '{0} | Installed | Version={1} | Package={2} | SourceZipName={3} | CachedZipName={4} | SourceKind={5} | Source={6}' -f `
    (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `
    $validated.PackageVersion, `
    $validated.PackageName, `
    $(if ($sourceZipName) { $sourceZipName } else { '-' }), `
    $cachedZipName, `
    $sourceContext.SourceKind, `
    $sourceContext.SourceDisplay

  if ($sourceContext.SourceKind -eq 'Uri' -and $sourceContext.SourceValue) {
    $summary = $summary + (' | Uri={0}' -f $sourceContext.SourceValue)
  }

  if ($sourceContext.SourceKind -eq 'GitHub' -and $sourceContext.SourceValue) {
    $summary = $summary + (' | GitHub={0}' -f $sourceContext.SourceValue)
    if ($sourceContext.RememberedInternetSource -and
        $sourceContext.RememberedInternetSource.Metadata -and
        $sourceContext.RememberedInternetSource.Metadata.DownloadUri) {
      $summary = $summary + (' | AssetUri={0}' -f $sourceContext.RememberedInternetSource.Metadata.DownloadUri)
    }
    if ($sourceContext.RememberedInternetSource -and
        $sourceContext.RememberedInternetSource.Metadata -and
        $sourceContext.RememberedInternetSource.Metadata.AssetName) {
      $summary = $summary + (' | AssetName={0}' -f $sourceContext.RememberedInternetSource.Metadata.AssetName)
    }
  }

  Add-TextLineUtf8NoBom -Path $script:SummaryLogPath -Line $summary

  Write-StatusLine -Message ('{0} updated to v{1}' -f $validated.PackageName, $validated.PackageVersion) -Color LightGreen

  ([ordered]@{
      PackageVersion = $validated.PackageVersion
      PackageName = $validated.PackageName
      ZipHash = $zipHash
      CacheZipPath = $cacheZipPath
      FilesCopied = $filesCopied
      FilesSkipped = $filesSkipped
    })
}

$mutex = $null
$state = $null
$sourcePlan = $null
$outerStageRoot = $null
$zipPath = $null
$script:DetailedLogPath = $null
$script:SummaryLogPath = $null
$script:RunId = $null
$script:SourceCheckDisposition = 'Checked'

try {
  $targetBin = $null

  if ($InternalStageRun) {
    $sourceContextPath = Get-SourceContextPathForStageRoot -StageRoot $StageRoot
    $targetBin = Get-TargetBinPathFromSourceContextPath -Path $sourceContextPath
    if ([string]::IsNullOrWhiteSpace($targetBin)) {
      throw 'Internal staged execution requires TargetBinPath in the source context.'
    }
  }
  else {
    $targetBin = Get-TargetBinPath
  }

  if ((-not $InternalStageRun) -and (-not [string]::IsNullOrWhiteSpace($TargetPath))) {
    Invoke-TargetPathHandoff -ResolvedTargetPath $targetBin
    return
  }

  if ($InternalStageRun) {
    $sourceContextPath = Get-SourceContextPathForStageRoot -StageRoot $StageRoot
    $script:RunId = Get-RunIdFromSourceContextPath -Path $sourceContextPath
  }

  if ([string]::IsNullOrWhiteSpace($script:RunId)) {
    $script:RunId = New-InstallerRunId
  }

  Initialize-Paths -BinPath $targetBin
  Remove-StaleInstallerArtifacts -TempDir $script:TempDir -BinPath $targetBin

  Write-Log -Message ('Starting install.ps1. InternalStageRun={0}; Bin={1}' -f $InternalStageRun, $targetBin)

  if (-not $SkipMutexAcquire) {
    if ($InternalStageRun) {
      $mutex = Enter-InstallMutex -BinPath $targetBin -WaitTimeoutSec 120
    }
    else {
      $mutex = Enter-InstallMutex -BinPath $targetBin -WaitTimeoutSec 0
    }
    Write-Log -Message ('Acquired installer mutex. InternalStageRun={0}' -f $InternalStageRun)
  }
  else {
    Write-Log -Message ('Skipping mutex acquisition. InternalStageRun={0}' -f $InternalStageRun)
  }

  $state = Read-InstallerState -Path $script:StatePath

  if ($InternalStageRun) {
    Invoke-StagedDeployment `
      -BinPath $targetBin `
      -StageRoot $StageRoot `
      -StatePath $script:StatePath `
      -TempDir $script:TempDir | Out-Null

    return
  }

  $sourcePlan = Resolve-SourcePlan `
    -State $state `
    -StatePath $script:StatePath `
    -Source $Source `
    -ForceRequery:$ForceRequery `
    -TempDir $script:TempDir

  $zipPath = [System.IO.Path]::GetFullPath([string]$sourcePlan.ZipPath)
  if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw ('Resolved zip does not exist: {0}' -f $zipPath)
  }

  $zipHash = Get-FileSha256Hex -Path $zipPath
  $zipHash8 = Get-ShortHash -Hash $zipHash

  $sourcePlan.SourceContext.Candidate.ZipPath = $zipPath
  $sourcePlan.SourceContext.Candidate.ZipName = [System.IO.Path]::GetFileName($zipPath)
  $sourcePlan.SourceContext.Candidate.ZipHash = $zipHash
  $sourcePlan.SourceContext.Candidate.ZipHash8 = $zipHash8
  $sourcePlan.SourceContext.TargetBinPath = $targetBin
  $sourcePlan.SourceContext.RunId = $script:RunId

  Write-Log -Message ('Resolved source zip: {0} (hash {1})' -f $zipPath, $zipHash8)

  if ((-not $Reinstall) -and $state.LastSuccessfulInstall -and ([string]$state.LastSuccessfulInstall.InstalledZipHash -eq $zipHash)) {
    Write-Log -Message ('Zip hash {0} matches installed state; skipping deployment.' -f $zipHash8)

    $latestState = $sourcePlan.StateAfterResolution
    if (-not $latestState) {
      $latestState = Read-InstallerState -Path $script:StatePath
    }
    $newState = Build-StateAfterNoOp `
      -OldState $latestState `
      -SourceContext $sourcePlan.SourceContext `
      -ZipHash $zipHash `
      -TempDir $script:TempDir

    Save-InstallerState -Path $script:StatePath -State $newState

    if ($DevMode) {
      Write-StatusLine -Message ('{0} already at the latest version (v{1})' -f (Get-InstallDisplayName -State $newState), (Get-InstallDisplayVersion -State $newState)) -Color DarkGray
    }
    elseif ($script:SourceCheckDisposition -eq 'LocalOffline') {
      Write-StatusLine -Message 'Not checking for updates (local/offline installation)' -Color DarkGray
    }
    elseif ($script:SourceCheckDisposition -eq 'AlreadyCheckedRecently') {
      Write-StatusLine -Message 'Skipped checking for updates (already checked recently)' -Color DarkGray
    }
    else {
      Write-StatusLine -Message ('{0} already at the latest version (v{1})' -f (Get-InstallDisplayName -State $newState), (Get-InstallDisplayVersion -State $newState)) -Color DarkGray
    }
    return
  }

  $outerStageRoot = Get-NewStagePath -TempDir $script:TempDir
  Write-Log -Message ('Extracting zip to stage: {0}' -f $outerStageRoot)
  Expand-ZipToStage -ZipPath $zipPath -StageRoot $outerStageRoot

  # Validate before handoff so internal run never starts from an unchecked package.
  $validated = Test-StagedPackage -StageRoot $outerStageRoot
  $sourcePlan.SourceContext.Candidate.PackageName = $validated.PackageName
  $sourcePlan.SourceContext.Candidate.PackageVersion = $validated.PackageVersion

  if ($DevMode) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or (-not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf))) {
      throw 'DevMode requires a valid current script path ($PSCommandPath).'
    }

    Write-Log -Message ('DevMode enabled: replacing staged installer with current script: {0}' -f $PSCommandPath)
    Copy-FileAtomic -SourcePath $PSCommandPath -DestinationPath $validated.InstallerPath
  }

  $contextPath = Join-Path $outerStageRoot 'install.ps1-source-context.json'
  Write-JsonFile -Path $contextPath -Object $sourcePlan.SourceContext

  Write-Log -Message ('Staged package validated. Version={0}; Package={1}; SyntaxFilesChecked={2}' -f $validated.PackageVersion, $validated.PackageName, $validated.SyntaxFilesChecked)
  Write-Log -Message 'Preparing staged installer handoff.'

  $powershellExe = Get-PowerShellHostPath
  $handoffInstallerPath = $PSCommandPath
  if ([string]::IsNullOrWhiteSpace($handoffInstallerPath) -or (-not (Test-Path -LiteralPath $handoffInstallerPath -PathType Leaf))) {
    throw 'Could not determine the current installer path for staged handoff.'
  }

  $handoffArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $handoffInstallerPath,
    '-InternalStageRun',
    '-SkipMutexAcquire',
    '-StageRoot', $outerStageRoot
  )
  if ($Reinstall) {
    $handoffArgs += '-Reinstall'
  }
  if ($VerbosePreference -eq 'Continue') {
    $handoffArgs += '-Verbose'
  }

  Write-Log -Message ('Launching staged install with current installer: {0}' -f $handoffInstallerPath)
  & $powershellExe @handoffArgs
  $handoffExitCode = $LASTEXITCODE
  if ($handoffExitCode -ne 0) {
    throw ('Staged installer failed with exit code {0}.' -f $handoffExitCode)
  }

  Write-Log -Message 'Staged installer handoff completed successfully.'
}
catch {
  $msg = $_.Exception.Message
  if ($msg) {
    Write-Log -Level ERROR -Message $msg
  }
  throw
}
finally {
  if ($outerStageRoot -and (Test-Path -LiteralPath $outerStageRoot)) {
    try {
      Remove-Item -LiteralPath $outerStageRoot -Recurse -Force
      Write-Log -Message ('Removed stage folder: {0}' -f $outerStageRoot)
    }
    catch {
      Write-Log -Level WARN -Message ('Could not remove stage folder {0}: {1}' -f $outerStageRoot, $_.Exception.Message)
    }
  }

  if ((-not $InternalStageRun) -and $sourcePlan -and $sourcePlan.IsTemporaryZip -and $zipPath -and (Test-Path -LiteralPath $zipPath)) {
    try {
      Remove-Item -LiteralPath $zipPath -Force
      Write-Log -Message ('Removed temporary downloaded zip: {0}' -f $zipPath)
    }
    catch {
      Write-Log -Level WARN -Message ('Could not remove temporary downloaded zip {0}: {1}' -f $zipPath, $_.Exception.Message)
    }
  }

  Exit-InstallMutex -Mutex $mutex
}
