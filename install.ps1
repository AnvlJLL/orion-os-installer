# Windows PowerShell 5.1; also supports: irm <url> | iex
[CmdletBinding()]
param([switch]$DryRun, [switch]$Check)

$localScript = $null
if ($MyInvocation.MyCommand.Name -eq 'install.ps1') { $localScript = $MyInvocation.MyCommand.Path }
# Return the status by reference so the caller does not capture interactive stdout.
$code = 1
& {
param([ref]$Result)
$ErrorActionPreference = 'Stop'
$DryRun = $DryRun -or $env:ORION_INSTALLER_DRY_RUN -eq '1'
$Check = $Check -or $env:ORION_INSTALLER_CHECK -eq '1'
$script:LogPath = Join-Path $HOME 'orion-installer.log'
$script:Logging = $false
$script:ExitCode = 1
$script:FailedStep = 'Read installer configuration'
$script:NextAction = 'Download a fresh copy of the installer and try again.'
$script:Report = New-Object System.Collections.Generic.List[string]
$script:AllGood = $true

function Protect-Text([string]$Text) {
    # Do not record credentials printed by a child process or a configured URL.
    if ($env:ORION_OS_UPDATE_TOKEN) { $Text = $Text.Replace($env:ORION_OS_UPDATE_TOKEN, '[REDACTED]') }
    $Text = $Text -replace '(https?://)[^/\s@]+@', '$1[REDACTED]@'
    $Text = $Text -replace '(?i)(authorization\s*[:=]\s*|bearer\s+|(?:token|password|api[_-]?key)\s*[:=]\s*)\S+', '$1[REDACTED]'
    $Text = $Text -replace '(gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+)', '[REDACTED]'
    return $Text
}
function Say([string]$Text) {
    $safe = Protect-Text $Text
    Write-Host $safe
    if ($script:Logging) {
        try { Add-Content -LiteralPath $script:LogPath -Value $safe -Encoding UTF8 }
        catch { $script:Logging = $false; Write-Host 'Log could not be written; check home-directory permissions.' }
    }
    else { $script:Report.Add($safe) }
}
function Mark([bool]$OK, [string]$Text) {
    if ($OK) { Say ("{0} {1}" -f [char]0x2713, $Text) }
    else { Say ("{0} {1}" -f [char]0x2717, $Text); $script:AllGood = $false }
}
function Note([string]$Text) { Say ("{0} {1}" -f [char]0x2192, $Text) }
function Fail([string]$Step, [string]$Reason, [string]$Next, [int]$Code = 1) {
    $script:FailedStep = $Step; $script:NextAction = $Next; $script:ExitCode = $Code
    throw $Reason
}
function Has([string]$Name) { return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }
function Probe([string]$Exe, [string[]]$Arguments) {
    try {
        $global:LASTEXITCODE = 0
        $result = & $Exe @Arguments 2>$null
        if ($LASTEXITCODE -eq 0) { return (($result | Out-String).Trim()) }
    } catch { }
    return ''
}
function Ask([string]$Question) {
    if ($env:ORION_INSTALLER_YES -eq '1') { return $true }
    Write-Host "$Question " -NoNewline
    if ($script:Logging) { Add-Content -LiteralPath $script:LogPath -Value $Question -Encoding UTF8 }
    # Read the console even when the installer text came from a pipeline.
    $answer = [Console]::ReadLine()
    if ($null -eq $answer) { Fail 'Read consent' 'No console answer was available.' 'Run in an interactive PowerShell window, or set ORION_INSTALLER_YES=1.' }
    return ($answer.Trim() -eq '' -or $answer.Trim() -match '^(?i)y(es)?$')
}
function Refresh-Path {
    # Standard winget/official-installer locations, in case the registry PATH lags behind.
    $known = @((Join-Path $env:ProgramFiles 'Git\cmd'), (Join-Path $env:ProgramFiles 'nodejs'), (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd'), (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')) | Where-Object { Test-Path -LiteralPath $_ }
    $env:PATH = (@([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'), (Join-Path $HOME '.local\bin')) + @($known) + @($env:PATH)) -join ';'
}
function Run([string]$Exe, [string[]]$Arguments, [string]$Step, [string]$Next) {
    $script:FailedStep = $Step; $script:NextAction = $Next
    $null = Get-Command $Exe -ErrorAction Stop
    Note $Step
    $global:LASTEXITCODE = 0
    # PS 5.1 represents native stderr as ErrorRecord; capture it without aborting
    # before the native exit code can be inspected.
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @Arguments 2>&1 | ForEach-Object { Say "$_" }; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $saved }
    if ($code -ne 0) { Fail $Step 'The command could not complete; access, connectivity, or a dependency may be missing.' $Next $code }
}
function RunInteractive([string]$Exe, [string[]]$Arguments, [string]$Step, [string]$Next) {
    $script:FailedStep = $Step; $script:NextAction = $Next
    $null = Get-Command $Exe -ErrorAction Stop
    if ($script:Logging) { Add-Content -LiteralPath $script:LogPath -Value (Protect-Text "$Step started") -Encoding UTF8 }
    $global:LASTEXITCODE = 0
    & $Exe @Arguments
    $commandCode = $LASTEXITCODE
    if ($script:Logging) { Add-Content -LiteralPath $script:LogPath -Value (Protect-Text "$Step finished, exit code $commandCode") -Encoding UTF8 }
    if ($commandCode -ne 0) { Fail $Step 'The command could not complete; access, connectivity, or a dependency may be missing.' $Next $commandCode }
}
function Find-Python {
    if (Has 'uv') {
        $found = Probe 'uv' @('python', 'find', '--no-python-downloads', '3.10')
        if ($found) { return $found }
        $found = Probe 'uv' @('python', 'find', '--no-python-downloads', '>=3.10')
        if ($found) { return $found }
    }
    foreach ($name in @('python', 'python3', 'py')) {
        if (Has $name) {
            # Windows Store execution aliases can open the Store during a probe.
            if ((Get-Command $name).Source -like '*\Microsoft\WindowsApps\*') { continue }
            $argsForPython = @('-c', 'import sys; print(sys.version.split()[0]); sys.exit(0 if sys.version_info >= (3,10) else 1)')
            if ($name -eq 'py') { $argsForPython = @('-3') + $argsForPython }
            $version = Probe $name $argsForPython
            if ($version) { return "$name $version" }
        }
    }
    return ''
}
function Find-GitBash {
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCommand) { return $null }
    $parent = Split-Path $gitCommand.Source -Parent
    # Git may live in cmd/, bin/, or mingw64/bin/. Never select WSL bash from PATH.
    for ($i = 0; $i -lt 4 -and $parent; $i++) {
        foreach ($relative in @('bin\bash.exe', 'usr\bin\bash.exe')) {
            $candidate = Join-Path $parent $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
        $parent = Split-Path $parent -Parent
    }
    return $null
}
function Package([string]$ID, [bool]$UserScope = $false, [bool]$Upgrade = $false) {
    $verb = 'install'; if ($Upgrade) { $verb = 'upgrade' }
    $packageArgs = @($verb, '--id', $ID, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    if ($UserScope) { $packageArgs += @('--scope', 'user') }
    else { Note "$ID may ask for Windows administrator permission through winget." }
    Run 'winget' $packageArgs "Install $ID" "Run winget $verb --id $ID in PowerShell, then rerun this installer."
    Refresh-Path
}

try {
    # Product identity lives here only as the offline fallback, mirroring installer.json.
    $defaults = '{"product_name":"Orion-OS","repo_url":"https://github.com/AnvlJLL/orion-os.git","ref":"main","install_dir_name":"orion-os","profile":"default","layers":[]}'
    $json = $null
    # IEX can inherit its caller's MyInvocation; do not read that caller's config.
    if ($localScript) {
        $configPath = Join-Path (Split-Path $localScript -Parent) 'installer.json'
        if (Test-Path -LiteralPath $configPath) { $json = Get-Content -LiteralPath $configPath -Raw }
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not $json -and $env:ORION_INSTALLER_BASE_URL) {
        try { $json = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri ($env:ORION_INSTALLER_BASE_URL.TrimEnd('/') + '/installer.json')).Content }
        catch { $json = $null }
    }
    if (-not $json) { Note 'installer.json unavailable; using embedded defaults.'; $json = $defaults }
    $config = $json | ConvertFrom-Json
    foreach ($key in @('product_name', 'repo_url', 'ref', 'install_dir_name', 'profile')) {
        if (-not ($config.$key -is [string]) -or [string]::IsNullOrWhiteSpace($config.$key) -or $config.$key -match '[\r\n]') { throw "Invalid configuration field: $key." }
    }
    if (-not ($config.layers -is [array])) { throw 'Configuration layers must be an array.' }
    if ($config.install_dir_name -match '[/\\]' -or $config.install_dir_name -in @('.', '..')) { throw 'install_dir_name must be a directory name.' }
    $repoURI = [uri]$config.repo_url
    if ($repoURI.Scheme -ne 'https' -or $repoURI.UserInfo -or $repoURI.Query -or $repoURI.Fragment) { throw 'repo_url must be an HTTPS URL without credentials or query parameters.' }
    if ($config.ref.StartsWith('-')) { throw 'Invalid repository ref.' }
    # profile/layers are retained in config; post-clone setup owns their use.
    $installDir = Join-Path $HOME $config.install_dir_name
    if ($env:ORION_INSTALL_DIR) { $installDir = [IO.Path]::GetFullPath($env:ORION_INSTALL_DIR) }
    Note ("{0} installer - {1}" -f $config.product_name, $config.ref)
    $isWindows = $env:OS -eq 'Windows_NT'
    Mark $isWindows ("OS: Windows {0}" -f [Environment]::OSVersion.Version)
    $online = $false
    try { $null = Invoke-WebRequest -UseBasicParsing -Method Head -TimeoutSec 8 -Uri 'https://github.com'; $online = $true } catch { }
    Mark $online 'Internet: github.com'
    $winget = Has 'winget'; Mark $winget 'Package manager: winget'
    $git = [bool](Probe 'git' @('--version')); Mark $git 'git'
    $nodeVersion = Probe 'node' @('--version')
    $nodeOK = $nodeVersion -match '^v?(\d+)\.' -and [int]$Matches[1] -ge 20
    Mark $nodeOK "Node (20 or newer): $nodeVersion"
    $uv = [bool](Probe 'uv' @('--version')); Mark $uv 'uv'
    $python = Find-Python; Mark ([bool]$python) "Python (3.10 or newer): $python"
    $claude = [bool](Probe 'claude' @('--version')); Mark $claude 'Claude Code'
    $diskOK = $false
    try { $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($installDir)); $diskOK = $drive.AvailableFreeSpace -ge 2GB } catch { }
    Mark $diskOK 'Free disk space: at least 2 GB'
    $exists = Test-Path -LiteralPath $installDir
    $reuse = $false
    if ($exists -and $git -and (Test-Path -LiteralPath (Join-Path $installDir '.git'))) {
        $origin = Probe 'git' @('-C', $installDir, 'remote', 'get-url', 'origin')
        $reuse = $origin.TrimEnd('/') -ceq $config.repo_url.TrimEnd('/')
    }
    $directoryOK = -not $exists -or $reuse
    if ($reuse) { Mark $true "Install directory: matching clone, will resume at $installDir" }
    elseif ($exists) { Mark $false "Install directory: already exists and is not a matching clone: $installDir" }
    else { Mark $true "Install directory: available at $installDir" }
    $missing = @()
    if (-not $git) { $missing += 'Git' }; if (-not $nodeOK) { $missing += 'Node' }
    if (-not $uv) { $missing += 'uv' }; if (-not $python) { $missing += 'Python 3.12 (side by side)' }
    if (-not $claude) { $missing += 'Claude Code' }
    $list = 'nothing'; if ($missing.Count) { $list = $missing -join ', ' }
    Say "I will install: $list. Nothing else on your computer will change."
    if ($Check) { if ($script:AllGood) { $Result.Value = 0 }; return }
    if ($DryRun) {
        if (-not $directoryOK) { Note 'Blocked: choose an empty install directory; no commands will run.' }
        if (-not $winget -and (-not $git -or -not $nodeOK -or -not $uv)) { Note 'Blocked: install App Installer (winget) from Microsoft Store.' }
        foreach ($entry in @(@('Git.Git', $git), @('OpenJS.NodeJS.LTS', $nodeOK), @('astral-sh.uv', $uv))) {
            if (-not $entry[1]) {
                $verb = 'install'; if ($entry[0] -eq 'OpenJS.NodeJS.LTS' -and $nodeVersion) { Note 'Ask permission before upgrading existing Node.'; $verb = 'upgrade' }
                $scope = ''; if ($entry[0] -in @('Git.Git', 'astral-sh.uv')) { $scope = ' --scope user' }
                Note "winget $verb --id $($entry[0]) --exact --silent --accept-package-agreements --accept-source-agreements$scope"
            }
        }
        Note 'Refresh PATH from Machine and User environment.'
        if (-not $python) { Note 'uv python install 3.12' }
        if (-not $claude) { Note 'irm https://claude.ai/install.ps1 | iex' }
        if (-not $exists) { Note "git clone --branch '$($config.ref)' '$($config.repo_url)' '$installDir'" }
        Note "In '$installDir': <Git installation>/bin/bash.exe scripts/orion-bootstrap.sh"
        Note "Start-Process powershell.exe (new window, working directory '$installDir', command: claude)"
        $Result.Value = 0; return
    }
    # Begin the log only after the read-only pre-flight. Mode runs leave no files.
    $script:Report | Set-Content -LiteralPath $script:LogPath -Encoding UTF8
    $script:Logging = $true
    if (-not $isWindows) { Fail 'OS check' 'This installer requires Windows.' 'Use the macOS installer in Terminal.' }
    if (-not $directoryOK) { Fail 'Install directory check' 'That path is occupied or its origin could not be verified; it has not been touched.' 'Set ORION_INSTALL_DIR to a new empty path and rerun.' }
    if (-not $online) { Fail 'Internet check' 'GitHub could not be reached.' 'Connect to the internet and rerun.' }
    if (-not $diskOK) { Fail 'Disk space check' 'The target drive needs at least 2 GB free.' 'Free 2 GB on the target drive and rerun.' }
    if (-not $winget -and (-not $git -or -not $nodeOK -or -not $uv)) { Fail 'Package manager check' 'winget is required to install missing dependencies.' 'Install App Installer from Microsoft Store, then rerun.' }
    if (-not (Ask 'Continue? [Y/n]')) { Note 'Cancelled; no dependencies or install files changed.'; $Result.Value = 0; return }
    # Resolve the upgrade decision before installing anything else.
    if ($nodeVersion -and -not $nodeOK) {
        Note "You have Node $nodeVersion; $($config.product_name) needs 20 or newer. Upgrading may affect other programs that use Node."
        if (-not (Ask 'Upgrade now? [Y/n]')) { Fail 'Node version check' 'The existing Node version is too old.' 'Install Node 20 or newer yourself, then rerun.' }
    }
    if (-not $git) { Package 'Git.Git' $true }
    if (-not $nodeOK) { Package 'OpenJS.NodeJS.LTS' $false ([bool]$nodeVersion) }
    if (-not $uv) { Package 'astral-sh.uv' $true }
    if (-not $python) { Run 'uv' @('python', 'install', '3.12') 'Install Python 3.12 alongside system Python' 'Run uv python install 3.12, then rerun.' }
    if (-not $claude) {
        $script:FailedStep = 'Install Claude Code'; $script:NextAction = 'Run irm https://claude.ai/install.ps1 | iex in PowerShell, then rerun.'
        Note 'Install Claude Code using its official installer.'
        # A child process contains the official script's exit, preserving our log and failures.
        $officialInstall = '$ErrorActionPreference = "Stop"; [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; irm https://claude.ai/install.ps1 | iex'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($officialInstall))
        Run 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) 'Install Claude Code' $script:NextAction
        Refresh-Path
    }
    if (-not (Probe 'git' @('--version')) -or -not (Probe 'uv' @('--version')) -or -not (Find-Python) -or -not (Probe 'claude' @('--version'))) { Fail 'Dependency verification' 'An installed tool is not available on PATH yet.' 'Open a new PowerShell window and rerun the installer.' }
    $verifiedNode = Probe 'node' @('--version')
    if ($verifiedNode -notmatch '^v?(\d+)\.' -or [int]$Matches[1] -lt 20) { Fail 'Node verification' 'Node 20 or newer is still not available on PATH.' 'Open a new PowerShell window with Node 20 or newer and rerun.' }
    $bash = Find-GitBash
    if (-not $bash) { Fail 'Find Git Bash' 'bash.exe was not found alongside the installed Git executable.' 'Repair Git for Windows, then rerun.' }
    if (-not $reuse) {
        Note 'A browser window will open to sign in to GitHub. This happens once.'
        RunInteractive 'git' @('clone', '--branch', $config.ref, $config.repo_url, $installDir) 'Download the code' 'Accept the repository invitation in GitHub, then rerun.'
    }
    Push-Location -LiteralPath $installDir
    try { RunInteractive $bash @('scripts/orion-bootstrap.sh') 'Run post-clone setup' 'Rerun this installer to resume post-clone setup.' }
    finally { Pop-Location }
    Note "Done. Opening Claude Code in $installDir - type hello to begin."
    $script:FailedStep = 'Open Claude Code'; $script:NextAction = "Open PowerShell in $installDir and type claude."
    $launch = "Set-Location -LiteralPath '" + $installDir.Replace("'", "''") + "'; claude"
    $encodedLaunch = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
    Start-Process powershell.exe -WorkingDirectory $installDir -ArgumentList @('-NoExit', '-EncodedCommand', $encodedLaunch) | Out-Null
    $Result.Value = 0; return
} catch {
    if (-not $DryRun -and -not $Check -and -not $script:Logging) {
        try { $script:Report | Set-Content -LiteralPath $script:LogPath -Encoding UTF8; $script:Logging = $true } catch { }
    }
    Say ("{0} {1} failed. {2}" -f [char]0x2717, $script:FailedStep, (Protect-Text $_.Exception.Message))
    Note $script:NextAction
    if ($script:Logging) { Note "Log: $script:LogPath" }
    elseif (-not $DryRun -and -not $Check) { Note "Log: $script:LogPath (could not be written)" }
    if ($env:ORION_INSTALLER_DEBUG -eq '1') { Say (Protect-Text ($_ | Out-String)) }
    $Result.Value = $script:ExitCode; return
}
} ([ref]$code)
if ($MyInvocation.MyCommand.Name -eq 'install.ps1') {
    exit $code
}
else { $global:LASTEXITCODE = $code }
