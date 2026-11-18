[CmdletBinding()]
param(
    [string]$Url = "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
    [string]$OutputReportPath = ""
)

$ErrorActionPreference = "Stop"

$protoRoot = Split-Path -Parent $PSScriptRoot
$binDir = Join-Path $protoRoot "bin"
$ytDlpPath = Join-Path $binDir "yt-dlp.exe"
$ffprobePath = Join-Path $binDir "ffprobe.exe"
$nodePath = "C:\Program Files\nodejs\node.exe"
$outputRoot = Join-Path $protoRoot "output"

if (-not (Test-Path $ytDlpPath)) { throw "yt-dlp.exe missing at $ytDlpPath" }
if (-not (Test-Path $ffprobePath)) { throw "ffprobe.exe missing at $ffprobePath" }
if (-not (Test-Path $nodePath)) { throw "Node.js missing at $nodePath" }
if (-not $OutputReportPath) {
    $OutputReportPath = Join-Path $protoRoot "fixtures\download_test_report.json"
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputReportPath) | Out-Null

$singleDir = Join-Path $outputRoot "single_stream"
$mergedDir = Join-Path $outputRoot "merged_stream"
$resumeDir = Join-Path $outputRoot "resume_test"

foreach ($d in @($singleDir, $mergedDir, $resumeDir)) {
    if (Test-Path $d) { Remove-Item -Recurse -Force $d }
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

function Parse-ProgressLine {
    param([string]$Line)
    if ($Line.StartsWith("HYPERDL|")) {
        $parts = $Line.Split("|")
        return [PSCustomObject]@{
            kind            = "download"
            status          = $parts[1]
            downloaded      = if ($parts[2] -match "^\d+$") { [int64]$parts[2] } else { $null }
            total           = if ($parts[3] -match "^\d+$") { [int64]$parts[3] } else { $null }
            total_estimate  = if ($parts[4] -match "^\d+$") { [int64]$parts[4] } else { $null }
            speed_bps       = if ($parts[5] -match "^\d+(\.\d+)?$") { [double]$parts[5] } else { $null }
            eta_seconds     = if ($parts[6] -match "^\d+(\.\d+)?$") { [double]$parts[6] } else { $null }
        }
    } elseif ($Line.StartsWith("HYPERDL_PP|")) {
        $parts = $Line.Split("|")
        return [PSCustomObject]@{
            kind          = "postprocess"
            status        = $parts[1]
            postprocessor = $parts[2]
        }
    }
    return $null
}

function Invoke-YtDlp {
    param([string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = & $ytDlpPath @Arguments 2>&1 | ForEach-Object { [string]$_ }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [PSCustomObject]@{
        ExitCode = $exitCode
        Lines    = @($lines)
    }
}

$originalPath = $env:Path
try {
    $env:Path = (($env:Path -split ";") | Where-Object { $_ -and ($_ -notmatch "Python") }) -join ";"

    Write-Host "Inspecting authorized test video for dynamic format selection: $Url"
    $rawJson = & $ytDlpPath --dump-single-json --no-playlist --no-warnings --ignore-config --js-runtimes "node:$nodePath" $Url
    if ($LASTEXITCODE -ne 0) {
        throw "Inspection failed with exit code $LASTEXITCODE."
    }
    $meta = $rawJson | ConvertFrom-Json

    # Pick genuine formats dynamically (never hardcoded format IDs)
    $validFormats = @($meta.formats | Where-Object {
        ($_.vcodec -ne "none" -or $_.acodec -ne "none") -and ($_.has_drm -ne $true)
    })

    $httpAudioFormats = @($validFormats | Where-Object {
        $_.vcodec -eq "none" -and $_.acodec -ne "none" -and $_.protocol -eq "https" -and ($_.filesize -or $_.filesize_approx)
    } | Sort-Object { if ($_.filesize) { [int64]$_.filesize } else { [int64]$_.filesize_approx } })

    $httpVideoOnlyFormats = @($validFormats | Where-Object {
        $_.vcodec -ne "none" -and $_.acodec -eq "none" -and $_.protocol -eq "https" -and $_.height -ge 360 -and $_.height -le 720 -and ($_.filesize -or $_.filesize_approx)
    } | Sort-Object { if ($_.filesize) { [int64]$_.filesize } else { [int64]$_.filesize_approx } })

    $singleFormat = if ($httpAudioFormats.Count -gt 0) {
        $httpAudioFormats[0]
    } else {
        @($validFormats | Where-Object { $_.vcodec -ne "none" -and $_.acodec -ne "none" } | Select-Object -First 1)[0]
    }

    if (-not $singleFormat) { throw "No suitable single format discovered." }
    if ($httpVideoOnlyFormats.Count -eq 0 -or $httpAudioFormats.Count -eq 0) {
        throw "Could not find separate video-only and audio-only HTTPS streams for merge test."
    }

    $mergeVideoFmt = $httpVideoOnlyFormats[0]
    $mergeAudioFmt = $httpAudioFormats[0]

    # Pick a format >= 2 MB for cancel/resume test
    $resumeFmt = @($validFormats | Where-Object {
        $_.protocol -eq "https" -and (
            ($_.filesize -and [int64]$_.filesize -ge 2097152) -or
            ($_.filesize_approx -and [int64]$_.filesize_approx -ge 2097152)
        )
    } | Sort-Object { if ($_.filesize) { [int64]$_.filesize } else { [int64]$_.filesize_approx } } | Select-Object -First 1)[0]
    if (-not $resumeFmt) { $resumeFmt = $singleFormat }

    # ------------------------------------------------------------
    # Sub-test 4.1: Single Format Download + Progress/Speed/ETA
    # ------------------------------------------------------------
    Write-Host "`n=== Sub-test 4.1: Single Format Download (format_id=$($singleFormat.format_id)) ==="
    $singleOutTpl = Join-Path $singleDir "%(id)s_%(format_id)s.%(ext)s"
    $singleArgs = @(
        "--newline",
        "--no-playlist",
        "--no-mtime",
        "--ignore-config",
        "--ffmpeg-location", $binDir,
        "--js-runtimes", "node:$nodePath",
        "--progress-template", "download:HYPERDL|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
        "-f", [string]$singleFormat.format_id,
        "-o", $singleOutTpl,
        $Url
    )
    $singleRes = Invoke-YtDlp $singleArgs
    $singleLines = $singleRes.Lines
    if ($singleRes.ExitCode -ne 0) { throw "Single download failed (exit $($singleRes.ExitCode)):`n$($singleLines -join "`n")" }

    $singleProgress = @($singleLines | ForEach-Object { Parse-ProgressLine ([string]$_) } | Where-Object { $_ -ne $null })
    $singleFile = Get-ChildItem -Path $singleDir -File | Select-Object -First 1
    $singleProbeJson = (& $ffprobePath -v error -show_entries format=format_name,duration,size -show_entries stream=index,codec_type,codec_name -of json $singleFile.FullName) | ConvertFrom-Json

    Write-Host "Downloaded file: $($singleFile.FullName) ($($singleFile.Length) bytes)"
    Write-Host "Sample progress events: $($singleProgress.Count) captured"
    $singleProgress | Where-Object { $_.status -eq "downloading" } | Select-Object -First 3 | Format-Table -AutoSize

    # ------------------------------------------------------------
    # Sub-test 4.2: Separate Video + Audio Stream Merging (FFmpeg)
    # ------------------------------------------------------------
    $mergeSelector = "$($mergeVideoFmt.format_id)+$($mergeAudioFmt.format_id)"
    Write-Host "`n=== Sub-test 4.2: FFmpeg Merge Download ($mergeSelector) ==="
    $mergeOutTpl = Join-Path $mergedDir "%(id)s_merged.%(ext)s"
    $mergeArgs = @(
        "--newline",
        "--no-playlist",
        "--no-mtime",
        "--ignore-config",
        "--js-runtimes", "node:$nodePath",
        "--ffmpeg-location", $binDir,
        "--merge-output-format", "mp4",
        "--progress-template", "download:HYPERDL|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
        "--progress-template", "postprocess:HYPERDL_PP|%(progress.status)s|%(progress.postprocessor)s",
        "-f", $mergeSelector,
        "-o", $mergeOutTpl,
        $Url
    )
    $mergeRes = Invoke-YtDlp $mergeArgs
    $mergeLines = $mergeRes.Lines
    if ($mergeRes.ExitCode -ne 0) { throw "Merge download failed (exit $($mergeRes.ExitCode)):`n$($mergeLines -join "`n")" }

    $mergeEvents = @($mergeLines | ForEach-Object { Parse-ProgressLine ([string]$_) } | Where-Object { $_ -ne $null })
    $ppEvents = @($mergeEvents | Where-Object { $_.kind -eq "postprocess" })
    $mergedFile = Get-ChildItem -Path $mergedDir -File -Filter "*.mp4" | Select-Object -First 1
    if (-not $mergedFile) { throw "Merged MP4 file not found in $mergedDir" }
    $mergedProbeJson = (& $ffprobePath -v error -show_entries format=format_name,duration,size -show_entries stream=index,codec_type,codec_name,width,height -of json $mergedFile.FullName) | ConvertFrom-Json

    Write-Host "Merged MP4: $($mergedFile.FullName) ($($mergedFile.Length) bytes)"
    Write-Host "Postprocessor events:"
    $ppEvents | Format-Table -AutoSize
    Write-Host "FFprobe streams in merged MP4:"
    $mergedProbeJson.streams | Format-Table -AutoSize

    # ------------------------------------------------------------
    # Sub-test 4.3: Cancellation + .part Persistence + --continue Resume
    # ------------------------------------------------------------
    Write-Host "`n=== Sub-test 4.3: Cancel & --continue Resume (format_id=$($resumeFmt.format_id)) ==="
    $resumeOutTpl = Join-Path $resumeDir "%(id)s_resume.%(ext)s"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ytDlpPath
    $psi.Arguments = "--newline --continue --no-playlist --no-mtime --ignore-config --ffmpeg-location `"$binDir`" --limit-rate 250K --js-runtimes `"node:$nodePath`" --progress-template `"download:HYPERDL|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s`" -f $($resumeFmt.format_id) -o `"$resumeOutTpl`" `"$Url`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    $killedAtBytes = 0
    $firstRunLog = @()
    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        $firstRunLog += $line
        $ev = Parse-ProgressLine $line
        if ($ev -and $ev.kind -eq "download" -and $ev.downloaded -ge 300000) {
            $killedAtBytes = $ev.downloaded
            Write-Host "Simulating cancellation after $killedAtBytes bytes (killing entire PyInstaller process tree PID $($proc.Id))..."
            # Must kill process tree (/T) because yt-dlp.exe is a PyInstaller onefile bootloader spawning a child yt-dlp.exe worker
            & taskkill.exe /F /T /PID $proc.Id | Out-Null
            break
        }
    }
    $proc.WaitForExit(5000) | Out-Null
    Start-Sleep -Milliseconds 300

    $partFile = Get-ChildItem -Path $resumeDir -File -Filter "*.part" | Select-Object -First 1
    if (-not $partFile) {
        throw "Expected .part file in $resumeDir after cancellation, none found. Log:`n$($firstRunLog -join "`n")"
    }
    $partBytesAfterCancel = $partFile.Length
    Write-Host "Canceled! Retained .part file: $($partFile.Name) ($partBytesAfterCancel bytes)"

    # Resume with --continue
    $resumeArgs = @(
        "--newline",
        "--continue",
        "--no-playlist",
        "--no-mtime",
        "--ignore-config",
        "--ffmpeg-location", $binDir,
        "--js-runtimes", "node:$nodePath",
        "--progress-template", "download:HYPERDL|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
        "-f", [string]$resumeFmt.format_id,
        "-o", $resumeOutTpl,
        $Url
    )
    $resumeRes = Invoke-YtDlp $resumeArgs
    $resumeLines = $resumeRes.Lines
    if ($resumeRes.ExitCode -ne 0) { throw "Resume download failed (exit $($resumeRes.ExitCode)):`n$($resumeLines -join "`n")" }

    $resumeMsg = ($resumeLines | Where-Object { $_ -match "Resuming download at byte" } | Select-Object -First 1)
    $resumeProgress = @($resumeLines | ForEach-Object { Parse-ProgressLine ([string]$_) } | Where-Object { $_ -ne $null -and $_.status -eq "downloading" })
    $firstResumedBytes = if ($resumeProgress.Count -gt 0) { $resumeProgress[0].downloaded } else { $null }
    $finalResumedFile = Get-ChildItem -Path $resumeDir -File | Where-Object { $_.Extension -ne ".part" -and $_.Extension -ne ".ytdl" } | Select-Object -First 1
    $resumedProbe = (& $ffprobePath -v error -show_entries format=format_name,duration,size -show_entries stream=index,codec_type,codec_name -of json $finalResumedFile.FullName) | ConvertFrom-Json

    Write-Host "Resume line : $resumeMsg"
    Write-Host "First progress byte after resume: $firstResumedBytes (part on disk was $partBytesAfterCancel)"
    Write-Host "Completed resumed file: $($finalResumedFile.Name) ($($finalResumedFile.Length) bytes)"

    $report = [PSCustomObject]@{
        tested_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        test_url      = $Url
        single_stream_test = [PSCustomObject]@{
            format_id               = [string]$singleFormat.format_id
            output_file_name        = $singleFile.Name
            output_bytes            = $singleFile.Length
            progress_events_count   = $singleProgress.Count
            sample_progress_events  = @($singleProgress | Where-Object { $_.status -eq "downloading" } | Select-Object -First 3)
            ffprobe_streams         = $singleProbeJson.streams
        }
        ffmpeg_merge_test = [PSCustomObject]@{
            video_format_id         = [string]$mergeVideoFmt.format_id
            audio_format_id         = [string]$mergeAudioFmt.format_id
            format_selector         = $mergeSelector
            output_file_name        = $mergedFile.Name
            output_bytes            = $mergedFile.Length
            postprocessor_events    = $ppEvents
            ffprobe_streams         = $mergedProbeJson.streams
        }
        cancel_resume_test = [PSCustomObject]@{
            format_id               = [string]$resumeFmt.format_id
            canceled_at_stream_bytes = $killedAtBytes
            part_file_name          = $partFile.Name
            part_bytes_on_disk      = $partBytesAfterCancel
            resume_log_line         = [string]$resumeMsg
            first_resumed_bytes     = $firstResumedBytes
            final_file_name         = $finalResumedFile.Name
            final_bytes             = $finalResumedFile.Length
            ffprobe_streams         = $resumedProbe.streams
        }
    }

    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputReportPath -Encoding UTF8
    Write-Host "`nSaved download test report to $OutputReportPath"
} finally {
    $env:Path = $originalPath
}
