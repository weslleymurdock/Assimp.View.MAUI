[CmdletBinding()]
#requires -Version 5.1

param(
    [Alias('abi', 'architecture', 'arch')]
    [string[]]$Rid,
    [string]$OutputRoot,
    [string]$VcpkgRoot,
    [Alias('ToolCacheRoot', 'DepsRoot')]
    [string]$CacheRoot,
    [int]$Jobs = 0,
    [ValidateSet('off', 'error', 'warn', 'info', 'debug', 'trace')]
    [string]$LogLevel = 'off',
    [ValidateSet('auto', 'always', 'never')]
    [string]$Progress = 'auto',
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$enUs = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Globalization.CultureInfo]::CurrentCulture = $enUs
[Globalization.CultureInfo]::CurrentUICulture = $enUs
[Globalization.CultureInfo]::DefaultThreadCurrentCulture = $enUs
[Globalization.CultureInfo]::DefaultThreadCurrentUICulture = $enUs
$utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList (,$false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$OutputEncoding = $utf8
$env:LANG = 'en_US.UTF-8'
$env:LANGUAGE = 'en_US:en'
$env:LC_ALL = 'C'
$env:VSLANG = '1033'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = $RepoRoot
}
else {
    $OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
}
if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
    $CacheRoot = if (-not [string]::IsNullOrWhiteSpace($env:ASSIMP_VIEW_MAUI_DEPS_ROOT)) {
        $env:ASSIMP_VIEW_MAUI_DEPS_ROOT
    }
    else {
        Join-Path $env:LOCALAPPDATA 'Assimp.View.Maui\deps'
    }
}
$CacheRoot = [IO.Path]::GetFullPath($CacheRoot)
New-Item -ItemType Directory -Path (Join-Path $CacheRoot 'downloads'), (Join-Path $CacheRoot 'binary-cache') -Force | Out-Null
$env:VCPKG_DOWNLOADS = Join-Path $CacheRoot 'downloads'
$env:VCPKG_DEFAULT_BINARY_CACHE = Join-Path $CacheRoot 'binary-cache'

function Fail([string]$Message) {
    if (Get-Command Clear-GradientProgress -ErrorAction SilentlyContinue) { Clear-GradientProgress }
    throw "build_windows.ps1: $Message"
}

function Normalize-Rid([string]$Value) {
    switch ($Value.ToLowerInvariant()) {
        'win-x64' { return 'win-x64' }
        'x64' { return 'win-x64' }
        'win-arm64' { return 'win-arm64' }
        'arm64' { return 'win-arm64' }
        default { Fail "invalid Windows RID '$Value'" }
    }
}

if ($null -eq $Rid -or $Rid.Count -eq 0) {
    $Rid = @('win-x64', 'win-arm64')
}
$Rid = @(
    $Rid |
        ForEach-Object { $_ -split '[,;]' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        ForEach-Object { Normalize-Rid $_ } |
        Select-Object -Unique
)
if ($Jobs -le 0) {
    $Jobs = [Environment]::ProcessorCount
}

$JobRoot = Join-Path ([IO.Path]::GetTempPath()) ("assimp-view-maui-windows-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $JobRoot -Force | Out-Null
$CommandLog = Join-Path $JobRoot 'commands.log'
New-Item -ItemType File -Path $CommandLog -Force | Out-Null
$BuildSucceeded = $false

function Clean-StaleJobRoots {
    $tempRoot = [IO.Path]::GetTempPath()
    $cutoff = (Get-Date).AddHours(-1)
    Get-ChildItem -LiteralPath $tempRoot -Directory -Filter 'assimp-view-maui-windows-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $JobRoot -and $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "required command not found: $Name"
    }
}

function Invoke-Logged([string]$Label, [string]$FilePath, [string[]]$Arguments, [int[]]$AllowedExitCodes = @(0)) {
    if ($LogLevel -ne 'off') {
        if ($LogLevel -in @('debug', 'trace')) {
            Write-ProgressLog ("[debug] {0}: {1} {2}" -f $Label, $FilePath, ($Arguments -join ' '))
        }
        if ($ProgressEnabled) {
            & $FilePath @Arguments 2>&1 | ForEach-Object {
                Clear-GradientProgress
                [Console]::Error.WriteLine([string]$_)
                Draw-GradientProgress
            }
        }
        else {
            & $FilePath @Arguments
        }
    }
    else {
        & $FilePath @Arguments >> $CommandLog 2>&1
    }
    $status = $LASTEXITCODE
    if ($status -notin $AllowedExitCodes) {
        if ($LogLevel -eq 'off') {
            [Console]::Error.WriteLine("[error] $Label failed; command log follows:")
            Get-Content -LiteralPath $CommandLog -Tail 200 | ForEach-Object { [Console]::Error.WriteLine($_) }
        }
        Fail "$Label failed with exit code $status"
    }
}

function Initialize-DotNetEnvironment {
    $dotnetCandidates = @()
    $dotnetCommand = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($dotnetCommand) { $dotnetCandidates += $dotnetCommand.Source }
    $dotnetCandidates += @(
        (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'dotnet\dotnet.exe')
    )
    $dotnetPath = $dotnetCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (-not $dotnetPath) {
        Fail '.NET host was not found; install the x64 .NET SDK/runtime before running the Windows native build'
    }
    $dotnetRoot = Split-Path -Parent $dotnetPath
    $env:DOTNET_ROOT = $dotnetRoot
    $env:DOTNET_ROOT_X64 = $dotnetRoot
    $runtimeList = (& $dotnetPath --list-runtimes 2>$null | Out-String)
    if ($runtimeList -notmatch 'Microsoft\.NETCore\.App\s+(\d+)\.') {
        Fail ".NET host '$dotnetPath' has no Microsoft.NETCore.App runtime"
    }
    Write-ProgressLog "using .NET host $dotnetPath"
}

function Download-File([string]$Url, [string]$Destination) {
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        Invoke-Logged "download $Url" $curl.Source @(
            '--fail', '--silent', '--show-error', '--location', '--retry', '5', '--retry-delay', '2', '--connect-timeout', '30',
            '--output', $Destination, $Url)
        return
    }
    $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
    if ($bits) {
        Write-ProgressLog "downloading $Url with BITS"
        try {
            Start-BitsTransfer -Source $Url -Destination $Destination -DisplayName 'Assimp.View.Maui dependency download'
        }
        catch {
            Fail "download failed: $Url"
        }
        return
    }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    }
    catch {
        Fail "no working download provider is available for $Url; install curl.exe or BITS"
    }
}

$ProgressEnabled = $false
$ProgressCompleted = 0
$ProgressTotal = 0
$ProgressFrame = 0
$ProgressLabel = ''

function Initialize-GradientProgress([int]$Total) {
    $script:ProgressTotal = $Total
    switch ($Progress) {
        'always' { $script:ProgressEnabled = $true }
        'never' { $script:ProgressEnabled = $false }
        'auto' { $script:ProgressEnabled = -not [Console]::IsErrorRedirected }
    }
}

function Clear-GradientProgress {
    if ($ProgressEnabled) {
        [Console]::Error.Write("`r$([char]27)[2K")
    }
}

function Draw-GradientProgress {
    if (-not $ProgressEnabled) { return }
    $width = 28
    $percent = 0
    if ($ProgressTotal -gt 0) {
        $percent = [math]::Floor(($ProgressCompleted * 100) / $ProgressTotal)
        $filled = [math]::Floor(($ProgressCompleted * $width) / $ProgressTotal)
    }
    else {
        $filled = $ProgressFrame % ($width + 1)
        $script:ProgressFrame++
    }
    $esc = [char]27
    [Console]::Error.Write(("`r${esc}[2K${esc}[38;2;99;102;241m[{0,3}%]${esc}[0m " -f @($percent)))
    for ($i = 0; $i -lt $width; $i++) {
        if ($i -lt $filled) {
            $red = 79 + [math]::Floor($i * 45 / $width)
            $green = 70 - [math]::Floor($i * 12 / $width)
            $blue = 229 + [math]::Floor($i * 8 / $width)
            [Console]::Error.Write(("${esc}[38;2;{0};{1};{2}m" -f @($red, $green, $blue)))
            [Console]::Error.Write([char]0x2501)
            [Console]::Error.Write("${esc}[0m")
        }
        else {
            [Console]::Error.Write("${esc}[38;2;55;48;163m")
            [Console]::Error.Write([char]0x2500)
            [Console]::Error.Write("${esc}[0m")
        }
    }
    [Console]::Error.Write(" $ProgressLabel")
}

function Update-GradientProgress([string]$Label) {
    if (-not $ProgressEnabled) { return }
    $script:ProgressCompleted++
    $script:ProgressLabel = $Label
    Draw-GradientProgress
}

function Write-ProgressLog([string]$Message) {
    Clear-GradientProgress
    [Console]::Error.WriteLine($Message)
    Draw-GradientProgress
}

function Complete-GradientProgress {
    if ($ProgressEnabled) {
        [Console]::Error.WriteLine()
        $script:ProgressEnabled = $false
    }
}

function Validate-Swig {
    $versionText = (& swig -version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { Fail 'could not execute SWIG -version' }
    $match = [regex]::Match($versionText, 'SWIG\s+Version\s+(\d+)\.(\d+)\.(\d+)')
    if (-not $match.Success) { Fail 'could not determine SWIG version' }
    $version = New-Object System.Version -ArgumentList @(
        [int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
    if ($version -lt [version]'4.3.0') {
        Fail "SWIG $version is too old; SWIG >= 4.3.0 is required for C# Doxygen comments"
    }
    $probeRoot = Join-Path $JobRoot 'swig-doxygen-probe'
    $probeCsharp = Join-Path $probeRoot 'csharp'
    New-Item -ItemType Directory -Path $probeCsharp -Force | Out-Null
    @'
#pragma once

/** @brief Confirms that SWIG can translate Doxygen comments for C#. */
class AssimpViewDoxygenProbeClass {
public:
    /** @brief Returns a value from the Doxygen validation probe. */
    int Value() const;
};
'@ | Set-Content -LiteralPath (Join-Path $probeRoot 'probe.h') -Encoding utf8
    @'
%module AssimpViewDoxygenProbeModule
%{
#include "probe.h"
%}
%include "probe.h"
'@ | Set-Content -LiteralPath (Join-Path $probeRoot 'probe.i') -Encoding utf8
    Invoke-Logged 'SWIG C# Doxygen probe' 'swig' @(
        '-c++', '-csharp', '-doxygen', '-namespace', 'Assimp.View.Maui',
        "-I$probeRoot", '-outdir', $probeCsharp,
        '-o', (Join-Path $probeRoot 'probe.cxx'), (Join-Path $probeRoot 'probe.i'))
    if (-not (Get-ChildItem -LiteralPath $probeCsharp -Filter '*.cs' -File)) {
        Fail "SWIG $version did not generate C# output for the Doxygen probe"
    }
    Write-ProgressLog "using SWIG $version with C# Doxygen support"
}

function Ensure-CachedZipTool([string]$Name, [string]$Version, [string]$Url, [string]$RelativeExecutable) {
    $toolsRoot = Join-Path $CacheRoot 'tools'
    $toolRoot = Join-Path $toolsRoot "$Name-$Version"
    $executable = Join-Path $toolRoot $RelativeExecutable
    if (Test-Path -LiteralPath $executable -PathType Leaf) {
        $env:Path = "$(Split-Path -Parent $executable);$env:Path"
        return
    }

    New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
    $lock = Join-Path $toolsRoot ".$Name-$Version.lock"
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
            break
        }
        catch {
            Start-Sleep -Milliseconds 200
        }
    }
    try {
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            $archive = Join-Path $CacheRoot "downloads\$Name-$Version.zip"
            if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
                Write-ProgressLog "Downloading $Name $Version"
                Download-File $Url $archive
            }
            $extractRoot = Join-Path $toolsRoot ".extract-$Name-$PID"
            if (Test-Path -LiteralPath $extractRoot) {
                Remove-Item -LiteralPath $extractRoot -Recurse -Force
            }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extractRoot)
            $sourceRoot = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1
            if (-not $sourceRoot) { Fail "$Name archive did not contain a root directory" }
            if (Test-Path -LiteralPath $toolRoot) {
                Remove-Item -LiteralPath $toolRoot -Recurse -Force
            }
            Move-Item -LiteralPath $sourceRoot.FullName -Destination $toolRoot
            Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            Fail "$Name archive was extracted but $RelativeExecutable was not found"
        }
    }
    finally {
        Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:Path = "$(Split-Path -Parent $executable);$env:Path"
}

function Ensure-HostDependencies {
    if ($SkipInstall) {
        Require-Command cmake
        Require-Command swig
        Require-Command git
        return
    }
    if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
        Ensure-CachedZipTool 'cmake' '3.31.10' 'https://github.com/Kitware/CMake/releases/download/v3.31.10/cmake-3.31.10-windows-x86_64.zip' 'bin\cmake.exe'
    }
    if (-not (Get-Command swig -ErrorAction SilentlyContinue)) {
        Ensure-CachedZipTool 'swigwin' '4.5.1' 'https://prdownloads.sourceforge.net/swig/swigwin-4.5.1.zip' 'swig.exe'
    }
    Require-Command cmake
    Require-Command swig
    Require-Command git
}

function Ensure-VcpkgToolArchives {
    # vcpkg pins its host CMake version and otherwise downloads it through
    # WinHTTP, which bypasses the downloader/cache policy used by this script.
    # Put the exact archive in VCPKG_DOWNLOADS so vcpkg can consume it without
    # another network request during dependency installation.
    $archive = Join-Path $CacheRoot 'downloads\cmake-3.31.10-windows-x86_64.zip'
    $url = 'https://github.com/Kitware/CMake/releases/download/v3.31.10/cmake-3.31.10-windows-x86_64.zip'
    $valid = $false
    if (Test-Path -LiteralPath $archive -PathType Leaf) {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($archive)
            try {
                $valid = [bool]($zip.Entries | Where-Object {
                    $_.FullName -eq 'cmake-3.31.10-windows-x86_64/bin/cmake.exe'
                } | Select-Object -First 1)
            }
            finally {
                $zip.Dispose()
            }
        }
        catch {
            $valid = $false
        }
    }
    if (-not $valid) {
        if (Test-Path -LiteralPath $archive) {
            Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        }
        Write-ProgressLog 'Downloading vcpkg CMake 3.31.10'
        Download-File $url $archive
    }
}

function Initialize-SwigEnvironment {
    $swigCommand = Get-Command swig -ErrorAction Stop
    $swigPath = $swigCommand.Source
    $swigItem = Get-Item -LiteralPath $swigPath -ErrorAction SilentlyContinue
    if ($swigItem) {
        $resolvedTarget = $null
        if ($swigItem.PSObject.Properties['ResolvedTarget']) {
            $resolvedTarget = $swigItem.ResolvedTarget
        }
        elseif ($swigItem.PSObject.Properties['Target']) {
            $resolvedTarget = $swigItem.Target
        }
        if ($resolvedTarget -is [Array]) {
            $resolvedTarget = $resolvedTarget | Select-Object -First 1
        }
        if ($resolvedTarget) {
            $swigPath = $resolvedTarget
        }
    }
    $swigLib = Join-Path (Split-Path -Parent $swigPath) 'Lib'
    if (Test-Path -LiteralPath $swigLib -PathType Container) {
        $env:SWIG_LIB = $swigLib
    }
}

function Find-VsWhere {
    $candidates = @()
    $command = Get-Command vswhere.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    $candidates += @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-Path $env:ProgramData 'Microsoft\VisualStudio\Installer\vswhere.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio\Installer\vswhere.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Find-VsInstallation([switch]$RequireArm64) {
    $vswhere = Find-VsWhere
    if (-not $vswhere) { return $null }
    $requirements = @('Microsoft.VisualStudio.Component.VC.Tools.x86.x64')
    if ($RequireArm64) {
        $requirements += 'Microsoft.VisualStudio.Component.VC.Tools.ARM64'
    }
    $arguments = @('-products', '*', '-requires') + $requirements + @('-property', 'installationPath')
    if (-not $RequireArm64) { $arguments = @('-latest') + $arguments }
    $installations = @(& $vswhere @arguments 2>$null | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
    if ($installations.Count -gt 0) { return $installations[0] }
    return $null
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList (,$identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-VisualStudioBootstrapper([switch]$IncludeArm64) {
    $downloadRoot = Join-Path $CacheRoot 'downloads'
    $installer = Join-Path $downloadRoot 'vs_BuildTools.exe'
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf) -or (Get-Item -LiteralPath $installer).Length -lt 1048576) {
        Write-ProgressLog 'Downloading Visual Studio Build Tools bootstrapper from Microsoft'
        Download-File 'https://aka.ms/vs/17/release/vs_BuildTools.exe' $installer
    }
    $arguments = @(
        '--quiet', '--wait', '--norestart', '--nocache',
        '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended')
    if ($IncludeArm64) {
        $arguments += @('--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64')
    }
    Invoke-Logged 'Visual Studio Build Tools bootstrapper install' $installer $arguments @(0, 3010)
}

function Invoke-VisualStudioLocked([scriptblock]$Action) {
    $lock = Join-Path $CacheRoot '.visualstudio-install.lock'
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
            Set-Content -LiteralPath (Join-Path $lock 'pid') -Value $PID -NoNewline
            break
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }
    try {
        & $Action
    }
    finally {
        Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-VisualStudio {
    $requiresArm64 = $Rid -contains 'win-arm64'
    $installation = Find-VsInstallation
    $hasArm64 = -not $requiresArm64 -or [bool](Find-VsInstallation -RequireArm64)
    if (-not $installation -or -not $hasArm64) {
        if ($SkipInstall) {
            if (-not $installation) { Fail 'Visual Studio C++ tools were not found' }
            Fail "Visual Studio installation '$installation' does not contain the ARM64 C++ component required by win-arm64"
        }
        if (-not (Test-IsAdministrator)) {
            Fail 'Visual Studio C++ tools are missing or incomplete. Run the CI process elevated so the existing installation can be modified without an interactive prompt.'
        }
        Invoke-VisualStudioLocked {
            $currentInstallation = Find-VsInstallation
            if (-not $currentInstallation) {
                Install-VisualStudioBootstrapper ([switch]$requiresArm64)
                $currentInstallation = Find-VsInstallation
            }
            if ($requiresArm64 -and $currentInstallation -and -not (Find-VsInstallation -RequireArm64)) {
                $setup = Join-Path (Split-Path -Parent (Find-VsWhere)) 'setup.exe'
                Invoke-Logged 'Visual Studio ARM64 C++ component install' $setup @(
                    'modify', '--installPath', $currentInstallation, '--quiet', '--wait', '--norestart', '--nocache',
                    '--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64') @(0, 3010)
            }
        }
        $installation = Find-VsInstallation
        $hasArm64 = -not $requiresArm64 -or [bool](Find-VsInstallation -RequireArm64)
    }
    if (-not $installation) { Fail 'Visual Studio C++ tools were not found in any detected installation' }
    if ($requiresArm64 -and -not $hasArm64) {
        Fail "Visual Studio installation '$installation' still does not contain the ARM64 C++ component after modification"
    }
    return $installation
}

function Select-CMakeGenerator([string]$VsInstallation) {
    $vswhere = Find-VsWhere
    if (-not $vswhere) { Fail 'vswhere.exe was not found while selecting the CMake generator' }
    $vsVersion = ((& $vswhere -path $VsInstallation -property installationVersion 2>$null | Out-String).Trim())
    if (-not $vsVersion) { Fail 'Visual Studio installation version could not be determined' }
    $major = [int]($vsVersion.Split('.')[0])
    if ($major -lt 18) { return 'Visual Studio 17 2022' }

    $generators = (& cmake --help 2>&1 | Out-String)
    if ($generators -notmatch 'Visual Studio 18 2026') {
        if ($SkipInstall) {
            Fail 'CMake does not expose the Visual Studio 18 2026 generator; remove -SkipInstall so CMake 4.5.0 can be cached on the configured tool-cache drive'
        }
        Ensure-CachedZipTool 'cmake' '4.5.0' 'https://github.com/Kitware/CMake/releases/download/v4.5.0/cmake-4.5.0-windows-x86_64.zip' 'bin\cmake.exe'
        $generators = (& cmake --help 2>&1 | Out-String)
    }
    if ($generators -notmatch 'Visual Studio 18 2026') {
        Fail "CMake with Visual Studio 18 2026 generator support is required; current CMake does not expose that generator"
    }
    return 'Visual Studio 18 2026'
}

function Copy-Tree([string]$Source, [string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-SourceFingerprint([string]$Source) {
    # A copied vcpkg tree may retain a .git file whose worktree path points
    # back into the original repository.  Under $ErrorActionPreference=Stop,
    # a failed git probe becomes a terminating PowerShell error instead of a
    # normal non-zero result.  Treat that tree as a plain source directory and
    # fall back to the deterministic file hash.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $revisionOutput = & git -C $Source rev-parse HEAD 2>&1
        $revisionExitCode = $LASTEXITCODE
        $revision = ($revisionOutput | Out-String).Trim()
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($revisionExitCode -eq 0 -and $revision -and $revision -notmatch '(?i)fatal:|not a git repository') {
        try {
            $ErrorActionPreference = 'Continue'
            $statusOutput = & git -C $Source status --porcelain --untracked-files=all 2>&1
            $statusExitCode = $LASTEXITCODE
            $status = ($statusOutput | Out-String).Trim()
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($statusExitCode -eq 0 -and -not $status) { return "$revision`:clean" }
        $hashes = Get-ChildItem -LiteralPath $Source -Recurse -File | Sort-Object FullName | Get-FileHash -Algorithm SHA256
        return "$revision`:" + (($hashes | ForEach-Object { "$($_.Hash)  $($_.Path)" }) -join "`n")
    }
    $hashes = Get-ChildItem -LiteralPath $Source -Recurse -File | Sort-Object FullName | Get-FileHash -Algorithm SHA256
    return (($hashes | ForEach-Object { "$($_.Hash)  $($_.Path)" }) -join "`n" | Out-String).Trim()
}

function Enter-DependencyCacheLock {
    $lock = Join-Path $CacheRoot '.vcpkg.lock'
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
            Set-Content -LiteralPath (Join-Path $lock 'pid') -Value $PID -NoNewline
            return $lock
        }
        catch {
            $ownerPath = Join-Path $lock 'pid'
            if (Test-Path -LiteralPath $ownerPath) {
                $ownerText = (Get-Content -LiteralPath $ownerPath -Raw).Trim()
                $ownerPid = 0
                if ([int]::TryParse($ownerText, [ref]$ownerPid)) {
                    $owner = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
                    if ($null -eq $owner) {
                        Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
                        continue
                    }
                }
            }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Exit-DependencyCacheLock([string]$Lock) {
    Remove-Item -LiteralPath $Lock -Recurse -Force -ErrorAction SilentlyContinue
}

function Prepare-Vcpkg {
    $source = $VcpkgRoot
    if ([string]::IsNullOrWhiteSpace($source)) {
        $source = $env:VCPKG_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($source)) {
        $source = Join-Path $RepoRoot 'lib\assimp_view\contrib\osre\contrib\vcpkg'
    }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { Fail "vcpkg source not found: $source" }
    $sourceExecutable = Join-Path $source 'vcpkg.exe'
    if ($SkipInstall -and
        (Test-Path -LiteralPath $sourceExecutable -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $source 'scripts\buildsystems\vcpkg.cmake') -PathType Leaf)) {
        # Offline validation/builds with -SkipInstall can use an already
        # bootstrapped vcpkg tree directly.  This avoids copying its buildtrees
        # (which may contain machine-specific stale paths) and never invokes
        # the bootstrap downloader.
        return $source
    }
    if (Test-Path -LiteralPath $sourceExecutable -PathType Leaf) {
        # A pre-bootstrapped vcpkg cache is a valid input.  Do not walk its
        # buildtrees to calculate a source hash: those trees may contain
        # stale junctions or paths from another machine.
        $sourceHash = 'vcpkg-binary:' + (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceExecutable).Hash
    }
    else {
        $sourceHash = Get-SourceFingerprint $source
    }
    $cached = Join-Path $CacheRoot 'vcpkg'
    $marker = Join-Path $cached '.assimp-view-source-hash'
    if ((Test-Path -LiteralPath (Join-Path $cached 'vcpkg.exe')) -and
        (Test-Path -LiteralPath $marker) -and
        ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $sourceHash)) {
        return $cached
    }

    $cacheLock = Enter-DependencyCacheLock
    try {
        if ((Test-Path -LiteralPath (Join-Path $cached 'vcpkg.exe')) -and
            (Test-Path -LiteralPath $marker) -and
            ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $sourceHash)) {
            return $cached
        }

        $local = Join-Path $JobRoot 'vcpkg-cache-staging'
        Copy-Tree $source $local
        $exe = Join-Path $local 'vcpkg.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            $bootstrap = Join-Path $local 'bootstrap-vcpkg.bat'
            if (-not (Test-Path -LiteralPath $bootstrap)) { Fail "bootstrap-vcpkg.bat not found in $source" }
            Invoke-Logged 'vcpkg bootstrap' 'cmd.exe' @('/d', '/c', "`"$bootstrap`" -disableMetrics")
        }
        if (-not (Test-Path -LiteralPath $exe)) { Fail 'vcpkg bootstrap did not create vcpkg.exe' }
        Set-Content -LiteralPath (Join-Path $local '.assimp-view-source-hash') -Value $sourceHash -NoNewline
        if (Test-Path -LiteralPath $cached) { Remove-Item -LiteralPath $cached -Recurse -Force }
        Move-Item -LiteralPath $local -Destination $cached
        return $cached
    }
    finally {
        Exit-DependencyCacheLock $cacheLock
    }
}

function Prepare-Overlay {
    $overlay = Join-Path $JobRoot 'osre'
    Copy-Tree (Join-Path $RepoRoot 'lib\assimp_view\contrib\osre') $overlay

    # OSRE's Windows sources use repository-root includes such as
    # <src/Engine/Platform/win32/Win32Window.h>.  The upstream CMake file
    # only adds src/Engine, which makes those includes resolve incorrectly
    # when the library is built from this isolated temporary overlay.
    $rootCmake = Join-Path $overlay 'CMakeLists.txt'
    $rootText = Get-Content -LiteralPath $rootCmake -Raw
    $rootMarker = 'INCLUDE_DIRECTORIES( BEFORE' + [Environment]::NewLine
    if ($rootText.Contains($rootMarker) -and
        -not ($rootText -match '(?m)^\s*\$\{CMAKE_SOURCE_DIR\}\s*$')) {
        $rootText = $rootText.Replace(
            $rootMarker,
            $rootMarker + '    ${CMAKE_SOURCE_DIR}' + [Environment]::NewLine)
        Set-Content -LiteralPath $rootCmake -Value $rootText -NoNewline -Encoding utf8
    }

    $engineCmake = Join-Path $overlay 'src\Engine\CMakeLists.txt'
    $engineText = Get-Content -LiteralPath $engineCmake -Raw
    $engineText = $engineText -replace 'cppcore\)', '$<TARGET_NAME_IF_EXISTS:cppcore>)'
    $engineText = $engineText -replace 'target_link_libraries \( osre cppcore zlibstatic GLEW::GLEW \$\{platform_libs\} assimp \)', 'target_link_libraries ( osre $<TARGET_NAME_IF_EXISTS:cppcore> $<TARGET_NAME_IF_EXISTS:zlibstatic> GLEW::GLEW ${platform_libs} $<TARGET_NAME_IF_EXISTS:assimp> )'
    Set-Content -LiteralPath $engineCmake -Value $engineText -NoNewline -Encoding utf8

    $common = Join-Path $overlay 'src\Engine\Common\osre_common.h'
    $text = Get-Content -LiteralPath $common -Raw
    $text = $text -replace '(?m)#elif defined\(__APPLE__\) \|\| defined\(__MACH__\)\r?\n#\s*error "Currently not supported platform"', '#elif defined(__APPLE__) || defined(__MACH__)`r`n#    define OSRE_APPLE'
    Set-Content -LiteralPath $common -Value $text -NoNewline -Encoding utf8
    return $overlay
}

function Write-BridgeSources {
    @'
#pragma once
namespace AssimpViewMaui {
class AssimpView {
public:
    /** @brief Creates a reusable Assimp View instance. */
    AssimpView();
    /** @brief Releases the native Assimp View instance. */
    ~AssimpView();
    /**
     * @brief Creates the native rendering window and graphics context.
     * @param width Initial view width in pixels.
     * @param height Initial view height in pixels.
     * @return true when the native view was initialized.
     */
    bool Initialize(int width, int height);
    /**
     * @brief Loads a 3D asset from a native URI/path.
     * @param path URI or path accepted by Assimp View.
     * @return true when the asset was loaded.
     */
    bool LoadAsset(const char *path);
    /** @brief Processes events and renders one frame. */
    bool Frame();
    /**
     * @brief Resizes the native rendering surface.
     * @param width New view width in pixels.
     * @param height New view height in pixels.
     */
    void Resize(int width, int height);
    /** @brief Releases the native rendering resources. */
    void Shutdown();
    /** @brief Reports whether an asset is currently loaded. */
    bool HasModel() const;
private:
    class Impl;
    Impl *m_impl;
};
} // namespace AssimpViewMaui
'@ | Set-Content -LiteralPath (Join-Path $JobRoot 'AssimpViewBridge.h') -Encoding utf8

    @'
#include "ModelLoadingApp.h"
#include "AssimpViewBridge.h"
#include "IO/Uri.h"
namespace AssimpViewMaui {
class AssimpView::Impl {
public:
    char arg0[16];
    char *argv[2];
    ModelLoadingApp app;
    bool initialized;
    Impl() : arg0{}, argv{arg0, nullptr}, app(1, argv), initialized(false) {
        const char name[] = "AssimpView";
        for (unsigned int i = 0; name[i] != '\0'; ++i) arg0[i] = name[i];
    }
};
AssimpView::AssimpView() : m_impl(new Impl) {}
AssimpView::~AssimpView() { Shutdown(); delete m_impl; m_impl = nullptr; }
bool AssimpView::Initialize(int width, int height) {
    if (m_impl == nullptr || m_impl->initialized) return m_impl != nullptr;
    m_impl->initialized = m_impl->app.initWindow(0, 0, static_cast<OSRE::ui32>(width), static_cast<OSRE::ui32>(height),
        "Assimp View", OSRE::App::WindowMode::Windowed, OSRE::App::WindowType::Root,
        OSRE::App::RenderBackendType::OpenGLRenderBackend);
    return m_impl->initialized;
}
bool AssimpView::LoadAsset(const char *path) {
    if (m_impl == nullptr || !m_impl->initialized || path == nullptr) return false;
    OSRE::IO::Uri uri{OSRE::String(path)};
    if (!uri.isValid()) return false;
    m_impl->app.importAsset(uri);
    return m_impl->app.hasModel();
}
bool AssimpView::Frame() {
    if (m_impl == nullptr || !m_impl->initialized || !m_impl->app.handleEvents()) return false;
    m_impl->app.update();
    m_impl->app.requestNextFrame();
    return true;
}
void AssimpView::Resize(int width, int height) {
    if (m_impl != nullptr && m_impl->initialized) m_impl->app.resize(0, 0, width, height);
}
void AssimpView::Shutdown() {
    if (m_impl != nullptr && m_impl->initialized) { m_impl->app.destroy(); m_impl->initialized = false; }
}
bool AssimpView::HasModel() const { return m_impl != nullptr && m_impl->app.hasModel(); }
} // namespace AssimpViewMaui
'@ | Set-Content -LiteralPath (Join-Path $JobRoot 'AssimpViewBridge.cpp') -Encoding utf8

    @'
%module AssimpViewModule
%{
#include "AssimpViewBridge.h"
%}
%include "AssimpViewBridge.h"
'@ | Set-Content -LiteralPath (Join-Path $JobRoot 'assimpview.i') -Encoding utf8

    # Keep the native facade and SWIG surface in one source-controlled template.
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'swig\AssimpViewBridge.h') -Destination (Join-Path $JobRoot 'AssimpViewBridge.h') -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'swig\AssimpViewBridge.cpp') -Destination (Join-Path $JobRoot 'AssimpViewBridge.cpp') -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'swig\assimpview.i') -Destination (Join-Path $JobRoot 'assimpview.i') -Force

    # Compile a temporary copy of the unchanged upstream source. Its OSRE
    # prerequisites are already included before the access shim is applied to
    # ModelLoadingApp.h, so no STL keyword-macro option is needed.
    $modelSource = Join-Path $RepoRoot 'lib\assimp_view\src\ModelLoading.cpp'
    $modelText = Get-Content -LiteralPath $modelSource -Raw
    $modelInclude = '#include "ModelLoadingApp.h"'
    if (([regex]::Matches($modelText, [regex]::Escape($modelInclude))).Count -ne 1) {
        Fail 'unexpected ModelLoading.cpp include layout; refusing to generate an altered source'
    }
    $modelShim = '#if defined(ASSIMP_VIEW_MODEL_LOADING_ACCESS_SHIM)' + [Environment]::NewLine + '#define protected public' + [Environment]::NewLine + '#endif' + [Environment]::NewLine + $modelInclude + [Environment]::NewLine + '#if defined(ASSIMP_VIEW_MODEL_LOADING_ACCESS_SHIM)' + [Environment]::NewLine + '#undef protected' + [Environment]::NewLine + '#endif'
    $modelText = $modelText.Replace($modelInclude, $modelShim)
    Set-Content -LiteralPath (Join-Path $JobRoot 'ModelLoading.cpp') -Value $modelText -NoNewline -Encoding utf8
}

function Generate-Bindings {
    $csharp = Join-Path $JobRoot 'swig\csharp'
    $cxx = Join-Path $JobRoot 'swig\cxx'
    New-Item -ItemType Directory -Path $csharp, $cxx -Force | Out-Null
    Invoke-Logged 'SWIG C# bindings' 'swig' @(
        '-c++', '-csharp', '-doxygen', '-namespace', 'Assimp.View.Maui',
        '-dllimport', 'assimpviewmaui', "-I$JobRoot", '-outdir', $csharp,
        '-o', (Join-Path $cxx 'assimpviewmaui.cxx'), (Join-Path $JobRoot 'assimpview.i'))
    if (-not (Get-ChildItem -LiteralPath $csharp -Filter '*.cs' -File)) { Fail 'SWIG did not generate C# classes' }
}

function Write-CMakeProject([string]$Overlay, [string]$NativeOut) {
    $overlayPath = $Overlay.Replace('\', '/')
    $nativePath = $NativeOut.Replace('\', '/')
    $sourcePath = (Join-Path $RepoRoot 'lib\assimp_view\src').Replace('\', '/')
    $bridgePath = (Join-Path $JobRoot 'AssimpViewBridge.cpp').Replace('\', '/')
    $swigPath = (Join-Path $JobRoot 'swig\cxx\assimpviewmaui.cxx').Replace('\', '/')
    $jobPath = $JobRoot.Replace('\', '/')
    $cmake = @"
cmake_minimum_required(VERSION 3.21)
project(AssimpViewMaui LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "$nativePath")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "$nativePath")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "$nativePath")
set(CMAKE_MODULE_PATH "$overlayPath/contrib/assimp/cmake-modules" `${CMAKE_MODULE_PATH})
set(OSRE_BUILD_PLAYER OFF CACHE BOOL "" FORCE)
set(OSRE_BUILD_SAMPLES OFF CACHE BOOL "" FORCE)
set(OSRE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(OSRE_BUILD_ED OFF CACHE BOOL "" FORCE)
set(OSRE_BUILD_DOC OFF CACHE BOOL "" FORCE)
set(ASSIMP_BUILD_ASSIMP_TOOLS OFF CACHE BOOL "" FORCE)
set(ASSIMP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(ASSIMP_BUILD_ZLIB ON CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
add_subdirectory("$overlayPath" `${CMAKE_BINARY_DIR}/osre EXCLUDE_FROM_ALL)
if(TARGET osre)
    target_include_directories(osre PRIVATE "$overlayPath")
endif()
add_library(assimpviewmaui SHARED
    "$jobPath/ModelLoading.cpp"
    "$bridgePath"
    "$swigPath")
set_source_files_properties("$jobPath/ModelLoading.cpp" PROPERTIES
    COMPILE_DEFINITIONS ASSIMP_VIEW_MODEL_LOADING_ACCESS_SHIM)
target_include_directories(assimpviewmaui PRIVATE
    "$sourcePath"
    "$overlayPath/src/Engine"
    "$overlayPath/include"
    "$overlayPath/contrib/assimp/include"
    "$overlayPath/contrib/cppcore/include"
    "$jobPath")
# ModelLoadingApp::importAsset remains protected in the unchanged submodule.
# Apply the access shim consistently to every translation unit in this target so
# the declaration and definition use the same MSVC decorated symbol.
target_link_libraries(assimpviewmaui PRIVATE osre)
set_target_properties(assimpviewmaui PROPERTIES
    WINDOWS_EXPORT_ALL_SYMBOLS ON
    LIBRARY_OUTPUT_DIRECTORY "$nativePath"
    ARCHIVE_OUTPUT_DIRECTORY "$nativePath"
    RUNTIME_OUTPUT_DIRECTORY "$nativePath")
foreach(_target osre cppcore assimp zlibstatic assimpviewmaui)
    if(TARGET `${_target})
        set_target_properties(`${_target} PROPERTIES
            LIBRARY_OUTPUT_DIRECTORY "$nativePath"
            ARCHIVE_OUTPUT_DIRECTORY "$nativePath"
            RUNTIME_OUTPUT_DIRECTORY "$nativePath")
    endif()
endforeach()
"@
    Set-Content -LiteralPath (Join-Path $JobRoot 'project\CMakeLists.txt') -Value $cmake -Encoding utf8
}

function Copy-Atomic([string]$Source, [string]$Destination) {
    $temporary = "$Destination.tmp.$([guid]::NewGuid().ToString('N'))"
    Copy-Item -LiteralPath $Source -Destination $temporary -Force
    Move-Item -LiteralPath $temporary -Destination $Destination -Force
}

function Clean-PublishedOutputs {
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { Fail 'refusing to clean an empty output path' }
    $fullOutput = [IO.Path]::GetFullPath($OutputRoot)
    $root = [IO.Path]::GetPathRoot($fullOutput)
    if ($fullOutput.TrimEnd('\') -eq $root.TrimEnd('\')) {
        Fail "refusing to clean a filesystem root: $fullOutput"
    }

    $platformRoot = Join-Path $fullOutput 'src\Assimp.View.Maui\Platforms\Windows'
    $managedRoot = Join-Path $platformRoot 'AssimpView'
    $lock = Join-Path $platformRoot '.assimp-view-publish.lock'
    New-Item -ItemType Directory -Path $platformRoot -Force | Out-Null
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
            break
        }
        catch {
            Start-Sleep -Milliseconds 200
        }
    }
    try {
        if (Test-Path -LiteralPath $managedRoot) {
            Remove-Item -LiteralPath $managedRoot -Recurse -Force
        }
        foreach ($targetRid in $Rid) {
            $nativeRoot = Join-Path $platformRoot "runtimes\$targetRid\native"
            if (Test-Path -LiteralPath $nativeRoot) {
                Remove-Item -LiteralPath $nativeRoot -Recurse -Force
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Publish([string]$TargetRid, [string]$NativeStage) {
    $platformRoot = Join-Path $OutputRoot 'src\Assimp.View.Maui\Platforms\Windows'
    $managedRoot = Join-Path $platformRoot 'AssimpView'
    $nativeRoot = Join-Path $platformRoot "runtimes\$TargetRid\native"
    New-Item -ItemType Directory -Path $managedRoot, $nativeRoot -Force | Out-Null

    $lock = Join-Path $platformRoot '.assimp-view-publish.lock'
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
            break
        }
        catch {
            Start-Sleep -Milliseconds 200
        }
    }
    try {
        Get-ChildItem -LiteralPath (Join-Path $JobRoot 'swig\csharp') -Filter '*.cs' -File | ForEach-Object {
            Copy-Atomic $_.FullName (Join-Path $managedRoot $_.Name)
        }
        Get-ChildItem -LiteralPath $NativeStage -File | ForEach-Object {
            Copy-Atomic $_.FullName (Join-Path $nativeRoot $_.Name)
        }
    }
    finally {
        Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    Clean-StaleJobRoots
    Clean-PublishedOutputs
    Initialize-GradientProgress (5 + (4 * $Rid.Count))
    Initialize-DotNetEnvironment
    Ensure-HostDependencies
    Initialize-SwigEnvironment
    Update-GradientProgress 'host dependencies'
    Validate-Swig
    Update-GradientProgress 'SWIG validation'
    $vsInstallation = Ensure-VisualStudio
    $cmakeGenerator = Select-CMakeGenerator $vsInstallation
    if (-not $SkipInstall) {
        Ensure-VcpkgToolArchives
    }
    Update-GradientProgress 'Visual Studio toolchain'
    $vcpkg = Prepare-Vcpkg
    Update-GradientProgress 'vcpkg toolchain'
    $overlay = Prepare-Overlay
    Write-BridgeSources
    Generate-Bindings
    Update-GradientProgress 'SWIG C# bindings'

    foreach ($targetRid in $Rid) {
        $vsArch = if ($targetRid -eq 'win-arm64') { 'ARM64' } else { 'x64' }
        $triplet = if ($targetRid -eq 'win-arm64') { 'arm64-windows-static' } else { 'x64-windows-static' }
        $installRoot = Join-Path $JobRoot "vcpkg-installed\$targetRid"
        $nativeOut = Join-Path $JobRoot "native\$targetRid"
        $buildDir = Join-Path $JobRoot "build\$targetRid"
        New-Item -ItemType Directory -Path $nativeOut, $buildDir, (Join-Path $JobRoot 'project') -Force | Out-Null

        if (-not $SkipInstall) {
            Invoke-Logged "vcpkg install $targetRid" (Join-Path $vcpkg 'vcpkg.exe') @(
                'install', "--triplet=$triplet", "--x-manifest-root=$overlay",
                "--x-install-root=$installRoot", '--clean-after-build')
        }
        else {
            $cachedInstallRoot = Join-Path $CacheRoot "installed\$targetRid"
            if (Test-Path -LiteralPath (Join-Path $cachedInstallRoot $triplet) -PathType Container) {
                $installRoot = $cachedInstallRoot
            }
            else {
                $installRoot = Join-Path $vcpkg 'installed'
            }
            if (-not (Test-Path -LiteralPath (Join-Path $installRoot $triplet) -PathType Container)) {
                Fail "--SkipInstall requires a populated vcpkg install tree for $targetRid under $cachedInstallRoot or $installRoot"
            }
        }
        Update-GradientProgress "vcpkg $targetRid"

        Write-CMakeProject $overlay $nativeOut
        $cmakeArgs = @(
            '-S', (Join-Path $JobRoot 'project'),
            '-B', $buildDir,
            '-G', $cmakeGenerator,
            '-A', $vsArch,
            "-DCMAKE_TOOLCHAIN_FILE=$(Join-Path $vcpkg 'scripts\buildsystems\vcpkg.cmake')",
            "-DVCPKG_TARGET_TRIPLET=$triplet",
            "-DVCPKG_INSTALLED_DIR=$installRoot",
            '-DCMAKE_BUILD_TYPE=Release',
            '-DBUILD_SHARED_LIBS=OFF',
            '-DASSIMP_BUILD_TESTS=OFF',
            '-DASSIMP_BUILD_ASSIMP_TOOLS=OFF',
            '-DASSIMP_BUILD_ZLIB=ON',
            '-DVCPKG_APPLOCAL_DEPS=OFF',
            '-DUSE_PLATFORM=VK_USE_PLATFORM_WIN32_KHR'
        )
        Invoke-Logged "CMake configure $targetRid" 'cmake' $cmakeArgs
        Update-GradientProgress "CMake configure $targetRid"
        # The Visual Studio generator delegates to MSBuild. With this OSRE
        # graph, MSBuild's multi-node scheduling can race project-generated
        # libraries under the temporary job root and report a generic CMake
        # exit code without a useful compiler diagnostic. Keep that backend
        # deterministic; Ninja/Make builds can still use the requested jobs.
        $buildParallel = $Jobs
        if ($cmakeGenerator -like 'Visual Studio *') {
            $buildParallel = 1
            Write-ProgressLog "Visual Studio generator: using serialized MSBuild for $targetRid"
        }
        Invoke-Logged "CMake build $targetRid" 'cmake' @('--build', $buildDir, '--config', 'Release', '--parallel', $buildParallel)
        Update-GradientProgress "CMake build $targetRid"

        $nativeStage = Join-Path $JobRoot "publish\$targetRid\native"
        New-Item -ItemType Directory -Path $nativeStage -Force | Out-Null
        $nativeStageFullPath = ([System.IO.Path]::GetFullPath($nativeStage)).TrimEnd('\')
        Get-ChildItem -Recurse -File -Path $JobRoot | Where-Object {
            $_.Extension -in '.dll', '.lib' -and
            $_.FullName -notmatch '\\debug\\|\\buildtrees\\|\\vcpkg\\' -and
            $_.FullName -notmatch '\\swig\\' -and
            $_.FullName -notlike "$nativeStageFullPath\*"
        } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $nativeStage $_.Name) -Force
        }
        if (-not (Get-ChildItem -LiteralPath $nativeStage -Filter '*.dll' -File)) {
            Fail "no Windows DLL was generated for $targetRid"
        }
        Publish $targetRid $nativeStage
        Update-GradientProgress "publish $targetRid"
        Write-ProgressLog "built Windows $targetRid ($vsInstallation)"
    }
    $BuildSucceeded = $true
}
finally {
    Complete-GradientProgress
    if (Test-Path -LiteralPath $JobRoot) {
        if ($BuildSucceeded) {
            Remove-Item -LiteralPath $JobRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            [Console]::Error.WriteLine("build_windows.ps1: build failed; temporary files and logs retained at $JobRoot")
            if (Test-Path -LiteralPath $CommandLog -PathType Leaf) {
                [Console]::Error.WriteLine("build_windows.ps1: command log: $CommandLog")
            }
        }
    }
}

