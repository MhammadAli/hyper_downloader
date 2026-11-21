[CmdletBinding()]
param(
    [switch]$ForceRebuild,
    [string[]]$Abis = @("arm64-v8a", "x86_64"),
    [int]$ApiLevel = 26
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$buildCache = Join-Path $PSScriptRoot "build_cache"
$srcDir = Join-Path $buildCache "src"
$buildDir = Join-Path $buildCache "build"
$jniLibsRoot = Join-Path $repoRoot "apps\client\android\app\src\main\jniLibs"

New-Item -ItemType Directory -Force -Path $buildCache, $srcDir, $buildDir, $jniLibsRoot | Out-Null

$sdkDir = if ($env:ANDROID_HOME) {
    $env:ANDROID_HOME
} elseif ($env:ANDROID_SDK_ROOT) {
    $env:ANDROID_SDK_ROOT
} else {
    Join-Path $env:LOCALAPPDATA "Android\Sdk"
}

$ndkDir = Join-Path $sdkDir "ndk\28.2.13676358"
if (-not (Test-Path $ndkDir)) {
    throw "Required Android NDK 28.2.13676358 not found at $ndkDir"
}

$toolchainBin = Join-Path $ndkDir "toolchains\llvm\prebuilt\windows-x86_64\bin"
$llvmStrip = Join-Path $toolchainBin "llvm-strip.exe"
$llvmObjdump = Join-Path $toolchainBin "llvm-objdump.exe"
$ndkToolchainCmake = Join-Path $ndkDir "build\cmake\android.toolchain.cmake"

$cmakeRoot = Join-Path $sdkDir "cmake"
$cmakeVerDir = Get-ChildItem -Path $cmakeRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $cmakeVerDir) {
    throw "Android SDK CMake not found under $cmakeRoot"
}
$cmakeExe = Join-Path $cmakeVerDir.FullName "bin\cmake.exe"
$ninjaExe = Join-Path $cmakeVerDir.FullName "bin\ninja.exe"
if (-not (Test-Path $cmakeExe) -or -not (Test-Path $ninjaExe)) {
    throw "Expected cmake.exe and ninja.exe under $($cmakeVerDir.FullName)\bin"
}

$gitBashExe = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path $gitBashExe)) {
    throw "Git Bash not found at $gitBashExe"
}

foreach ($abi in $Abis) {
    if ($abi -notin @("arm64-v8a", "x86_64")) {
        throw "Unsupported ABI '$abi'. Only arm64-v8a and x86_64 are targeted."
    }
}

function Convert-ToMsysPath([string]$winPath) {
    $normalized = $winPath -replace '\\', '/'
    if ($normalized -match '^([A-Za-z]):/(.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        return "/$drive/$($Matches[2])"
    }
    return $normalized
}

function Assert-16KbAligned([string]$soPath) {
    if (-not (Test-Path $soPath)) {
        throw "Expected native binary missing: $soPath"
    }
    $lines = & $llvmObjdump -p $soPath | ForEach-Object { $_.ToString() }
    $loadLines = $lines | Where-Object { $_ -cmatch "^\s*LOAD\b" }
    if (-not $loadLines) {
        throw "Could not read ELF LOAD segments from $soPath"
    }
    foreach ($line in $loadLines) {
        if ($line -notmatch "align 2\*\*(14|15|16|17|18)") {
            throw "16 KB ELF alignment check FAILED for $soPath`n$line"
        }
    }
    Write-Host "  [16KB OK] $soPath ($([math]::Round((Get-Item $soPath).Length / 1MB, 2)) MB)"
}

# 1. Fetch QuickJS-NG v0.18.0
$qjsVersion = "v0.18.0"
$qjsArchive = Join-Path $buildCache "quickjs-$qjsVersion.tar.gz"
$qjsSrc = Join-Path $srcDir "quickjs-0.18.0"

if ($ForceRebuild -or -not (Test-Path $qjsArchive)) {
    Write-Host "Downloading QuickJS-NG $qjsVersion source..."
    & curl.exe -fSL "https://github.com/quickjs-ng/quickjs/archive/refs/tags/$qjsVersion.tar.gz" -o $qjsArchive
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to download QuickJS-NG $qjsVersion (exit $LASTEXITCODE)"
    }
}
if ($ForceRebuild -or -not (Test-Path $qjsSrc)) {
    if (Test-Path $qjsSrc) { Remove-Item -Recurse -Force $qjsSrc }
    & tar.exe -xzf $qjsArchive -C $srcDir
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract QuickJS-NG archive"
    }
}

# 2. Fetch FFmpeg 7.1.1
$ffmpegVersion = "7.1.1"
$ffmpegArchive = Join-Path $buildCache "ffmpeg-$ffmpegVersion.tar.gz"
$ffmpegSrc = Join-Path $srcDir "FFmpeg-n$ffmpegVersion"

if ($ForceRebuild -or -not (Test-Path $ffmpegArchive)) {
    Write-Host "Downloading FFmpeg n$ffmpegVersion source..."
    & curl.exe -fSL "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n$ffmpegVersion.tar.gz" -o $ffmpegArchive
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to download FFmpeg n$ffmpegVersion (exit $LASTEXITCODE)"
    }
}
if ($ForceRebuild -or -not (Test-Path $ffmpegSrc)) {
    if (Test-Path $ffmpegSrc) { Remove-Item -Recurse -Force $ffmpegSrc }
    & tar.exe -xzf $ffmpegArchive -C $srcDir
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract FFmpeg archive"
    }
}

$bashBuildScript = Convert-ToMsysPath (Join-Path $PSScriptRoot "build_ffmpeg_android.sh")
$ffmpegSrcMsys = Convert-ToMsysPath $ffmpegSrc
$buildDirMsys = Convert-ToMsysPath $buildDir
$ndkDirMsys = Convert-ToMsysPath $ndkDir

foreach ($abi in $Abis) {
    $abiJniDir = Join-Path $jniLibsRoot $abi
    New-Item -ItemType Directory -Force -Path $abiJniDir | Out-Null

    $outQjs = Join-Path $abiJniDir "libqjs.so"
    if ($ForceRebuild -or -not (Test-Path $outQjs)) {
        Write-Host "`nBuilding QuickJS-NG ($qjsVersion) for $abi..."
        $qjsBuild = Join-Path $buildDir "qjs-$abi"
        if (Test-Path $qjsBuild) { Remove-Item -Recurse -Force $qjsBuild }

        & $cmakeExe -S $qjsSrc -B $qjsBuild -G Ninja `
            "-DCMAKE_MAKE_PROGRAM=$ninjaExe" `
            "-DCMAKE_TOOLCHAIN_FILE=$ndkToolchainCmake" `
            "-DANDROID_ABI=$abi" `
            "-DANDROID_PLATFORM=android-$ApiLevel" `
            "-DCMAKE_BUILD_TYPE=Release" `
            "-DBUILD_SHARED_LIBS=OFF" `
            "-DQJS_BUILD_EXAMPLES=OFF" `
            "-DQJS_ENABLE_INSTALL=OFF" `
            "-DCMAKE_C_FLAGS=-fPIE -O2" `
            "-DCMAKE_EXE_LINKER_FLAGS=-pie -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
        if ($LASTEXITCODE -ne 0) {
            throw "CMake configure failed for QuickJS-NG ($abi)"
        }

        & $cmakeExe --build $qjsBuild --target qjs_exe -j 8
        if ($LASTEXITCODE -ne 0) {
            throw "CMake build failed for QuickJS-NG ($abi)"
        }

        $builtQjs = Join-Path $qjsBuild "qjs"
        if (-not (Test-Path $builtQjs)) {
            throw "Expected built binary at $builtQjs"
        }
        Copy-Item -Force $builtQjs $outQjs
        & $llvmStrip --strip-unneeded $outQjs
        if ($LASTEXITCODE -ne 0) {
            throw "llvm-strip failed for $outQjs"
        }
    } else {
        Write-Host "libqjs.so already exists for $abi at $outQjs"
    }

    $outFfmpeg = Join-Path $abiJniDir "libffmpeg.so"
    $outFfprobe = Join-Path $abiJniDir "libffprobe.so"
    if ($ForceRebuild -or -not (Test-Path $outFfmpeg) -or -not (Test-Path $outFfprobe)) {
        Write-Host "`nBuilding FFmpeg ($ffmpegVersion, LGPL-2.1) for $abi..."
        $ffmpegOutWin = Join-Path $buildDir "ffmpeg-out-$abi"
        $ffmpegOutMsys = Convert-ToMsysPath $ffmpegOutWin

        & $gitBashExe -lc "bash '$bashBuildScript' '$abi' '$ffmpegSrcMsys' '$buildDirMsys' '$ffmpegOutMsys' '$ndkDirMsys' '$ApiLevel'"
        if ($LASTEXITCODE -ne 0) {
            throw "FFmpeg build failed for $abi (exit $LASTEXITCODE)"
        }

        Copy-Item -Force (Join-Path $ffmpegOutWin "bin\ffmpeg") $outFfmpeg
        Copy-Item -Force (Join-Path $ffmpegOutWin "bin\ffprobe") $outFfprobe
    } else {
        Write-Host "libffmpeg.so and libffprobe.so already exist for $abi"
    }

    Write-Host "`nVerifying 16 KB ELF alignment for ${abi}:"
    Assert-16KbAligned $outQjs
    Assert-16KbAligned $outFfmpeg
    Assert-16KbAligned $outFfprobe
}

Write-Host "`nAll Android native binaries provisioned and verified successfully."
