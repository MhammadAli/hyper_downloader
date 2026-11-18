[CmdletBinding()]
param(
    [switch]$ForceRedownload
)

$ErrorActionPreference = "Stop"

$protoRoot = Split-Path -Parent $PSScriptRoot
$binDir = Join-Path $protoRoot "bin"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null

$ytDlpPath = Join-Path $binDir "yt-dlp.exe"
$ffmpegPath = Join-Path $binDir "ffmpeg.exe"
$ffprobePath = Join-Path $binDir "ffprobe.exe"
$nodePath = "C:\Program Files\nodejs\node.exe"

if (-not (Test-Path $nodePath)) {
    throw "Expected Node.js executable at $nodePath, but it was not found."
}

$nodeVersionRaw = (& $nodePath --version).Trim()
Write-Host "Node.js verified: $nodePath ($nodeVersionRaw)"

if ($ForceRedownload -or -not (Test-Path $ytDlpPath)) {
    Write-Host "Downloading official standalone yt-dlp.exe..."
    & curl.exe -fSL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" -o $ytDlpPath
    if ($LASTEXITCODE -ne 0) {
        throw "curl.exe failed to download yt-dlp.exe (exit code $LASTEXITCODE)."
    }

    $sumsFile = Join-Path $env:TEMP "yt-dlp-SHA2-256SUMS"
    & curl.exe -fSL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS" -o $sumsFile
    if ($LASTEXITCODE -ne 0) {
        throw "curl.exe failed to download SHA2-256SUMS (exit code $LASTEXITCODE)."
    }

    $expectedLine = Get-Content $sumsFile | Where-Object { $_ -match "\syt-dlp\.exe$" } | Select-Object -First 1
    if (-not $expectedLine) {
        throw "Could not find yt-dlp.exe entry in SHA2-256SUMS."
    }
    $expectedHash = ($expectedLine -split "\s+")[0].ToUpperInvariant()
    $actualHash = (Get-FileHash -Path $ytDlpPath -Algorithm SHA256).Hash.ToUpperInvariant()
    Remove-Item $sumsFile -ErrorAction SilentlyContinue

    if ($actualHash -ne $expectedHash) {
        Remove-Item $ytDlpPath -ErrorAction SilentlyContinue
        throw "SHA-256 mismatch for yt-dlp.exe! Expected: $expectedHash, Actual: $actualHash"
    }
    Write-Host "Verified yt-dlp.exe SHA-256: $actualHash"
} else {
    Write-Host "yt-dlp.exe already present at $ytDlpPath"
}

if ($ForceRedownload -or -not (Test-Path $ffmpegPath) -or -not (Test-Path $ffprobePath)) {
    $ffmpegUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n9.0-latest-win64-lgpl-shared-9.0.zip"
    $zipPath = Join-Path $env:TEMP "ffmpeg-win64-lgpl.zip"
    $extractDir = Join-Path $env:TEMP "ffmpeg-win64-extract"

    Write-Host "Downloading LGPL FFmpeg build: $ffmpegUrl"
    & curl.exe -fSL $ffmpegUrl -o $zipPath
    if ($LASTEXITCODE -ne 0) {
        throw "curl.exe failed to download FFmpeg archive (exit code $LASTEXITCODE)."
    }

    if (Test-Path $extractDir) {
        Remove-Item -Recurse -Force $extractDir
    }
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    $extractedBin = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
    $binSource = Join-Path $extractedBin.FullName "bin"
    if (-not (Test-Path $binSource)) {
        throw "Expected bin/ folder inside extracted FFmpeg archive at $binSource."
    }

    Copy-Item -Path (Join-Path $binSource "*") -Destination $binDir -Force
    Remove-Item -Force $zipPath -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
    Write-Host "Extracted FFmpeg LGPL shared binaries to $binDir"
} else {
    Write-Host "FFmpeg and FFprobe already present in $binDir"
}

# Verify yt-dlp.exe works with Python removed from PATH (no global Python dependency)
$originalPath = $env:Path
try {
    $filteredPathParts = ($env:Path -split ";") | Where-Object { $_ -and ($_ -notmatch "Python") }
    $env:Path = ($filteredPathParts -join ";")

    Write-Host "`n--- Verification (Python stripped from PATH) ---"
    $ytVersion = (& $ytDlpPath --version).Trim()
    $ffVersionLine = (& $ffmpegPath -version | Select-Object -First 1).Trim()
    $fpVersionLine = (& $ffprobePath -version | Select-Object -First 1).Trim()
    Write-Host "yt-dlp.exe version : $ytVersion"
    Write-Host "ffmpeg.exe         : $ffVersionLine"
    Write-Host "ffprobe.exe        : $fpVersionLine"
    Write-Host "node.exe           : $nodeVersionRaw"
} finally {
    $env:Path = $originalPath
}
