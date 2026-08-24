<#
.SYNOPSIS
    Builds the wowee project (Windows equivalent of build.sh).

.DESCRIPTION
    Default toolchain is MSYS2 MinGW GCC. Pass 'vs' to generate a Visual Studio
    solution (convenient for debugging).
#>

param(
    [Parameter(Position = 0)]
    [string]$Toolchain
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

function Ensure-Fsr2Sdk {
    $sdkDir = Join-Path $ScriptDir "extern\FidelityFX-FSR2"
    $sdkHeader = Join-Path $sdkDir "src\ffx-fsr2-api\ffx_fsr2.h"
    if (Test-Path $sdkHeader) { return }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warning "git not found; cannot auto-fetch AMD FSR2 SDK."
        return
    }

    Write-Host "Fetching AMD FidelityFX FSR2 SDK into $sdkDir ..."
    New-Item -ItemType Directory -Path (Join-Path $ScriptDir "extern") -Force | Out-Null
    & git clone --depth 1 https://github.com/GPUOpen-Effects/FidelityFX-FSR2.git $sdkDir
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to clone AMD FSR2 SDK. Build will use internal fallback path."
    }
}

function Ensure-FidelityFxSdk {
    $sdkDir = Join-Path $ScriptDir "extern\FidelityFX-SDK"
    $sdkHeader = Join-Path $sdkDir "sdk\include\FidelityFX\host\ffx_frameinterpolation.h"
    $sdkRepo = if ($env:WOWEE_FFX_SDK_REPO) { $env:WOWEE_FFX_SDK_REPO } else { "https://github.com/Kelsidavis/FidelityFX-SDK.git" }
    $sdkRef = if ($env:WOWEE_FFX_SDK_REF) { $env:WOWEE_FFX_SDK_REF } else { "main" }
    if (Test-Path $sdkHeader) { return }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warning "git not found; cannot auto-fetch AMD FidelityFX SDK."
        return
    }

    Write-Host "Fetching AMD FidelityFX SDK ($sdkRef from $sdkRepo) into $sdkDir ..."
    New-Item -ItemType Directory -Path (Join-Path $ScriptDir "extern") -Force | Out-Null
    & git clone --depth 1 --branch $sdkRef $sdkRepo $sdkDir
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to clone AMD FidelityFX SDK. FSR3 framegen extern will be unavailable."
    }
}

. (Join-Path $ScriptDir "scripts\Ensure-Mingw.ps1")
. (Join-Path $ScriptDir "scripts\Ensure-WindowsDeps.ps1")

$Toolchain = Resolve-WoweeToolchain -Name $Toolchain
Write-Host "Building wowee (toolchain: $Toolchain)..."
Ensure-Fsr2Sdk
Ensure-FidelityFxSdk

$cmakeExe = "cmake"
$buildDir = "build"
$cmakeArgs = [System.Collections.Generic.List[string]]::new()
$buildExtra = @()
$binDirName = "bin"

if ($Toolchain -eq "mingw") {
    $mingw = Ensure-MingwEnvironment
    $deps = Ensure-WindowsDeps -RepoRoot $ScriptDir
    $cmakeExe = $mingw.Cmake
    $cmakeArgs.Add("-G")
    $cmakeArgs.Add("Ninja")
    $cmakeArgs.Add("-DCMAKE_BUILD_TYPE=Release")
    $cmakeArgs.Add("-DWOWEE_WARNINGS_AS_ERRORS=OFF")
    $cmakeArgs.Add("-DCMAKE_C_COMPILER=$($mingw.Gcc)")
    $cmakeArgs.Add("-DCMAKE_CXX_COMPILER=$($mingw.Gxx)")
    $cmakeArgs.Add("-DCMAKE_MAKE_PROGRAM=$($mingw.Ninja)")
    $prefixFwd = ($mingw.Prefix -replace '\\', '/')
    $cmakeArgs.Add("-DCMAKE_PREFIX_PATH=$prefixFwd")
    foreach ($a in $deps.CMakeArgs) { $cmakeArgs.Add($a) }
} else {
    $deps = Ensure-WindowsDeps -RepoRoot $ScriptDir
    $buildDir = "build-vs"
    $cmakeArgs.Add("-G")
    $cmakeArgs.Add("Visual Studio 17 2022")
    $cmakeArgs.Add("-A")
    $cmakeArgs.Add("x64")
    $cmakeArgs.Add("-DWOWEE_WARNINGS_AS_ERRORS=OFF")
    foreach ($a in $deps.CMakeArgs) { $cmakeArgs.Add($a) }
    $buildExtra = @("--config", "RelWithDebInfo")
}

if (-not (Test-Path $buildDir)) {
    New-Item -ItemType Directory -Path $buildDir | Out-Null
}
Reset-CMakeCacheIfGeneratorMismatch -BuildDir (Join-Path $ScriptDir $buildDir) -WantGenerator $(if ($Toolchain -eq "mingw") { "Ninja" } else { "Visual Studio 17 2022" })
Set-Location $buildDir

Write-Host "Configuring with CMake..."
$configure = @("..") + $cmakeArgs
& $cmakeExe @configure
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$numProcs = $env:NUMBER_OF_PROCESSORS
if (-not $numProcs) { $numProcs = 4 }
Write-Host "Building with $numProcs cores..."
& $cmakeExe --build . --parallel $numProcs @buildExtra
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$binDir = Join-Path (Get-Location) "bin"
if ($Toolchain -eq "vs") {
    $cfgBin = Join-Path $binDir "RelWithDebInfo"
    if (Test-Path $cfgBin) { $binDir = $cfgBin }
}
Copy-WoweeRuntimeDlls -SourceBinDirs @($deps.RuntimeBinDirs) -DestBinDir $binDir

$binData = Join-Path $binDir "Data"
if (-not (Test-Path $binData)) {
    $target = (Resolve-Path (Join-Path $ScriptDir "Data")).Path
    cmd /c mklink /J "$binData" "$target"
}

$exeHint = Join-Path $binDir "wowee.exe"
Write-Host ""
Write-Host "Build complete! Binary: $exeHint"
if ($Toolchain -eq "vs") {
    Write-Host "Open $buildDir in Visual Studio to debug (RelWithDebInfo)."
    Write-Host "Or: ./build.bat   (default MinGW GCC)"
} else {
    Write-Host "Run with: & '$exeHint'"
    Write-Host "Keep $($mingw.Prefix)\bin on PATH so MinGW DLLs resolve."
    Write-Host "VS debug build: ./build.bat vs"
}
