[CmdletBinding()]
param(
  [switch]$KeepWorkRoot
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:InstallerPath = Join-Path $script:RepoRoot 'install.ps1'
$script:Failures = @()
$script:WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('install.ps1-requirements-tests-{0}' -f [guid]::NewGuid().ToString('N'))

function Get-TestPowerShellHost {
  $candidates = @(
    'powershell.exe',
    'powershell',
    'pwsh.exe',
    'pwsh'
  )

  foreach ($candidate in $candidates) {
    try {
      $command = Get-Command -Name $candidate -ErrorAction Stop
      if ($command -and $command.Source) {
        return $command.Source
      }
    }
    catch {}
  }

  throw 'Could not find a PowerShell host executable for running integration tests.'
}

$script:PowerShellExe = Get-TestPowerShellHost

function Get-OptionalPowerShellHost {
  param([Parameter(Mandatory = $true)][string[]]$Candidates)

  foreach ($candidate in $Candidates) {
    try {
      $command = Get-Command -Name $candidate -ErrorAction Stop
      if ($command -and $command.Source) {
        return $command.Source
      }
    }
    catch {}
  }

  $null
}

$script:PwshExe = Get-OptionalPowerShellHost -Candidates @('pwsh.exe', 'pwsh')

function Fail-Test {
  param([Parameter(Mandatory = $true)][string]$Message)
  throw $Message
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not $Condition) {
    Fail-Test -Message $Message
  }
}

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)]$Actual,
    [Parameter(Mandatory = $true)]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if ($Actual -cne $Expected) {
    Fail-Test -Message ('{0}. Expected: "{1}". Actual: "{2}".' -f $Message, $Expected, $Actual)
  }
}

function Assert-Match {
  param(
    [Parameter(Mandatory = $true)][string]$Actual,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if ($Actual -notmatch $Pattern) {
    Fail-Test -Message ('{0}. Pattern: {1}. Actual: {2}' -f $Message, $Pattern, $Actual)
  }
}

function Assert-NotMatch {
  param(
    [Parameter(Mandatory = $true)][string]$Actual,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if ($Actual -match $Pattern) {
    Fail-Test -Message ('{0}. Pattern: {1}. Actual: {2}' -f $Message, $Pattern, $Actual)
  }
}

function Assert-LineCount {
  param(
    [Parameter(Mandatory = $true)][string]$Actual,
    [Parameter(Mandatory = $true)][int]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $normalized = @((($Actual -split "\r?\n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
  if ($normalized.Count -ne $Expected) {
    Fail-Test -Message ('{0}. Expected lines: "{1}". Actual lines: "{2}". Actual: {3}' -f $Message, $Expected, $normalized.Count, $Actual)
  }
}

function Assert-Exists {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    Fail-Test -Message ('{0}: {1}' -f $Message, $Path)
  }
}

function Assert-NotExists {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (Test-Path -LiteralPath $Path) {
    Fail-Test -Message ('{0}: {1}' -f $Message, $Path)
  }
}

function Assert-NoOperationalArtifacts {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$MessagePrefix
  )

  Assert-NotExists -Path (Join-Path $Root 'log') -Message ('{0} should not create log' -f $MessagePrefix)
  Assert-NotExists -Path (Join-Path $Root 'state') -Message ('{0} should not create state' -f $MessagePrefix)
  Assert-NotExists -Path (Join-Path $Root 'temp') -Message ('{0} should not create temp' -f $MessagePrefix)
}

function Assert-NoInstalledStateArtifacts {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Bin,
    [Parameter(Mandatory = $true)][string]$MessagePrefix
  )

  Assert-NotExists -Path (Join-Path $Root 'state\install.ps1-state.json') -Message ('{0} should not write state file' -f $MessagePrefix)
  Assert-NotExists -Path (Join-Path $Bin 'VERSION') -Message ('{0} should not write VERSION' -f $MessagePrefix)

  $cachedZip = Get-ChildItem -LiteralPath (Join-Path $Root 'temp') -File -Filter 'install.ps1-v*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
  Assert-True -Condition ($null -eq $cachedZip) -Message ('{0} should not cache an installed zip' -f $MessagePrefix)
}

function New-TestDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  $Path
}

function Write-Utf8File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )

  $dir = Split-Path -Parent $Path
  if ($dir) {
    New-TestDirectory -Path $dir | Out-Null
  }

  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Read-JsonObject {
  param([Parameter(Mandatory = $true)][string]$Path)

  [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

function New-TestInstallRoot {
  param([Parameter(Mandatory = $true)][string]$Name)

  $root = Join-Path $script:WorkRoot $Name
  $bin = Join-Path $root 'bin'
  New-TestDirectory -Path $bin | Out-Null
  [pscustomobject]@{
    Root = $root
    Bin  = $bin
  }
}

function New-TestPackageZip {
  param(
    [Parameter(Mandatory = $true)][string]$PackageName,
    [Parameter(Mandatory = $true)][string]$Version,
    [switch]$IncludePostInstall,
    [string]$PostInstallBody,
    [string]$InstallerBody,
    [string]$ToolBody = "Write-Output 'tool ok'",
    [switch]$InvalidSyntax,
    [switch]$MissingInstaller,
    [switch]$MultipleTopLevelFolders,
    [switch]$InvalidTopLevelFolderName,
    [switch]$NoPowerShellFiles
  )

  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem

  $stage = Join-Path $script:WorkRoot ('pkg-{0}' -f [guid]::NewGuid().ToString('N'))
  $folderName = if ($InvalidTopLevelFolderName) { '{0}-v{1}' -f $PackageName, $Version } else { '{0}-{1}' -f $PackageName, $Version }
  $top = Join-Path $stage $folderName
  New-TestDirectory -Path $top | Out-Null

  if (-not $NoPowerShellFiles) {
    Write-Utf8File -Path (Join-Path $top 'tool.ps1') -Text $ToolBody
  }
  Write-Utf8File -Path (Join-Path $top 'lib\helper.psm1') -Text "function Get-Helper { 'helper' }"

  if (-not $MissingInstaller) {
    if ([string]::IsNullOrWhiteSpace($InstallerBody)) {
      Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $top 'install.ps1') -Force
    }
    else {
      Write-Utf8File -Path (Join-Path $top 'install.ps1') -Text $InstallerBody
    }
  }

  if ($IncludePostInstall) {
    $postInstall = if ([string]::IsNullOrWhiteSpace($PostInstallBody)) { @'
$markerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'state\post-install.marker.txt'
[System.IO.File]::WriteAllText($markerPath, 'post-install ran')
'@ } else { $PostInstallBody }
    Write-Utf8File -Path (Join-Path $top 'post-install.ps1') -Text $postInstall
  }

  if ($InvalidSyntax) {
    Write-Utf8File -Path (Join-Path $top 'broken.ps1') -Text 'function Broken-Thing {'
  }

  if ($MultipleTopLevelFolders) {
    $other = Join-Path $stage 'Other-1.0.0'
    New-TestDirectory -Path $other | Out-Null
    Write-Utf8File -Path (Join-Path $other 'install.ps1') -Text "Write-Output 'other'"
    Write-Utf8File -Path (Join-Path $other 'other.ps1') -Text "Write-Output 'other'"
  }

  $zipPath = Join-Path $script:WorkRoot ('{0}-{1}-{2}.zip' -f $PackageName, $Version, ([guid]::NewGuid().ToString('N').Substring(0,8)))
  [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath)
  Remove-Item -LiteralPath $stage -Recurse -Force
  $zipPath
}

function Invoke-Installer {
  param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [string[]]$Arguments = @()
  )

  $output = @()
  $exitCode = 0

  Push-Location -LiteralPath $WorkingDirectory
  try {
    $output = & $script:PowerShellExe '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $InstallerPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    Pop-Location
  }

  [pscustomobject]@{
    ExitCode = $exitCode
    Output   = (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
  }
}

function Invoke-InstallerWithHost {
  param(
    [Parameter(Mandatory = $true)][string]$PowerShellExe,
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [string[]]$Arguments = @()
  )

  $output = @()
  $exitCode = 0

  Push-Location -LiteralPath $WorkingDirectory
  try {
    $output = & $PowerShellExe '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $InstallerPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    Pop-Location
  }

  [pscustomobject]@{
    ExitCode = $exitCode
    Output   = (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
  }
}

function Invoke-TestCase {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Body
  )

  try {
    & $Body
    Write-Host ('[PASS] {0}' -f $Name)
  }
  catch {
    $msg = $_.Exception.Message
    $script:Failures += ('{0}: {1}' -f $Name, $msg)
    Write-Host ('[FAIL] {0}' -f $Name)
    Write-Host ('       {0}' -f $msg)
  }
}

New-TestDirectory -Path $script:WorkRoot | Out-Null

Invoke-TestCase -Name 'Rejects non-bin working directory without TargetPath' -Body {
  $caller = New-TestInstallRoot -Name 'reject-non-bin'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $caller.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '1.0.0'

  $result = Invoke-Installer -InstallerPath (Join-Path $caller.Bin 'install.ps1') -WorkingDirectory $caller.Root -Arguments @('-Source', $zipPath)
  Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Installer should fail when run outside a bin directory without -TargetPath'
  Assert-Match -Actual $result.Output -Pattern 'folder named "bin"' -Message 'Failure should explain the bin-directory requirement'
  Assert-NoOperationalArtifacts -Root $caller.Root -MessagePrefix 'Non-bin rejection'
}

Invoke-TestCase -Name 'Rejects -TargetPath that does not exist' -Body {
  $caller = New-TestInstallRoot -Name 'missing-target-path-caller'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $caller.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '1.0.0'
  $missingTarget = Join-Path $script:WorkRoot 'missing-target\bin'

  $result = Invoke-Installer -InstallerPath (Join-Path $caller.Bin 'install.ps1') -WorkingDirectory $caller.Bin -Arguments @('-TargetPath', $missingTarget, '-Source', $zipPath)
  Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Installer should reject a TargetPath that does not exist'
  Assert-Match -Actual $result.Output -Pattern 'must point to an existing directory' -Message 'Failure should explain that TargetPath must exist'
  Assert-NoOperationalArtifacts -Root $caller.Root -MessagePrefix 'Missing TargetPath rejection'
}

Invoke-TestCase -Name 'Rejects -TargetPath not named bin' -Body {
  $caller = New-TestInstallRoot -Name 'invalid-target-leaf-caller'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $caller.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '1.0.0'
  $targetRoot = Join-Path $script:WorkRoot 'invalid-target-leaf'
  $target = Join-Path $targetRoot 'tools'
  New-TestDirectory -Path $target | Out-Null

  $result = Invoke-Installer -InstallerPath (Join-Path $caller.Bin 'install.ps1') -WorkingDirectory $caller.Bin -Arguments @('-TargetPath', $target, '-Source', $zipPath)
  Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Installer should reject a TargetPath whose leaf is not bin'
  Assert-Match -Actual $result.Output -Pattern 'folder named "bin"' -Message 'Failure should explain the TargetPath bin requirement'
  Assert-NoOperationalArtifacts -Root $caller.Root -MessagePrefix 'Non-bin TargetPath rejection'
  Assert-NoOperationalArtifacts -Root $targetRoot -MessagePrefix 'Rejected target path'
}

Invoke-TestCase -Name 'Installs into TargetPath and creates target-local operational artifacts' -Body {
  $caller = New-TestInstallRoot -Name 'target-caller'
  $target = New-TestInstallRoot -Name 'target-install'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $caller.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '3.0.2' -IncludePostInstall

  $result = Invoke-Installer -InstallerPath (Join-Path $caller.Bin 'install.ps1') -WorkingDirectory $caller.Bin -Arguments @('-TargetPath', $target.Bin, '-Source', $zipPath)
  Assert-Equal -Actual $result.ExitCode -Expected 0 -Message 'TargetPath install should succeed'

  Assert-Exists -Path (Join-Path $target.Root 'log') -Message 'Target log directory should exist'
  Assert-Exists -Path (Join-Path $target.Root 'state') -Message 'Target state directory should exist'
  Assert-Exists -Path (Join-Path $target.Root 'temp') -Message 'Target temp directory should exist'
  Assert-NotExists -Path (Join-Path $caller.Root 'log') -Message 'Caller log directory should not be created for TargetPath installs'
  Assert-NotExists -Path (Join-Path $caller.Root 'state') -Message 'Caller state directory should not be created for TargetPath installs'
  Assert-NotExists -Path (Join-Path $caller.Root 'temp') -Message 'Caller temp directory should not be created for TargetPath installs'

  Assert-Equal -Actual ([System.IO.File]::ReadAllText((Join-Path $target.Bin 'VERSION')).Trim()) -Expected '3.0.2' -Message 'VERSION should contain only the package version'
  Assert-Exists -Path (Join-Path $target.Root 'state\install.ps1-state.json') -Message 'State file should exist'
  Assert-Exists -Path (Join-Path $target.Root 'state\post-install.marker.txt') -Message 'post-install.ps1 should have run'

  $summaryPath = Join-Path $target.Root ('log\install.ps1-summary-{0}.log' -f (Get-Date -Format 'yyyy'))
  Assert-Exists -Path $summaryPath -Message 'Summary log should exist'
  $summary = [System.IO.File]::ReadAllText($summaryPath)
  Assert-Match -Actual $summary -Pattern 'SourceKind=Zip' -Message 'Summary log should record the source kind'

  $cachedZip = Get-ChildItem -LiteralPath (Join-Path $target.Root 'temp') -File -Filter 'install.ps1-v*.zip' | Select-Object -First 1
  Assert-True -Condition ($null -ne $cachedZip) -Message 'Installed zip should be cached in temp'
  Assert-Match -Actual $cachedZip.Name -Pattern '^install\.ps1-v3\.0\.2-[0-9a-f]{8}-\d{4}-\d{2}-\d{2}-\d{2}\.\d{2}\.\d{2}\.zip$' -Message 'Cached zip name should match the required naming pattern'
}

Invoke-TestCase -Name 'TargetPath install works when launched from pwsh' -Body {
  if (-not $script:PwshExe) {
    return
  }

  $caller = New-TestInstallRoot -Name 'target-pwsh-caller'
  $target = New-TestInstallRoot -Name 'target-pwsh-install'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $caller.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '3.0.2'

  $result = Invoke-InstallerWithHost -PowerShellExe $script:PwshExe -InstallerPath (Join-Path $caller.Bin 'install.ps1') -WorkingDirectory $caller.Bin -Arguments @('-TargetPath', $target.Bin, '-Source', $zipPath)
  Assert-Equal -Actual $result.ExitCode -Expected 0 -Message 'TargetPath install from pwsh should succeed'
  Assert-Exists -Path (Join-Path $target.Bin 'VERSION') -Message 'pwsh TargetPath install should complete deployment into target bin'
}

Invoke-TestCase -Name 'Staged deployment uses current installer logic instead of packaged installer logic' -Body {
  $root = New-TestInstallRoot -Name 'stage-host-current'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $legacyInstaller = @'
Write-Output "legacy packaged installer ran"
exit 99
'@
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '3.0.2' -InstallerBody $legacyInstaller -ToolBody "Write-Output 'expected'"

  $result = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $result.ExitCode -Expected 0 -Message 'Install should succeed even if the packaged install.ps1 is not executable as TI''s internal runner'
  Assert-Match -Actual $result.Output -Pattern 'ReqApp updated to v3\.0\.2' -Message 'Install should complete using the current installer logic'
  Assert-Match -Actual ([System.IO.File]::ReadAllText((Join-Path $root.Bin 'install.ps1'))) -Pattern 'legacy packaged installer ran' -Message 'The packaged install.ps1 should still be installed into bin as payload'
  Assert-Match -Actual ([System.IO.File]::ReadAllText((Join-Path $root.Bin 'tool.ps1'))) -Pattern 'expected' -Message 'Payload files should still be deployed normally'
}

Invoke-TestCase -Name 'Reinstall backs up replaced files and keeps extra local files' -Body {
  $root = New-TestInstallRoot -Name 'reinstall-backups'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '3.0.2' -ToolBody "Write-Output 'expected'"

  $first = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $first.ExitCode -Expected 0 -Message 'Initial install should succeed'

  Write-Utf8File -Path (Join-Path $root.Bin 'tool.ps1') -Text "Write-Output 'mutated'"
  Write-Utf8File -Path (Join-Path $root.Bin 'extra.keep.txt') -Text 'keep me'

  $second = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Reinstall', '-Source', $zipPath)
  Assert-Equal -Actual $second.ExitCode -Expected 0 -Message 'Reinstall should succeed'
  Assert-Match -Actual ([System.IO.File]::ReadAllText((Join-Path $root.Bin 'tool.ps1'))) -Pattern 'expected' -Message 'Differing file should be restored from the package'
  Assert-Exists -Path (Join-Path $root.Bin 'extra.keep.txt') -Message 'Extra local files must not be deleted'

  $backup = Get-ChildItem -LiteralPath (Join-Path $root.Root 'temp') -File -Filter 'tool.ps1.install.ps1.*.bak' | Select-Object -First 1
  Assert-True -Condition ($null -ne $backup) -Message 'A backup should be kept for replaced files'
  Assert-Match -Actual ([System.IO.File]::ReadAllText($backup.FullName)) -Pattern 'mutated' -Message 'Backup should contain the pre-reinstall file content'
}

Invoke-TestCase -Name 'Reinstall forces deployment even when zip hash matches' -Body {
  $root = New-TestInstallRoot -Name 'reinstall-force'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $postInstall = @'
$counterPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'state\post-install-count.txt'
$count = 0
if (Test-Path -LiteralPath $counterPath) {
  $count = [int]([System.IO.File]::ReadAllText($counterPath).Trim())
}
[System.IO.File]::WriteAllText($counterPath, [string]($count + 1))
'@
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '3.0.2' -IncludePostInstall -PostInstallBody $postInstall

  $first = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $first.ExitCode -Expected 0 -Message 'Initial install should succeed'
  Assert-Equal -Actual ([System.IO.File]::ReadAllText((Join-Path $root.Root 'state\post-install-count.txt')).Trim()) -Expected '1' -Message 'Initial install should run post-install once'

  $second = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Reinstall', '-Source', $zipPath)
  Assert-Equal -Actual $second.ExitCode -Expected 0 -Message 'Forced reinstall should succeed'
  Assert-NotMatch -Actual $second.Output -Pattern 'Already current' -Message 'Forced reinstall should not no-op on matching zip hash'
  Assert-Equal -Actual ([System.IO.File]::ReadAllText((Join-Path $root.Root 'state\post-install-count.txt')).Trim()) -Expected '2' -Message 'Forced reinstall should rerun post-install even when the zip hash matches'
}

Invoke-TestCase -Name 'State is trusted over VERSION for skip decisions' -Body {
  $root = New-TestInstallRoot -Name 'state-over-version'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '3.0.2'

  $first = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $first.ExitCode -Expected 0 -Message 'Initial install should succeed'
  Assert-Match -Actual $first.Output -Pattern 'ReqApp updated to v3\.0\.2' -Message 'Initial install should report the updated version'

  Write-Utf8File -Path (Join-Path $root.Bin 'VERSION') -Text '0.0.0'
  $second = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $second.ExitCode -Expected 2 -Message 'Local/offline no-op should exit with code 2'
  Assert-Match -Actual $second.Output -Pattern 'Not checking for updates \(local/offline installation\)' -Message 'Local/offline no-op should say that update checking was skipped'
  Assert-LineCount -Actual $second.Output -Expected 1 -Message 'Local/offline no-op should emit one line of output'
  Assert-Equal -Actual ([System.IO.File]::ReadAllText((Join-Path $root.Bin 'VERSION')).Trim()) -Expected '0.0.0' -Message 'VERSION should remain untouched on a no-op, proving state drove the decision'
}

Invoke-TestCase -Name 'DevMode matching hash reports already latest without reinstalling' -Body {
  $root = New-TestInstallRoot -Name 'devmode-noop'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $postInstall = @'
$counterPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'state\post-install-count.txt'
$count = 0
if (Test-Path -LiteralPath $counterPath) {
  $count = [int]([System.IO.File]::ReadAllText($counterPath).Trim())
}
[System.IO.File]::WriteAllText($counterPath, [string]($count + 1))
'@
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '3.0.2' -IncludePostInstall -PostInstallBody $postInstall

  $first = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-DevMode', '-Source', $zipPath)
  Assert-Equal -Actual $first.ExitCode -Expected 0 -Message 'Initial DevMode install should succeed'
  Assert-Equal -Actual ([System.IO.File]::ReadAllText((Join-Path $root.Root 'state\post-install-count.txt')).Trim()) -Expected '1' -Message 'Initial DevMode install should run post-install once'

  $second = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-DevMode', '-Source', $zipPath)
  Assert-Equal -Actual $second.ExitCode -Expected 0 -Message 'Second DevMode install should succeed'
  Assert-Match -Actual $second.Output -Pattern 'ReqApp already at the latest version \(v3\.0\.2\)' -Message 'DevMode no-op should report that the installed version is already current'
  Assert-LineCount -Actual $second.Output -Expected 1 -Message 'DevMode no-op should emit one line of output'
  Assert-Equal -Actual ([System.IO.File]::ReadAllText((Join-Path $root.Root 'state\post-install-count.txt')).Trim()) -Expected '1' -Message 'DevMode no-op should not rerun post-install when the zip hash matches'
}

Invoke-TestCase -Name 'Cooldown no-op reports skipped update check' -Body {
  $root = New-TestInstallRoot -Name 'cooldown-skip'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '3.0.2'

  $first = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $first.ExitCode -Expected 0 -Message 'Initial install should succeed'

  $statePath = Join-Path $root.Root 'state\install.ps1-state.json'
  $state = Read-JsonObject -Path $statePath
  $state.RememberedInternetSource = [ordered]@{
    Kind = 'GitHub'
    Value = 'owner/repo'
    Display = 'github:owner/repo'
    LastCheckedUtc = [DateTime]::UtcNow.ToString('o')
    Metadata = [ordered]@{
      DownloadUri = 'https://example.invalid/fake.zip'
    }
    CachedZipPath = [string]$state.LastSuccessfulInstall.InstalledZipPath
    CachedZipHash = [string]$state.LastSuccessfulInstall.InstalledZipHash
    CachedZipHash8 = [string]$state.LastSuccessfulInstall.InstalledZipHash8
    CachedPackageVersion = [string]$state.LastSuccessfulInstall.PackageVersion
  }
  $state.InternetSourceQueryHistory = @([ordered]@{
      Kind = 'GitHub'
      Value = 'owner/repo'
      LastAttemptUtc = [DateTime]::UtcNow.ToString('o')
    })
  Write-Utf8File -Path $statePath -Text ($state | ConvertTo-Json -Depth 12)

  $second = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @()
  Assert-Equal -Actual $second.ExitCode -Expected 1 -Message 'Cooldown no-op run should exit with code 1'
  Assert-Match -Actual $second.Output -Pattern 'Skipped checking for updates \(already checked recently\)' -Message 'Cooldown no-op should report that the update check was skipped'
  Assert-LineCount -Actual $second.Output -Expected 1 -Message 'Cooldown no-op should emit one line of output'

  $savedState = Read-JsonObject -Path $statePath
  Assert-Equal -Actual (@($savedState.InternetSourceQueryHistory).Count) -Expected 1 -Message 'Cooldown no-op should preserve the remembered query history entry in saved state'
  $savedStateRaw = [System.IO.File]::ReadAllText($statePath)
  Assert-Match -Actual $savedStateRaw -Pattern '"LastAttemptUtc"\s*:\s*"\d{4}-\d{2}-\d{2}T[^"]+Z"' -Message 'Cooldown no-op should persist LastAttemptUtc in round-trippable UTC format'
}

Invoke-TestCase -Name 'Changed zip hash with same version triggers reinstall' -Body {
  $root = New-TestInstallRoot -Name 'same-hash-new'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $zipV1 = New-TestPackageZip -PackageName 'ReqApp' -Version '3.0.2' -ToolBody "Write-Output 'first'"
  $zipV2 = New-TestPackageZip -PackageName 'ReqApp' -Version '3.0.2' -ToolBody "Write-Output 'second'"

  $first = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipV1)
  Assert-Equal -Actual $first.ExitCode -Expected 0 -Message 'Initial install should succeed'
  Assert-Match -Actual ([System.IO.File]::ReadAllText((Join-Path $root.Bin 'tool.ps1'))) -Pattern 'first' -Message 'First package payload should be installed'

  $second = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipV2)
  Assert-Equal -Actual $second.ExitCode -Expected 0 -Message 'Install with changed zip hash should succeed'
  Assert-NotMatch -Actual $second.Output -Pattern 'Already current' -Message 'Different zip hash should not be treated as already current'
  Assert-Match -Actual ([System.IO.File]::ReadAllText((Join-Path $root.Bin 'tool.ps1'))) -Pattern 'second' -Message 'Second package payload should replace the earlier payload'
}

Invoke-TestCase -Name 'Missing state file causes reinstall and state recreation' -Body {
  $root = New-TestInstallRoot -Name 'missing-state-file'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $postInstall = @'
$counterPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'state\post-install-count.txt'
$count = 0
if (Test-Path -LiteralPath $counterPath) {
  $count = [int]([System.IO.File]::ReadAllText($counterPath).Trim())
}
[System.IO.File]::WriteAllText($counterPath, [string]($count + 1))
'@
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '3.0.2' -IncludePostInstall -PostInstallBody $postInstall

  $first = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $first.ExitCode -Expected 0 -Message 'Initial install should succeed'

  Remove-Item -LiteralPath (Join-Path $root.Root 'state\install.ps1-state.json') -Force

  $second = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $second.ExitCode -Expected 0 -Message 'Install should succeed when the state file is missing'
  Assert-NotMatch -Actual $second.Output -Pattern 'Already current' -Message 'Missing state should prevent a no-op skip'
  Assert-Exists -Path (Join-Path $root.Root 'state\install.ps1-state.json') -Message 'State file should be recreated after reinstall'
  Assert-Equal -Actual ([System.IO.File]::ReadAllText((Join-Path $root.Root 'state\post-install-count.txt')).Trim()) -Expected '2' -Message 'Missing state should cause deployment to run again'
}

Invoke-TestCase -Name 'Unreadable state file is ignored and rewritten' -Body {
  $root = New-TestInstallRoot -Name 'corrupt-state-file'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $postInstall = @'
$counterPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'state\post-install-count.txt'
$count = 0
if (Test-Path -LiteralPath $counterPath) {
  $count = [int]([System.IO.File]::ReadAllText($counterPath).Trim())
}
[System.IO.File]::WriteAllText($counterPath, [string]($count + 1))
'@
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '3.0.2' -IncludePostInstall -PostInstallBody $postInstall

  $first = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $first.ExitCode -Expected 0 -Message 'Initial install should succeed'

  Write-Utf8File -Path (Join-Path $root.Root 'state\install.ps1-state.json') -Text '{"broken": '

  $second = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $second.ExitCode -Expected 0 -Message 'Install should succeed when the state file is unreadable'
  Assert-Match -Actual $second.Output -Pattern 'State file is unreadable; ignoring it' -Message 'Unreadable state should produce a warning'
  Assert-NotMatch -Actual $second.Output -Pattern 'Already current' -Message 'Unreadable state should prevent a no-op skip'
  Assert-Equal -Actual ([System.IO.File]::ReadAllText((Join-Path $root.Root 'state\post-install-count.txt')).Trim()) -Expected '2' -Message 'Unreadable state should cause deployment to run again'

  $state = Read-JsonObject -Path (Join-Path $root.Root 'state\install.ps1-state.json')
  Assert-Equal -Actual ([string]$state.SchemaVersion) -Expected '2' -Message 'Unreadable state should be rewritten with the normalized schema version'
  Assert-True -Condition ($null -ne $state.LastSuccessfulInstall) -Message 'Rewritten state should restore the last successful install snapshot'
}

Invoke-TestCase -Name 'Rejects invalid package structure' -Body {
  $root = New-TestInstallRoot -Name 'invalid-structure'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '1.0.0' -MultipleTopLevelFolders

  $result = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $result.ExitCode -Expected 3 -Message 'Invalid package structure should exit with internal-error code 3'
  Assert-Match -Actual $result.Output -Pattern 'exactly one top-level folder' -Message 'Failure should mention the top-level folder rule'
  Assert-NoInstalledStateArtifacts -Root $root.Root -Bin $root.Bin -MessagePrefix 'Invalid package structure rejection'
}

Invoke-TestCase -Name 'Rejects invalid top-level package folder name' -Body {
  $root = New-TestInstallRoot -Name 'invalid-folder-name'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '1.0.0' -InvalidTopLevelFolderName

  $result = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Installer should reject a package whose top-level folder does not end with a numeric version'
  Assert-Match -Actual $result.Output -Pattern 'Top-level folder name must be <NAME>-<NUMERICAL_VERSION>' -Message 'Failure should explain the required top-level folder naming convention'
  Assert-NoInstalledStateArtifacts -Root $root.Root -Bin $root.Bin -MessagePrefix 'Invalid folder name rejection'
}

Invoke-TestCase -Name 'Rejects package missing install.ps1' -Body {
  $root = New-TestInstallRoot -Name 'missing-installer'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '1.0.0' -MissingInstaller

  $result = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Installer should reject a package missing install.ps1'
  Assert-Match -Actual $result.Output -Pattern 'Package must contain install\.ps1' -Message 'Failure should mention missing install.ps1'
  Assert-NoInstalledStateArtifacts -Root $root.Root -Bin $root.Bin -MessagePrefix 'Missing install.ps1 rejection'
}

Invoke-TestCase -Name 'Rejects syntax-invalid PowerShell package content' -Body {
  $root = New-TestInstallRoot -Name 'syntax-invalid'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '1.0.0' -InvalidSyntax

  $result = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Installer should reject syntax-invalid packages'
  Assert-Match -Actual $result.Output -Pattern 'syntax errors' -Message 'Failure should mention syntax validation'
  Assert-Match -Actual $result.Output -Pattern 'broken\.ps1\(\d+,\d+\)' -Message 'Failure should identify the syntax-invalid file and location'
  Assert-NoInstalledStateArtifacts -Root $root.Root -Bin $root.Bin -MessagePrefix 'Syntax validation rejection'
}

Invoke-TestCase -Name 'Failing post-install stops success state from being recorded' -Body {
  $root = New-TestInstallRoot -Name 'postfail'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $postInstall = @'
Write-Error 'post install broke'
exit 7
'@
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '1.0.0' -IncludePostInstall -PostInstallBody $postInstall

  $result = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $result.ExitCode -Expected 11 -Message 'Post-install exit code 7 should map to installer exit code 11'
  Assert-Match -Actual $result.Output -Pattern 'post-install\.ps1 failed with exit code 7' -Message 'Failure should report the post-install exit code'
  Assert-Exists -Path (Join-Path $root.Bin 'VERSION') -Message 'VERSION is written before post-install executes'
  Assert-NotExists -Path (Join-Path $root.Root 'state\install.ps1-state.json') -Message 'Failed post-install should not record a successful install state'
}

Invoke-TestCase -Name 'Long stage path succeeds with short atomic temp names' -Body {
  $root = New-TestInstallRoot -Name 'long-stage-path-regression-case-aaaaaaaaaaaa'
  Copy-Item -LiteralPath $script:InstallerPath -Destination (Join-Path $root.Bin 'install.ps1') -Force
  $zipPath = New-TestPackageZip -PackageName 'ReqApp' -Version '1.0.0'

  $result = Invoke-Installer -InstallerPath (Join-Path $root.Bin 'install.ps1') -WorkingDirectory $root.Bin -Arguments @('-Source', $zipPath)
  Assert-Equal -Actual $result.ExitCode -Expected 0 -Message 'Long stage paths should succeed with short atomic temp names'
  Assert-Exists -Path (Join-Path $root.Bin 'VERSION') -Message 'Long-path install should complete and write VERSION'
  Assert-Exists -Path (Join-Path $root.Root 'state\install.ps1-state.json') -Message 'Long-path install should record successful state'
  Assert-Match -Actual $result.Output -Pattern 'ReqApp updated to v1\.0\.0' -Message 'Long-path install should complete normal deployment with the concise status line'
  Assert-LineCount -Actual $result.Output -Expected 1 -Message 'Long-path install should emit one line of output'
}

if ($script:Failures.Count -gt 0) {
  Write-Host ''
  Write-Host 'Failures:'
  foreach ($failure in $script:Failures) {
    Write-Host ('- {0}' -f $failure)
  }

  if (-not $KeepWorkRoot) {
    try { Remove-Item -LiteralPath $script:WorkRoot -Recurse -Force } catch {}
  }

  exit 1
}

Write-Host ''
Write-Host 'All local requirement tests passed.'
Write-Host ('Work root: {0}' -f $script:WorkRoot)
Write-Host 'Note: this suite intentionally focuses on local/offline requirements. Live GitHub-source behavior still needs a separate integration test because it depends on external GitHub API responses.'

if (-not $KeepWorkRoot) {
  try { Remove-Item -LiteralPath $script:WorkRoot -Recurse -Force } catch {}
}
