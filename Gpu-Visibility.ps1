#requires -Version 5.1
<#
.SYNOPSIS
    System-wide AMD ROCm + llama.cpp Vulkan GPU visibility manager for Windows.

.DESCRIPTION
    Detects Windows display adapters and maps them to:
      * HIP/ROCm physical indices used by HIP_VISIBLE_DEVICES
      * llama.cpp Vulkan physical indices used by GGML_VK_VISIBLE_DEVICES

    Set mode writes persistent Machine-scope environment variables so the
    selection survives logoff and reboot. The current PowerShell process is
    updated too, and the Windows Environment setting change is broadcast.

    The tool deliberately manages visibility independently from Lemonade.
    It can use Lemonade-cached hipInfo.exe / llama-server.exe as probe binaries
    when present, but Lemonade is not required.

    Variables managed:
      HIP_VISIBLE_DEVICES
      GGML_VK_VISIBLE_DEVICES

    Conflicting/legacy AMD selectors cleared by Set/Disable:
      ROCR_VISIBLE_DEVICES
      GPU_DEVICE_ORDINAL

    Existing processes do not inherit changed environment variables. Restart
    applications such as Lemonade, llama-server or LM Studio after Set/Disable.

    Set and Disable automatically request UAC elevation only for the narrow
    Machine-scope environment write. The original console remains open.
    Status/Detect/Verify do not require elevation.

    No Windows reboot is required, but Machine-scope values persist across reboot.

.EXAMPLE
    .\Gpu-Visibility.ps1

.EXAMPLE
    .\Gpu-Visibility.ps1 Status

.EXAMPLE
    .\Gpu-Visibility.ps1 Set -Gpu 1

.EXAMPLE
    .\Gpu-Visibility.ps1 Set -Gpu "1,2"

.EXAMPLE
    .\Gpu-Visibility.ps1 Set -Gpu r9700

.EXAMPLE
    .\Gpu-Visibility.ps1 Disable

.EXAMPLE
    .\Gpu-Visibility.ps1 Set -VulkanGpu igpu890m -RocmGpu r9700
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('Menu','Status','Detect','Set','Verify','Disable')]
    [string]$Action = 'Menu',

    # Comma-separated menu numbers, aliases or unambiguous name fragments.
    [string]$Gpu,

    # Independent backend selections. Supply both; -Gpu remains shorthand for both.
    [string]$VulkanGpu,
    [string]$RocmGpu,

    # Optional explicit probe executables.
    [string]$HipProbePath,
    [string]$VulkanProbePath,

    # Continue if probe verification is incomplete. Does not bypass missing
    # HIP/Vulkan mappings for a selected GPU.
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    throw 'PSScriptRoot is unavailable. Save this script to disk before running it.'
}

$script:InventoryPath = Join-Path $PSScriptRoot 'gpu-visibility.inventory.json'
$script:LogPath = Join-Path $PSScriptRoot 'gpu-visibility.log'
$script:Revision = '2026-10-24-independent-backends-8'

$script:ManagedVariables = @(
    'HIP_VISIBLE_DEVICES',
    'GGML_VK_VISIBLE_DEVICES'
)

$script:ConflictVariables = @(
    'ROCR_VISIBLE_DEVICES',
    'GPU_DEVICE_ORDINAL'
)

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO'
    )

    $line = '{0:u} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8

    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        'DEBUG' { }
        default { Write-Host $Message }
    }
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Invoke-ElevatedMachineEnvironmentWrite {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Updates
    )

    # If already elevated, do the Machine-scope writes directly.
    if (Test-IsAdministrator) {
        foreach ($name in $Updates.Keys) {
            $value = $Updates[$name]
            if ($null -eq $value -or [string]::IsNullOrEmpty([string]$value)) {
                [Environment]::SetEnvironmentVariable(
                    [string]$name,
                    $null,
                    [EnvironmentVariableTarget]::Machine
                )
            } else {
                [Environment]::SetEnvironmentVariable(
                    [string]$name,
                    [string]$value,
                    [EnvironmentVariableTarget]::Machine
                )
            }
        }
        return
    }

    # Keep the original console alive. Only a tiny helper process is elevated.
    # It writes Machine-scope values and reports any failure back through a temp file.
    $powershell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) {
        try {
            $powershell = (Get-Command powershell.exe -ErrorAction Stop | Select-Object -First 1).Source
        } catch {
            throw 'Cannot locate powershell.exe for automatic UAC elevation.'
        }
    }

    $errorFile = Join-Path ([IO.Path]::GetTempPath()) ('gpu-visibility-uac-' + [guid]::NewGuid().ToString('N') + '.txt')

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('$ErrorActionPreference = ''Stop''')
    [void]$lines.Add('try {')

    foreach ($name in @($Updates.Keys | Sort-Object)) {
        $value = $Updates[$name]
        $escapedName = ([string]$name).Replace("'", "''")

        if ($null -eq $value -or [string]::IsNullOrEmpty([string]$value)) {
            [void]$lines.Add(
                "  [Environment]::SetEnvironmentVariable('$escapedName', `$null, [EnvironmentVariableTarget]::Machine)"
            )
        } else {
            $escapedValue = ([string]$value).Replace("'", "''")
            [void]$lines.Add(
                "  [Environment]::SetEnvironmentVariable('$escapedName', '$escapedValue', [EnvironmentVariableTarget]::Machine)"
            )
        }
    }

    $escapedErrorFile = $errorFile.Replace("'", "''")
    [void]$lines.Add('  exit 0')
    [void]$lines.Add('} catch {')
    [void]$lines.Add(
        "  [IO.File]::WriteAllText('$escapedErrorFile', (`$_ | Out-String), [Text.Encoding]::UTF8)"
    )
    [void]$lines.Add('  exit 1')
    [void]$lines.Add('}')

    $helperScript = $lines.ToArray() -join "`r`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helperScript))

    Write-Host ''
    Write-Host 'Administrator rights are required for Machine-scope GPU visibility.' -ForegroundColor Yellow
    Write-Host 'Requesting UAC elevation for the system environment update...' -ForegroundColor Yellow
    Write-Log 'Requesting UAC elevation for Machine-scope environment update.'

    try {
        $proc = Start-Process `
            -FilePath $powershell `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $errorFile) {
            Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
        }
        throw "UAC elevation was cancelled or failed: $($_.Exception.Message)"
    }

    try {
        if ($proc.ExitCode -ne 0) {
            $detail = $null
            if (Test-Path -LiteralPath $errorFile) {
                try {
                    $detail = Get-Content -LiteralPath $errorFile -Raw -Encoding UTF8
                } catch { }
            }

            if ([string]::IsNullOrWhiteSpace([string]$detail)) {
                throw "Elevated environment helper failed with exit code $($proc.ExitCode)."
            }

            throw "Elevated environment helper failed: $($detail.Trim())"
        }
    } finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }

    Write-Log 'Elevated Machine-scope environment update completed successfully.'
}

function Get-EnvironmentValue {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][EnvironmentVariableTarget]$Target
    )
    return [Environment]::GetEnvironmentVariable($Name, $Target)
}

function Set-EnvironmentValue {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [AllowNull()][string]$Value,
        [Parameter(Mandatory=$true)][EnvironmentVariableTarget]$Target
    )

    if ([string]::IsNullOrEmpty($Value)) {
        [Environment]::SetEnvironmentVariable($Name, $null, $Target)
    } else {
        [Environment]::SetEnvironmentVariable($Name, $Value, $Target)
    }
}

function Broadcast-EnvironmentChange {
    try {
        if (-not ('GpuVisibility.NativeMethods' -as [type])) {
            $nativeTypeDefinition = @'
using System;
using System.Runtime.InteropServices;

namespace GpuVisibility {
    public static class NativeMethods {
        [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint Msg,
            UIntPtr wParam,
            string lParam,
            uint fuFlags,
            uint uTimeout,
            out UIntPtr lpdwResult
        );
    }
}
'@
            Add-Type -TypeDefinition $nativeTypeDefinition -ErrorAction Stop
        }

        $HWND_BROADCAST = [IntPtr]0xffff
        $WM_SETTINGCHANGE = 0x001A
        $SMTO_ABORTIFHUNG = 0x0002
        $result = [UIntPtr]::Zero

        [void][GpuVisibility.NativeMethods]::SendMessageTimeout(
            $HWND_BROADCAST,
            $WM_SETTINGCHANGE,
            [UIntPtr]::Zero,
            'Environment',
            $SMTO_ABORTIFHUNG,
            5000,
            [ref]$result
        )
        Write-Log 'Broadcast WM_SETTINGCHANGE(Environment).' 'DEBUG'
    } catch {
        Write-Log "Could not broadcast Environment change: $($_.Exception.Message)" 'WARN'
    }
}

function Get-GpuAlias {
    param([string]$Name, [string]$GfxFamily)

    $text = ([string]$Name + ' ' + [string]$GfxFamily)

    if ($text -match '(?i)Radeon\s+AI\s+PRO\s+R9700|\bR9700\b|gfx1201') { return 'r9700' }
    if ($text -match '(?i)RX\s*7800M|\b7800M\b|gfx1101') { return 'rx7800m' }
    if ($text -match '(?i)Radeon\s+890M|\b890M\b|gfx1150') { return 'igpu890m' }

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $simple = ([string]$Name).ToLowerInvariant()
        $simple = $simple -replace '(advanced micro devices|amd|radeon|graphics|display|adapter|\(tm\)|\(r\))',''
        $simple = $simple -replace '[^a-z0-9]+','-'
        $simple = $simple.Trim('-')
        if (-not [string]::IsNullOrWhiteSpace($simple)) { return $simple }
    }

    return $null
}

function Normalize-GpuName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }

    $value = $Name.ToLowerInvariant()
    $value = $value -replace '\([^)]*\)',' '
    $value = $value -replace '(advanced micro devices|amd|radeon|graphics|display|adapter|series|gpu)',' '
    $value = $value -replace '[^a-z0-9]+',' '
    $value = ($value -split '\s+' | Where-Object { $_ }) -join ' '
    return $value.Trim()
}

function Get-WindowsDisplayAdapters {
    $result = New-Object System.Collections.Generic.List[object]

    $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
    foreach ($gpu in $controllers) {
        $name = [string]$gpu.Name
        [void]$result.Add([pscustomobject]@{
            Name          = $name
            Alias         = Get-GpuAlias -Name $name -GfxFamily $null
            Normalized    = Normalize-GpuName -Name $name
            PnpDeviceId   = [string]$gpu.PNPDeviceID
            Status        = [string]$gpu.Status
            DriverVersion = [string]$gpu.DriverVersion
            VideoMemoryMB = if ($gpu.AdapterRAM) { [math]::Round(([double]$gpu.AdapterRAM / 1MB), 0) } else { $null }
        })
    }

    return $result.ToArray()
}

function Add-UniqueExistingFile {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    try {
        $full = [IO.Path]::GetFullPath($Path)
    } catch {
        return
    }

    if ((Test-Path -LiteralPath $full -PathType Leaf) -and -not $List.Contains($full)) {
        [void]$List.Add($full)
    }
}

function Find-HipProbeExecutables {
    param([string]$ExplicitPath)

    $found = New-Object System.Collections.Generic.List[string]

    Add-UniqueExistingFile -List $found -Path $ExplicitPath

    foreach ($root in @($env:ROCM_PATH, $env:HIP_PATH)) {
        if ($root) { Add-UniqueExistingFile -List $found -Path (Join-Path $root 'bin\hipInfo.exe') }
    }

    try {
        $cmd = Get-Command hipInfo.exe -ErrorAction Stop | Select-Object -First 1
        Add-UniqueExistingFile -List $found -Path $cmd.Source
    } catch { }

    $roots = @(
        'C:\lemonade_server\cache\bin\therock',
        (Join-Path $env:LOCALAPPDATA 'lemonade_server\cache\bin\therock')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique

    foreach ($root in $roots) {
        try {
            foreach ($item in @(Get-ChildItem -LiteralPath $root -Filter hipInfo.exe -File -Recurse -ErrorAction SilentlyContinue)) {
                Add-UniqueExistingFile -List $found -Path $item.FullName
            }
        } catch { }
    }

    return $found.ToArray()
}

function Find-VulkanProbeExecutables {
    param([string]$ExplicitPath)

    $found = New-Object System.Collections.Generic.List[string]

    Add-UniqueExistingFile -List $found -Path $ExplicitPath

    try {
        $cmd = Get-Command llama-server.exe -ErrorAction Stop | Select-Object -First 1
        Add-UniqueExistingFile -List $found -Path $cmd.Source
    } catch { }

    $known = @(
        'C:\lemonade_server\cache\bin\llamacpp\vulkan\llama-server.exe',
        (Join-Path $env:LOCALAPPDATA 'lemonade_server\cache\bin\llamacpp\vulkan\llama-server.exe')
    )
    foreach ($path in $known) {
        Add-UniqueExistingFile -List $found -Path $path
    }

    $roots = @(
        'C:\lemonade_server\cache\bin\llamacpp',
        (Join-Path $env:LOCALAPPDATA 'lemonade_server\cache\bin\llamacpp')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique

    foreach ($root in $roots) {
        try {
            foreach ($item in @(Get-ChildItem -LiteralPath $root -Filter llama-server.exe -File -Recurse -ErrorAction SilentlyContinue)) {
                Add-UniqueExistingFile -List $found -Path $item.FullName
            }
        } catch { }
    }

    return $found.ToArray()
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [hashtable]$EnvironmentOverrides = @{},
        [string[]]$EnvironmentRemovals = @()
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = Split-Path -Parent $FilePath

    if ($Arguments.Count -gt 0) {
        # Probe arguments used by this tool contain no spaces requiring shell parsing.
        $psi.Arguments = ($Arguments -join ' ')
    }

    foreach ($name in $EnvironmentRemovals) {
        if ($psi.EnvironmentVariables.ContainsKey($name)) {
            $psi.EnvironmentVariables.Remove($name)
        }
    }

    foreach ($key in $EnvironmentOverrides.Keys) {
        $value = $EnvironmentOverrides[$key]
        if ($null -eq $value) {
            if ($psi.EnvironmentVariables.ContainsKey([string]$key)) {
                $psi.EnvironmentVariables.Remove([string]$key)
            }
        } else {
            $psi.EnvironmentVariables[[string]$key] = [string]$value
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        if (-not $process.Start()) {
            throw "Process could not be started: $FilePath"
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $process.WaitForExit()

        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $process.ExitCode

        return [pscustomobject]@{
            ExitCode = $exitCode
            StdOut   = [string]$stdout
            StdErr   = [string]$stderr
            AllText  = (([string]$stdout) + "`n" + ([string]$stderr))
        }
    } finally {
        $process.Dispose()
    }
}

function Parse-HipInfoDevices {
    param(
        [string]$Text,
        [string]$Source
    )

    $result = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($line in @(([string]$Text) -split "`r?`n")) {
        if ($line -match '(?i)^\s*(?:device\s*#?|device#)\s*[:=]?\s*(\d+)\s*$' -or
            $line -match '(?i)^\s*Device\s+(\d+)\b') {

            if ($null -ne $current) {
                [void]$result.Add([pscustomobject]$current)
            }

            $current = [ordered]@{
                Index     = [int]$Matches[1]
                Name      = $null
                GfxFamily = $null
                Source    = $Source
            }
            continue
        }

        if ($null -eq $current) { continue }

        if ($line -match '(?i)^\s*(?:Name|Device\s+Name)\s*:\s*(.+?)\s*$') {
            $current.Name = $Matches[1].Trim()
            continue
        }

        if ($line -match '(?i)^\s*(?:gcnArchName|Architecture|Arch)\s*:\s*(gfx[0-9a-z:._-]+)') {
            $current.GfxFamily = $Matches[1].Trim()
            continue
        }
    }

    if ($null -ne $current) {
        [void]$result.Add([pscustomobject]$current)
    }

    $normalized = @(
        $result.ToArray() |
        Sort-Object Index -Unique |
        ForEach-Object {
            [pscustomobject]@{
                Index      = [int]$_.Index
                Name       = [string]$_.Name
                GfxFamily  = [string]$_.GfxFamily
                Alias      = Get-GpuAlias -Name ([string]$_.Name) -GfxFamily ([string]$_.GfxFamily)
                Normalized = Normalize-GpuName -Name ([string]$_.Name)
                Source     = [string]$_.Source
            }
        }
    )

    return $normalized
}

function Parse-VulkanDevices {
    param(
        [string]$Text,
        [string]$Source
    )

    $result = New-Object System.Collections.Generic.List[object]

    foreach ($line in @(([string]$Text) -split "`r?`n")) {
        if ($line -match '(?i)^\s*Vulkan(\d+)\s*:\s*(.+?)\s*$') {
            $index = [int]$Matches[1]
            $name = $Matches[2].Trim()

            [void]$result.Add([pscustomobject]@{
                Index      = $index
                Name       = $name
                Alias      = Get-GpuAlias -Name $name -GfxFamily $null
                Normalized = Normalize-GpuName -Name $name
                Source     = $Source
            })
        }
    }

    return @($result.ToArray() | Sort-Object Index -Unique)
}

function Select-BestHipProbe {
    param([string[]]$Executables)

    $candidates = New-Object System.Collections.Generic.List[object]

    foreach ($exe in @($Executables)) {
        Write-Log "Probing HIP device order with $exe" 'DEBUG'
        try {
            $probe = Invoke-NativeCapture `
                -FilePath $exe `
                -EnvironmentRemovals @('HIP_VISIBLE_DEVICES','ROCR_VISIBLE_DEVICES','GPU_DEVICE_ORDINAL')

            $devices = @(Parse-HipInfoDevices -Text $probe.AllText -Source $exe)
            if ($devices.Count -gt 0) {
                $known = @($devices | Where-Object { $_.Alias }).Count
                [void]$candidates.Add([pscustomobject]@{
                    Source  = $exe
                    Devices = $devices
                    Score   = (($known * 100) + $devices.Count)
                    ExitCode = $probe.ExitCode
                })
            }
        } catch {
            Write-Log "HIP probe failed for '$exe': $($_.Exception.Message)" 'DEBUG'
        }
    }

    if ($candidates.Count -eq 0) { return $null }

    return @($candidates.ToArray() | Sort-Object Score -Descending | Select-Object -First 1)[0]
}

function Select-BestVulkanProbe {
    param([string[]]$Executables)

    $candidates = New-Object System.Collections.Generic.List[object]

    foreach ($exe in @($Executables)) {
        Write-Log "Probing Vulkan device order with $exe --list-devices" 'DEBUG'
        try {
            $probe = Invoke-NativeCapture `
                -FilePath $exe `
                -Arguments @('--list-devices') `
                -EnvironmentRemovals @('GGML_VK_VISIBLE_DEVICES')

            $devices = @(Parse-VulkanDevices -Text $probe.AllText -Source $exe)
            if ($devices.Count -gt 0) {
                $known = @($devices | Where-Object { $_.Alias }).Count
                [void]$candidates.Add([pscustomobject]@{
                    Source  = $exe
                    Devices = $devices
                    Score   = (($known * 100) + $devices.Count)
                    ExitCode = $probe.ExitCode
                })
            }
        } catch {
            Write-Log "Vulkan probe failed for '$exe': $($_.Exception.Message)" 'DEBUG'
        }
    }

    if ($candidates.Count -eq 0) { return $null }

    return @($candidates.ToArray() | Sort-Object Score -Descending | Select-Object -First 1)[0]
}

function Test-DeviceMatch {
    param(
        [object]$WindowsGpu,
        [object]$ProbeGpu
    )

    if ($null -eq $WindowsGpu -or $null -eq $ProbeGpu) { return $false }

    if ($WindowsGpu.Alias -and $ProbeGpu.Alias -and
        [string]$WindowsGpu.Alias -eq [string]$ProbeGpu.Alias) {
        return $true
    }

    $a = [string]$WindowsGpu.Normalized
    $b = [string]$ProbeGpu.Normalized

    if (-not [string]::IsNullOrWhiteSpace($a) -and
        -not [string]::IsNullOrWhiteSpace($b)) {

        if ($a -eq $b) { return $true }
        if ($a.Length -ge 4 -and $b.Contains($a)) { return $true }
        if ($b.Length -ge 4 -and $a.Contains($b)) { return $true }
    }

    return $false
}

function Build-Inventory {
    param(
        [object[]]$WindowsGpus,
        [object[]]$HipDevices,
        [object[]]$VulkanDevices
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $usedHip = New-Object System.Collections.Generic.List[int]
    $usedVk = New-Object System.Collections.Generic.List[int]

    foreach ($win in @($WindowsGpus)) {
        $hip = @(
            $HipDevices |
            Where-Object { -not $usedHip.Contains([int]$_.Index) -and (Test-DeviceMatch -WindowsGpu $win -ProbeGpu $_) } |
            Select-Object -First 1
        )

        $vk = @(
            $VulkanDevices |
            Where-Object { -not $usedVk.Contains([int]$_.Index) -and (Test-DeviceMatch -WindowsGpu $win -ProbeGpu $_) } |
            Select-Object -First 1
        )

        $hipItem = if ($hip.Count -eq 1) { $hip[0] } else { $null }
        $vkItem = if ($vk.Count -eq 1) { $vk[0] } else { $null }

        if ($hipItem) { [void]$usedHip.Add([int]$hipItem.Index) }
        if ($vkItem) { [void]$usedVk.Add([int]$vkItem.Index) }

        [void]$rows.Add([pscustomobject]@{
            Name          = [string]$win.Name
            Alias         = [string]$win.Alias
            Status        = [string]$win.Status
            DriverVersion = [string]$win.DriverVersion

            HipIndex      = if ($hipItem) { [int]$hipItem.Index } else { $null }
            HipName       = if ($hipItem) { [string]$hipItem.Name } else { $null }
            GfxFamily     = if ($hipItem) { [string]$hipItem.GfxFamily } else { $null }

            VulkanIndex   = if ($vkItem) { [int]$vkItem.Index } else { $null }
            VulkanName    = if ($vkItem) { [string]$vkItem.Name } else { $null }

            EligibleBoth  = ($null -ne $hipItem -and $null -ne $vkItem)
        })
    }

    # Keep probe-only devices visible in diagnostics if Windows matching failed.
    foreach ($hip in @($HipDevices)) {
        if (-not $usedHip.Contains([int]$hip.Index)) {
            [void]$rows.Add([pscustomobject]@{
                Name          = if ($hip.Name) { [string]$hip.Name } else { "<unmatched HIP device $($hip.Index)>" }
                Alias         = [string]$hip.Alias
                Status        = 'ProbeOnly'
                DriverVersion = $null
                HipIndex      = [int]$hip.Index
                HipName       = [string]$hip.Name
                GfxFamily     = [string]$hip.GfxFamily
                VulkanIndex   = $null
                VulkanName    = $null
                EligibleBoth  = $false
            })
        }
    }

    foreach ($vk in @($VulkanDevices)) {
        if (-not $usedVk.Contains([int]$vk.Index)) {
            [void]$rows.Add([pscustomobject]@{
                Name          = if ($vk.Name) { [string]$vk.Name } else { "<unmatched Vulkan device $($vk.Index)>" }
                Alias         = [string]$vk.Alias
                Status        = 'ProbeOnly'
                DriverVersion = $null
                HipIndex      = $null
                HipName       = $null
                GfxFamily     = $null
                VulkanIndex   = [int]$vk.Index
                VulkanName    = [string]$vk.Name
                EligibleBoth  = $false
            })
        }
    }

    return $rows.ToArray()
}

function Get-HardwareInventory {
    Write-Log 'Detecting Windows video adapters.'
    $windows = @(Get-WindowsDisplayAdapters)

    $hipExecutables = @(Find-HipProbeExecutables -ExplicitPath $HipProbePath)
    $vkExecutables = @(Find-VulkanProbeExecutables -ExplicitPath $VulkanProbePath)

    $hipProbe = Select-BestHipProbe -Executables $hipExecutables
    $vkProbe = Select-BestVulkanProbe -Executables $vkExecutables

    $hipDevices = @()
    if ($hipProbe) { $hipDevices = @($hipProbe.Devices) }

    $vkDevices = @()
    if ($vkProbe) { $vkDevices = @($vkProbe.Devices) }

    if ($hipDevices.Count -eq 0) {
        Write-Log 'No HIP device mapping was discovered. Use -HipProbePath if hipInfo.exe is installed elsewhere.' 'WARN'
    }

    if ($vkDevices.Count -eq 0) {
        Write-Log 'No llama.cpp Vulkan device mapping was discovered. Use -VulkanProbePath with a Vulkan-enabled llama-server.exe.' 'WARN'
    }

    $devices = @(Build-Inventory -WindowsGpus $windows -HipDevices $hipDevices -VulkanDevices $vkDevices)

    $inventory = [pscustomobject]@{
        SchemaVersion = 1
        Revision = $script:Revision
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        ComputerName = $env:COMPUTERNAME

        HipProbeSource = if ($hipProbe) { [string]$hipProbe.Source } else { $null }
        VulkanProbeSource = if ($vkProbe) { [string]$vkProbe.Source } else { $null }

        HipProbeCandidates = $hipExecutables
        VulkanProbeCandidates = $vkExecutables

        Devices = $devices
    }

    $inventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:InventoryPath -Encoding UTF8
    return $inventory
}

function Show-Inventory {
    param([object]$Inventory)

    $devices = @($Inventory.Devices)

    Write-Host ''
    Write-Host '=== Physical GPU mapping ===' -ForegroundColor Cyan

    $rows = @(
        for ($i = 0; $i -lt $devices.Count; $i++) {
            $d = $devices[$i]
            [pscustomobject]@{
                '#'      = ($i + 1)
                Name     = [string]$d.Name
                Alias    = [string]$d.Alias
                'ROCm (HIP)' = if ($null -ne $d.HipIndex) { [string]$d.HipIndex } else { '-' }
                'Vulkan (VK)' = if ($null -ne $d.VulkanIndex) { [string]$d.VulkanIndex } else { '-' }
                Gfx      = if ([string]::IsNullOrWhiteSpace([string]$d.GfxFamily)) { '-' } else { [string]$d.GfxFamily }
                Both     = if ([bool]$d.EligibleBoth) { 'Yes' } else { 'No' }
            }
        }
    )

    if ($rows.Count -gt 0) {
        $rows | Format-Table -AutoSize
    } else {
        Write-Host 'No display adapters were found.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host "HIP probe    : $($Inventory.HipProbeSource)"
    Write-Host "Vulkan probe : $($Inventory.VulkanProbeSource)"
    Write-Host "Inventory    : $script:InventoryPath"
}

function Get-VisibilityScopeState {
    $names = @($script:ManagedVariables + $script:ConflictVariables)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($name in $names) {
        [void]$rows.Add([pscustomobject]@{
            Variable = $name
            Process  = Get-EnvironmentValue -Name $name -Target ([EnvironmentVariableTarget]::Process)
            User     = Get-EnvironmentValue -Name $name -Target ([EnvironmentVariableTarget]::User)
            Machine  = Get-EnvironmentValue -Name $name -Target ([EnvironmentVariableTarget]::Machine)
        })
    }
    return $rows.ToArray()
}

function Get-SelectedNamesForIndices {
    param(
        [object]$Inventory,
        [string]$Value,
        [ValidateSet('HIP','Vulkan')][string]$Kind
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return '<unrestricted>' }

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($token in @($Value -split ',')) {
        $trimmed = ([string]$token).Trim()
        if ($trimmed -notmatch '^\d+$') {
            [void]$names.Add("?($trimmed)")
            continue
        }

        $index = [int]$trimmed
        $match = if ($Kind -eq 'HIP') {
            $Inventory.Devices |
                Where-Object { $null -ne $_.HipIndex -and [int]$_.HipIndex -eq $index } |
                Select-Object -First 1
        } else {
            $Inventory.Devices |
                Where-Object { $null -ne $_.VulkanIndex -and [int]$_.VulkanIndex -eq $index } |
                Select-Object -First 1
        }

        if ($null -ne $match) {
            [void]$names.Add([string]$match.Name)
        } else {
            [void]$names.Add("?index=$index")
        }
    }

    return ($names.ToArray() -join ' + ')
}

function Show-Status {
    param([object]$Inventory)

    Show-Inventory -Inventory $Inventory

    Write-Host ''
    Write-Host '=== Visibility environment ===' -ForegroundColor Cyan
    Get-VisibilityScopeState | Format-Table -AutoSize

    $machineHip = Get-EnvironmentValue -Name 'HIP_VISIBLE_DEVICES' -Target ([EnvironmentVariableTarget]::Machine)
    $machineVk = Get-EnvironmentValue -Name 'GGML_VK_VISIBLE_DEVICES' -Target ([EnvironmentVariableTarget]::Machine)

    Write-Host ''
    Write-Host '=== Machine-scope selection ===' -ForegroundColor Cyan
    Write-Host ("ROCm   : {0}  =>  {1}" -f $(if ($machineHip) { $machineHip } else { '<unset>' }), (Get-SelectedNamesForIndices -Inventory $Inventory -Value $machineHip -Kind HIP))
    Write-Host ("Vulkan : {0}  =>  {1}" -f $(if ($machineVk) { $machineVk } else { '<unset>' }), (Get-SelectedNamesForIndices -Inventory $Inventory -Value $machineVk -Kind Vulkan))

    $running = @(Get-RunningGpuConsumers)
    if ($running.Count -gt 0) {
        Write-Host ''
        Write-Host '=== Running processes that may still have OLD visibility ===' -ForegroundColor Yellow
        $running | Format-Table Name, ProcessId, ExecutablePath -AutoSize
        Write-Host 'Restart these applications/processes for changed visibility to take effect.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Windows reboot required: No' -ForegroundColor Green
    Write-Host 'Machine-scope settings survive reboot: Yes' -ForegroundColor Green
}

function Resolve-GpuSelection {
    param(
        [object]$Inventory,
        [string]$Selection,
        [ValidateSet('Both','HIP','Vulkan')][string]$Backend = 'Both'
    )

    if ([string]::IsNullOrWhiteSpace($Selection)) {
        throw 'Specify one or more GPUs, for example -Gpu 1 or -Gpu "1,2" or -Gpu r9700.'
    }

    $devices = @($Inventory.Devices)
    if ($Selection.Trim() -ieq 'all') {
        $Selection = (@(for ($i=0; $i -lt $devices.Count; $i++) {
            $d = $devices[$i]
            if (($Backend -eq 'Both' -and $d.EligibleBoth) -or
                ($Backend -eq 'HIP' -and $null -ne $d.HipIndex) -or
                ($Backend -eq 'Vulkan' -and $null -ne $d.VulkanIndex)) { $i + 1 }
        }) -join ',')
    }
    $chosen = New-Object System.Collections.Generic.List[object]

    foreach ($raw in @($Selection -split ',')) {
        $token = ([string]$raw).Trim()
        if ([string]::IsNullOrWhiteSpace($token)) { continue }

        $match = @()
        $number = 0

        if ([int]::TryParse($token, [ref]$number)) {
            if ($number -lt 1 -or $number -gt $devices.Count) {
                throw "GPU number '$token' is outside valid range 1..$($devices.Count)."
            }
            $match = @($devices[$number - 1])
        } else {
            $match = @(
                $devices |
                Where-Object {
                    ([string]$_.Alias -eq $token) -or
                    ([string]$_.Name -like "*$token*")
                }
            )
        }

        if ($match.Count -eq 0) {
            throw "GPU selection '$token' did not match any detected adapter."
        }
        if ($match.Count -gt 1) {
            throw "GPU selection '$token' is ambiguous. Use the numeric # shown by Detect/Status."
        }

        $device = $match[0]
        if (($Backend -eq 'Both' -and -not [bool]$device.EligibleBoth) -or
            ($Backend -eq 'HIP' -and $null -eq $device.HipIndex) -or
            ($Backend -eq 'Vulkan' -and $null -eq $device.VulkanIndex)) {
            throw "GPU '$($device.Name)' has no usable $Backend mapping. Choose a GPU with an index in that backend's column."
        }

        $already = @($chosen.ToArray() | Where-Object { [string]$_.Name -eq [string]$device.Name })
        if ($already.Count -eq 0) {
            [void]$chosen.Add($device)
        }
    }

    if ($chosen.Count -eq 0) {
        throw 'No GPUs were selected.'
    }

    return $chosen.ToArray()
}

function Get-RunningGpuConsumers {
    $names = @(
        'llama-server.exe',
        'LemonadeServer.exe',
        'lemond.exe',
        'LM Studio.exe',
        'lm-studio.exe',
        'lms.exe'
    )

    try {
        return @(
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in $names } |
            ForEach-Object {
                [pscustomobject]@{
                    Name = [string]$_.Name
                    ProcessId = [int]$_.ProcessId
                    ExecutablePath = [string]$_.ExecutablePath
                }
            }
        )
    } catch {
        return @()
    }
}

function Clear-VisibilityVariableAllScopes {
    param([string]$Name)

    foreach ($target in @(
        [EnvironmentVariableTarget]::Machine,
        [EnvironmentVariableTarget]::User,
        [EnvironmentVariableTarget]::Process
    )) {
        Set-EnvironmentValue -Name $Name -Value $null -Target $target
    }
}

function Clear-VisibilityVariableUserProcessScopes {
    param([string]$Name)

    foreach ($target in @(
        [EnvironmentVariableTarget]::User,
        [EnvironmentVariableTarget]::Process
    )) {
        Set-EnvironmentValue -Name $Name -Value $null -Target $target
    }
}

function Set-SystemVisibility {
    param(
        [object]$Inventory,
        [object[]]$Selected,
        [object[]]$HipSelected,
        [object[]]$VulkanSelected,
        [switch]$ConfirmSelection
    )

    if ($PSBoundParameters.ContainsKey('Selected')) {
        if ($PSBoundParameters.ContainsKey('HipSelected') -or $PSBoundParameters.ContainsKey('VulkanSelected')) {
            throw 'Use a shared selection or separate backend selections, not both.'
        }
        $HipSelected = $Selected
        $VulkanSelected = $Selected
    }
    if ($null -eq $HipSelected -or $null -eq $VulkanSelected -or @($HipSelected).Count -eq 0 -or @($VulkanSelected).Count -eq 0) {
        throw 'Select at least one GPU for each backend.'
    }
    $hip = (@($HipSelected | ForEach-Object { [string]$_.HipIndex }) -join ',')
    $vk = (@($VulkanSelected | ForEach-Object { [string]$_.VulkanIndex }) -join ',')

    Write-Host ''
    Write-Host '=== Requested system-wide visibility ===' -ForegroundColor Cyan
    Write-Host ('Vulkan (VK): ' + (($VulkanSelected | ForEach-Object Name) -join ', '))
    Write-Host ('ROCm (HIP) : ' + (($HipSelected | ForEach-Object Name) -join ', '))
    Write-Host "HIP_VISIBLE_DEVICES     = $hip"
    Write-Host "GGML_VK_VISIBLE_DEVICES = $vk"

    if ($ConfirmSelection) {
        Write-Host 'This saves settings for all Windows users. Restart GPU applications afterward.'
        if ((Read-Host 'Apply these selections? [y/N]') -notmatch '^(?i:y|yes)$') {
            Write-Host 'Cancelled. No settings changed.'
            return
        }
    }

    # Remove User-scope copies so Machine scope is authoritative for this user.
    foreach ($name in $script:ManagedVariables) {
        $existingUser = Get-EnvironmentValue -Name $name -Target ([EnvironmentVariableTarget]::User)
        if ($existingUser) {
            Write-Log "Removing User-scope $name='$existingUser' so the Machine-scope visibility setting is authoritative." 'WARN'
            Set-EnvironmentValue -Name $name -Value $null -Target ([EnvironmentVariableTarget]::User)
        }
    }

    # Old AMD selectors can intersect with HIP_VISIBLE_DEVICES and make the
    # resulting device set confusing. This visibility manager owns the policy,
    # so clear them from all scopes when taking control.
    foreach ($name in $script:ConflictVariables) {
        # In PowerShell command syntax, commas after a command invocation can be
        # parsed as additional argument values. Build the list with separate
        # statements instead of comma-separated command calls.
        $values = @(
            $(Get-EnvironmentValue -Name $name -Target ([EnvironmentVariableTarget]::Machine))
            $(Get-EnvironmentValue -Name $name -Target ([EnvironmentVariableTarget]::User))
            $(Get-EnvironmentValue -Name $name -Target ([EnvironmentVariableTarget]::Process))
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

        $values = @($values)

        if ($values.Count -gt 0) {
            Write-Log "Removing conflicting selector $name before applying the canonical Windows HIP visibility setting." 'WARN'
        }

        Clear-VisibilityVariableUserProcessScopes -Name $name
    }

    Invoke-ElevatedMachineEnvironmentWrite -Updates @{
        HIP_VISIBLE_DEVICES     = $hip
        GGML_VK_VISIBLE_DEVICES = $vk
        ROCR_VISIBLE_DEVICES    = $null
        GPU_DEVICE_ORDINAL      = $null
    }

    # Update current shell as well. Existing sibling processes remain unchanged.
    Set-EnvironmentValue -Name 'HIP_VISIBLE_DEVICES' -Value $hip -Target ([EnvironmentVariableTarget]::Process)
    Set-EnvironmentValue -Name 'GGML_VK_VISIBLE_DEVICES' -Value $vk -Target ([EnvironmentVariableTarget]::Process)

    Broadcast-EnvironmentChange

    $readHip = Get-EnvironmentValue -Name 'HIP_VISIBLE_DEVICES' -Target ([EnvironmentVariableTarget]::Machine)
    $readVk = Get-EnvironmentValue -Name 'GGML_VK_VISIBLE_DEVICES' -Target ([EnvironmentVariableTarget]::Machine)

    if ([string]$readHip -ne [string]$hip -or [string]$readVk -ne [string]$vk) {
        throw "Machine-scope visibility verification failed after write (HIP='$readHip', Vulkan='$readVk')."
    }

    Write-Host ''
    Write-Host 'System-wide GPU visibility saved successfully.' -ForegroundColor Green
    Write-Host 'The settings survive reboot/logon.' -ForegroundColor Green
    Write-Host 'Windows reboot required: No' -ForegroundColor Green

    $running = @(Get-RunningGpuConsumers)
    if ($running.Count -gt 0) {
        Write-Host ''
        Write-Host 'Restart required for these already-running GPU consumers:' -ForegroundColor Yellow
        $running | Format-Table Name, ProcessId, ExecutablePath -AutoSize
    }

    Write-Host ''
    Write-Host 'Verifying child-process visibility...' -ForegroundColor Cyan
    # Read back each backend's own saved filter; the GPU sets may differ.
    Verify-Visibility -Inventory $Inventory -DoNotThrow:$Force
}

function Compare-ExpectedAliases {
    param(
        [object[]]$Expected,
        [object[]]$Actual
    )

    $expectedAliases = @($Expected | ForEach-Object { [string]$_.Alias })
    $actualAliases = @($Actual | ForEach-Object { [string]$_.Alias })

    if ($expectedAliases.Count -ne $actualAliases.Count) { return $false }

    for ($i = 0; $i -lt $expectedAliases.Count; $i++) {
        if ([string]$expectedAliases[$i] -ne [string]$actualAliases[$i]) {
            return $false
        }
    }

    return $true
}

function Get-ExpectedDevicesForVisibility {
    param(
        [object]$Inventory,
        [ValidateSet('HIP','Vulkan')][string]$Kind,
        [AllowNull()][string]$VisibilityValue
    )

    $all = @($Inventory.Devices)

    # An unset visibility variable means unrestricted visibility, not "zero GPUs".
    # In that case use the backend's own physical index order as the expected
    # order. Windows display-adapter enumeration order is not authoritative.
    if ([string]::IsNullOrWhiteSpace($VisibilityValue)) {
        if ($Kind -eq 'HIP') {
            return @(
                $all |
                Where-Object { $null -ne $_.HipIndex } |
                Sort-Object { [int]$_.HipIndex }
            )
        }

        return @(
            $all |
            Where-Object { $null -ne $_.VulkanIndex } |
            Sort-Object { [int]$_.VulkanIndex }
        )
    }

    # A configured visibility variable is an ordered list of physical indices.
    # Preserve that order: after filtering, child runtimes normally renumber the
    # selected devices from logical index 0 in this same sequence.
    $result = New-Object System.Collections.Generic.List[object]

    foreach ($token in @($VisibilityValue -split ',')) {
        $trimmed = ([string]$token).Trim()
        $index = 0

        if (-not [int]::TryParse($trimmed, [ref]$index)) {
            throw "Invalid $Kind visibility index '$trimmed' in '$VisibilityValue'."
        }

        $match = if ($Kind -eq 'HIP') {
            $all |
                Where-Object { $null -ne $_.HipIndex -and [int]$_.HipIndex -eq $index } |
                Select-Object -First 1
        } else {
            $all |
                Where-Object { $null -ne $_.VulkanIndex -and [int]$_.VulkanIndex -eq $index } |
                Select-Object -First 1
        }

        if ($null -eq $match) {
            throw "Configured $Kind visibility index '$index' cannot be mapped to a detected GPU. Run Detect and correct the mapping before relying on this setting."
        }

        [void]$result.Add($match)
    }

    return $result.ToArray()
}

function Verify-Visibility {
    param(
        [object]$Inventory,
        [AllowNull()][object[]]$ExpectedDevices = $null,
        [switch]$DoNotThrow
    )

    $hipValue = Get-EnvironmentValue -Name 'HIP_VISIBLE_DEVICES' -Target ([EnvironmentVariableTarget]::Machine)
    $vkValue = Get-EnvironmentValue -Name 'GGML_VK_VISIBLE_DEVICES' -Target ([EnvironmentVariableTarget]::Machine)

    # Set-SystemVisibility can pass the selected physical GPU list directly.
    # Standalone Verify instead derives backend-specific expectations from the
    # currently persisted Machine-scope variables.
    if ($null -ne $ExpectedDevices) {
        $expectedHip = @($ExpectedDevices)
        $expectedVk = @($ExpectedDevices)
    } else {
        $expectedHip = @(Get-ExpectedDevicesForVisibility -Inventory $Inventory -Kind HIP -VisibilityValue $hipValue)
        $expectedVk = @(Get-ExpectedDevicesForVisibility -Inventory $Inventory -Kind Vulkan -VisibilityValue $vkValue)
    }

    $failures = New-Object System.Collections.Generic.List[string]
    $verifiedAny = $false

    Write-Host ''
    Write-Host '=== Expected child-process visibility ===' -ForegroundColor Cyan
    Write-Host ("ROCm/HIP: {0} => {1}" -f `
        $(if ([string]::IsNullOrWhiteSpace($hipValue)) { '<unrestricted>' } else { $hipValue }), `
        (($expectedHip | ForEach-Object { $_.Name }) -join ', '))
    Write-Host ("Vulkan  : {0} => {1}" -f `
        $(if ([string]::IsNullOrWhiteSpace($vkValue)) { '<unrestricted>' } else { $vkValue }), `
        (($expectedVk | ForEach-Object { $_.Name }) -join ', '))

    $hipSource = [string]$Inventory.HipProbeSource
    if ($hipSource -and (Test-Path -LiteralPath $hipSource -PathType Leaf)) {
        try {
            $probe = Invoke-NativeCapture `
                -FilePath $hipSource `
                -EnvironmentOverrides @{
                    HIP_VISIBLE_DEVICES = $hipValue
                    ROCR_VISIBLE_DEVICES = $null
                    GPU_DEVICE_ORDINAL = $null
                }

            $actual = @(Parse-HipInfoDevices -Text $probe.AllText -Source $hipSource)
            if ($actual.Count -gt 0) {
                $verifiedAny = $true
                if (Compare-ExpectedAliases -Expected $expectedHip -Actual $actual) {
                    Write-Host ('ROCm/HIP verification: PASS  -> ' + (($actual | ForEach-Object { "$($_.Index):$($_.Name)" }) -join '; ')) -ForegroundColor Green
                } else {
                    [void]$failures.Add('HIP child-process device list does not match the expected physical GPUs/order.')
                    Write-Warning ('ROCm/HIP verification mismatch. Expected: ' +
                        (($expectedHip | ForEach-Object { $_.Name }) -join '; ') +
                        '. Child saw: ' +
                        (($actual | ForEach-Object { "$($_.Index):$($_.Name)" }) -join '; '))
                }
            } else {
                Write-Warning 'HIP verification probe returned no parseable devices.'
            }
        } catch {
            Write-Warning "HIP verification probe failed: $($_.Exception.Message)"
        }
    } else {
        Write-Warning 'HIP verification skipped because no hipInfo.exe probe is available.'
    }

    $vkSource = [string]$Inventory.VulkanProbeSource
    if ($vkSource -and (Test-Path -LiteralPath $vkSource -PathType Leaf)) {
        try {
            $probe = Invoke-NativeCapture `
                -FilePath $vkSource `
                -Arguments @('--list-devices') `
                -EnvironmentOverrides @{
                    GGML_VK_VISIBLE_DEVICES = $vkValue
                }

            $actual = @(Parse-VulkanDevices -Text $probe.AllText -Source $vkSource)
            if ($actual.Count -gt 0) {
                $verifiedAny = $true
                if (Compare-ExpectedAliases -Expected $expectedVk -Actual $actual) {
                    Write-Host ('Vulkan verification: PASS    -> ' + (($actual | ForEach-Object { "Vulkan$($_.Index):$($_.Name)" }) -join '; ')) -ForegroundColor Green
                } else {
                    [void]$failures.Add('Vulkan child-process device list does not match the expected physical GPUs/order.')
                    Write-Warning ('Vulkan verification mismatch. Expected: ' +
                        (($expectedVk | ForEach-Object { $_.Name }) -join '; ') +
                        '. Child saw: ' +
                        (($actual | ForEach-Object { "Vulkan$($_.Index):$($_.Name)" }) -join '; '))
                }
            } else {
                Write-Warning 'Vulkan verification probe returned no parseable devices.'
            }
        } catch {
            Write-Warning "Vulkan verification probe failed: $($_.Exception.Message)"
        }
    } else {
        Write-Warning 'Vulkan verification skipped because no Vulkan-enabled llama-server.exe probe is available.'
    }

    if (-not $verifiedAny) {
        Write-Warning 'No runtime child-process verification could be completed. Machine-scope variables are persisted, but verify with your target runtime after restarting it.'
        return
    }

    if ($failures.Count -gt 0 -and -not $DoNotThrow) {
        throw ('Visibility verification failed: ' + ($failures.ToArray() -join ' '))
    }

    if ($failures.Count -eq 0) {
        Write-Host 'Visibility verification completed successfully.' -ForegroundColor Green
    }
}


function Disable-Visibility {
    Write-Host ''
    Write-Host 'Removing all managed GPU visibility restrictions from Machine, User and current Process scopes...' -ForegroundColor Cyan

    Invoke-ElevatedMachineEnvironmentWrite -Updates @{
        HIP_VISIBLE_DEVICES     = $null
        GGML_VK_VISIBLE_DEVICES = $null
        ROCR_VISIBLE_DEVICES    = $null
        GPU_DEVICE_ORDINAL      = $null
    }

    foreach ($name in @($script:ManagedVariables + $script:ConflictVariables)) {
        Clear-VisibilityVariableUserProcessScopes -Name $name
        Write-Host "Removed: $name"
    }

    Broadcast-EnvironmentChange

    Write-Host ''
    Write-Host 'GPU visibility restrictions disabled.' -ForegroundColor Green
    Write-Host 'New processes will see their normal full GPU set.' -ForegroundColor Green
    Write-Host 'Windows reboot required: No' -ForegroundColor Green

    $running = @(Get-RunningGpuConsumers)
    if ($running.Count -gt 0) {
        Write-Host ''
        Write-Host 'Restart required for these already-running GPU consumers:' -ForegroundColor Yellow
        $running | Format-Table Name, ProcessId, ExecutablePath -AutoSize
    }
}

function Invoke-Menu {
    param([object]$Inventory)

    while ($true) {
        Write-Host ''
        Write-Host 'GPU Visibility Manager' -ForegroundColor Cyan
        Write-Host '  1. Status'
        Write-Host '  2. Detect / refresh GPU mapping'
        Write-Host '  3. Choose Vulkan and ROCm GPUs separately (system-wide)'
        Write-Host '  4. Verify current system-wide visibility'
        Write-Host '  5. Disable all visibility restrictions'
        Write-Host '  0. Exit'

        $choice = Read-Host 'Select'

        switch ($choice) {
            '1' {
                Show-Status -Inventory $Inventory
            }
            '2' {
                $Inventory = Get-HardwareInventory
                Show-Inventory -Inventory $Inventory
            }
            '3' {
                Show-Inventory -Inventory $Inventory
                try {
                    Write-Host 'Choose each backend separately using the # column, aliases, or all.'
                    Write-Host 'Examples: 3 or 3,4. Enter at either prompt cancels without changes.'
                    $vkSelection = Read-Host 'Vulkan (VK) GPU number(s)'
                    if ([string]::IsNullOrWhiteSpace($vkSelection)) { Write-Host 'Cancelled.'; continue }
                    $vkSelected = @(Resolve-GpuSelection -Inventory $Inventory -Selection $vkSelection -Backend Vulkan)
                    $hipSelection = Read-Host 'ROCm (HIP) GPU number(s)'
                    if ([string]::IsNullOrWhiteSpace($hipSelection)) { Write-Host 'Cancelled.'; continue }
                    $hipSelected = @(Resolve-GpuSelection -Inventory $Inventory -Selection $hipSelection -Backend HIP)
                    Set-SystemVisibility -Inventory $Inventory -HipSelected $hipSelected -VulkanSelected $vkSelected -ConfirmSelection
                } catch { Write-Warning $_.Exception.Message }
            }
            '4' {
                Verify-Visibility -Inventory $Inventory
            }
            '5' {
                $answer = Read-Host 'Remove HIP/Vulkan visibility restrictions from Machine, User and current Process scopes? Type YES'
                if ($answer -ceq 'YES') {
                    Disable-Visibility
                } else {
                    Write-Host 'Disable cancelled.' -ForegroundColor Yellow
                }
            }
            '0' {
                return
            }
            default {
                Write-Warning 'Unknown selection.'
            }
        }
    }
}

function Invoke-Main {
    Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction SilentlyContinue
    Write-Log "GPU Visibility Manager revision $script:Revision"

    $inventory = Get-HardwareInventory

    switch ($Action) {
        'Detect' {
            Show-Inventory -Inventory $inventory
        }

        'Status' {
            Show-Status -Inventory $inventory
        }

        'Set' {
            if ($VulkanGpu -or $RocmGpu) {
                if ($Gpu -or [string]::IsNullOrWhiteSpace($VulkanGpu) -or [string]::IsNullOrWhiteSpace($RocmGpu)) {
                    throw 'Supply both -VulkanGpu and -RocmGpu, without -Gpu. Or use -Gpu for the same GPUs in both backends.'
                }
                $vkSelected = @(Resolve-GpuSelection -Inventory $inventory -Selection $VulkanGpu -Backend Vulkan)
                $hipSelected = @(Resolve-GpuSelection -Inventory $inventory -Selection $RocmGpu -Backend HIP)
                Set-SystemVisibility -Inventory $inventory -HipSelected $hipSelected -VulkanSelected $vkSelected
                break
            }
            if ([string]::IsNullOrWhiteSpace($Gpu)) {
                Show-Inventory -Inventory $inventory
                throw '-Gpu is required for Set. Example: Set -Gpu 1 or Set -Gpu "1,2".'
            }
            $selected = @(Resolve-GpuSelection -Inventory $inventory -Selection $Gpu)
            Set-SystemVisibility -Inventory $inventory -Selected $selected
        }

        'Verify' {
            Verify-Visibility -Inventory $inventory
        }

        'Disable' {
            Disable-Visibility
        }

        'Menu' {
            Invoke-Menu -Inventory $inventory
        }
    }
}

try {
    Invoke-Main
} catch {
    Write-Host ''
    Write-Host 'FATAL SCRIPT ERROR' -ForegroundColor Red
    Write-Host "Message : $($_.Exception.Message)" -ForegroundColor Red

    if ($_.InvocationInfo) {
        Write-Host "Line    : $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
        if ($_.InvocationInfo.PositionMessage) {
            Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkRed
        }
    }

    if ($_.ScriptStackTrace) {
        Write-Host 'Stack:' -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }

    throw
}
