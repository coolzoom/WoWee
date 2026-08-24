<#
.SYNOPSIS
    Find or install MSYS2 MinGW64 (GCC, Ninja, CMake, client libraries).
#>

$script:MingwPackages = @(
    "mingw-w64-x86_64-cmake",
    "mingw-w64-x86_64-gcc",
    "mingw-w64-x86_64-ninja",
    "mingw-w64-x86_64-pkgconf",
    "mingw-w64-x86_64-SDL2",
    "mingw-w64-x86_64-glm",
    "mingw-w64-x86_64-openssl",
    "mingw-w64-x86_64-zlib",
    "mingw-w64-x86_64-ffmpeg",
    "mingw-w64-x86_64-vulkan-loader",
    "mingw-w64-x86_64-vulkan-headers",
    "mingw-w64-x86_64-shaderc",
    "mingw-w64-x86_64-unicorn"
)

function Invoke-NativeLogged {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    # PowerShell 5 Start-Process joins -ArgumentList and re-parses it, so
    # `bash -lc "pacman -S ..."` became `bash -lc pacman` (no operation).
    # Quote each arg and pass a single command-line string instead.
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $quoted = foreach ($a in $ArgumentList) {
            if ($null -eq $a) { continue }
            $s = [string]$a
            if ($s -match '[\s"]') {
                '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"'
            } else {
                $s
            }
        }
        $argLine = ($quoted -join " ")
        $p = Start-Process -FilePath $FilePath -ArgumentList $argLine -Wait -NoNewWindow -PassThru
        return [int]$p.ExitCode
    } finally {
        $ErrorActionPreference = $old
    }
}

function Find-Msys2Root {
    $candidates = @()
    if ($env:MSYS2_ROOT) { $candidates += $env:MSYS2_ROOT }
    $candidates += @(
        "C:\msys64",
        "D:\msys64",
        "C:\tools\msys64",
        (Join-Path $env:LOCALAPPDATA "msys64")
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c "usr\bin\pacman.exe"))) {
            return (Resolve-Path $c).Path
        }
    }
    return $null
}

function Install-Msys2 {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "MSYS2 is not installed and winget was not found. Install MSYS2 from https://www.msys2.org/ and re-run."
    }
    Write-Host "Installing MSYS2 via winget (MSYS2.MSYS2) ..."
    $code = Invoke-NativeLogged -FilePath "winget.exe" -ArgumentList @(
        "install", "--id", "MSYS2.MSYS2", "-e",
        "--accept-package-agreements", "--accept-source-agreements"
    )
    if ($code -ne 0 -and $code -ne -1978335189) {
        Write-Warning "winget install MSYS2 returned $code; will look for an existing install."
    }
    for ($i = 0; $i -lt 15; $i++) {
        $found = Find-Msys2Root
        if ($found) { return [string]$found }
        Start-Sleep -Seconds 1
    }
    throw "MSYS2 was installed but pacman.exe was not found. Set MSYS2_ROOT to the MSYS2 directory (usually C:\msys64)."
}

function Get-PacmanLockPath {
    param([string]$Msys2Root)
    return (Join-Path $Msys2Root "var\lib\pacman\db.lck")
}

function Unlock-PacmanDatabase {
    param([string]$Msys2Root)
    $lock = Get-PacmanLockPath -Msys2Root $Msys2Root
    if (-not (Test-Path $lock)) { return }

    $pacmanProcs = @(Get-Process -Name "pacman" -ErrorAction SilentlyContinue)
    if ($pacmanProcs.Count -gt 0) {
        Write-Host "Waiting for another pacman process to finish ..."
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 2
            $pacmanProcs = @(Get-Process -Name "pacman" -ErrorAction SilentlyContinue)
            if ($pacmanProcs.Count -eq 0) { break }
        }
        if (@(Get-Process -Name "pacman" -ErrorAction SilentlyContinue).Count -gt 0) {
            throw "Another pacman is still running. Close MSYS2 package operations and re-run."
        }
    }

    if (Test-Path $lock) {
        Write-Warning "Removing stale pacman lock $lock"
        Remove-Item -Force $lock
    }
}

function Ensure-MingwPackages {
    param([Parameter(Mandatory = $true)][string]$Msys2Root)

    $pacman = Join-Path $Msys2Root "usr\bin\pacman.exe"
    $gcc = Join-Path $Msys2Root "mingw64\bin\g++.exe"
    $ninja = Join-Path $Msys2Root "mingw64\bin\ninja.exe"
    $cmake = Join-Path $Msys2Root "mingw64\bin\cmake.exe"
    if ((Test-Path $gcc) -and (Test-Path $ninja) -and (Test-Path $cmake)) {
        Write-Host "MinGW GCC already present at $(Join-Path $Msys2Root 'mingw64\bin')"
        return
    }

    Write-Host "Installing MinGW64 packages via pacman (this can take a while) ..."
    Unlock-PacmanDatabase -Msys2Root $Msys2Root

    $pacmanArgs = @("-S", "-y", "--needed", "--noconfirm") + $script:MingwPackages
    $code = 1
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        Unlock-PacmanDatabase -Msys2Root $Msys2Root
        $code = Invoke-NativeLogged -FilePath $pacman -ArgumentList $pacmanArgs
        if ($code -eq 0) { break }
        Write-Warning "pacman attempt $attempt failed (exit $code); retrying ..."
        Start-Sleep -Seconds 3
    }
    if ($code -ne 0) {
        $lock = Get-PacmanLockPath -Msys2Root $Msys2Root
        throw "pacman failed to install MinGW packages (exit $code). If no pacman is running, delete $lock and retry."
    }
    if (-not (Test-Path $gcc)) {
        throw "g++.exe was not found after pacman install under $Msys2Root\mingw64\bin"
    }
}

function Use-MingwEnvironment {
    param([Parameter(Mandatory = $true)][string]$Msys2Root)

    $prefix = Join-Path $Msys2Root "mingw64"
    $mingwBin = Join-Path $prefix "bin"
    $usrBin = Join-Path $Msys2Root "usr\bin"
    $env:MSYS2_ROOT = $Msys2Root
    $env:MSYSTEM = "MINGW64"
    $env:MINGW_PREFIX = $prefix
    $env:Path = "$mingwBin;$usrBin;$env:Path"
    return [pscustomobject]@{
        Root     = $Msys2Root
        Prefix   = $prefix
        Gcc      = (Join-Path $mingwBin "gcc.exe")
        Gxx      = (Join-Path $mingwBin "g++.exe")
        Cmake    = (Join-Path $mingwBin "cmake.exe")
        Ninja    = (Join-Path $mingwBin "ninja.exe")
    }
}

function Ensure-MingwEnvironment {
    $root = Find-Msys2Root
    if (-not $root) {
        $root = Install-Msys2
    }
    if ($root -is [System.Array]) {
        $root = @($root | Where-Object {
            $_ -is [string] -and (Test-Path (Join-Path $_ "usr\bin\pacman.exe"))
        } | Select-Object -Last 1)
    }
    $root = [string]$root
    if (-not $root -or -not (Test-Path (Join-Path $root "usr\bin\pacman.exe"))) {
        throw "Could not resolve MSYS2 root. Set MSYS2_ROOT (usually C:\msys64) and re-run."
    }
    Ensure-MingwPackages -Msys2Root $root
    return (Use-MingwEnvironment -Msys2Root $root)
}

function Resolve-WoweeToolchain {
    param([string]$Name)
    if (-not $Name) { $Name = $env:WOWEE_TOOLCHAIN }
    if (-not $Name) { $Name = "mingw" }
    switch -Regex ($Name.ToLowerInvariant()) {
        '^(vs|msvc|visualstudio|visual-studio)$' { return "vs" }
        default { return "mingw" }
    }
}

function Reset-CMakeCacheIfGeneratorMismatch {
    param([string]$BuildDir, [string]$WantGenerator)
    $cache = Join-Path $BuildDir "CMakeCache.txt"
    if (-not (Test-Path $cache)) { return }
    $hit = Select-String -Path $cache -Pattern '^CMAKE_GENERATOR:INTERNAL=(.+)$' | Select-Object -First 1
    if (-not $hit) { return }
    $have = $hit.Matches[0].Groups[1].Value
    if ($have -eq $WantGenerator) { return }
    Write-Host "CMake generator changed ($have -> $WantGenerator); clearing cache in $BuildDir"
    Remove-Item -Force $cache
    $cf = Join-Path $BuildDir "CMakeFiles"
    if (Test-Path $cf) { Remove-Item -Recurse -Force $cf }
}
