[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$BackendPort = 8000,
    [switch]$WebServer,
    [ValidateRange(1, 65535)]
    [int]$WebPort = 8091,
    [switch]$CheckProviderDns
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Split-Path -Parent $MyInvocation.MyCommand.Path)).Path
$venvCandidates = @(
    (Join-Path $projectRoot '.venv\Scripts\python.exe'),
    (Join-Path $projectRoot '.python312\python.exe')
)
$python = $venvCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $python) {
    throw 'Project Python environment not found. Expected .venv or .python312.'
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter is not available on PATH.'
}

$backendUrl = "http://127.0.0.1:$BackendPort"
$flutterApiUrl = "$backendUrl/api/v1"
$runtimeRoot = Join-Path $projectRoot '.runtime'
$backendProcess = $null
$startedBackend = $false

function Test-BackendHealth {
    param([string]$Url)
    try {
        $health = Invoke-RestMethod -Uri "$Url/api/v1/health" -TimeoutSec 3
        return $health.status -eq 'ok' -and $health.database -eq 'connected'
    } catch {
        return $false
    }
}

function Get-PortListeners {
    param([int]$Port)
    return @(
        Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique
    )
}

function Get-ProjectBackendTargets {
    param([int]$ListenerProcessId)
    $direct = Get-CimInstance Win32_Process -Filter "ProcessId = $ListenerProcessId" -ErrorAction SilentlyContinue
    if ($direct) {
        $command = [string]$direct.CommandLine
        $isProject = $command.IndexOf($projectRoot, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $command.IndexOf('uvicorn', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $command.IndexOf('backend.main:app', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($isProject) { return @([int]$direct.ProcessId) }
        return @()
    }

    # On Windows a terminated multiprocessing parent can remain recorded as
    # the socket owner while its worker keeps listening. Resolve only orphan
    # workers whose executable is inside this repository and whose command
    # records that exact missing parent PID.
    $orphans = @(
        Get-CimInstance Win32_Process -Filter "ParentProcessId = $ListenerProcessId" -ErrorAction SilentlyContinue |
            Where-Object {
                $executable = [string]$_.ExecutablePath
                $command = [string]$_.CommandLine
                $executable.IndexOf($projectRoot, [System.StringComparison]::OrdinalIgnoreCase) -eq 0 -and
                    $command.IndexOf('multiprocessing.spawn', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                    $command.IndexOf("parent_pid=$ListenerProcessId", [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            } |
            Select-Object -ExpandProperty ProcessId -Unique
    )
    return $orphans
}

Push-Location $projectRoot
try {
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null

    Write-Host 'Applying Alembic migrations...'
    & $python -m alembic -c 'backend\alembic.ini' upgrade head
    if ($LASTEXITCODE -ne 0) { throw 'Alembic migration failed.' }

    Write-Host 'Running safe development preflight...'
    $preflightArgs = @('-m', 'backend.preflight', '--backend-url', $backendUrl)
    if ($CheckProviderDns) { $preflightArgs += '--check-dns' }
    & $python @preflightArgs
    if ($LASTEXITCODE -ne 0) {
        throw 'Development preflight failed. Resolve the UNAVAILABLE/NO item above.'
    }

    # SO_REUSEADDR workers can be revealed in layers as earlier listeners
    # stop, so rediscover and verify every layer before starting a replacement.
    for ($cleanupRound = 0; $cleanupRound -lt 10; $cleanupRound++) {
        $listeners = @(Get-PortListeners -Port $BackendPort)
        if ($listeners.Count -eq 0) { break }
        $projectTargets = @()
        $unrelated = @()
        foreach ($listenerPid in $listeners) {
            $targets = @(Get-ProjectBackendTargets -ListenerProcessId $listenerPid)
            if ($targets.Count -eq 0) {
                $unrelated += $listenerPid
            } else {
                $projectTargets += $targets
            }
        }
        if ($unrelated.Count -gt 0) {
            throw "Port $BackendPort is owned by an unrelated process (PID $($unrelated -join ', ')). Choose -BackendPort or stop it yourself."
        }
        Write-Host "Replacing $($listeners.Count) verified project backend listener(s) on port $BackendPort..."
        foreach ($targetPid in ($projectTargets | Sort-Object -Unique)) {
            Stop-Process -Id $targetPid -ErrorAction SilentlyContinue
            Wait-Process -Id $targetPid -Timeout 10 -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 300
    }
    if (@(Get-PortListeners -Port $BackendPort).Count -ne 0) {
        throw "Verified project listeners on port $BackendPort did not stop."
    }

    $backendProcess = Start-Process `
        -FilePath $python `
        -ArgumentList @(
            '-m', 'uvicorn', 'backend.main:app',
            '--host', '127.0.0.1',
            '--port', $BackendPort.ToString(),
            '--log-level', 'info'
        ) `
        -WorkingDirectory $projectRoot `
        -RedirectStandardOutput (Join-Path $runtimeRoot 'backend-dev.stdout.log') `
        -RedirectStandardError (Join-Path $runtimeRoot 'backend-dev.stderr.log') `
        -WindowStyle Hidden `
        -PassThru
    $startedBackend = $true

    Write-Host "Starting exactly one backend at $backendUrl..."
    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        Start-Sleep -Milliseconds 250
        if ($backendProcess.HasExited) {
            throw 'Backend exited during startup. See .runtime\backend-dev.stderr.log.'
        }
        if (Test-BackendHealth -Url $backendUrl) {
            $ready = $true
            break
        }
    }
    if (-not $ready) {
        throw 'Backend did not become healthy. See .runtime\backend-dev.stderr.log.'
    }

    Write-Host "Backend URL: $backendUrl"
    Write-Host "Flutter API URL: $flutterApiUrl"
    if ($WebServer) {
        Write-Host "Flutter web URL: http://127.0.0.1:$WebPort"
        & flutter run -d web-server --web-hostname=127.0.0.1 --web-port=$WebPort `
            --dart-define="API_BASE_URL=$flutterApiUrl"
    } else {
        & flutter run -d chrome --dart-define="API_BASE_URL=$flutterApiUrl"
    }
} finally {
    if ($startedBackend -and $null -ne $backendProcess -and -not $backendProcess.HasExited) {
        Write-Host 'Stopping the backend started by this launcher...'
        Stop-Process -Id $backendProcess.Id -ErrorAction SilentlyContinue
        Wait-Process -Id $backendProcess.Id -Timeout 10 -ErrorAction SilentlyContinue
    }
    Pop-Location
}
