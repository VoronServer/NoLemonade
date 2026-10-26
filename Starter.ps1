param([string]$FlmModelPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# NoLemonade v0.3.0 starter
#
# LemonadeServer must see both AMD GPUs.
# Only the llama.cpp child is restricted to the R9700 by the wrapper.

$projectRoot = 'C:\AI\NoLemonade'
$server = Join-Path $projectRoot 'lemonade-src\build\Release\LemonadeServer.exe'
$launcher = Join-Path $projectRoot 'NoLemonadeLauncher.exe'
$port = 13305
$baseUrl = "http://127.0.0.1:$port"

foreach ($p in @($server, $launcher)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "Required NoLemonade executable missing: $p"
    }
}

# Never collide with an existing production/server process.
$existing = @(Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -in @('LemonadeServer.exe', 'lemond.exe')
    })

if ($existing.Count -gt 0) {
    $existing | Select-Object ProcessId, Name, ExecutablePath | Format-Table -AutoSize
    throw 'A Lemonade server is already running. NoLemonade was not started.'
}

if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
    throw "Port $port is occupied. NoLemonade was not started."
}

# Save this PowerShell process environment.
# We explicitly CLEAR AMD visibility filters for LemonadeServer.exe so it can
# enumerate both 890M and R9700. The wrapper re-applies R9700-only visibility
# to llama-server later.
$names = @(
    'FLM_MODEL_PATH',
    'LEMONADE_LLAMACPP_ROCM_BIN',
    'HIP_VISIBLE_DEVICES',
    'ROCR_VISIBLE_DEVICES'
)

$saved = @{}
foreach ($name in $names) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$process = $null

try {
    # Long-lived terminals can retain the old FLM path after models are moved.
    # Explicit launch override wins; otherwise use current Windows configuration.
    if (-not $PSBoundParameters.ContainsKey('FlmModelPath')) {
        $FlmModelPath = [Environment]::GetEnvironmentVariable('FLM_MODEL_PATH', 'User')
        if ([string]::IsNullOrWhiteSpace($FlmModelPath)) {
            $FlmModelPath = [Environment]::GetEnvironmentVariable('FLM_MODEL_PATH', 'Machine')
        }
        if ([string]::IsNullOrWhiteSpace($FlmModelPath)) {
            $FlmModelPath = $saved['FLM_MODEL_PATH']
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($FlmModelPath)) {
        if (-not (Test-Path -LiteralPath $FlmModelPath -PathType Container)) {
            throw "FLM model directory does not exist: $FlmModelPath"
        }
        $env:FLM_MODEL_PATH = $FlmModelPath
        Write-Host "FastFlowLM model directory: $FlmModelPath"
    }
    $env:LEMONADE_LLAMACPP_ROCM_BIN = $launcher
    Remove-Item Env:HIP_VISIBLE_DEVICES -ErrorAction SilentlyContinue
    Remove-Item Env:ROCR_VISIBLE_DEVICES -ErrorAction SilentlyContinue

    $process = Start-Process `
        -FilePath $server `
        -WorkingDirectory (Split-Path -Parent $server) `
        -WindowStyle Hidden `
        -PassThru

    Write-Host "NoLemonade launched. PID: $($process.Id)"
}
finally {
    # Restore only this PowerShell session. The child already inherited the
    # intentional NoLemonade environment.
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable(
            $name, $saved[$name], 'Process')
    }
}

# Wait until the API is actually ready; fail closed if it never becomes ready.
$systemInfo = $null
for ($i = 0; $i -lt 30; $i++) {
    if ($process.HasExited) {
        throw "NoLemonade exited during startup with code $($process.ExitCode)."
    }

    try {
        $systemInfo = Invoke-RestMethod `
            -Uri "$baseUrl/api/v1/system-info" `
            -TimeoutSec 2
        break
    }
    catch {
        Start-Sleep -Seconds 1
    }
}

if ($null -eq $systemInfo) {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
    throw 'NoLemonade API did not become ready. The newly launched process was stopped.'
}

$amd = @($systemInfo.devices.amd_gpu)
$igpu = @($amd | Where-Object { $_.name -match '(?i)890M' }) | Select-Object -First 1
$dgpu = @($amd | Where-Object { $_.name -match '(?i)R9700' }) | Select-Object -First 1

$igpuOk = (
    $null -ne $igpu -and
    $igpu.integrated -eq $true -and
    $igpu.family -eq 'gfx1150'
)

$dgpuOk = (
    $null -ne $dgpu -and
    $dgpu.integrated -eq $false -and
    $dgpu.family -eq 'gfx120X' -and
    [double]$dgpu.vram_gb -ge 24.0 -and
    [double]$dgpu.vram_gb -le 40.0
)

Write-Host "`n=== AMD HARDWARE DETECTION ==="
$amd |
    Select-Object name, available, integrated, family, vram_gb, virtual_mem_gb |
    Format-Table -AutoSize

if (-not $igpuOk -or -not $dgpuOk) {
    Write-Host "`nExpected:"
    Write-Host "  890M   -> integrated=True,  family=gfx1150"
    Write-Host "  R9700  -> integrated=False, family=gfx120X, VRAM roughly 32 GB"

    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }

    throw 'NoLemonade GPU detection acceptance test failed. The newly launched process was stopped.'
}

Write-Host "`nPASS: 890M and R9700 are classified correctly."

Write-Host "`n=== BACKEND DISCOVERY ==="
if ($null -eq $systemInfo.PSObject.Properties['recipes']) {
    Write-Warning 'The system-info response has no recipe list; backend discovery needs investigation.'
}
else {
    foreach ($recipe in $systemInfo.recipes.PSObject.Properties) {
        foreach ($backend in $recipe.Value.backends.PSObject.Properties) {
            Write-Host ("{0}:{1} -> {2}" -f $recipe.Name, $backend.Name, $backend.Value.state)
        }
    }
}
try {
    $modelList = Invoke-RestMethod -Uri "$baseUrl/api/v1/models" -TimeoutSec 10
    $flmModels = @($modelList.data | Where-Object { $_.recipe -eq 'flm' })
    $installedFlm = @($flmModels | Where-Object { $_.downloaded -eq $true })
    Write-Host "FastFlowLM: $($installedFlm.Count) installed / $($flmModels.Count) listed models."
    if ($flmModels.Count -gt 0 -and $installedFlm.Count -eq 0) {
        Write-Warning "No installed FLM models found. Check FLM_MODEL_PATH: $FlmModelPath"
    }
}
catch {
    Write-Warning "Model-list check failed: $($_.Exception.Message)"
}

# NoLemonade v0.3.0 treats corrected Windows AMD telemetry as an acceptance gate.
try {
    $stats = Invoke-RestMethod -Uri "$baseUrl/api/v1/system-stats" -TimeoutSec 3
    Write-Host "`n=== AMD GPU TELEMETRY ==="

    $amdStats = @(
        @($stats.gpus) |
            Where-Object { $_.vendor -match '(?i)^amd$' }
    )

    $amdStats |
        Select-Object id, name, vendor, memory_type, memory_total_gb, memory_used_gb, gpu_percent |
        Format-Table -AutoSize

    $stats890 = @($amdStats | Where-Object { $_.name -match '(?i)890M' })
    $statsR9700 = @($amdStats | Where-Object { $_.name -match '(?i)R9700' })
    $primary = @(
        $amdStats |
            Where-Object { $_.id -eq $stats.primary_gpu_id }
    ) | Select-Object -First 1

    $telemetryOk = (
        $stats890.Count -eq 1 -and
        $statsR9700.Count -eq 1 -and
        $statsR9700[0].memory_type -eq 'dedicated' -and
        [double]$statsR9700[0].memory_total_gb -ge 24.0 -and
        [double]$statsR9700[0].memory_total_gb -le 40.0 -and
        $null -ne $primary -and
        $primary.name -match '(?i)R9700'
    )

    if (-not $telemetryOk) {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force
        }
        throw @"
NoLemonade Windows AMD telemetry acceptance test failed.

Expected:
  exactly one 890M telemetry adapter
  exactly one R9700 telemetry adapter
  R9700 memory_type=dedicated
  R9700 dedicated memory roughly 32 GB
  primary_gpu_id points to R9700

The newly launched NoLemonade process was stopped.
"@
    }

    Write-Host "PASS: telemetry is deduplicated and R9700 is the primary GPU."
}
catch {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
    throw
}

Write-Host "`n=== SERVER ==="
Get-CimInstance Win32_Process |
    Where-Object { $_.ProcessId -eq $process.Id } |
    Select-Object ProcessId, Name, ExecutablePath |
    Format-Table -AutoSize

Write-Host @"

NoLemonade v0.3.0 is running.

LemonadeServer sees:
  890M  -> gfx1150 integrated
  R9700 -> gfx120X discrete

ROCm llama.cpp launches through:
  $launcher

Only the llama.cpp child is restricted to the R9700.
"@
