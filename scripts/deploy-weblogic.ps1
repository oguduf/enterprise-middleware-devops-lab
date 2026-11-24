[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WarPath,
    [Parameter(Mandatory = $true)][ValidateSet('deploy', 'redeploy', 'rollback')][string]$Action,
    [Parameter(Mandatory = $true)][string]$ExpectedSha256,
    [Parameter(Mandatory = $true)][string]$AdminUrl,
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$HealthUrl,
    [string]$AppName = 'middleware-demo',
    [string]$WlHome = $env:WEBLOGIC_WL_HOME,
    [string]$JavaPath = $env:WEBLOGIC_JAVA_EXE,
    [string]$UserConfigFile = $env:WEBLOGIC_USER_CONFIG_FILE,
    [string]$UserKeyFile = $env:WEBLOGIC_USER_KEY_FILE,
    [ValidateRange(1, 86400)][int]$DeployTimeoutSeconds = 600,
    [ValidateRange(1, 120)][int]$HealthTimeoutSeconds = 5,
    [ValidateRange(0, 300)][int]$HealthIntervalSeconds = 5,
    [ValidateRange(1, 60)][int]$HealthAttempts = 12,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-DeployLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = '{0} {1}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')), $Message
    Write-Host $line
}

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path)
}

function Test-WarArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedDigest
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "WAR file does not exist: $Path" }
    if ([System.IO.Path]::GetExtension($Path) -ine '.war') { throw 'Artifact must have a .war extension.' }
    if ($ExpectedDigest -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Expected SHA-256 must contain exactly 64 hexadecimal characters.' }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead((Get-NormalizedPath $Path))
    try {
        if (-not ($archive.Entries | Where-Object { $_.FullName -match '^WEB-INF/' })) {
            throw 'WAR archive is missing WEB-INF content.'
        }
        foreach ($entry in $archive.Entries) {
            if ($entry.Length -gt 0) {
                $stream = $entry.Open()
                try {
                    $buffer = New-Object byte[] 8192
                    while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) { }
                }
                finally { $stream.Dispose() }
            }
        }
    }
    finally { $archive.Dispose() }

    $actualDigest = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualDigest -ine $ExpectedDigest) { throw "WAR SHA-256 mismatch. Expected $ExpectedDigest, received $actualDigest." }
    Write-DeployLog "WAR archive and SHA-256 verified: $actualDigest"
    return $actualDigest
}

function Assert-SafeDeploymentSettings {
    param(
        [string]$Name,
        [string]$TargetName,
        [string]$ManagementUrl,
        [string]$ReadinessUrl
    )
    if ($Name -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Application name contains unsupported characters.' }
    if ($TargetName -notmatch '^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$') { throw 'Target must be a comma-separated list of WebLogic target names.' }
    if ($ManagementUrl -notmatch '^t3s?://[^\s/@]+(?::\d+)?(?:/[^\s]*)?$') { throw 'Admin URL must be a t3/t3s URL without embedded credentials.' }
    if ($ReadinessUrl -notmatch '^https?://[^\s/@]+(?::\d+)?(?:/[^\s]*)?$') { throw 'Health URL must be an HTTP(S) URL without embedded credentials.' }
}

function Assert-CredentialFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$RepositoryRoot)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'WebLogic user config and key files must exist on the runner outside the repository.'
    }
    $fullPath = Get-NormalizedPath $Path
    $repoPath = (Get-NormalizedPath $RepositoryRoot).TrimEnd('\') + '\'
    if ($fullPath.StartsWith($repoPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'WebLogic credential files must be stored outside the repository checkout.'
    }
    if ((Get-Item -LiteralPath $fullPath -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw 'WebLogic credential files must not be symbolic links or reparse points.'
    }
    $fileStream = [System.IO.File]::OpenRead($fullPath)
    $fileStream.Dispose()

    $unsafeSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
    $acl = Get-Acl -LiteralPath $fullPath
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        try { $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
        catch { continue }
        if ($sid -in $unsafeSids) { throw "Credential file ACL grants access to a broad principal ($($rule.IdentityReference)); restrict its ACL." }
    }
}

function Get-WebLogicClientClasspath {
    param([Parameter(Mandatory = $true)][string]$WlHome, [Parameter(Mandatory = $true)][string]$JavaExecutable)
    $setupScript = Join-Path $WlHome 'server\bin\setWLSEnv.cmd'
    if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) { throw "WebLogic environment setup script was not found: $setupScript" }
    $javaHome = Split-Path -Parent (Split-Path -Parent $JavaExecutable)
    $batchPath = Join-Path ([System.IO.Path]::GetTempPath()) ('wls-env-' + [guid]::NewGuid().ToString('N') + '.cmd')
    $classpathPath = Join-Path ([System.IO.Path]::GetTempPath()) ('wls-classpath-' + [guid]::NewGuid().ToString('N') + '.txt')
    foreach ($pathValue in @($WlHome, $JavaExecutable, $setupScript, $javaHome, $batchPath, $classpathPath)) {
        if ($pathValue.IndexOfAny([char[]]'&|<>^%"') -ge 0 -or $pathValue -match '[\r\n]') {
            throw 'WebLogic and Java paths must not contain command-interpreter metacharacters.'
        }
    }
    $batch = @"
@echo off
set "JAVA_HOME=$javaHome"
set "WL_HOME=$WlHome"
set "WEBLOGIC_CLASSPATH_OUTPUT=$classpathPath"
call "$setupScript" >nul
if errorlevel 1 exit /b 1
set CLASSPATH > "%WEBLOGIC_CLASSPATH_OUTPUT%"
exit /b 0
"@
    try {
        [System.IO.File]::WriteAllText($batchPath, $batch, [System.Text.Encoding]::ASCII)
        $commandProcessor = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:SystemRoot 'System32\cmd.exe' }
        $output = @(& $commandProcessor /d /c "`"$batchPath`"" 2>&1)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "WebLogic setWLSEnv.cmd failed with native exit code $exitCode." }
        if (-not (Test-Path -LiteralPath $classpathPath -PathType Leaf)) { throw 'WebLogic setWLSEnv.cmd did not produce a client CLASSPATH.' }
        $classpathLine = Get-Content -LiteralPath $classpathPath -Raw
        if ($classpathLine -notmatch '(?m)^CLASSPATH=(.*)$') { throw 'WebLogic setWLSEnv.cmd did not produce a client CLASSPATH.' }
        $classpath = $Matches[1].Trim()
        if ([string]::IsNullOrWhiteSpace($classpath)) { throw 'WebLogic client CLASSPATH is empty.' }
        return $classpath
    }
    finally {
        Remove-Item -LiteralPath $batchPath,$classpathPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WebLogicDeployer {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $global:LASTEXITCODE = 0
    $output = @(& $Executable @Arguments 2>&1)
    $nativeExitCode = $LASTEXITCODE
    foreach ($line in $output) { Write-DeployLog ([string]$line) }
    if ($nativeExitCode -ne 0) { throw "weblogic.Deployer exited with native exit code $nativeExitCode." }
    return ($output -join [Environment]::NewLine)
}

function Test-WebLogicHealth {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$IntervalSeconds,
        [Parameter(Mandatory = $true)][int]$Attempts,
        [scriptblock]$Request = {
            param($RequestUrl, $Timeout)
            Invoke-WebRequest -Uri $RequestUrl -Method Get -TimeoutSec $Timeout -UseBasicParsing
        },
        [scriptblock]$Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $response = & $Request $Url $TimeoutSeconds
            $body = $response.Content | ConvertFrom-Json -ErrorAction Stop
            if ([int]$response.StatusCode -eq 200 -and $body.status -eq 'UP') {
                Write-DeployLog "Health check succeeded on attempt $attempt/$Attempts."
                return $true
            }
            Write-DeployLog "Health check attempt $attempt/$Attempts returned an unhealthy response."
        }
        catch { Write-DeployLog "Health check attempt $attempt/$Attempts failed: $($_.Exception.Message)" }
        if ($attempt -lt $Attempts -and $IntervalSeconds -gt 0) { & $Sleep $IntervalSeconds }
    }
    throw "Application health check failed after $Attempts attempts."
}

function Invoke-WebLogicDeployment {
    param(
        [string]$WarPath, [string]$Action, [string]$ExpectedSha256,
        [string]$AdminUrl, [string]$Target, [string]$HealthUrl,
        [string]$AppName, [string]$WlHome, [string]$JavaPath,
        [string]$UserConfigFile, [string]$UserKeyFile,
        [int]$DeployTimeoutSeconds, [int]$HealthTimeoutSeconds,
        [int]$HealthIntervalSeconds, [int]$HealthAttempts,
        [bool]$IsDryRun
    )
    Assert-SafeDeploymentSettings -Name $AppName -TargetName $Target -ManagementUrl $AdminUrl -ReadinessUrl $HealthUrl
    $null = Test-WarArtifact -Path $WarPath -ExpectedDigest $ExpectedSha256

    if ($IsDryRun) {
        Write-DeployLog 'DRY RUN: configuration, WAR structure, and SHA-256 are valid; no middleware command or health request was made.'
        return
    }

    if ([string]::IsNullOrWhiteSpace($WlHome)) { throw 'WEBLOGIC_WL_HOME is required for a live deployment.' }
    $deployerJar = Join-Path $WlHome 'server\lib\weblogic.jar'
    if (-not (Test-Path -LiteralPath $deployerJar -PathType Leaf)) { throw "WebLogic deployer library was not found: $deployerJar" }
    if ([string]::IsNullOrWhiteSpace($JavaPath)) {
        if ($env:JAVA_HOME) { $JavaPath = Join-Path $env:JAVA_HOME 'bin\java.exe' }
        else { $JavaPath = (Get-Command java.exe -ErrorAction Stop).Source }
    }
    if (-not (Test-Path -LiteralPath $JavaPath -PathType Leaf)) { throw "Java executable was not found: $JavaPath" }
    $clientClasspath = Get-WebLogicClientClasspath -WlHome $WlHome -JavaExecutable $JavaPath

    $repositoryRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { Split-Path -Parent $PSScriptRoot }
    Assert-CredentialFile -Path $UserConfigFile -RepositoryRoot $repositoryRoot
    Assert-CredentialFile -Path $UserKeyFile -RepositoryRoot $repositoryRoot

    $baseArguments = @(
        '-cp', $clientClasspath, 'weblogic.Deployer',
        '-adminurl', $AdminUrl,
        '-userconfigfile', (Get-NormalizedPath $UserConfigFile),
        '-userkeyfile', (Get-NormalizedPath $UserKeyFile)
    )
    $listOutput = Invoke-WebLogicDeployer -Executable $JavaPath -Arguments ($baseArguments + @('-listapps')) -TimeoutSeconds $DeployTimeoutSeconds
    $isDeployed = $listOutput -match ('(?m)^\s*' + [regex]::Escape($AppName) + '(?:\s|$)')
    if ($Action -eq 'deploy' -and $isDeployed) { throw "Application '$AppName' already exists; choose redeploy." }
    if ($Action -in @('redeploy', 'rollback') -and -not $isDeployed) { throw "Application '$AppName' is not deployed; redeploy/rollback requires an existing application." }

    $operation = if ($Action -eq 'deploy') { '-deploy' } else { '-redeploy' }
    $deployArguments = $baseArguments + @(
        $operation, '-name', $AppName,
        '-source', (Get-NormalizedPath $WarPath),
        '-targets', $Target, '-upload', '-stage',
        '-timeout', [string]$DeployTimeoutSeconds, '-verbose'
    )
    $null = Invoke-WebLogicDeployer -Executable $JavaPath -Arguments $deployArguments -TimeoutSeconds $DeployTimeoutSeconds
    $afterOutput = Invoke-WebLogicDeployer -Executable $JavaPath -Arguments ($baseArguments + @('-listapps')) -TimeoutSeconds $DeployTimeoutSeconds
    if ($afterOutput -notmatch ('(?m)^\s*' + [regex]::Escape($AppName) + '(?:\s|$)')) {
        throw "WebLogic did not report '$AppName' after the deployer command."
    }
    $null = Test-WebLogicHealth -Url $HealthUrl -TimeoutSeconds $HealthTimeoutSeconds -IntervalSeconds $HealthIntervalSeconds -Attempts $HealthAttempts
    Write-DeployLog "WebLogic $Action completed for '$AppName' on target '$Target'."
}

$script:WasDotSourced = $MyInvocation.InvocationName -eq '.'
if (-not $script:WasDotSourced) {
    try {
        Invoke-WebLogicDeployment -WarPath $WarPath -Action $Action -ExpectedSha256 $ExpectedSha256 `
            -AdminUrl $AdminUrl -Target $Target -HealthUrl $HealthUrl -AppName $AppName `
            -WlHome $WlHome -JavaPath $JavaPath -UserConfigFile $UserConfigFile -UserKeyFile $UserKeyFile `
            -DeployTimeoutSeconds $DeployTimeoutSeconds -HealthTimeoutSeconds $HealthTimeoutSeconds `
            -HealthIntervalSeconds $HealthIntervalSeconds -HealthAttempts $HealthAttempts -IsDryRun ([bool]$DryRun)
        exit 0
    }
    catch {
        [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
        exit 1
    }
}
