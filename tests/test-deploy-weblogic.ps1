$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$ExpectedText)
    $didThrow = $false
    try { & $Action }
    catch {
        $didThrow = $true
        if ($_.Exception.Message -notmatch [regex]::Escape($ExpectedText)) { throw "Expected error containing '$ExpectedText', got '$($_.Exception.Message)'" }
    }
    if (-not $didThrow) { throw "Expected an error containing '$ExpectedText', but no error was raised." }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('weblogic-ps-tests-' + [guid]::NewGuid().ToString('N'))
$mockEnvironmentNames = @('MOCK_WL_CALLS', 'MOCK_WL_DEPLOYED_FILE', 'MOCK_WL_EXIT')
$originalMockEnvironment = @{}
foreach ($name in $mockEnvironmentNames) { $originalMockEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $war = Join-Path $testRoot 'middleware-demo.war'
    $archive = [System.IO.Compression.ZipFile]::Open($war, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry('WEB-INF/web.xml')
        $writer = New-Object System.IO.StreamWriter($entry.Open())
        try { $writer.Write('<web-app/>') } finally { $writer.Dispose() }
    }
    finally { $archive.Dispose() }
    $digest = (Get-FileHash -LiteralPath $war -Algorithm SHA256).Hash

    # Dot-source only the functions; mandatory parameters keep normal CLI calls explicit.
    . (Join-Path $repoRoot 'scripts/deploy-weblogic.ps1') `
        -WarPath $war -Action deploy -ExpectedSha256 $digest `
        -AdminUrl 't3://localhost:7001' -Target 'AdminServer' `
        -HealthUrl 'http://localhost:7001/middleware-demo/health'

    Assert-True ((Test-WarArtifact -Path $war -ExpectedDigest $digest) -eq $digest) 'valid WAR and digest are accepted'
    Assert-Throws { Test-WarArtifact -Path $war -ExpectedDigest ('0' * 64) } 'SHA-256 mismatch'
    Assert-Throws { Assert-SafeDeploymentSettings -Name middleware-demo -TargetName AdminServer -ManagementUrl 't3://user:pass@localhost:7001' -ReadinessUrl 'http://localhost/health' } 'without embedded credentials'

    $deployScript = Join-Path $repoRoot 'scripts/deploy-weblogic.ps1'
    $powerShellHost = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $powerShellHost -PathType Leaf)) { $powerShellHost = (Get-Command powershell.exe).Source }
    $entryOutput = @(& $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $deployScript `
        -WarPath $war -Action deploy -ExpectedSha256 $digest `
        -AdminUrl 't3://localhost:7001' -Target AdminServer `
        -HealthUrl 'http://localhost:7001/middleware-demo/health' -DryRun 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) 'script entry point returns success for dry-run'
    Assert-True (($entryOutput -join "`n") -match 'DRY RUN') 'script entry point avoids middleware in dry-run'

    # Dry-run must not require a WebLogic installation or credential files and must not connect.
    Invoke-WebLogicDeployment -WarPath $war -Action deploy -ExpectedSha256 $digest `
        -AdminUrl 't3://localhost:7001' -Target AdminServer `
        -HealthUrl 'http://localhost:7001/middleware-demo/health' -AppName middleware-demo `
        -WlHome (Join-Path $testRoot 'no-wl-home') -JavaPath (Join-Path $testRoot 'no-java.exe') `
        -UserConfigFile '' -UserKeyFile '' -DeployTimeoutSeconds 30 `
        -HealthTimeoutSeconds 1 -HealthIntervalSeconds 0 -HealthAttempts 1 -IsDryRun $true

    # Credential files inside the checkout are rejected before a live command can run.
    $insideCheckout = Join-Path $repoRoot ('.test-credential-' + [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $insideCheckout -Value 'test-only' -NoNewline
    try { Assert-Throws { Assert-CredentialFile -Path $insideCheckout -RepositoryRoot $repoRoot } 'outside the repository checkout' }
    finally { Remove-Item -LiteralPath $insideCheckout -Force }

    $script:HealthCallCount = 0
    $noSleep = { param($Seconds) }
    $request = {
        param($RequestUrl, $Timeout)
        $script:HealthCallCount++
        if ($script:HealthCallCount -lt 2) { return [pscustomobject]@{ StatusCode = 503; Content = '{"status":"DOWN"}' } }
        return [pscustomobject]@{ StatusCode = 200; Content = '{"status":"UP"}' }
    }
    Assert-True (Test-WebLogicHealth -Url 'http://localhost/health' -TimeoutSeconds 1 -IntervalSeconds 1 -Attempts 3 -Request $request -Sleep $noSleep) 'health check retries and accepts HTTP 200 status UP'
    Assert-True ($script:HealthCallCount -eq 2) 'health retry count is exact'

    $fakeJava = Join-Path $testRoot 'fake-java.cmd'
    $env:MOCK_WL_CALLS = Join-Path $testRoot 'java-calls.txt'
    $env:MOCK_WL_DEPLOYED_FILE = Join-Path $testRoot 'deployed.flag'
    $env:MOCK_WL_EXIT = '0'
    @'
@echo off
>>"%MOCK_WL_CALLS%" echo %*
echo %* | findstr /C:"-listapps" >nul
if not errorlevel 1 (
  if exist "%MOCK_WL_DEPLOYED_FILE%" echo middleware-demo
  exit /b 0
)
echo %* | findstr /C:"-deploy" >nul
if not errorlevel 1 type nul > "%MOCK_WL_DEPLOYED_FILE%"
if not "%MOCK_WL_EXIT%"=="0" exit /b %MOCK_WL_EXIT%
exit /b 0
'@ | Set-Content -LiteralPath $fakeJava -Encoding ASCII

    # Native process exit codes are checked; the stub does not contact middleware.
    Assert-True ((Invoke-WebLogicDeployer -Executable $fakeJava -Arguments @('-version') -TimeoutSeconds 5) -eq '') 'native exit 0 is accepted'
    $env:MOCK_WL_EXIT = '9'
    Assert-Throws { Invoke-WebLogicDeployer -Executable $fakeJava -Arguments @('-version') -TimeoutSeconds 5 } 'exit code 9'
    $env:MOCK_WL_EXIT = '0'

    # Build a tiny installation fixture and fake environment script.
    $wlHome = Join-Path $testRoot 'wlserver'
    $lib = Join-Path $wlHome 'server/lib'
    New-Item -ItemType Directory -Path $lib -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $lib 'weblogic.jar') -Force | Out-Null
    $setEnvScript = Join-Path $wlHome 'server/bin/setWLSEnv.cmd'
    New-Item -ItemType Directory -Path (Split-Path -Parent $setEnvScript) -Force | Out-Null
    @('@echo off', 'set CLASSPATH=fake-weblogic-client-classpath') | Set-Content -LiteralPath $setEnvScript -Encoding ASCII
    $common = @{
        WarPath = $war; ExpectedSha256 = $digest; AdminUrl = 't3://localhost:7001'; Target = 'AdminServer'
        HealthUrl = 'http://localhost:7001/middleware-demo/health'; AppName = 'middleware-demo'
        WlHome = $wlHome; JavaPath = $fakeJava; UserConfigFile = (Join-Path $testRoot 'user.config')
        UserKeyFile = (Join-Path $testRoot 'user.key'); DeployTimeoutSeconds = 30; HealthTimeoutSeconds = 1
        HealthIntervalSeconds = 0; HealthAttempts = 1; IsDryRun = $false
    }
    New-Item -ItemType File -Path $common.UserConfigFile,$common.UserKeyFile -Force | Out-Null
    Assert-CredentialFile -Path $common.UserConfigFile -RepositoryRoot $repoRoot
    Assert-CredentialFile -Path $common.UserKeyFile -RepositoryRoot $repoRoot
    $keyAcl = Get-Acl -LiteralPath $common.UserKeyFile
    $everyone = (New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')).Translate([System.Security.Principal.NTAccount])
    $broadReadRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $everyone, [System.Security.AccessControl.FileSystemRights]::Read,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $keyAcl.AddAccessRule($broadReadRule)
    Set-Acl -LiteralPath $common.UserKeyFile -AclObject $keyAcl
    Assert-Throws { Assert-CredentialFile -Path $common.UserKeyFile -RepositoryRoot $repoRoot } 'restrict its ACL'

    # Mock only credential/health boundaries after testing real ACL checks; exercise real native exit handling.
    function Assert-CredentialFile { param([string]$Path, [string]$RepositoryRoot) }
    function Test-WebLogicHealth { param([string]$Url, [int]$TimeoutSeconds, [int]$IntervalSeconds, [int]$Attempts) $script:HealthWasCalled = $true; return $true }
    $script:HealthWasCalled = $false
    Assert-True ((Get-WebLogicClientClasspath -WlHome $wlHome -JavaExecutable $fakeJava) -eq 'fake-weblogic-client-classpath') 'client classpath is sourced from setWLSEnv.cmd'
    Invoke-WebLogicDeployment @common -Action deploy
    Assert-True (Test-Path -LiteralPath $env:MOCK_WL_DEPLOYED_FILE) 'deploy creates the expected app in the command stub'
    Assert-True ((Get-Content $env:MOCK_WL_CALLS -Raw) -match '(?m)-deploy') 'deploy operation is selected'
    Assert-True $script:HealthWasCalled 'health check runs after successful deployment'

    Remove-Item -LiteralPath $env:MOCK_WL_CALLS -Force
    Invoke-WebLogicDeployment @common -Action redeploy
    Assert-True ((Get-Content $env:MOCK_WL_CALLS -Raw) -match '(?m)-redeploy') 'redeploy operation is selected for an existing app'
    Remove-Item -LiteralPath $env:MOCK_WL_CALLS -Force
    Invoke-WebLogicDeployment @common -Action rollback
    Assert-True ((Get-Content $env:MOCK_WL_CALLS -Raw) -match '(?m)-redeploy') 'rollback uses redeploy for the verified existing app'

    Assert-Throws { Invoke-WebLogicDeployment @common -Action deploy } 'already exists; choose redeploy'
    Remove-Item -LiteralPath $env:MOCK_WL_DEPLOYED_FILE -Force
    Assert-Throws { Invoke-WebLogicDeployment @common -Action redeploy } 'is not deployed'
    New-Item -ItemType File -Path $env:MOCK_WL_DEPLOYED_FILE -Force | Out-Null

    Remove-Item -LiteralPath $env:MOCK_WL_CALLS -Force
    $env:MOCK_WL_EXIT = '7'
    $script:HealthWasCalled = $false
    Assert-Throws { Invoke-WebLogicDeployment @common -Action redeploy } 'exit code 7'
    Assert-True (-not $script:HealthWasCalled) 'native failure stops before health checks'
    Write-Output 'PowerShell WebLogic deployment tests passed (stubbed Java; no middleware contacted).'
}
finally {
    foreach ($name in $mockEnvironmentNames) {
        [Environment]::SetEnvironmentVariable($name, $originalMockEnvironment[$name], 'Process')
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# GitHub's pwsh shell exits with the last native process code. The negative
# deployer test intentionally leaves that value nonzero, so clear it only after
# every assertion and cleanup step has completed successfully.
$global:LASTEXITCODE = 0
