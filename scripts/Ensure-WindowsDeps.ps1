<#
.SYNOPSIS
    Detect SDL2, OpenSSL, zlib, GLM, FFmpeg and Vulkan on Windows.
    Reuse what is already installed; download or bootstrap the rest for MSVC CMake.
#>

$script:Sdl2Version = "2.32.10"
$script:GlmVersion = "1.0.1"
$script:ZlibVersion = "1.3.1"
$script:OpenSslZipUrls = @(
    "https://download.firedaemon.com/FireDaemon-OpenSSL/openssl-3.5.7.zip",
    "https://download.firedaemon.com/FireDaemon-OpenSSL/openssl-3.5.4.zip",
    "https://download.firedaemon.com/FireDaemon-OpenSSL/openssl-3.4.1.zip"
)

function Wowee-InvokeLogged {
    param([scriptblock]$Command)
    & $Command 2>&1 | ForEach-Object { Write-Host $_ }
}

function Wowee-DownloadFile {
    param([string]$Url, [string]$Destination)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host "Downloading $Url ..."
    $dir = Split-Path -Parent $Destination
    if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -L --fail --retry 3 -o $Destination $Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url" }
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    }
}

function Wowee-FirstExisting {
    param([string[]]$Paths, [string]$Child)
    foreach ($p in $Paths) {
        if (-not $p) { continue }
        $check = if ($Child) { Join-Path $p $Child } else { $p }
        if (Test-Path $check) { return (Resolve-Path $p).Path }
    }
    return $null
}

function Find-Sdl2CMakeDir {
    param([string]$RepoRoot, [string]$VcpkgInstalled)
    $candidates = @()
    # vcpkg first: headers live at include/SDL2/SDL.h, matching this client's includes.
    if ($VcpkgInstalled) {
        $candidates += (Join-Path $VcpkgInstalled "share\sdl2")
        $candidates += (Join-Path $VcpkgInstalled "share\SDL2")
    }
    if ($env:SDL2_DIR) { $candidates += $env:SDL2_DIR }
    $vendored = Join-Path $RepoRoot "extern\SDL2-$script:Sdl2Version"
    $candidates += $vendored
    $candidates += (Join-Path $vendored "cmake")
    Get-ChildItem -Path (Join-Path $RepoRoot "extern") -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "SDL2-*" } |
        ForEach-Object { $candidates += $_.FullName; $candidates += (Join-Path $_.FullName "cmake") }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if (Test-Path (Join-Path $c "SDL2Config.cmake")) { return (Resolve-Path $c).Path }
        if (Test-Path (Join-Path $c "sdl2-config.cmake")) { return (Resolve-Path $c).Path }
        $nested = Join-Path $c "cmake"
        if (Test-Path (Join-Path $nested "SDL2Config.cmake")) { return (Resolve-Path $nested).Path }
    }
    return $null
}

function Test-VcpkgRel {
    param([string]$VcpkgRoot, [string]$RelativePath)
    if (-not $VcpkgRoot) { return $false }
    return (Test-Path (Join-Path $VcpkgRoot "installed\x64-windows\$RelativePath"))
}

function Test-VcpkgSdl2 {
    param([string]$VcpkgRoot)
    return (Test-VcpkgRel -VcpkgRoot $VcpkgRoot -RelativePath "include\SDL2\SDL.h")
}

function Install-Sdl2VcDevel {
    param([string]$RepoRoot)
    $ver = $script:Sdl2Version
    $dest = Join-Path $RepoRoot "extern\SDL2-$ver"
    $cmakeDir = Join-Path $dest "cmake"
    if (Test-Path (Join-Path $cmakeDir "SDL2Config.cmake")) { return (Resolve-Path $cmakeDir).Path }

    $url = "https://github.com/libsdl-org/SDL/releases/download/release-$ver/SDL2-devel-$ver-VC.zip"
    $zip = Join-Path $RepoRoot "extern\SDL2-devel-$ver-VC.zip"
    Wowee-DownloadFile -Url $url -Destination $zip
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Expand-Archive -Path $zip -DestinationPath (Join-Path $RepoRoot "extern") -Force
    Remove-Item -Force $zip -ErrorAction SilentlyContinue
    if (-not (Test-Path (Join-Path $cmakeDir "SDL2Config.cmake"))) {
        throw "SDL2 extracted, but cmake/SDL2Config.cmake was not found under $dest"
    }
    return (Resolve-Path $cmakeDir).Path
}

function Find-OpenSslRoot {
    param([string]$RepoRoot, [string]$VcpkgInstalled)
    $candidates = @(
        $env:OPENSSL_ROOT_DIR,
        "C:\Program Files\OpenSSL-Win64",
        "C:\Program Files\OpenSSL",
        "C:\Program Files\FireDaemon OpenSSL 3.5",
        "C:\Program Files\FireDaemon OpenSSL 3",
        "C:\OpenSSL-Win64",
        (Join-Path $RepoRoot "extern\openssl-install")
    )
    Get-ChildItem -Path (Join-Path $RepoRoot "extern") -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "openssl*" } |
        ForEach-Object {
            $candidates += $_.FullName
            $candidates += (Join-Path $_.FullName "x64")
            $candidates += (Join-Path $_.FullName "x64\bin")
            $parent = Join-Path $_.FullName "x64"
            if (Test-Path $parent) { $candidates += $parent }
        }
    if ($VcpkgInstalled) { $candidates += $VcpkgInstalled }

    $hit = Wowee-FirstExisting -Paths $candidates -Child "include\openssl\ssl.h"
    if ($hit) { return $hit }

    $sslHeader = Get-ChildItem -Path (Join-Path $RepoRoot "extern") -Filter ssl.h -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '[\\/]include[\\/]openssl[\\/]ssl\.h$' } |
        Select-Object -First 1
    if ($sslHeader) {
        return (Resolve-Path (Split-Path (Split-Path $sslHeader.DirectoryName -Parent) -Parent)).Path
    }
    return $null
}

function Install-OpenSsl {
    param([string]$RepoRoot)
    $existing = Find-OpenSslRoot -RepoRoot $RepoRoot -VcpkgInstalled $null
    if ($existing) { return $existing }

    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        foreach ($pkg in @("FireDaemon.OpenSSL", "ShiningLight.OpenSSL.Light", "ShiningLight.OpenSSL")) {
            Write-Host "Trying winget install $pkg ..."
            Wowee-InvokeLogged { winget.exe install --id $pkg -e --accept-package-agreements --accept-source-agreements }
            $existing = Find-OpenSslRoot -RepoRoot $RepoRoot -VcpkgInstalled $null
            if ($existing) { return $existing }
        }
    }

    $extern = Join-Path $RepoRoot "extern"
    New-Item -ItemType Directory -Path $extern -Force | Out-Null
    $zip = Join-Path $extern "openssl-win64.zip"
    $ok = $false
    foreach ($url in $script:OpenSslZipUrls) {
        try {
            Wowee-DownloadFile -Url $url -Destination $zip
            $ok = $true
            break
        } catch {
            Write-Warning $_.Exception.Message
        }
    }
    if (-not $ok) { throw "Failed to download a prebuilt Windows OpenSSL package" }

    Write-Host "Extracting OpenSSL ..."
    Expand-Archive -Path $zip -DestinationPath $extern -Force
    Remove-Item -Force $zip -ErrorAction SilentlyContinue

    $found = Find-OpenSslRoot -RepoRoot $RepoRoot -VcpkgInstalled $null
    if (-not $found) { throw "OpenSSL extracted, but include/openssl/ssl.h was not found under extern\" }
    return $found
}

function Find-ZlibPrefix {
    param([string]$RepoRoot, [string]$VcpkgInstalled)
    $candidates = @(
        (Join-Path $RepoRoot "extern\zlib-install"),
        $VcpkgInstalled
    )
    return Wowee-FirstExisting -Paths $candidates -Child "include\zlib.h"
}

function Install-Zlib {
    param([string]$RepoRoot)
    $ver = $script:ZlibVersion
    $src = Join-Path $RepoRoot "extern\zlib-$ver"
    $prefix = Join-Path $RepoRoot "extern\zlib-install"
    if (Test-Path (Join-Path $prefix "include\zlib.h")) { return $prefix }

    $tagZip = "zlib" + ($ver -replace '\.', '')
    $url = "https://github.com/madler/zlib/releases/download/v$ver/${tagZip}.zip"
    $zip = Join-Path $RepoRoot "extern\${tagZip}.zip"
    Wowee-DownloadFile -Url $url -Destination $zip
    $extern = Join-Path $RepoRoot "extern"
    if (Test-Path $src) { Remove-Item -Recurse -Force $src }
    Expand-Archive -Path $zip -DestinationPath $extern -Force
    Remove-Item -Force $zip -ErrorAction SilentlyContinue
    if (-not (Test-Path $src)) {
        $found = Get-ChildItem $extern -Directory | Where-Object { $_.Name -like "zlib*" -and $_.Name -ne "zlib-install" } | Select-Object -First 1
        if ($found) { $src = $found.FullName }
    }

    $build = Join-Path $RepoRoot "extern\zlib-build"
    Write-Host "Building zlib $ver ..."
    & cmake -S $src -B $build -DCMAKE_BUILD_TYPE=Release "-DCMAKE_INSTALL_PREFIX=$prefix"
    if ($LASTEXITCODE -ne 0) { throw "zlib CMake configure failed" }
    & cmake --build $build --config Release --target install
    if ($LASTEXITCODE -ne 0) { throw "zlib build/install failed" }
    return (Resolve-Path $prefix).Path
}

function Find-GlmDir {
    param([string]$RepoRoot, [string]$VcpkgInstalled)
    $candidates = @(
        (Join-Path $RepoRoot "extern\glm-$script:GlmVersion"),
        (Join-Path $RepoRoot "extern\glm"),
        $VcpkgInstalled
    )
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if (Test-Path (Join-Path $c "glm\glm.hpp")) { return (Resolve-Path $c).Path }
        if (Test-Path (Join-Path $c "include\glm\glm.hpp")) { return (Resolve-Path $c).Path }
    }
    return $null
}

function Install-Glm {
    param([string]$RepoRoot)
    $ver = $script:GlmVersion
    $dest = Join-Path $RepoRoot "extern\glm-$ver"
    if (Test-Path (Join-Path $dest "glm\glm.hpp")) { return (Resolve-Path $dest).Path }

    $url = "https://github.com/g-truc/glm/archive/refs/tags/$ver.zip"
    $zip = Join-Path $RepoRoot "extern\glm-$ver.zip"
    Wowee-DownloadFile -Url $url -Destination $zip
    $extern = Join-Path $RepoRoot "extern"
    Expand-Archive -Path $zip -DestinationPath $extern -Force
    Remove-Item -Force $zip -ErrorAction SilentlyContinue
    $extracted = Join-Path $extern "glm-$ver"
    if (-not (Test-Path (Join-Path $extracted "glm\glm.hpp"))) {
        throw "GLM extracted, but glm/glm.hpp was not found under $extracted"
    }
    return (Resolve-Path $extracted).Path
}

function Find-FfmpegRoot {
    param([string]$RepoRoot, [string]$VcpkgInstalled)
    $candidates = @()
    Get-ChildItem -Path (Join-Path $RepoRoot "extern") -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "ffmpeg*" } |
        ForEach-Object { $candidates += $_.FullName }
    if ($VcpkgInstalled) { $candidates += $VcpkgInstalled }
    return Wowee-FirstExisting -Paths $candidates -Child "include\libavformat\avformat.h"
}

function Install-Ffmpeg {
    param([string]$RepoRoot)
    $urls = @(
        "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n7.1-latest-win64-gpl-shared.zip",
        "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl-shared.zip"
    )
    $zip = Join-Path $RepoRoot "extern\ffmpeg-win64-shared.zip"
    $ok = $false
    foreach ($url in $urls) {
        try {
            Wowee-DownloadFile -Url $url -Destination $zip
            $ok = $true
            break
        } catch {
            Write-Warning $_.Exception.Message
        }
    }
    if (-not $ok) { throw "Failed to download a Windows FFmpeg shared build" }

    Write-Host "Extracting FFmpeg ..."
    Expand-Archive -Path $zip -DestinationPath (Join-Path $RepoRoot "extern") -Force
    Remove-Item -Force $zip -ErrorAction SilentlyContinue
    $found = Find-FfmpegRoot -RepoRoot $RepoRoot -VcpkgInstalled $null
    if (-not $found) { throw "FFmpeg extracted, but include/libavformat/avformat.h was not found" }
    return $found
}

function Find-VulkanSdk {
    param([string]$VcpkgInstalled)
    if ($env:VULKAN_SDK -and (Test-Path (Join-Path $env:VULKAN_SDK "Include\vulkan\vulkan.h"))) {
        return $env:VULKAN_SDK
    }
    $sdkRoot = "C:\VulkanSDK"
    if (Test-Path $sdkRoot) {
        $latest = Get-ChildItem $sdkRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "Include\vulkan\vulkan.h") } |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if ($latest) { return $latest.FullName }
    }
    if ($VcpkgInstalled -and (Test-Path (Join-Path $VcpkgInstalled "include\vulkan\vulkan.h"))) {
        return $VcpkgInstalled
    }
    return $null
}

function Install-VulkanViaWinget {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return $null }
    Write-Host "Vulkan SDK not found; installing KhronosGroup.VulkanSDK via winget ..."
    & winget.exe install --id KhronosGroup.VulkanSDK -e --accept-package-agreements --accept-source-agreements
    return Find-VulkanSdk -VcpkgInstalled $null
}

function Get-VcpkgRoot {
    param([string]$RepoRoot)
    if ($env:VCPKG_ROOT -and (Test-Path (Join-Path $env:VCPKG_ROOT "scripts\buildsystems\vcpkg.cmake"))) {
        return $env:VCPKG_ROOT
    }
    $local = Join-Path $RepoRoot "extern\vcpkg"
    if (Test-Path (Join-Path $local "scripts\buildsystems\vcpkg.cmake")) { return $local }
    return $null
}

function Ensure-Vcpkg {
    param([string]$RepoRoot)
    $root = Get-VcpkgRoot -RepoRoot $RepoRoot
    if (-not $root) {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw "vcpkg is required for OpenSSL (and Vulkan loader fallback) but git was not found"
        }
        $root = Join-Path $RepoRoot "extern\vcpkg"
        Write-Host "Cloning vcpkg into $root ..."
        New-Item -ItemType Directory -Path (Join-Path $RepoRoot "extern") -Force | Out-Null
        Wowee-InvokeLogged { git clone --depth 1 https://github.com/microsoft/vcpkg.git $root }
        if ($LASTEXITCODE -ne 0) { throw "Failed to clone vcpkg" }
    }
    $exe = Join-Path $root "vcpkg.exe"
    if (-not (Test-Path $exe)) {
        Write-Host "Bootstrapping vcpkg ..."
        Wowee-InvokeLogged { & (Join-Path $root "bootstrap-vcpkg.bat") -disableMetrics }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { throw "vcpkg bootstrap failed" }
    }
    return $root
}

function Install-VcpkgPorts {
    param([string]$VcpkgRoot, [string[]]$Ports)
    if (-not $Ports -or $Ports.Count -eq 0) { return }
    $exe = Join-Path $VcpkgRoot "vcpkg.exe"
    if (-not (Test-Path $exe)) { throw "vcpkg.exe not found at $exe" }
    Write-Host "vcpkg install $($Ports -join ' ') --triplet x64-windows ..."
    # Quote ports so sdl2[vulkan] is not treated as a PowerShell wildcard.
    $portArgs = @($Ports | ForEach-Object { "$_" })
    Wowee-InvokeLogged { & $exe install --triplet x64-windows @portArgs }
    if ($LASTEXITCODE -ne 0) { throw "vcpkg install failed for: $($Ports -join ', ')" }
}

function Copy-WoweeRuntimeDlls {
    param(
        [string[]]$SourceBinDirs,
        [string]$DestBinDir
    )
    if (-not (Test-Path $DestBinDir)) {
        New-Item -ItemType Directory -Path $DestBinDir -Force | Out-Null
    }
    foreach ($src in $SourceBinDirs) {
        if (-not $src -or -not (Test-Path $src)) { continue }
        Get-ChildItem $src -Filter *.dll -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -Force $_.FullName (Join-Path $DestBinDir $_.Name)
        }
    }
}

function Ensure-WindowsDeps {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $result = [ordered]@{
        CMakeArgs     = [System.Collections.Generic.List[string]]::new()
        PrefixPaths   = [System.Collections.Generic.List[string]]::new()
        RuntimeBinDirs = [System.Collections.Generic.List[string]]::new()
        VcpkgRoot     = $null
        Sdl2CMakeDir  = $null
    }

    if ($env:MSYSTEM) {
        Write-Host "MSYS2 detected; using packages from the MinGW prefix (no extra downloads)."
        return [pscustomobject]$result
    }

    Write-Host "Preferring vcpkg for SDL2, OpenSSL, zlib, GLM, FFmpeg, and Vulkan."
    $sdl2FromVcpkg = $false
    $opensslFromVcpkg = $false
    $zlibFromVcpkg = $false
    $glmFromVcpkg = $false
    $ffmpegFromVcpkg = $false
    $vulkanFromVcpkg = $false

    try {
        $vcpkgRoot = Ensure-Vcpkg -RepoRoot $RepoRoot
        $needed = [System.Collections.Generic.List[string]]::new()
        if (-not (Test-VcpkgSdl2 -VcpkgRoot $vcpkgRoot)) { $needed.Add("sdl2[vulkan]") }
        if (-not (Test-VcpkgRel -VcpkgRoot $vcpkgRoot -RelativePath "include\openssl\ssl.h")) { $needed.Add("openssl") }
        if (-not (Test-VcpkgRel -VcpkgRoot $vcpkgRoot -RelativePath "include\zlib.h")) { $needed.Add("zlib") }
        if (-not (Test-VcpkgRel -VcpkgRoot $vcpkgRoot -RelativePath "include\glm\glm.hpp")) { $needed.Add("glm") }
        if (-not (Test-VcpkgRel -VcpkgRoot $vcpkgRoot -RelativePath "include\libavformat\avformat.h")) { $needed.Add("ffmpeg") }
        if (-not (Test-VcpkgRel -VcpkgRoot $vcpkgRoot -RelativePath "include\vulkan\vulkan.h")) { $needed.Add("vulkan-headers") }
        if (-not (Test-VcpkgRel -VcpkgRoot $vcpkgRoot -RelativePath "lib\vulkan-1.lib")) { $needed.Add("vulkan-loader") }
        if ($needed.Count -gt 0) {
            Write-Host "vcpkg will install: $($needed -join ', ')"
            Install-VcpkgPorts -VcpkgRoot $vcpkgRoot -Ports ($needed | Select-Object -Unique)
        }
    } catch {
        Write-Warning "vcpkg bootstrap/install failed: $($_.Exception.Message)"
    }

    $installed = $null
    if ($vcpkgRoot) {
        $candidate = Join-Path $vcpkgRoot "installed\x64-windows"
        if (Test-Path $candidate) { $installed = $candidate }
    }

    $sdl2FromVcpkg = Test-VcpkgSdl2 -VcpkgRoot $vcpkgRoot
    $opensslFromVcpkg = Test-VcpkgRel -VcpkgRoot $vcpkgRoot -RelativePath "include\openssl\ssl.h"
    $zlibFromVcpkg = Test-VcpkgRel -VcpkgRoot $vcpkgRoot -RelativePath "include\zlib.h"
    $glmFromVcpkg = Test-VcpkgRel -VcpkgRoot $vcpkgRoot -RelativePath "include\glm\glm.hpp"
    $ffmpegFromVcpkg = Test-VcpkgRel -VcpkgRoot $vcpkgRoot -RelativePath "include\libavformat\avformat.h"
    $vulkanFromVcpkg = (Test-VcpkgRel -VcpkgRoot $vcpkgRoot -RelativePath "include\vulkan\vulkan.h") -and
                       (Test-VcpkgRel -VcpkgRoot $vcpkgRoot -RelativePath "lib\vulkan-1.lib")

    $sdl2 = Find-Sdl2CMakeDir -RepoRoot $RepoRoot -VcpkgInstalled $installed
    $openssl = Find-OpenSslRoot -RepoRoot $RepoRoot -VcpkgInstalled $installed
    $zlib = Find-ZlibPrefix -RepoRoot $RepoRoot -VcpkgInstalled $installed
    $glm = Find-GlmDir -RepoRoot $RepoRoot -VcpkgInstalled $installed
    $ffmpeg = Find-FfmpegRoot -RepoRoot $RepoRoot -VcpkgInstalled $installed
    $vulkan = Find-VulkanSdk -VcpkgInstalled $installed

    if ($sdl2FromVcpkg) {
        Write-Host "Using vcpkg SDL2"
    } elseif ($sdl2) {
        Write-Host "Using existing SDL2 at $sdl2"
    } else {
        Write-Host "SDL2 not found; downloading the official SDL2 VC devel package ..."
        $sdl2 = Install-Sdl2VcDevel -RepoRoot $RepoRoot
        Write-Host "Installed SDL2 to $sdl2"
    }

    if ($glmFromVcpkg) {
        Write-Host "Using vcpkg GLM"
    } elseif ($glm) {
        Write-Host "Using existing GLM at $glm"
    } else {
        Write-Host "GLM not found; downloading $script:GlmVersion ..."
        $glm = Install-Glm -RepoRoot $RepoRoot
    }

    if ($ffmpegFromVcpkg) {
        Write-Host "Using vcpkg FFmpeg"
    } elseif ($ffmpeg) {
        Write-Host "Using existing FFmpeg at $ffmpeg"
    } else {
        Write-Host "FFmpeg not found; downloading a Windows shared build ..."
        $ffmpeg = Install-Ffmpeg -RepoRoot $RepoRoot
    }

    if ($zlibFromVcpkg) {
        Write-Host "Using vcpkg zlib"
    } elseif ($zlib) {
        Write-Host "Using existing zlib at $zlib"
    } else {
        Write-Host "zlib not found; downloading and building $script:ZlibVersion ..."
        $zlib = Install-Zlib -RepoRoot $RepoRoot
    }

    if ($opensslFromVcpkg) {
        Write-Host "Using vcpkg OpenSSL"
    } elseif ($openssl) {
        Write-Host "Using existing OpenSSL at $openssl"
    } else {
        Write-Host "OpenSSL not found; installing a Windows prebuilt package ..."
        $openssl = Install-OpenSsl -RepoRoot $RepoRoot
        Write-Host "Installed OpenSSL to $openssl"
    }

    if ($vulkanFromVcpkg) {
        Write-Host "Using vcpkg Vulkan headers/loader"
        $vulkan = $installed
    } elseif ($vulkan) {
        Write-Host "Using existing Vulkan at $vulkan"
    } else {
        $vulkan = Install-VulkanViaWinget
        if ($vulkan) {
            Write-Host "Using Vulkan SDK at $vulkan"
        } else {
            Write-Warning "Vulkan not found. Install the Vulkan SDK or vcpkg vulkan-headers + vulkan-loader."
        }
    }

    if ($vcpkgRoot -and (Test-Path (Join-Path $vcpkgRoot "scripts\buildsystems\vcpkg.cmake"))) {
        $result.VcpkgRoot = $vcpkgRoot
        $result.CMakeArgs.Add("-DCMAKE_TOOLCHAIN_FILE=$vcpkgRoot\scripts\buildsystems\vcpkg.cmake")
        $result.CMakeArgs.Add("-DVCPKG_TARGET_TRIPLET=x64-windows")
        $result.CMakeArgs.Add("-DVCPKG_MANIFEST_MODE=OFF")
        $vcpkgBin = Join-Path $vcpkgRoot "installed\x64-windows\bin"
        if (Test-Path $vcpkgBin) { $result.RuntimeBinDirs.Add($vcpkgBin) }
    }

    if ($sdl2) {
        $result.Sdl2CMakeDir = $sdl2
        if (-not $sdl2FromVcpkg) {
            $result.CMakeArgs.Add("-DSDL2_DIR=$sdl2")
        }
        $sdlRoot = Split-Path $sdl2 -Parent
        foreach ($binGuess in @((Join-Path $sdlRoot "lib\x64"), (Join-Path $sdlRoot "bin"))) {
            if (Test-Path $binGuess) { $result.RuntimeBinDirs.Add($binGuess) }
        }
    }
    if ($openssl -and -not $opensslFromVcpkg) {
        $result.CMakeArgs.Add("-DOPENSSL_ROOT_DIR=$openssl")
        $result.PrefixPaths.Add($openssl)
        foreach ($binGuess in @((Join-Path $openssl "bin"), (Join-Path $openssl "lib"))) {
            if (Test-Path $binGuess) { $result.RuntimeBinDirs.Add($binGuess) }
        }
    }
    if ($zlib -and -not $zlibFromVcpkg) {
        $result.PrefixPaths.Add($zlib)
        $zbin = Join-Path $zlib "bin"
        if (Test-Path $zbin) { $result.RuntimeBinDirs.Add($zbin) }
    }
    if ($glm -and -not $glmFromVcpkg) {
        $glmConfig = Join-Path $glm "cmake\glm"
        if (Test-Path (Join-Path $glmConfig "glmConfig.cmake")) {
            $result.CMakeArgs.Add("-Dglm_DIR=$glmConfig")
        }
        $result.PrefixPaths.Add($glm)
    }
    if ($ffmpeg -and -not $ffmpegFromVcpkg) {
        $result.PrefixPaths.Add($ffmpeg)
        $ffbin = Join-Path $ffmpeg "bin"
        if (Test-Path $ffbin) { $result.RuntimeBinDirs.Add($ffbin) }
    }
    if ($vulkan -and -not $vulkanFromVcpkg) {
        $env:VULKAN_SDK = $vulkan
        $result.CMakeArgs.Add("-DVULKAN_SDK=$vulkan")
        $vkInc = Join-Path $vulkan "Include"
        if (-not (Test-Path $vkInc)) { $vkInc = Join-Path $vulkan "include" }
        $vkLib = Join-Path $vulkan "Lib\vulkan-1.lib"
        if (-not (Test-Path $vkLib)) { $vkLib = Join-Path $vulkan "lib\vulkan-1.lib" }
        if (Test-Path $vkInc) { $result.CMakeArgs.Add("-DVulkan_INCLUDE_DIR=$vkInc") }
        if (Test-Path $vkLib) { $result.CMakeArgs.Add("-DVulkan_LIBRARY=$vkLib") }
        $vkBin = Join-Path $vulkan "Bin"
        if (-not (Test-Path $vkBin)) { $vkBin = Join-Path $vulkan "bin" }
        if (Test-Path $vkBin) { $result.RuntimeBinDirs.Add($vkBin) }
    } elseif ($vulkanFromVcpkg -and $installed) {
        $vkInc = Join-Path $installed "include"
        $vkLib = Join-Path $installed "lib\vulkan-1.lib"
        if (Test-Path (Join-Path $vkInc "vulkan\vulkan.h")) {
            $result.CMakeArgs.Add("-DVulkan_INCLUDE_DIR=$vkInc")
        }
        if (Test-Path $vkLib) {
            $result.CMakeArgs.Add("-DVulkan_LIBRARY=$vkLib")
        }
    }

    if ($result.PrefixPaths.Count -gt 0) {
        $joined = ($result.PrefixPaths | Select-Object -Unique) -join ";"
        $result.CMakeArgs.Add("-DCMAKE_PREFIX_PATH=$joined")
    }

    return [pscustomobject]$result
}
