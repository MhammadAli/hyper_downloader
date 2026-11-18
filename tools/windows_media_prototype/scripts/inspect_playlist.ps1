[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlaylistUrl,
    [int]$MaxPlaylistEntries = 10,
    [int]$MaxItemsToInspectFormats = 2,
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
    $OutputFixturePath = Join-Path $protoRoot "fixtures\playlist_inspection_sample.json"
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputFixturePath) | Out-Null

$originalPath = $env:Path
try {
    $env:Path = (($env:Path -split ";") | Where-Object { $_ -and ($_ -notmatch "Python") }) -join ";"

    Write-Host "Enumerating playlist (flat): $PlaylistUrl"
    $flatArgs = @(
        "--dump-single-json",
        "--flat-playlist",
        "--no-warnings",
        "--ignore-config",
        "--playlist-end", "$MaxPlaylistEntries",
        "--js-runtimes", "node:$nodePath",
        $PlaylistUrl
    )

    $rawPlaylistJson = & $ytDlpPath @flatArgs
    if ($LASTEXITCODE -ne 0) {
        throw "yt-dlp playlist enumeration failed with exit code $LASTEXITCODE."
    }

    $playlistMeta = $rawPlaylistJson | ConvertFrom-Json
    $entriesOut = @()
    $index = 0

    foreach ($entry in $playlistMeta.entries) {
        $itemUrl = if ($entry.url) { [string]$entry.url } elseif ($entry.webpage_url) { [string]$entry.webpage_url } else { "https://www.youtube.com/watch?v=$($entry.id)" }
        $thumb = if ($entry.thumbnails -and $entry.thumbnails.Count -gt 0) { [string]$entry.thumbnails[-1].url } else { $null }

        $itemRecord = [ordered]@{
            order_index       = $index
            item_id           = [string]$entry.id
            title             = [string]$entry.title
            url               = $itemUrl
            duration_seconds  = if ($null -ne $entry.duration) { [double]$entry.duration } else { $null }
            thumbnail         = $thumb
            format_inspection = $null
        }

        if ($index -lt $MaxItemsToInspectFormats) {
            Write-Host "  Inspecting item #$index independently: $($entry.title) ($itemUrl)"
            $itemArgs = @(
                "--dump-single-json",
                "--no-playlist",
                "--no-warnings",
                "--ignore-config",
                "--js-runtimes", "node:$nodePath",
                $itemUrl
            )
            $itemRaw = & $ytDlpPath @itemArgs
            if ($LASTEXITCODE -eq 0 -and $itemRaw) {
                $itemMeta = $itemRaw | ConvertFrom-Json
                $validFmts = @($itemMeta.formats | Where-Object {
                    ($_.vcodec -ne "none" -or $_.acodec -ne "none") -and ($_.has_drm -ne $true)
                })
                $resolutions = @($validFmts | Where-Object { $_.width -and $_.height } | ForEach-Object { "$($_.width)x$($_.height)" } | Select-Object -Unique)
                $vcodecs = @($validFmts | Where-Object { $_.vcodec -and $_.vcodec -ne "none" } | ForEach-Object { [string]$_.vcodec } | Select-Object -Unique)
                $acodecs = @($validFmts | Where-Object { $_.acodec -and $_.acodec -ne "none" } | ForEach-Object { [string]$_.acodec } | Select-Object -Unique)
                $exactCount = @($validFmts | Where-Object { $null -ne $_.filesize }).Count
                $estCount = @($validFmts | Where-Object { $null -eq $_.filesize -and $null -ne $_.filesize_approx }).Count

                $itemRecord.format_inspection = [ordered]@{
                    status               = "inspected"
                    title                = [string]$itemMeta.title
                    duration_seconds     = if ($null -ne $itemMeta.duration) { [double]$itemMeta.duration } else { $null }
                    thumbnail            = [string]$itemMeta.thumbnail
                    discovered_formats   = $validFmts.Count
                    exact_size_formats   = $exactCount
                    approx_size_formats  = $estCount
                    available_resolutions = $resolutions
                    video_codecs         = $vcodecs
                    audio_codecs         = $acodecs
                    sample_format_ids    = @($validFmts | Select-Object -First 8 | ForEach-Object { [string]$_.format_id })
                }
            } else {
                $itemRecord.format_inspection = [ordered]@{
                    status = "failed"
                    error  = "Exit code $LASTEXITCODE"
                }
            }
        } else {
            $itemRecord.format_inspection = [ordered]@{
                status = "pending_inspection"
            }
        }

        $entriesOut += [PSCustomObject]$itemRecord
        $index++
    }

    $result = [PSCustomObject]@{
        inspected_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        playlist_id      = [string]$playlistMeta.id
        title            = [string]$playlistMeta.title
        uploader         = [string]$playlistMeta.uploader
        playlist_count   = if ($null -ne $playlistMeta.playlist_count) { [int]$playlistMeta.playlist_count } else { $entriesOut.Count }
        enumerated_count = $entriesOut.Count
        entries          = $entriesOut
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputFixturePath -Encoding UTF8

    Write-Host "`n=== Playlist Inspection Summary ==="
    Write-Host "Playlist Title : $($result.title)"
    Write-Host "Playlist ID    : $($result.playlist_id)"
    Write-Host "Enumerated     : $($result.enumerated_count) (Total reported: $($result.playlist_count))"
    Write-Host "Fixture        : $OutputFixturePath`n"

    $entriesOut | Select-Object order_index, item_id, title, duration_seconds, @{
        Name = "inspection_status"; Expression = { $_.format_inspection.status }
    }, @{
        Name = "format_count"; Expression = { $_.format_inspection.discovered_formats }
    } | Format-Table -AutoSize
} finally {
    $env:Path = $originalPath
}
