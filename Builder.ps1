param([switch]$RuntimeOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# NoLemonade v0.3.0
# Purpose:
#   1. Build a side-by-side LemonadeServer.exe with NoLemonade's Windows AMD
#      correctness fixes:
#        - R9700 classified as discrete / gfx120X
#        - sane VRAM reporting (DXGI first; reject negative WMI sentinels)
#        - dedicated GPU preferred as primary over UMA/shared adapters
#        - suppress an unclassified duplicate AMD adapter when an identical
#          classified adapter is present
#   2. Build the temporary R9700-only llama.cpp launcher around a selected
#      gfx120X ROCm nightly package. Set the build number once in $runtimeTag;
#      the matching release asset, download URL, SHA-256, cache and wrapper
#      paths are resolved automatically.
#
# Safety:
#   - Does not modify C:\lemonade_server.
#   - Does not modify ~/.config/lemonade.
#   - Does not modify model registrations.
#   - Does not write machine/user environment variables.
#   - All project files live under C:\AI\NoLemonade.

$projectRoot = 'C:\AI\NoLemonade'
$lemonadeSrc = Join-Path $projectRoot 'lemonade-src'
$launcherSource = Join-Path $projectRoot 'NoLemonadeLauncher.cs'
$launcherExe = Join-Path $projectRoot 'NoLemonadeLauncher.exe'

$lemonadeTag = 'v2026.43.3'
$lemonadeRepo = 'https://github.com/lemonade-sdk/lemonade.git'

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

# NoLemonade owns complete, verified ROCm runtimes side-by-side.
# We deliberately do NOT depend on or modify Lemonade's ~/.cache runtime.
#
# SELECT THE LLAMA.CPP ROCm BUILD HERE -- this is the only version value that
# needs to change. Format: b followed by the numeric build number.
$runtimeTag = 'b1353'

$runtimeArch = 'gfx120X'
if ($runtimeTag -notmatch '^b[0-9]+$') {
    throw "Invalid runtimeTag '$runtimeTag'. Expected 'b' followed by the numeric build number."
}

$runtimeAsset = "llama-$runtimeTag-windows-rocm-$runtimeArch-x64.zip"
$downloadsDir = Join-Path $projectRoot 'downloads'
$runtimeZip = Join-Path $downloadsDir $runtimeAsset
$runtimeRoot = Join-Path $projectRoot "runtime\$runtimeTag-$runtimeArch"
$realLlama = Join-Path $runtimeRoot 'llama-server.exe'
$rocmBin = $runtimeRoot

# Refuse to rebuild the executable currently being used by a running NoLemonade
# process. This is read-only and avoids partial/retry linker behaviour on Windows.
$runningNoLemonade = @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith(
                $projectRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            (-not $RuntimeOnly -or $_.Name -ne 'LemonadeServer.exe') -and
            $_.Name -in @(
                'LemonadeServer.exe',
                'NoLemonadeLauncher.exe',
                'NoLemonadeR9700Launcher.exe',
                'llama-server.exe'
            )
        }
)
if ($runningNoLemonade.Count -gt 0) {
    $runningNoLemonade |
        Select-Object ProcessId, ParentProcessId, Name, ExecutablePath |
        Format-Table -AutoSize
    throw 'A NoLemonade process is running. Stop it before rebuilding; no source files were changed.'
}


function Resolve-CommandPath {
    param([Parameter(Mandatory=$true)][string]$Name)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    return $null
}

function Resolve-CMakePath {
    $fromPath = Resolve-CommandPath 'cmake'
    if ($fromPath) {
        return $fromPath
    }

    # Standalone Kitware CMake installed by WinGet/MSI may not appear in the
    # current PowerShell PATH until a new shell is opened. Probe its normal
    # install locations directly so Builder can continue in the same session.
    $standaloneCandidates = @(
        (Join-Path ${env:ProgramFiles} 'CMake\bin\cmake.exe'),
        (Join-Path ${env:LOCALAPPDATA} 'Programs\CMake\bin\cmake.exe')
    )

    if (${env:ProgramFiles(x86)}) {
        $standaloneCandidates +=
            (Join-Path ${env:ProgramFiles(x86)} 'CMake\bin\cmake.exe')
    }

    foreach ($candidate in $standaloneCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    # Visual Studio 2022 installs its bundled CMake here when the
    # "C++ CMake tools for Windows" component is present.
    $vsRoot = Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio\2022'
    if (Test-Path -LiteralPath $vsRoot) {
        $candidates = @(
            Get-ChildItem -LiteralPath $vsRoot -Directory -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Join-Path $_.FullName 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
                }
        )

        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }

    # Last fallback: use vswhere if available to discover a non-standard VS install.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $installations = @(
            & $vswhere -products * -version '[17.0,18.0)' -property installationPath 2>$null
        )

        foreach ($installation in $installations) {
            if (-not [string]::IsNullOrWhiteSpace($installation)) {
                $candidate = Join-Path $installation 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    return $candidate
                }
            }
        }
    }

    return $null
}

function Install-CMakeIfMissing {
    $cmakePath = Resolve-CMakePath
    if ($cmakePath) {
        return $cmakePath
    }

    $winget = Resolve-CommandPath 'winget'
    if (-not $winget) {
        throw @"
CMake is not installed and Windows Package Manager (winget) was not found.

NoLemonade will not download or execute an unverified installer directly.
Install Microsoft App Installer / WinGet, then rerun Builder.ps1.

No Lemonade files or configuration were changed.
"@
    }

    Write-Host "`n=== INSTALL CMAKE ==="
    Write-Host "CMake was not found."
    Write-Host "Installing exact WinGet package: Kitware.CMake"
    Write-Host "A Windows elevation prompt may appear depending on the selected installer."

    & $winget install `
        --exact `
        --id Kitware.CMake `
        --source winget `
        --accept-source-agreements `
        --accept-package-agreements |
        Out-Host

    $wingetExit = $LASTEXITCODE
    if ($wingetExit -ne 0) {
        throw "WinGet failed to install Kitware.CMake with exit code ${wingetExit}. No Lemonade files were changed."
    }

    $cmakePath = Resolve-CMakePath
    if (-not $cmakePath) {
        throw @"
WinGet reported success, but cmake.exe could not be located in PATH or the
standard Kitware/Visual Studio locations.

NoLemonade stopped before cloning, patching, or building Lemonade.
Open a new PowerShell and run:
  cmake --version

If that works, rerun Builder.ps1.
"@
    }

    $versionText = (& $cmakePath --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '(?i)^cmake version ') {
        throw "CMake was found at '$cmakePath' but version verification failed."
    }

    Write-Host "Installed/verified CMake:"
    Write-Host $versionText

    return $cmakePath
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments
    )

    # Windows PowerShell 5.1 converts native stderr lines into PowerShell
    # error records. Tools such as git and cmake legitimately use stderr for
    # progress/status output, which would otherwise trip the script-wide
    # ErrorActionPreference='Stop'.
    #
    # Relax PowerShell error promotion only around this native process.
    # The native exit code remains the authoritative success/failure gate.
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $FilePath @Arguments 2>&1 | Out-Host
        $nativeExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    if ($nativeExit -ne 0) {
        throw "Command failed with exit code ${nativeExit}: $FilePath $($Arguments -join ' ')"
    }
}

Write-Host "=== NoLemonade v0.3.0 builder ==="
Write-Host "Selected llama.cpp ROCm build: $runtimeTag ($runtimeArch, Windows x64)"

$git = Resolve-CommandPath 'git'
if (-not $git) {
    throw "Git was not found in PATH. No changes were made."
}

$cmake = $null
if (-not $RuntimeOnly) { $cmake = Install-CMakeIfMissing }

Write-Host "Git:   $git"
Write-Host "CMake: $cmake"

if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
    throw "Required C# compiler missing: $csc"
}

function Test-NoLemonadeRuntime {
    param([Parameter(Mandatory=$true)][string]$Root)

    $server = Join-Path $Root 'llama-server.exe'
    $hipBackend = Join-Path $Root 'ggml-hip.dll'
    $rocblas = Join-Path $Root 'rocblas.dll'
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $hipBackend -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $rocblas -PathType Leaf)) { return $false }

    $amdhip = @(
        Get-ChildItem -LiteralPath $Root -File -Filter 'amdhip64_*.dll' `
            -ErrorAction SilentlyContinue
    )
    if ($amdhip.Count -lt 1) { return $false }

    $hipblas = @(
        Get-ChildItem -LiteralPath $Root -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -in @(
                    'libhipblas.dll',
                    'hipblas.dll',
                    'hipblaslt.dll',
                    'libhipblaslt.dll'
                )
            }
    )
    if ($hipblas.Count -lt 1) { return $false }

    return $true
}

function Get-FileSha256Lower {
    param([Parameter(Mandatory=$true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Resolve-NoLemonadeRuntimeRelease {
    param(
        [Parameter(Mandatory=$true)][string]$Tag,
        [Parameter(Mandatory=$true)][string]$AssetName
    )

    # Resolve the exact release asset and its GitHub-published SHA-256 digest.
    # This removes all per-build hardcoding: changing $runtimeTag is sufficient.
    $apiUri = "https://api.github.com/repos/lemonade-sdk/llamacpp-rocm/releases/tags/$Tag"
    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'User-Agent' = 'NoLemonade-Builder'
    }

    Write-Host "`nResolving official llama.cpp ROCm release metadata: $Tag"

    try {
        $release = Invoke-RestMethod `
            -Uri $apiUri `
            -Headers $headers `
            -UseBasicParsing `
            -ErrorAction Stop
    }
    catch {
        throw @"
Could not resolve GitHub release metadata for '$Tag'.
No runtime download or overwrite was attempted.

API:
  $apiUri

Error:
  $($_.Exception.Message)
"@
    }

    $tagProperty = $release.PSObject.Properties['tag_name']
    if ($null -eq $tagProperty -or [string]$tagProperty.Value -ne $Tag) {
        throw "GitHub release metadata did not resolve to the requested tag '$Tag'."
    }

    $assetsProperty = $release.PSObject.Properties['assets']
    if ($null -eq $assetsProperty) {
        throw "GitHub release '$Tag' did not expose an assets collection."
    }

    $assetMatches = @(
        $assetsProperty.Value |
            Where-Object { $_.name -eq $AssetName }
    )

    if ($assetMatches.Count -ne 1) {
        $availableNames = @(
            $assetsProperty.Value |
                ForEach-Object { $_.name } |
                Sort-Object
        )

        throw @"
Expected exactly one official release asset named:
  $AssetName

Release: $Tag
Matching assets found: $($assetMatches.Count)

Available assets:
  $($availableNames -join "`n  ")

No download was attempted.
"@
    }

    $asset = $assetMatches[0]
    $urlProperty = $asset.PSObject.Properties['browser_download_url']
    $digestProperty = $asset.PSObject.Properties['digest']

    if ($null -eq $urlProperty -or
        [string]::IsNullOrWhiteSpace([string]$urlProperty.Value)) {
        throw "GitHub asset '$AssetName' has no browser_download_url."
    }

    if ($null -eq $digestProperty -or
        [string]::IsNullOrWhiteSpace([string]$digestProperty.Value)) {
        throw @"
GitHub did not publish a digest for '$AssetName'.
NoLemonade will not download or trust an unverified runtime automatically.
"@
    }

    $digestText = [string]$digestProperty.Value
    $digestMatch = [regex]::Match($digestText, '^sha256:([0-9A-Fa-f]{64})$')
    if (-not $digestMatch.Success) {
        throw "Unexpected GitHub digest format for '$AssetName': $digestText"
    }

    [PSCustomObject]@{
        Tag = $Tag
        AssetName = $AssetName
        Url = [string]$urlProperty.Value
        Sha256 = $digestMatch.Groups[1].Value.ToLowerInvariant()
    }
}

function Invoke-Download {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$OutFile,
        [switch]$Resume
    )

    $curl = Resolve-CommandPath 'curl.exe'
    if ($curl) {
        # Windows PowerShell 5.1 turns native stderr into PowerShell error
        # records. curl's normal progress meter uses stderr, so under the
        # script-wide ErrorActionPreference='Stop' it can look like a failed
        # download even when curl is healthy.
        #
        # Keep this relaxation scoped to the native curl invocation only.
        # --silent removes the progress meter, while --show-error preserves
        # real curl diagnostics. The actual success gate is curl's exit code
        # followed by SHA-256 verification.
        $savedErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'

            $curlArgs = @(
                '--fail',
                '--location',
                '--retry', '3',
                '--retry-delay', '2',
                '--silent',
                '--show-error'
            )

            if ($Resume) {
                $curlArgs += @('--continue-at', '-')
            }

            $curlArgs += @(
                '--output', $OutFile,
                $Uri
            )

            & $curl @curlArgs 2>&1 | Out-Host
            $curlExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }

        if ($curlExit -ne 0) {
            throw "curl.exe failed with exit code ${curlExit} while downloading $Uri"
        }
        return
    }

    if ($Resume) {
        throw @"
A partial NoLemonade runtime download already exists, but curl.exe is not
available to resume it safely:
  $OutFile

NoLemonade refuses to overwrite the partial file automatically.
"@
    }

    # PowerShell fallback; still writes only to NoLemonade's own downloads folder.
    Invoke-WebRequest `
        -Uri $Uri `
        -OutFile $OutFile `
        -UseBasicParsing
}

function Remove-NoLemonadeStaging {
    param([Parameter(Mandatory=$true)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $prefix = [IO.Path]::GetFullPath($runtimeRoot) + '.staging-'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        (Get-Item -LiteralPath $Path).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing to remove unexpected staging path: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force -WhatIf
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Ensure-NoLemonadeRuntime {
    # Directory names and locally authored manifests are not proof of provenance.
    # Compare the full payload against a freshly verified official archive.
    $releaseAsset = Resolve-NoLemonadeRuntimeRelease `
        -Tag $runtimeTag `
        -AssetName $runtimeAsset

    $runtimeUrl = $releaseAsset.Url
    $runtimeSha256 = $releaseAsset.Sha256

    Write-Host "Resolved official asset:"
    Write-Host "  $runtimeAsset"
    Write-Host "SHA-256:"
    Write-Host "  $runtimeSha256"

    if (-not (Test-Path -LiteralPath $downloadsDir)) {
        New-Item -ItemType Directory -Path $downloadsDir | Out-Null
    }

    if (Test-Path -LiteralPath $runtimeZip -PathType Leaf) {
        $existingHash = Get-FileSha256Lower -Path $runtimeZip
        if ($existingHash -ne $runtimeSha256) {
            $rejectedZip = "$runtimeZip.rejected-$([guid]::NewGuid().ToString('N'))"
            Move-Item -LiteralPath $runtimeZip -Destination $rejectedZip -WhatIf
            Move-Item -LiteralPath $runtimeZip -Destination $rejectedZip
            Write-Warning "Preserved incorrect archive at $rejectedZip"
        }

    }
    if (-not (Test-Path -LiteralPath $runtimeZip -PathType Leaf)) {
        Write-Host "`n=== DOWNLOAD VERIFIED ROCm RUNTIME ==="
        Write-Host "Build:"
        Write-Host "  $runtimeTag"
        Write-Host "Asset:"
        Write-Host "  $runtimeAsset"
        Write-Host "Expected SHA-256:"
        Write-Host "  $runtimeSha256"
        Write-Host "Destination:"
        Write-Host "  $runtimeZip"

        # Download to a separate .partial path and only rename after hash verification.
        # If our own previous partial file exists, resume it in-place rather than
        # deleting or overwriting it.
        $partial = "$runtimeZip.partial"
        $resumeDownload = $false

        if (Test-Path -LiteralPath $partial -PathType Leaf) {
            $partialItem = Get-Item -LiteralPath $partial
            Write-Host "`nFound existing NoLemonade partial download:"
            Write-Host "  $partial"
            Write-Host "  $($partialItem.Length) bytes"
            Write-Host "Attempting a non-destructive HTTP resume."
            $resumeDownload = $true
        }

        Invoke-Download `
            -Uri $runtimeUrl `
            -OutFile $partial `
            -Resume:$resumeDownload

        $downloadedHash = Get-FileSha256Lower -Path $partial
        if ($downloadedHash -ne $runtimeSha256) {
            $rejectedPartial = "$partial.rejected-$([guid]::NewGuid().ToString('N'))"
            Move-Item -LiteralPath $partial -Destination $rejectedPartial -WhatIf
            Move-Item -LiteralPath $partial -Destination $rejectedPartial
            throw @"
Downloaded runtime failed SHA-256 verification.

Expected:
  $runtimeSha256

Actual:
  $downloadedHash

Rejected download was preserved for inspection; retry will start fresh:
  $rejectedPartial
"@
        }

        Move-Item -LiteralPath $partial -Destination $runtimeZip
        Write-Host "PASS: runtime ZIP SHA-256 verified."
    }

    # Extract into a unique staging directory; never merge into an existing runtime.
    $staging = "$runtimeRoot.staging-$([guid]::NewGuid().ToString('N'))"
    if (Test-Path -LiteralPath $staging) {
        throw @"
A previous runtime staging directory exists:
  $staging

NoLemonade refuses to overwrite it automatically.
Inspect or rename it, then rerun Builder.ps1.
"@
    }

    New-Item -ItemType Directory -Path $staging | Out-Null

    Write-Host "`n=== EXTRACT ROCm RUNTIME ==="
    Expand-Archive -LiteralPath $runtimeZip -DestinationPath $staging

    # GitHub release archives may contain either files directly at the root or
    # one top-level directory. Normalize by discovering llama-server.exe.
    $servers = @(
        Get-ChildItem -LiteralPath $staging -Recurse -File `
            -Filter 'llama-server.exe' -ErrorAction Stop
    )

    if ($servers.Count -ne 1) {
        throw "Expected exactly one llama-server.exe in extracted runtime; found $($servers.Count)."
    }

    $extractedRoot = $servers[0].Directory.FullName

    if (-not (Test-NoLemonadeRuntime -Root $extractedRoot)) {
        Write-Host "`nExtracted runtime dependency inventory:"
        Get-ChildItem -LiteralPath $extractedRoot -File |
            Where-Object { $_.Name -match '(?i)(ggml|hip|roc|comgr|kpack)' } |
            Select-Object Name, Length, LastWriteTime |
            Sort-Object Name |
            Format-Table -AutoSize

        throw @"
The official runtime archive extracted successfully but did not pass the
NoLemonade dependency integrity check.

Nothing was installed into Lemonade and the staging directory was preserved:
  $staging
"@
    }

    $expectedFiles = @(Get-ChildItem -LiteralPath $extractedRoot -Recurse -File -Force)
    $matches = Test-Path -LiteralPath $runtimeRoot -PathType Container
    if ($matches) {
        $actualFiles = @(Get-ChildItem -LiteralPath $runtimeRoot -Recurse -File -Force)
        $matches = $actualFiles.Count -eq $expectedFiles.Count
        foreach ($file in $expectedFiles) {
            if (-not $matches) { break }
            $relative = $file.FullName.Substring($extractedRoot.Length).TrimStart('\')
            $installed = Join-Path $runtimeRoot $relative
            $matches = (Test-Path -LiteralPath $installed -PathType Leaf) -and
                ((Get-FileSha256Lower $installed) -eq (Get-FileSha256Lower $file.FullName))
        }
    }

    if ($matches) {
        Write-Host "PASS: every installed runtime file matches the verified $runtimeTag archive."
        Remove-NoLemonadeStaging -Path $staging
        return
    }

    # Recheck immediately before replacement: a model may have started during download.
    $active = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('NoLemonadeLauncher.exe', 'NoLemonadeR9700Launcher.exe') -or
        ($_.ExecutablePath -and $_.ExecutablePath.StartsWith(
            $runtimeRoot + '\', [System.StringComparison]::OrdinalIgnoreCase))
    })
    if ($active.Count -gt 0) {
        throw "Runtime is in use; verified download retained at $staging. Unload the model and retry."
    }
    if (Test-Path -LiteralPath $runtimeRoot) {
        $resolvedRuntime = (Resolve-Path -LiteralPath $runtimeRoot).Path
        $allowedRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'runtime')) + '\'
        if (-not $resolvedRuntime.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Runtime path escapes project runtime directory: $resolvedRuntime"
        }
        $backup = "$runtimeRoot.replaced-$([guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $runtimeRoot -Destination $backup -WhatIf
        Move-Item -LiteralPath $runtimeRoot -Destination $backup
        Write-Host "Previous runtime preserved: $backup"
    }

    try {
        Move-Item -LiteralPath $extractedRoot -Destination $runtimeRoot
    }
    catch {
        if ((Test-Path variable:backup) -and -not (Test-Path -LiteralPath $runtimeRoot)) {
            Move-Item -LiteralPath $backup -Destination $runtimeRoot
        }
        throw
    }
    if ($extractedRoot -ne $staging) {
        Remove-NoLemonadeStaging -Path $staging
    }

    if (-not (Test-NoLemonadeRuntime -Root $runtimeRoot)) {
        throw "Final NoLemonade runtime integrity check failed: $runtimeRoot"
    }

    Write-Host "PASS: complete NoLemonade ROCm runtime provisioned."
}

Ensure-NoLemonadeRuntime
if ($RuntimeOnly) {
    Write-Host 'Runtime verification complete. Server and launcher were not rebuilt.'
    return
}

function Invoke-LlamaListDevices {
    param([Parameter(Mandatory=$true)][string]$Exe)

    # Use Start-Process with redirected native streams so Windows PowerShell 5.1
    # cannot turn llama.cpp stderr diagnostics into formatted NativeCommandError
    # records. Temporary files are NoLemonade-owned and removed immediately.
    $tmpBase = Join-Path $projectRoot ("probe-" + [Guid]::NewGuid().ToString('N'))
    $stdoutFile = "$tmpBase.stdout.txt"
    $stderrFile = "$tmpBase.stderr.txt"

    try {
        $p = Start-Process `
            -FilePath $Exe `
            -ArgumentList '--list-devices' `
            -WorkingDirectory (Split-Path -Parent $Exe) `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile `
            -Wait `
            -PassThru `
            -NoNewWindow

        $stdout = ''
        $stderr = ''

        if (Test-Path -LiteralPath $stdoutFile -PathType Leaf) {
            $stdout = [System.IO.File]::ReadAllText($stdoutFile)
        }
        if (Test-Path -LiteralPath $stderrFile -PathType Leaf) {
            $stderr = [System.IO.File]::ReadAllText($stderrFile)
        }

        $combined = ''
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $combined += $stderr.TrimEnd()
        }
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            if ($combined.Length -gt 0) {
                $combined += [Environment]::NewLine
            }
            $combined += $stdout.TrimEnd()
        }

        [PSCustomObject]@{
            ExitCode = $p.ExitCode
            Output = $combined
        }
    }
    finally {
        foreach ($tmp in @($stdoutFile, $stderrFile)) {
            if (Test-Path -LiteralPath $tmp -PathType Leaf) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# Verify the selected official runtime package and discover the R9700's current Windows HIP index.
# Windows/ROCm enumeration order is not assumed to be stable.
Write-Host "`n=== VERIFY REAL ROCm BACKEND ==="

Write-Host "`nBaseline device listing (informational):"

$baselineNames = @(
    'PATH',
    'HIP_VISIBLE_DEVICES',
    'ROCR_VISIBLE_DEVICES'
)

$baselineSaved = @{}
foreach ($name in $baselineNames) {
    $baselineSaved[$name] =
        [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
    $env:PATH = "$rocmBin;$($baselineSaved['PATH'])"

    # A deterministic baseline must expose the complete Windows HIP inventory.
    [Environment]::SetEnvironmentVariable(
        'HIP_VISIBLE_DEVICES', $null, 'Process')
    [Environment]::SetEnvironmentVariable(
        'ROCR_VISIBLE_DEVICES', $null, 'Process')

    Push-Location $rocmBin
    try {
        $baseline = Invoke-LlamaListDevices -Exe $realLlama
    }
    finally {
        Pop-Location
    }
}
finally {
    foreach ($name in $baselineNames) {
        [Environment]::SetEnvironmentVariable(
            $name, $baselineSaved[$name], 'Process')
    }
}

$baselineOutput = $baseline.Output
$baselineExit = $baseline.ExitCode
Write-Host $baselineOutput

if ($baselineExit -ne 0) {
    Write-Warning "Baseline llama-server --list-devices exited with code $baselineExit."
}

function Invoke-RocmDeviceProbe {
    param(
        [Parameter(Mandatory=$true)][int]$Index
    )

    $probeNames = @(
        'PATH',
        'HIP_VISIBLE_DEVICES',
        'ROCR_VISIBLE_DEVICES',
        'GGML_CUDA_DISABLE_GRAPHS'
    )

    $probeSaved = @{}
    foreach ($name in $probeNames) {
        $probeSaved[$name] =
            [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        $env:PATH = "$rocmBin;$($probeSaved['PATH'])"

        # AMD's Windows guidance is to use HIP_VISIBLE_DEVICES for isolation.
        # Do not stack ROCR_VISIBLE_DEVICES on top of it: that can filter and
        # renumber the ROCr set before HIP applies its own index selection.
        $env:HIP_VISIBLE_DEVICES = "$Index"
        [Environment]::SetEnvironmentVariable(
            'ROCR_VISIBLE_DEVICES', $null, 'Process')

        $env:GGML_CUDA_DISABLE_GRAPHS = '1'

        Push-Location $rocmBin
        try {
            $probeRun = Invoke-LlamaListDevices -Exe $realLlama
            $output = $probeRun.Output
            $exitCode = $probeRun.ExitCode
        }
        finally {
            Pop-Location
        }
    }
    finally {
        foreach ($name in $probeNames) {
            [Environment]::SetEnvironmentVariable(
                $name, $probeSaved[$name], 'Process')
        }
    }

    [PSCustomObject]@{
        Index = $Index
        ExitCode = $exitCode
        Output = $output.TrimEnd()
        HasR9700 = ($output -match '(?i)R9700')
        Has890M = ($output -match '(?i)890M')
    }
}

Write-Host "`nProbing ROCm physical device indices 0..3:"
$rocmProbes = @()

foreach ($index in 0..3) {
    $probe = Invoke-RocmDeviceProbe -Index $index
    $rocmProbes += $probe

    Write-Host "`n--- index $index ---"
    Write-Host $probe.Output
}

$r9700Probe = @(
    $rocmProbes |
        Where-Object {
            $_.ExitCode -eq 0 -and
            $_.HasR9700 -and
            -not $_.Has890M
        }
) | Select-Object -First 1

if ($null -eq $r9700Probe) {
    Write-Host "`n=== ROCm BUNDLE INVENTORY ==="

    Get-ChildItem -LiteralPath $rocmBin -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '(?i)(ggml|hip|roc|comgr|kpack)'
        } |
        Select-Object Name, Length, LastWriteTime |
        Sort-Object Name |
        Format-Table -AutoSize

    throw @"
NoLemonade could not find an isolated ROCm device index that exposes the R9700.

Indices 0..3 were tested with:
  HIP_VISIBLE_DEVICES=<index>
  ROCR_VISIBLE_DEVICES=<unset on Windows>
  GGML_CUDA_DISABLE_GRAPHS=1
  PATH prefixed with:
    $rocmBin
  working directory:
    $rocmBin

No Lemonade source/config/runtime files were changed.

The output above is now sufficient to distinguish a device-index problem from
a missing/non-loading HIP backend.
"@
}

$r9700Index = [int]$r9700Probe.Index

Write-Host "`nPASS: R9700 detected at physical Windows HIP index $r9700Index."
Write-Host "That index will be compiled into the NoLemonade child wrapper."

if (-not (Test-Path -LiteralPath $projectRoot)) {
    New-Item -ItemType Directory -Path $projectRoot | Out-Null
}

# ---------------------------------------------------------------------------
# Lemonade source: side-by-side checkout only.
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $lemonadeSrc)) {
    Write-Host "`n=== CLONE LEMONADE $lemonadeTag ==="
    Invoke-Checked $git clone --branch $lemonadeTag --depth 1 $lemonadeRepo $lemonadeSrc
}
else {
    if (-not (Test-Path -LiteralPath (Join-Path $lemonadeSrc '.git'))) {
        throw "Existing path is not a Git checkout; refusing to touch it: $lemonadeSrc"
    }

    $origin = (& $git -C $lemonadeSrc remote get-url origin 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $origin -notmatch 'lemonade-sdk/lemonade') {
        throw "Unexpected repository at $lemonadeSrc. Refusing to continue."
    }

    Write-Host "`nUsing existing NoLemonade source checkout: $lemonadeSrc"
}

$systemInfo = Join-Path $lemonadeSrc 'src\cpp\server\system_info.cpp'
$wmiHelper = Join-Path $lemonadeSrc 'src\cpp\server\utils\wmi_helper.cpp'
$metricsHeader = Join-Path $lemonadeSrc 'src\cpp\include\lemon\system_metrics_platform.h'
$amdMetrics = Join-Path $lemonadeSrc 'src\cpp\server\platform\amd_metrics_windows.h'

foreach ($sourceFile in @($systemInfo, $wmiHelper, $metricsHeader, $amdMetrics)) {
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        throw "Expected Lemonade source file missing: $sourceFile"
    }
}

# Validate that the checkout is still exactly the intended upstream tag.
$expectedCommit = (& $git -C $lemonadeSrc rev-list -n 1 $lemonadeTag 2>$null | Out-String).Trim()
$currentCommit = (& $git -C $lemonadeSrc rev-parse HEAD 2>$null | Out-String).Trim()
if (-not $expectedCommit -or -not $currentCommit -or $expectedCommit -ne $currentCommit) {
    throw @"
NoLemonade source checkout is not at the expected $lemonadeTag commit.
Expected: $expectedCommit
Current:  $currentCommit

No reset/checkout was performed.
"@
}

$backupRoot = Join-Path $projectRoot (
    'backups\v0.3.0-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-pid$PID"
)
$backedUp = @{}

function Backup-PatchTarget {
    param([Parameter(Mandatory=$true)][string]$Path)

    if ($backedUp.ContainsKey($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $backupRoot | Out-Null
    }

    $relative = $Path.Substring($lemonadeSrc.Length).TrimStart('\')
    $destination = Join-Path $backupRoot $relative
    $destinationDir = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $Path -Destination $destination
    $backedUp[$Path] = $destination
}

function Write-PatchedSource {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )

    Backup-PatchTarget -Path $Path
    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Apply-LiteralPatch {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][string]$Original,
        [Parameter(Mandatory=$true)][string]$Patched
    )

    $content = [System.IO.File]::ReadAllText($Path)

    # Match the source file's existing line-ending convention rather than
    # normalizing the whole file as a side effect of patching it.
    $lineEnding = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $originalEffective = (($Original -split '\r?\n') -join $lineEnding)
    $patchedEffective = (($Patched -split '\r?\n') -join $lineEnding)

    if ($content.Contains($patchedEffective)) {
        Write-Host "PASS/already patched: $Label"
        return
    }

    $count = ([regex]::Matches(
        $content,
        [regex]::Escape($originalEffective)
    )).Count

    if ($count -ne 1) {
        throw @"
Patch precondition failed: $Label
Expected exactly one unpatched source block, found $count.
No write was performed for this patch.
File: $Path
"@
    }

    Write-PatchedSource `
        -Path $Path `
        -Content ($content.Replace($originalEffective, $patchedEffective))
    Write-Host "PATCHED: $Label"
}

Write-Host "`n=== PATCH WINDOWS AMD CORRECTNESS ==="

# 1) R9700 is a discrete RDNA4 adapter.
$originalKeywords = '"rx ", "xt", "pro w", "pro v", "radeon pro", "firepro", "fury"'
$patchedKeywords  = '"rx ", "xt", "pro w", "pro v", "radeon pro", "r9700", "firepro", "fury"'
Apply-LiteralPatch `
    -Path $systemInfo `
    -Label 'R9700 discrete classification' `
    -Original $originalKeywords `
    -Patched $patchedKeywords

# 2) Never cast a negative signed WMI value to uint64_t. On the R9700,
# Win32_VideoController.AdapterRAM can return a negative sentinel. The stock
# conversion turns that into ~16 EiB and poisons memory-fit decisions.
$oldWmiSigned = @'
        } else if (vtProp.vt == VT_I4) {
            result = static_cast<uint64_t>(vtProp.lVal);
        }
'@
$newWmiSigned = @'
        } else if (vtProp.vt == VT_I4) {
            // NoLemonade: a negative signed WMI value is an invalid/sentinel
            // value for an unsigned byte count. Never wrap it into uint64_t.
            if (vtProp.lVal > 0) {
                result = static_cast<uint64_t>(vtProp.lVal);
            }
        }
'@
Apply-LiteralPatch `
    -Path $wmiHelper `
    -Label 'reject negative WMI uint64 sentinels' `
    -Original $oldWmiSigned `
    -Patched $newWmiSigned

# 3) The existing helper is called by AMD dGPU discovery. Prefer DXGI's
# DedicatedVideoMemory (the same Windows source used by working telemetry),
# then retain dxdiag as fallback. WMI remains only a final guarded fallback.
$systemInfoText = [System.IO.File]::ReadAllText($systemInfo)
$dxgiMarker = '// NoLemonade: prefer DXGI dedicated memory for Windows GPU capacity.'
if ($systemInfoText.Contains($dxgiMarker)) {
    Write-Host 'PASS/already patched: DXGI-first AMD VRAM capacity'
}
else {
    $pattern = '(?s)double WindowsSystemInfo::get_gpu_vram_dxdiag\(const std::string& gpu_name\) \{.*?\r?\n\}\r?\n\r?\n#endif // _WIN32'
    $matches = [regex]::Matches($systemInfoText, $pattern)
    if ($matches.Count -ne 1) {
        throw "Patch precondition failed: expected exactly one get_gpu_vram_dxdiag() block, found $($matches.Count)."
    }

    $replacement = @'
double WindowsSystemInfo::get_gpu_vram_dxdiag(const std::string& gpu_name) {
    std::string gpu_name_lower = gpu_name;
    std::transform(gpu_name_lower.begin(), gpu_name_lower.end(),
                   gpu_name_lower.begin(), ::tolower);

    // NoLemonade: prefer DXGI dedicated memory for Windows GPU capacity.
    // This avoids Win32_VideoController.AdapterRAM truncation/sentinel values
    // on modern large-VRAM AMD adapters.
    Microsoft::WRL::ComPtr<IDXGIFactory1> factory;
    if (SUCCEEDED(CreateDXGIFactory1(
            __uuidof(IDXGIFactory1),
            reinterpret_cast<void**>(factory.GetAddressOf())))) {
        Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
        for (UINT i = 0;
             factory->EnumAdapters1(
                 i, adapter.ReleaseAndGetAddressOf()) != DXGI_ERROR_NOT_FOUND;
             ++i) {
            DXGI_ADAPTER_DESC1 desc{};
            if (FAILED(adapter->GetDesc1(&desc)) ||
                desc.VendorId != 0x1002 ||
                (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) {
                continue;
            }

            std::string desc_name =
                wmi::wstring_to_string(std::wstring(desc.Description));
            std::transform(desc_name.begin(), desc_name.end(),
                           desc_name.begin(), ::tolower);

            const bool same_adapter =
                desc_name == gpu_name_lower ||
                desc_name.find(gpu_name_lower) != std::string::npos ||
                gpu_name_lower.find(desc_name) != std::string::npos;

            if (same_adapter && desc.DedicatedVideoMemory > 0) {
                return static_cast<double>(desc.DedicatedVideoMemory) /
                       (1024.0 * 1024.0 * 1024.0);
            }
        }
    }

    // Preserve upstream dxdiag fallback for unusual adapters where DXGI did
    // not produce a usable dedicated-memory value.
    if (!dxdiag_cache_loaded_) {
        load_dxdiag_cache();
        dxdiag_cache_loaded_ = true;
    }

    for (const auto& entry : dxdiag_vram_cache_) {
        if (entry.first.find(gpu_name_lower) != std::string::npos) {
            return entry.second;
        }
    }
    return 0.0;
}

#endif // _WIN32
'@

    $lineEnding = if ($systemInfoText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $replacement = (($replacement -split '\r?\n') -join $lineEnding)
    $newText = [regex]::Replace($systemInfoText, $pattern, $replacement)
    Write-PatchedSource -Path $systemInfo -Content $newText
    Write-Host 'PATCHED: DXGI-first AMD VRAM capacity'
}

# 4) Primary GPU selection must prefer a dedicated accelerator over a larger
# shared/UMA memory pool. Capacity remains the tie-breaker within each class.
$oldSort = @'
        std::sort(result.gpus.begin(), result.gpus.end(),
                  [](const GpuDeviceMetrics& a, const GpuDeviceMetrics& b) {
                      // Unknown capacities sort last; a valid zero sorts normally.
                      if (a.memory_total_gb != b.memory_total_gb)
                          return a.memory_total_gb > b.memory_total_gb;
                      return a.id < b.id;
                  });
'@
$newSort = @'
        std::sort(result.gpus.begin(), result.gpus.end(),
                  [](const GpuDeviceMetrics& a, const GpuDeviceMetrics& b) {
                      // NoLemonade: a discrete/dedicated accelerator is primary
                      // before a UMA/shared adapter, regardless of the UMA pool's
                      // larger apparent capacity.
                      const auto rank = [](const std::string& type) {
                          if (type == "dedicated") return 2;
                          if (type == "shared") return 1;
                          return 0;
                      };
                      const int a_rank = rank(a.memory_type);
                      const int b_rank = rank(b.memory_type);
                      if (a_rank != b_rank) return a_rank > b_rank;

                      // Capacity is the tie-breaker within the same memory class.
                      if (a.memory_total_gb != b.memory_total_gb)
                          return a.memory_total_gb > b.memory_total_gb;
                      return a.id < b.id;
                  });
'@
Apply-LiteralPatch `
    -Path $metricsHeader `
    -Label 'dedicated GPU primary-selection priority' `
    -Original $oldSort `
    -Patched $newSort

# 5) Some AMD Windows drivers expose the same marketing adapter twice through
# DXGI, with one LUID classified by DXCore and the duplicate LUID unclassified.
# Suppress only that unclassified duplicate. Two identical GPUs that are both
# classified remain distinct.
$oldAdapterReturn = @'
        factory->Release();
        return adapters;
'@
$newAdapterReturn = @'
        factory->Release();

        // NoLemonade: suppress only an unclassified duplicate when a same-name
        // classified adapter is present. Keep multiple same-name adapters when
        // both are classified so genuine multi-GPU systems remain visible.
        std::vector<AmdAdapter> filtered;
        filtered.reserve(adapters.size());
        for (size_t i = 0; i < adapters.size(); ++i) {
            const auto& candidate = adapters[i];
            bool drop_unclassified_duplicate = false;

            if (!candidate.integrated.has_value() && !candidate.name.empty()) {
                for (size_t j = 0; j < adapters.size(); ++j) {
                    if (i == j) continue;
                    const auto& other = adapters[j];
                    if (other.integrated.has_value() &&
                        other.name == candidate.name) {
                        drop_unclassified_duplicate = true;
                        break;
                    }
                }
            }

            if (!drop_unclassified_duplicate) {
                filtered.push_back(candidate);
            }
        }

        return filtered;
'@
Apply-LiteralPatch `
    -Path $amdMetrics `
    -Label 'suppress unclassified same-name AMD telemetry duplicate' `
    -Original $oldAdapterReturn `
    -Patched $newAdapterReturn

Write-Host "`n=== PATCH DIFF ==="
& $git -C $lemonadeSrc diff -- `
    src/cpp/server/system_info.cpp `
    src/cpp/server/utils/wmi_helper.cpp `
    src/cpp/include/lemon/system_metrics_platform.h `
    src/cpp/server/platform/amd_metrics_windows.h
if ($LASTEXITCODE -ne 0) {
    throw "git diff failed"
}

if ($backedUp.Count -gt 0) {
    Write-Host "`nSource backups created before first modification:"
    Write-Host "  $backupRoot"
    Write-Host "These are copies only; no upstream/install files were removed."
}

# ---------------------------------------------------------------------------
# Build the temporary R9700-only llama.cpp wrapper.
# The visibility restriction is deliberately inside this child wrapper,
# NOT on LemonadeServer.exe, so Lemonade can enumerate both 890M and R9700.
# ---------------------------------------------------------------------------
$realLlamaCs = $realLlama.Replace('\', '\\')
$rocmBinCs = $rocmBin.Replace('\', '\\')

$code = @"
using System;
using System.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.ComponentModel;

class NoLemonadeLauncher
{
    const string RealExe = @"$realLlama";
    const string RocmBin = @"$rocmBin";

    const uint CREATE_SUSPENDED = 0x00000004;
    const uint CREATE_NO_WINDOW = 0x08000000;
    const uint STARTF_USESTDHANDLES = 0x00000100;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    const uint INFINITE = 0xFFFFFFFF;

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public uint cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public ushort wShowWindow;
        public ushort cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(
        IntPtr job, int infoClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info,
        int length);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true,
        CharSet = CharSet.Unicode, EntryPoint = "CreateProcessW")]
    static extern bool CreateProcess(
        string application, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint creationFlags,
        IntPtr environment, string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInfo);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint code);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr process, uint code);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetStdHandle(int handle);

    static void Check(bool success, string operation)
    {
        if (!success)
            throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
    }

    static string Quote(string value)
    {
        StringBuilder result = new StringBuilder("\"");
        int slashes = 0;

        foreach (char c in value)
        {
            if (c == '\\')
            {
                slashes++;
            }
            else if (c == '"')
            {
                result.Append('\\', slashes * 2 + 1);
                result.Append('"');
                slashes = 0;
            }
            else
            {
                result.Append('\\', slashes);
                slashes = 0;
                result.Append(c);
            }
        }

        result.Append('\\', slashes * 2);
        result.Append('"');
        return result.ToString();
    }

    static int Run(string[] args)
    {
        if (!File.Exists(RealExe))
            throw new FileNotFoundException("NoLemonade llama-server missing", RealExe);

        foreach (string dll in new string[] {
            "ggml-hip.dll", "rocblas.dll"
        })
        {
            string path = Path.Combine(RocmBin, dll);
            if (!File.Exists(path))
                throw new FileNotFoundException("ROCm runtime DLL missing", path);
        }

        string[] amdhip = Directory.GetFiles(RocmBin, "amdhip64_*.dll");
        if (amdhip.Length == 0)
            throw new FileNotFoundException(
                "No amdhip64_*.dll found in NoLemonade ROCm runtime", RocmBin);

        // Child-only environment. LemonadeServer itself remains unrestricted
        // and can therefore enumerate both the 890M and R9700.
        Environment.SetEnvironmentVariable(
            "PATH", RocmBin + ";" + Environment.GetEnvironmentVariable("PATH"));

        Environment.SetEnvironmentVariable("HIP_VISIBLE_DEVICES", "$r9700Index");

        // Windows ROCm/HIP guidance uses HIP_VISIBLE_DEVICES. Remove any
        // inherited ROCR filter so the two isolation mechanisms do not stack.
        Environment.SetEnvironmentVariable("ROCR_VISIBLE_DEVICES", null);

        Environment.SetEnvironmentVariable("GGML_CUDA_DISABLE_GRAPHS", "1");

        StringBuilder command = new StringBuilder(Quote(RealExe));
        foreach (string arg in args)
            command.Append(" ").Append(Quote(arg));

        IntPtr job = IntPtr.Zero;
        PROCESS_INFORMATION pi = new PROCESS_INFORMATION();

        try
        {
            job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(), "CreateJobObject");

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits =
                new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();

            limits.BasicLimitInformation.LimitFlags =
                JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

            Check(SetInformationJobObject(
                job, 9, ref limits,
                Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))),
                "SetInformationJobObject");

            STARTUPINFO si = new STARTUPINFO();
            si.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
            si.dwFlags = STARTF_USESTDHANDLES;
            si.hStdInput = GetStdHandle(-10);
            si.hStdOutput = GetStdHandle(-11);
            si.hStdError = GetStdHandle(-12);

            Check(CreateProcess(
                RealExe,
                command,
                IntPtr.Zero,
                IntPtr.Zero,
                true,
                CREATE_SUSPENDED | CREATE_NO_WINDOW,
                IntPtr.Zero,
                Path.GetDirectoryName(RealExe),
                ref si,
                out pi),
                "CreateProcess");

            if (!AssignProcessToJobObject(job, pi.hProcess))
            {
                int error = Marshal.GetLastWin32Error();
                TerminateProcess(pi.hProcess, 1);
                throw new Win32Exception(error, "AssignProcessToJobObject");
            }

            if (ResumeThread(pi.hThread) == uint.MaxValue)
            {
                int error = Marshal.GetLastWin32Error();
                TerminateProcess(pi.hProcess, 1);
                throw new Win32Exception(error, "ResumeThread");
            }

            uint wait = WaitForSingleObject(pi.hProcess, INFINITE);
            if (wait != 0)
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(), "WaitForSingleObject");

            uint code;
            Check(GetExitCodeProcess(pi.hProcess, out code), "GetExitCodeProcess");
            return unchecked((int)code);
        }
        finally
        {
            if (pi.hThread != IntPtr.Zero)
                CloseHandle(pi.hThread);
            if (pi.hProcess != IntPtr.Zero)
                CloseHandle(pi.hProcess);
            if (job != IntPtr.Zero)
                CloseHandle(job);
        }
    }

    static int Main(string[] args)
    {
        try
        {
            return Run(args);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("NoLemonade launcher failed: " + ex.Message);
            return 90;
        }
    }
}
"@

# Write source only if content changed.
$writeLauncherSource = $true
if (Test-Path -LiteralPath $launcherSource -PathType Leaf) {
    $existingSource = [System.IO.File]::ReadAllText($launcherSource)
    if ($existingSource -eq $code) {
        $writeLauncherSource = $false
    }
}
if ($writeLauncherSource) {
    [System.IO.File]::WriteAllText(
        $launcherSource,
        $code,
        [System.Text.UTF8Encoding]::new($false)
    )
}

# Compile to a temporary file first, then move into place only on success.
$tempLauncher = "$launcherExe.new"
if (Test-Path -LiteralPath $tempLauncher) {
    Remove-Item -LiteralPath $tempLauncher -Force
}

& $csc /nologo /target:exe /platform:x64 /optimize+ "/out:$tempLauncher" "$launcherSource"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempLauncher -PathType Leaf)) {
    throw "C# launcher compilation failed. Existing launcher was not changed."
}

if (Test-Path -LiteralPath $launcherExe -PathType Leaf) {
    $oldHash = (Get-FileHash $launcherExe -Algorithm SHA256).Hash
    $newHash = (Get-FileHash $tempLauncher -Algorithm SHA256).Hash
    if ($oldHash -eq $newHash) {
        Remove-Item -LiteralPath $tempLauncher -Force
    }
    else {
        $backup = "$launcherExe.bak"
        Copy-Item -LiteralPath $launcherExe -Destination $backup -Force
        Move-Item -LiteralPath $tempLauncher -Destination $launcherExe -Force
        Write-Host "Previous launcher backed up to: $backup"
    }
}
else {
    Move-Item -LiteralPath $tempLauncher -Destination $launcherExe
}

Write-Host "`n=== VERIFY NoLemonade ROCm WRAPPER ==="
$wrappedDevices = (& $launcherExe --list-devices 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "NoLemonade wrapper --list-devices failed:`n$wrappedDevices"
}
Write-Host $wrappedDevices.TrimEnd()

if ($wrappedDevices -notmatch '(?i)R9700') {
    throw "NoLemonade wrapper does not report the R9700."
}
if ($wrappedDevices -match '(?i)890M') {
    throw "NoLemonade wrapper still exposes the 890M to the ROCm child; expected isolated R9700."
}

# ---------------------------------------------------------------------------
# Build patched LemonadeServer.exe side-by-side.
# ---------------------------------------------------------------------------

function Resolve-VSWherePath {
    $standard = Join-Path ${env:ProgramFiles(x86)} `
        'Microsoft Visual Studio\Installer\vswhere.exe'

    if (Test-Path -LiteralPath $standard -PathType Leaf) {
        return $standard
    }

    $fromPath = Resolve-CommandPath 'vswhere'
    if ($fromPath) {
        return $fromPath
    }

    return $null
}

function Get-VS2022CppInstance {
    $vswhere = Resolve-VSWherePath
    if (-not $vswhere) {
        return $null
    }

    # Require the actual x64/x86 MSVC toolset, not merely a VS shell/core install.
    $installationPath = (
        & $vswhere `
            -latest `
            -products * `
            -version '[17.0,18.0)' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null |
        Select-Object -First 1
    )

    if ([string]::IsNullOrWhiteSpace($installationPath)) {
        return $null
    }

    $msbuild = Join-Path $installationPath 'MSBuild\Current\Bin\MSBuild.exe'
    $vcvars = Join-Path $installationPath 'VC\Auxiliary\Build\vcvars64.bat'

    if (-not (Test-Path -LiteralPath $msbuild -PathType Leaf)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) {
        return $null
    }

    [PSCustomObject]@{
        InstallationPath = $installationPath
        MSBuild = $msbuild
        VcVars64 = $vcvars
        VSWhere = $vswhere
    }
}

function Ensure-VS2022CppBuildTools {
    $instance = Get-VS2022CppInstance
    if ($instance) {
        Write-Host "`nVisual Studio 2022 C++ toolchain detected:"
        Write-Host "  $($instance.InstallationPath)"
        return $instance
    }

    $winget = Resolve-CommandPath 'winget'
    if (-not $winget) {
        throw @"
Visual Studio 2022 with the x64/x86 C++ toolchain is required by Lemonade's
'windows' CMake preset, but no suitable instance was found and winget is not
available.

NoLemonade did not modify any Visual Studio installation.
"@
    }

    Write-Host @"

=== VISUAL STUDIO 2022 C++ BUILD TOOLS REQUIRED ===

Lemonade v2026.43.3's Windows preset uses:
  Generator: Visual Studio 17 2022
  Architecture: x64

Lemonade's own build documentation requires:
  Desktop development with C++

NoLemonade can install:
  Package:  Microsoft.VisualStudio.2022.BuildTools
  Workload: Microsoft.VisualStudio.Workload.VCTools
  Options:  include recommended C++ components
            (MSVC x64/x86 tools, Windows SDK, CMake integration, etc.)

This is a substantial Windows development-tool installation and may consume
several GB of disk space. It may display a UAC elevation prompt.

It will NOT install the full Visual Studio IDE.
It will NOT modify Lemonade's installed binaries, config, cache, or models.
"@

    $answer = Read-Host 'Install Visual Studio 2022 C++ Build Tools now? [Y/N]'
    if ($answer -notmatch '^(?i:y|yes)$') {
        throw "Visual Studio Build Tools installation was declined. No build was attempted."
    }

    Write-Host "`n=== INSTALL VISUAL STUDIO 2022 C++ BUILD TOOLS ==="

    $override = (
        '--passive ' +
        '--wait ' +
        '--norestart ' +
        '--add Microsoft.VisualStudio.Workload.VCTools ' +
        '--includeRecommended'
    )

    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        & $winget install `
            --exact `
            --id Microsoft.VisualStudio.2022.BuildTools `
            --source winget `
            --accept-source-agreements `
            --accept-package-agreements `
            --override $override 2>&1 |
            Out-Host

        $wingetExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    # Trust post-state over winget's presentation/translation of installer
    # return codes. A successful instance discovery is the real acceptance gate.
    $instance = Get-VS2022CppInstance

    if (-not $instance) {
        throw @"
Visual Studio 2022 C++ Build Tools are still not detectable after installation.

winget exit code:
  $wingetExit

NoLemonade will not delete, repair, or modify the Visual Studio installation
automatically. Check Visual Studio Installer and ensure 'Desktop development
with C++' is installed, then rerun Builder.ps1.
"@
    }

    Write-Host "`nPASS: Visual Studio 2022 C++ toolchain detected:"
    Write-Host "  $($instance.InstallationPath)"

    return $instance
}

$vs2022 = Ensure-VS2022CppBuildTools

Write-Host "`n=== CONFIGURE PATCHED LEMONADE ==="
Write-Host "VS 2022: $($vs2022.InstallationPath)"
Push-Location $lemonadeSrc
try {
    Invoke-Checked $cmake --preset windows

    Write-Host "`n=== BUILD PATCHED LemonadeServer.exe ==="
    Invoke-Checked $cmake --build --preset windows --target LemonadeServer
}
finally {
    Pop-Location
}

$patchedServer = Join-Path $lemonadeSrc 'build\Release\LemonadeServer.exe'
if (-not (Test-Path -LiteralPath $patchedServer -PathType Leaf)) {
    throw "Build completed but patched LemonadeServer.exe was not found: $patchedServer"
}

Write-Host "`n=== NoLemonade v0.3.0 BUILD RESULT ==="
Get-Item $patchedServer, $launcherExe |
    Select-Object FullName, Length, LastWriteTime

Write-Host "`nSHA256:"
Get-FileHash $patchedServer, $launcherExe -Algorithm SHA256 |
    Select-Object Path, Hash

Write-Host @"

Build complete.

Patched server:
  $patchedServer

ROCm wrapper:
  $launcherExe

Next:
  Run C:\AI\NoLemonade\Starter.ps1

Nothing under C:\lemonade_server or ~/.config/lemonade was modified.
"@
