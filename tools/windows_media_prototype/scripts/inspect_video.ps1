[CmdletBinding()]
param(
    [string]$Url = "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
    [string]$OutputFixturePath = ""
)

$ErrorActionPreference = "Stop"

$protoRoot = Split-Path -Parent $PSScriptRoot
$ytDlpPath = Join-Path $protoRoot "bin\yt-dlp.exe"
$nodePath = "C:\Program Files\nodejs\node.exe"

if (-not (Test-Path $ytDlpPath)) {
    throw "yt-dlp.exe not found at $ytDlpPath. Run provision_tools.ps1 first."
}
if (-not (Test-Path $nodePath)) {
    throw "Node.js not found at $nodePath."
}
if (-not $OutputFixturePath) {
    $OutputFixturePath = Join-Path $protoRoot "fixtures\video_inspection_sample.json"
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputFixturePath) | Out-Null

$originalPath = $env:Path
try {
    # Ensure no reliance on global Python
    $env:Path = (($env:Path -split ";") | Where-Object { $_ -and ($_ -notmatch "Python") }) -join ";"

    $argsList = @(
        "--dump-single-json",
        "--no-playlist",
        "--no-warnings",
        "--ignore-config",
        "--js-runtimes", "node:$nodePath",
        $Url
    )

    Write-Host "Inspecting video: $Url"
    $rawJson = & $ytDlpPath @argsList
    if ($LASTEXITCODE -ne 0) {
        throw "yt-dlp inspection failed with exit code $LASTEXITCODE."
    }

    $meta = $rawJson | ConvertFrom-Json

    $discoveredFormats = @()
    $excludedStoryboards = 0
    $excludedDrm = 0

    foreach ($fmt in $meta.formats) {
        $vcodec = if ($fmt.vcodec) { [string]$fmt.vcodec } else { "none" }
        $acodec = if ($fmt.acodec) { [string]$fmt.acodec } else { "none" }
        $hasVideo = ($vcodec -ne "none")
        $hasAudio = ($acodec -ne "none")

        if (-not $hasVideo -and -not $hasAudio) {
            $excludedStoryboards++
            continue
        }
        if ($fmt.has_drm -eq $true) {
            $excludedDrm++
            continue
        }

        $streamKind = if ($hasVideo -and $hasAudio) {
            "muxed_av"
        } elseif ($hasVideo) {
            "video_only"
        } else {
            "audio_only"
        }

        $exactSize = $fmt.filesize
        $approxSize = $fmt.filesize_approx
        $resolvedSize = $null
        $sizeAccuracy = "unknown"

        if ($null -ne $exactSize) {
            $resolvedSize = [int64]$exactSize
            $sizeAccuracy = "exact"
        } elseif ($null -ne $approxSize) {
            $resolvedSize = [int64]$approxSize
            $sizeAccuracy = "estimated"
        }

        $resolution = if ($hasVideo -and $fmt.width -and $fmt.height) {
            "$($fmt.width)x$($fmt.height)"
        } elseif (-not $hasVideo) {
            "audio only"
        } else {
            "unknown"
        }

        $discoveredFormats += [PSCustomObject]@{
            format_id       = [string]$fmt.format_id
            container       = [string]$fmt.ext
            stream_kind     = $streamKind
            resolution      = $resolution
            width           = if ($fmt.width) { [int]$fmt.width } else { $null }
            height          = if ($fmt.height) { [int]$fmt.height } else { $null }
            fps             = if ($fmt.fps) { [double]$fmt.fps } else { $null }
            vcodec          = if ($hasVideo) { $vcodec } else { $null }
            acodec          = if ($hasAudio) { $acodec } else { $null }
            tbr_kbps        = if ($fmt.tbr) { [math]::Round([double]$fmt.tbr, 2) } else { $null }
            file_size_bytes = $resolvedSize
            size_accuracy   = $sizeAccuracy
            protocol        = [string]$fmt.protocol
            format_note     = if ($fmt.format_note) { [string]$fmt.format_note } else { $null }
        }
    }

    $result = [PSCustomObject]@{
        inspected_at_utc     = (Get-Date).ToUniversalTime().ToString("o")
        yt_dlp_version       = (& $ytDlpPath --version).Trim()
        node_version         = (& $nodePath --version).Trim()
        id                   = [string]$meta.id
        title                = [string]$meta.title
        uploader             = [string]$meta.uploader
        channel_id           = [string]$meta.channel_id
        duration_seconds     = if ($null -ne $meta.duration) { [double]$meta.duration } else { $null }
        thumbnail            = [string]$meta.thumbnail
        webpage_url          = [string]$meta.webpage_url
        license              = if ($meta.license) { [string]$meta.license } else { $null }
        discovered_count     = $discoveredFormats.Count
        excluded_storyboards = $excludedStoryboards
        excluded_drm         = $excludedDrm
        formats              = $discoveredFormats
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputFixturePath -Encoding UTF8

    Write-Host "`n=== Video Inspection Summary ==="
    Write-Host "Title    : $($result.title)"
    Write-Host "Uploader : $($result.uploader)"
    Write-Host "Duration : $($result.duration_seconds) s"
    Write-Host "Thumb    : $($result.thumbnail)"
    Write-Host "Formats  : $($result.discovered_count) genuine (excluded $excludedStoryboards storyboards, $excludedDrm DRM)"
    Write-Host "Fixture  : $OutputFixturePath`n"

    $discoveredFormats | Select-Object `
        format_id, container, stream_kind, resolution, fps, vcodec, acodec, tbr_kbps, file_size_bytes, size_accuracy |
        Format-Table -AutoSize
} finally {
    $env:Path = $originalPath
}
