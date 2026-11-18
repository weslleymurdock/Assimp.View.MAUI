[CmdletBinding()]
param(
    [Alias('abi', 'architecture', 'arch')]
    [string[]]$Rid,
    [string]$OutputRoot,
    [string]$VcpkgRoot,
    [int]$Jobs = 0,
    [ValidateSet('off', 'error', 'warn', 'info', 'debug', 'trace')]
    [string]$LogLevel = 'off',
    [ValidateSet('auto', 'always', 'never')]
    [string]$Progress = 'auto',
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = $RepoRoot
}
else {
    $OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
}

function Fail([string]$Message) {
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

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "required command not found: $Name"
    }
}

function Invoke-Logged([string]$Label, [string]$FilePath, [string[]]$Arguments) {
    if ($LogLevel -ne 'off') {
        if ($LogLevel -in @('debug', 'trace')) {
            Write-Host ("[debug] {0}: {1} {2}" -f $Label, $FilePath, ($Arguments -join ' '))
        }
        & $FilePath @Arguments
    }
    else {
        & $FilePath @Arguments >> $CommandLog 2>&1
    }
    $status = $LASTEXITCODE
    if ($status -ne 0) {
        if ($LogLevel -eq 'off') {
            [Console]::Error.WriteLine("[error] $Label failed; command log follows:")
            Get-Content -LiteralPath $CommandLog -Tail 200 | ForEach-Object { [Console]::Error.WriteLine($_) }
        }
        Fail "$Label failed with exit code $status"
    }
}

$ProgressEnabled = $false
$ProgressCompleted = 0
$ProgressTotal = 0
$ProgressFrame = 0

function Initialize-GradientProgress([int]$Total) {
    $script:ProgressTotal = $Total
    switch ($Progress) {
        'always' { $script:ProgressEnabled = $true }
        'never' { $script:ProgressEnabled = $false }
        'auto' { $script:ProgressEnabled = -not [Console]::IsErrorRedirected }
    }
}

function Update-GradientProgress([string]$Label) {
    if (-not $ProgressEnabled) { return }
    $script:ProgressCompleted++
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
    [Console]::Error.Write("`r$esc[2K$esc[38;2;99;102;241m[{0,3}%]$esc[0m " -f $percent)
    for ($i = 0; $i -lt $width; $i++) {
        if ($i -lt $filled) {
            $red = 79 + [math]::Floor($i * 45 / $width)
            $green = 70 - [math]::Floor($i * 12 / $width)
            $blue = 229 + [math]::Floor($i * 8 / $width)
            [Console]::Error.Write("$esc[38;2;{0};{1};{2}m━$esc[0m" -f $red, $green, $blue)
        }
        else {
            [Console]::Error.Write("$esc[38;2;55;48;163m─$esc[0m")
        }
    }
    [Console]::Error.Write(" $Label")
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
    $version = [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
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
    Write-Host "using SWIG $version with C# Doxygen support"
}

function Install-WingetPackage([string]$Id) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Invoke-Logged "winget install $Id" 'winget' @('install', '--id', $Id, '--exact', '--silent', '--accept-source-agreements', '--accept-package-agreements')
        return
    }
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Invoke-Logged "choco install $Id" 'choco' @('install', $Id, '-y', '--no-progress')
        return
    }
    Fail "install $Id or provide it on PATH; neither winget nor choco is available"
}

function Ensure-HostDependencies {
    if ($SkipInstall) {
        Require-Command cmake
        Require-Command swig
        Require-Command git
        return
    }
    if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { Install-WingetPackage 'Kitware.CMake' }
    if (-not (Get-Command swig -ErrorAction SilentlyContinue)) { Install-WingetPackage 'SWIG.SWIG' }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Install-WingetPackage 'Git.Git' }
    Require-Command cmake
    Require-Command swig
    Require-Command git
}

function Find-VsWhere {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Ensure-VisualStudio {
    $vswhere = Find-VsWhere
    if (-not $vswhere -and -not $SkipInstall) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            & winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --silent --accept-source-agreements --accept-package-agreements `
                --override '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --includeRecommended'
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { Fail "Visual Studio Build Tools installation failed: $LASTEXITCODE" }
        }
        else {
            $installer = Join-Path $JobRoot 'vs_BuildTools.exe'
            Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $installer
            $arguments = '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --includeRecommended'
            $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
            if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
                Fail "Visual Studio Build Tools installation failed: $($process.ExitCode)"
            }
        }
        $vswhere = Find-VsWhere
    }
    if (-not $vswhere) { Fail 'vswhere.exe was not found; install Visual Studio 2022 C++ Build Tools' }
    $installation = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath).Trim()
    if (-not $installation) { Fail 'Visual Studio C++ tools were not found' }
    return $installation
}

function Copy-Tree([string]$Source, [string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
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
    $local = Join-Path $JobRoot 'vcpkg'
    Copy-Tree $source $local
    $exe = Join-Path $local 'vcpkg.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        $bootstrap = Join-Path $local 'bootstrap-vcpkg.bat'
        if (-not (Test-Path -LiteralPath $bootstrap)) { Fail "bootstrap-vcpkg.bat not found in $source" }
        & cmd.exe /d /c "`"$bootstrap`" -disableMetrics"
        if ($LASTEXITCODE -ne 0) { Fail "vcpkg bootstrap failed: $LASTEXITCODE" }
    }
    if (-not (Test-Path -LiteralPath $exe)) { Fail 'vcpkg bootstrap did not create vcpkg.exe' }
    return $local
}

function Prepare-Overlay {
    $overlay = Join-Path $JobRoot 'osre'
    Copy-Tree (Join-Path $RepoRoot 'lib\assimp_view\contrib\osre') $overlay

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
#define protected public
#include "ModelLoadingApp.h"
#undef protected
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
        OSRE::RenderBackend::RenderBackendType::OpenGLRenderBackend);
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
add_library(assimpviewmaui SHARED
    "$sourcePath/ModelLoading.cpp"
    "$bridgePath"
    "$swigPath")
target_include_directories(assimpviewmaui PRIVATE
    "$sourcePath"
    "$overlayPath/src/Engine"
    "$overlayPath/include"
    "$overlayPath/contrib/assimp/include"
    "$overlayPath/contrib/cppcore/include"
    "$jobPath")
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
    Initialize-GradientProgress (5 + (4 * $Rid.Count))
    Ensure-HostDependencies
    Update-GradientProgress 'host dependencies'
    Validate-Swig
    Update-GradientProgress 'SWIG validation'
    $vsInstallation = Ensure-VisualStudio
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
            $installRoot = Join-Path $vcpkg 'installed'
            if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
                Fail "--SkipInstall requires a populated vcpkg installed directory: $installRoot"
            }
        }
        Update-GradientProgress "vcpkg $targetRid"

        Write-CMakeProject $overlay $nativeOut
        $cmakeArgs = @(
            '-S', (Join-Path $JobRoot 'project'),
            '-B', $buildDir,
            '-G', 'Visual Studio 17 2022',
            '-A', $vsArch,
            "-DCMAKE_TOOLCHAIN_FILE=$(Join-Path $vcpkg 'scripts\buildsystems\vcpkg.cmake')",
            "-DVCPKG_TARGET_TRIPLET=$triplet",
            "-DVCPKG_INSTALLED_DIR=$installRoot",
            '-DCMAKE_BUILD_TYPE=Release',
            '-DBUILD_SHARED_LIBS=OFF',
            '-DASSIMP_BUILD_TESTS=OFF',
            '-DASSIMP_BUILD_ASSIMP_TOOLS=OFF',
            '-DASSIMP_BUILD_ZLIB=ON',
            '-DUSE_PLATFORM=VK_USE_PLATFORM_WIN32_KHR'
        )
        Invoke-Logged "CMake configure $targetRid" 'cmake' $cmakeArgs
        Update-GradientProgress "CMake configure $targetRid"
        Invoke-Logged "CMake build $targetRid" 'cmake' @('--build', $buildDir, '--config', 'Release', '--parallel', $Jobs)
        Update-GradientProgress "CMake build $targetRid"

        $nativeStage = Join-Path $JobRoot "publish\$targetRid\native"
        New-Item -ItemType Directory -Path $nativeStage -Force | Out-Null
        Get-ChildItem -Recurse -File -Path $JobRoot | Where-Object {
            $_.Extension -in '.dll', '.lib' -and
            $_.FullName -notmatch '\\debug\\|\\buildtrees\\|\\vcpkg\\' -and
            $_.FullName -notmatch '\\swig\\'
        } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $nativeStage $_.Name) -Force
        }
        if (-not (Get-ChildItem -LiteralPath $nativeStage -Filter '*.dll' -File)) {
            Fail "no Windows DLL was generated for $targetRid"
        }
        Publish $targetRid $nativeStage
        Update-GradientProgress "publish $targetRid"
        Write-Host "built Windows $targetRid ($vsInstallation)" -ForegroundColor Green
    }
}
finally {
    Complete-GradientProgress
    if (Test-Path -LiteralPath $JobRoot) {
        Remove-Item -LiteralPath $JobRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

