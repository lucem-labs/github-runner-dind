<#
.SYNOPSIS
Keeps a warm pool of ephemeral GitHub Actions runners, one per slot, each in a brand-new
container attached to that slot's Docker-in-Docker sidecar (compose.yaml).

.DESCRIPTION
For every slot without a runner, the supervisor mints a single-use just-in-time (JIT) runner
config with GitHub's generate-jitconfig API and starts `docker run --rm` with it. GitHub
dispatches queued jobs to idle runners whose labels match; a runner runs exactly one job, then
its container exits and is removed, and the supervisor starts a replacement. The credential
that can mint configs stays on the host: containers only ever receive their own single-use
config.

Credentials (-Auth):
  gh   the host user's GitHub CLI login (`gh auth token`). Needs admin access to the repository.
  app  a GitHub App installed on the repository with "Administration: Read and write"; needs
       PowerShell 7 to read the private key (-AppId, -AppPrivateKeyPath).

Stop with Ctrl+C (or stop the scheduled task): runner containers are stopped and their
registrations deleted.

.EXAMPLE
./runner-supervisor.ps1 -Repository owner/repo -Labels ci
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository,
    [ValidateRange(1, 32)]
    [int]$Slots = 2,
    # Custom labels; self-hosted, linux and x64 are always added.
    [string[]]$Labels = @('ci'),
    [string]$Image = 'ghcr.io/lucem-labs/github-runner-dind:latest',
    # Compose project of the dind sidecars (compose.yaml, RUNNERS_PROJECT).
    [string]$Project = 'github-runners',
    # Defaults to compose.yaml next to the supervisor folder.
    [string]$ComposeFile,
    [ValidatePattern('^[a-z0-9-]+$')]
    [string]$NamePrefix = 'runner',
    [int]$RunnerGroupId = 1,
    [ValidateSet('gh', 'app')]
    [string]$Auth = 'gh',
    [string]$AppId,
    [string]$AppPrivateKeyPath,
    [int]$PollSeconds = 5,
    # Start the missing runners once and exit, leaving them running (for testing).
    [switch]$Once,
    # Remove this project's runner containers and runner registrations, then exit.
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
# Resolved here: Windows PowerShell 5.1 doesn't set $PSScriptRoot for parameter defaults.
if (-not $ComposeFile) { $ComposeFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'compose.yaml' }
$labelPrefix = 'io.github.runner-supervisor'
$apiBase = 'https://api.github.com'
$namePattern = '^' + [regex]::Escape($NamePrefix) + '-\d+-[0-9a-f]{8}$'

function Write-Log([string]$Message) { Write-Host ("{0:u} {1}" -f (Get-Date).ToUniversalTime(), $Message) }

#region GitHub API

$script:appToken = $null
$script:appTokenExpires = [DateTimeOffset]::MinValue

function ConvertTo-Base64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-AppToken {
    if ($script:appToken -and [DateTimeOffset]::UtcNow -lt $script:appTokenExpires.AddMinutes(-5)) { return $script:appToken }
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'GitHub App authentication needs PowerShell 7 (pwsh).' }
    if (-not $AppId -or -not $AppPrivateKeyPath) { throw '-Auth app needs -AppId and -AppPrivateKeyPath.' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
    $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes((@{ iat = $now - 60; exp = $now + 540; iss = $AppId } | ConvertTo-Json -Compress)))
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem((Get-Content -Raw -Path $AppPrivateKeyPath))
        $signature = $rsa.SignData([Text.Encoding]::ASCII.GetBytes("$header.$payload"),
            [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    }
    finally { $rsa.Dispose() }
    $jwt = "$header.$payload.$(ConvertTo-Base64Url $signature)"
    $appHeaders = @{ Authorization = "Bearer $jwt"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $installation = Invoke-RestMethod -Headers $appHeaders -Uri "$apiBase/repos/$Repository/installation"
    $token = Invoke-RestMethod -Method Post -Headers $appHeaders -Uri "$apiBase/app/installations/$($installation.id)/access_tokens"
    $script:appToken = $token.token
    $script:appTokenExpires = [DateTimeOffset]::Parse($token.expires_at)
    $script:appToken
}

function Get-ApiToken {
    if ($Auth -eq 'app') { return Get-AppToken }
    $token = (& gh auth token 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'The GitHub CLI is not logged in (gh auth login), or gh is not installed.' }
    "$token".Trim()
}

function Invoke-GitHub([string]$Method, [string]$Path, $Body) {
    $headers = @{ Authorization = "Bearer $(Get-ApiToken)"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $arguments = @{ Method = $Method; Uri = "$apiBase/$Path"; Headers = $headers }
    if ($null -ne $Body) { $arguments.Body = ($Body | ConvertTo-Json -Depth 5 -Compress); $arguments.ContentType = 'application/json' }
    Invoke-RestMethod @arguments
}

function Remove-RunnerRegistration([long]$RunnerId) {
    try { Invoke-GitHub DELETE "repos/$Repository/actions/runners/$RunnerId" $null | Out-Null }
    catch {
        # 404: an ephemeral runner removes itself after its job. Anything else is worth reporting.
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -ne 404) { Write-Log "Could not delete runner $RunnerId registration: $($_.Exception.Message)" }
    }
}

#endregion

#region Docker

function Invoke-Docker([string[]]$Arguments) {
    # Read stdout only: Windows PowerShell turns redirected native stderr into terminating errors.
    $output = & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "docker $($Arguments[0]) failed with exit code $LASTEXITCODE." }
    $output
}

function Get-RunnerContainers([string]$Slot) {
    $filters = @('--filter', "label=$labelPrefix.project=$Project")
    if ($Slot) { $filters += @('--filter', "label=$labelPrefix.slot=$Slot") }
    @(Invoke-Docker (@('ps', '--all', '--quiet') + $filters) | Where-Object { $_ })
}

function Test-DindReady([int]$Slot) {
    $state = & docker inspect --format '{{.State.Health.Status}}' "$Project-dind-$Slot-1"
    $LASTEXITCODE -eq 0 -and "$state".Trim() -eq 'healthy'
}

function Start-Runner([int]$Slot) {
    $suffix = -join ((1..8) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    $name = "$NamePrefix-$Slot-$suffix"
    $config = Invoke-GitHub POST "repos/$Repository/actions/runners/generate-jitconfig" @{
        name            = $name
        runner_group_id = $RunnerGroupId
        labels          = @('self-hosted', 'linux', 'x64') + $Labels
        work_folder     = '_work'
    }
    foreach ($cache in @('nuget', 'npm')) { Invoke-Docker @('volume', 'create', "${Project}_runner-$Slot-$cache") | Out-Null }

    # The config travels through this process's environment (`-e NAME` without a value), never
    # on a command line where other host processes could read it.
    $env:RUNNER_JITCONFIG = $config.encoded_jit_config
    try {
        $id = Invoke-Docker @(
            'run', '--detach', '--rm', '--init',
            '--name', "$Project-$name",
            '--label', "$labelPrefix.project=$Project",
            '--label', "$labelPrefix.slot=$Slot",
            '--label', "$labelPrefix.runner-id=$($config.runner.id)",
            '--network', "container:$Project-dind-$Slot-1",
            '--volume', "${Project}_dind-$Slot-certs:/certs:ro",
            '--volume', "${Project}_runner-$Slot-nuget:/home/runner/.nuget",
            '--volume', "${Project}_runner-$Slot-npm:/home/runner/.npm",
            '--env', 'RUNNER_JITCONFIG',
            $Image)
    }
    catch {
        Remove-RunnerRegistration $config.runner.id
        throw
    }
    finally { Remove-Item Env:RUNNER_JITCONFIG -ErrorAction SilentlyContinue }

    Write-Log "Slot ${Slot}: started $name (runner $($config.runner.id))."
    [pscustomobject]@{ ContainerId = "$id".Trim(); RunnerId = [long]$config.runner.id; Name = $name; StartedAt = Get-Date }
}

#endregion

function Remove-StaleRunners {
    # Leftovers from a crash, reboot or killed supervisor: this project's runner containers, and
    # the registrations named like ours. Every runner container is removed first, so no
    # registration matching our name pattern can still be serving a job.
    $containers = Get-RunnerContainers
    if ($containers.Count -gt 0) {
        Write-Log "Removing $($containers.Count) leftover runner container(s)."
        Invoke-Docker (@('rm', '--force') + $containers) | Out-Null
    }
    $stale = @()
    $page = 1
    do {
        $response = Invoke-GitHub GET "repos/$Repository/actions/runners?per_page=100&page=$page" $null
        $stale += @($response.runners | Where-Object { $_.name -match $namePattern })
        $page++
    } while (@($response.runners).Count -eq 100)
    foreach ($runner in $stale) {
        Write-Log "Deleting leftover runner registration $($runner.name) ($($runner.status))."
        Remove-RunnerRegistration $runner.id
    }
}

function Stop-AllRunners($State) {
    $containers = Get-RunnerContainers
    if ($containers.Count -gt 0) {
        Write-Log "Stopping $($containers.Count) runner container(s)."
        & docker stop --time 20 @containers | Out-Null
    }
    foreach ($entry in $State.Values) { if ($entry.Runner) { Remove-RunnerRegistration $entry.Runner.RunnerId } }
}

# --- Main ---------------------------------------------------------------------------------

# One supervisor (or cleanup) per project: two would remove each other's runner containers as
# leftovers and fight over the slots.
$instanceLock = New-Object System.Threading.Mutex($false, "Global\github-runner-supervisor-$Project")
$haveLock = $false
try { $haveLock = $instanceLock.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $haveLock = $true } # previous holder was killed
if (-not $haveLock) {
    throw "Another runner supervisor is already running for project '$Project' (for example its scheduled task). Stop it first."
}

if ($Cleanup) {
    Remove-StaleRunners
    Write-Log 'Cleanup complete.'
    return
}

Write-Log "Supervising $Slots runner slot(s) for $Repository (labels: $(@('self-hosted', 'linux', 'x64') + $Labels -join ', '); image: $Image; auth: $Auth)."
# Docker Desktop, the network or the GitHub CLI may still be starting (for example right after
# logon, when the scheduled task starts): wait and retry instead of exiting, because Task
# Scheduler does not restart a task whose script exits with an error.
while ($true) {
    try {
        & docker compose --file $ComposeFile --project-name $Project up --detach --wait
        if ($LASTEXITCODE -ne 0) { throw 'starting the Docker-in-Docker sidecars failed' }
        Remove-StaleRunners
        break
    }
    catch {
        if ($Once) { throw }
        Write-Log "Not ready yet ($($_.Exception.Message)); retrying in 30s."
        Start-Sleep -Seconds 30
    }
}

$state = @{}
foreach ($slot in 1..$Slots) { $state[$slot] = @{ Runner = $null; Failures = 0; NotBefore = [DateTime]::MinValue } }

try {
    while ($true) {
        try {
        foreach ($slot in 1..$Slots) {
            $entry = $state[$slot]
            if ($entry.Runner) {
                if ((Get-RunnerContainers $slot).Count -gt 0) { continue }
                # The container exited: normally after its job. A quick exit counts as a failure.
                $lifetime = (Get-Date) - $entry.Runner.StartedAt
                Remove-RunnerRegistration $entry.Runner.RunnerId
                if ($lifetime.TotalSeconds -lt 60) {
                    $entry.Failures++
                    $delay = [Math]::Min(300, 15 * [Math]::Pow(2, $entry.Failures - 1))
                    $entry.NotBefore = (Get-Date).AddSeconds($delay)
                    Write-Log "Slot ${slot}: $($entry.Runner.Name) exited after $([int]$lifetime.TotalSeconds)s; retrying in ${delay}s."
                }
                else {
                    $entry.Failures = 0
                    Write-Log "Slot ${slot}: $($entry.Runner.Name) finished after $([int]$lifetime.TotalMinutes) min."
                }
                $entry.Runner = $null
            }
            if ((Get-Date) -lt $entry.NotBefore) { continue }
            if (-not (Test-DindReady $slot)) {
                Write-Log "Slot ${slot}: Docker-in-Docker sidecar is not healthy yet."
                $entry.NotBefore = (Get-Date).AddSeconds(15)
                continue
            }
            try { $entry.Runner = Start-Runner $slot }
            catch {
                $entry.Failures++
                $delay = [Math]::Min(300, 15 * [Math]::Pow(2, $entry.Failures - 1))
                $entry.NotBefore = (Get-Date).AddSeconds($delay)
                Write-Log "Slot ${slot}: could not start a runner ($($_.Exception.Message)); retrying in ${delay}s."
            }
        }
        }
        catch {
            # For example Docker Desktop restarting: keep supervising rather than exiting.
            if ($Once) { throw }
            Write-Log "Supervision error ($($_.Exception.Message)); retrying in 30s."
            Start-Sleep -Seconds 30
            continue
        }
        if ($Once) { break }
        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if (-not $Once) { Stop-AllRunners $state }
}
