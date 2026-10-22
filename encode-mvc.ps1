<#
.SYNOPSIS
  Encode a 3D video (SBS/TAB) to Blu-ray 3D (H.264 MVC) using x264-mvc, ffmpeg and tsMuxeR.

.DESCRIPTION
  The 3D layout is read from the input file name (same markers as NTM-3D/mpv-android):
    Half SBS: hsbs, half-sbs, half_sbs, sbs-half, sbs_half, half_2x1
    Half TAB: htab, half-tab, half_tab, tab-half, tab_half, half_1x2, half-ou, half_ou, half-overunder
    Full SBS: fsbs, full-sbs, full_sbs, sbs-full, sbs_full, 2x1, full_2x1
    Full TAB: ftab, full-tab, full_tab, tab-full, tab_full, 1x2, full_1x2, full-ou, full_ou, full-overunder
    Generic : 3d, sbs -> Half SBS;  tab, ou, overunder, over-under, over_under, topbottom, top-bottom, top_bottom, tb -> Half TAB
  Any aspect ratio is supported: each eye is scaled to fit the Blu-ray eye frame (1920x1080 or
  1280x720) with the correct display aspect ratio and padded with black bars.

.PARAMETER Format
  Override the file name detection: fsbs, hsbs, ftab, htab (also sbs, tb, htb, ftb, frames).
.PARAMETER Output
  iso (default, needs tsMuxeR) or mvc (raw Annex B MVC stream).
#>
param(
    [Parameter(Position = 0)]
    [string]$InputFile,

    [string]$Format = '',
    [ValidateSet('iso', 'mvc')][string]$Output = 'iso',
    [string]$OutDir = '',
    [ValidateSet(720, 1080)][int]$EyeHeight = 1080,
    [string]$Fps = 'auto',
    [double]$Crf = 18,
    [int]$MaxBitrate = 48000,
    [int]$BufSize = 24000,
    [int]$TargetBitrate = 0,
    [string]$Preset = 'slower',
    [string]$X264 = '',
    [string]$FfmpegDir = '',
    [string]$TsMuxer = '',
    [switch]$TwoPass,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'

if (-not $InputFile) {
    Write-Host 'Usage: .\encode-mvc.ps1 <input> [-Format fsbs|hsbs|ftab|htab] [-Output iso|mvc] [-OutDir dir]'
    Write-Host '                        [-EyeHeight 1080|720] [-Fps auto|24|24000/1001|...] [-Crf n] [-MaxBitrate kbps] [-BufSize kbit] [-TargetBitrate kbps] [-Preset name]'
    Write-Host '                        [-X264 path] [-FfmpegDir dir] [-TsMuxer path] [-TwoPass] [-KeepTemp]'
    Write-Host 'The 3D format is detected from the file name (e.g. movie.fsbs.mkv, movie_HTAB.mp4) unless -Format is given.'
    exit
}

if ($TwoPass -and $TargetBitrate -le 0) { throw '-TwoPass needs -TargetBitrate.' }

$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }

function Resolve-Format([string]$text) {
    $t = $text.ToLower()
    $has = { param($p) $t -match "(?<![a-z0-9])($p)(?![a-z0-9])" }
    if (& $has 'hsbs|half[-_]sbs|sbs[-_]half|half[-_]2x1') { return @{ Layout = 'sbs'; Full = $false } }
    if (& $has 'htab|half[-_]tab|tab[-_]half|half[-_]1x2|half[-_]ou|half[-_]overunder') { return @{ Layout = 'tb'; Full = $false } }
    if (& $has 'fsbs|full[-_]sbs|sbs[-_]full|full[-_]2x1|2x1') { return @{ Layout = 'sbs'; Full = $true } }
    if (& $has 'ftab|full[-_]tab|tab[-_]full|full[-_]1x2|full[-_]ou|full[-_]overunder|1x2') { return @{ Layout = 'tb'; Full = $true } }
    if (& $has 'tab|ou|overunder|over[-_]under|topbottom|top[-_]bottom|tb') { return @{ Layout = 'tb'; Full = $false } }
    if (& $has 'sbs|3d') { return @{ Layout = 'sbs'; Full = $false } }
    return $null
}

function Find-Tool([string]$name, [string[]]$dirs) {
    foreach ($d in $dirs) {
        if ($d) {
            $p = Join-Path $d $name
            if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
        }
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function ConvertTo-Rational([string]$s) {
    if ($s -match '^(\d+(?:\.\d+)?)[/:](\d+(?:\.\d+)?)$') {
        $d = [double]$matches[2]
        if ($d -eq 0) { return 0.0 }
        return [double]$matches[1] / $d
    }
    $v = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $v }
    return 0.0
}

function Get-Even([double]$v) { [int]([math]::Max(2, 2 * [math]::Round($v / 2))) }

$inputFull = (Resolve-Path -LiteralPath $InputFile).Path
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFull)

# Format: -Format override, otherwise taken from the file name.
$layout = $null
if ($Format) {
    $f = $Format.ToLower()
    $f = switch ($f) {
        'sbs' { 'fsbs' } 'fullsbs' { 'fsbs' } 'halfsbs' { 'hsbs' }
        'tb' { 'ftab' } 'ftb' { 'ftab' } 'fulltb' { 'ftab' } 'fulltab' { 'ftab' }
        'htb' { 'htab' } 'halftb' { 'htab' } 'halftab' { 'htab' }
        default { $f }
    }
    if ($f -eq 'frames') { $layout = @{ Layout = 'frames'; Full = $true } }
    elseif ($f -in @('fsbs', 'hsbs', 'ftab', 'htab')) { $layout = Resolve-Format $f }
    else { throw "Invalid -Format '$Format'. Use fsbs, hsbs, ftab, htab or frames." }
}
else {
    $layout = Resolve-Format $baseName
    if (-not $layout) { throw "Could not detect the 3D format from '$baseName'. Add a marker such as fsbs/hsbs/ftab/htab to the file name or pass -Format." }
}

function Get-ReleaseTool([string]$repo, [string]$assetPattern, [string]$destName) {
    $dest = Join-Path (Join-Path $root 'downloaded-tools') $destName
    if (Test-Path -LiteralPath $dest) { return $dest }
    Write-Host "Downloading $destName from github.com/$repo ..."
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'encode-mvc' }
    $asset = $rel.assets | Where-Object { $_.name -match $assetPattern -and $_.name -notmatch '\.(sha256|sha512|md5)$' } | Select-Object -First 1
    if (-not $asset) { throw "No release asset matching '$assetPattern' in $repo." }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dl_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
        $expected = $null
        $sumAsset = $rel.assets | Where-Object { $_.name -eq ($asset.name + '.sha256') } | Select-Object -First 1
        if ($sumAsset) {
            $text = (Invoke-WebRequest -Uri $sumAsset.browser_download_url -UseBasicParsing).Content
            if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
            $expected = $text.Trim().Split()[0]
        }
        else {
            $sums = $rel.assets | Where-Object { $_.name -match '^checksums?\.sha256$' } | Select-Object -First 1
            if ($sums) {
                $text = (Invoke-WebRequest -Uri $sums.browser_download_url -UseBasicParsing).Content
                if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
                $m = [regex]::Match($text, '(?m)^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($asset.name) + '\s*$')
                if ($m.Success) { $expected = $m.Groups[1].Value }
            }
        }
        if (-not $expected) { throw "No checksum published for $($asset.name); refusing to use it." }
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected.ToUpper()) { throw "Checksum mismatch for $($asset.name)." }
        $extract = Join-Path $tmp 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract
        $dir = Split-Path -Parent $dest
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $exe = Get-ChildItem -LiteralPath $extract -Recurse -Filter $destName | Select-Object -First 1
        if (-not $exe) { throw "$destName not found inside $($asset.name)." }
        # Keep the whole folder: tsMuxeR needs the DLLs next to it, ffmpeg tools come in a bin folder.
        Copy-Item -Path (Join-Path $exe.DirectoryName '*') -Destination $dir -Recurse -Force
        return $dest
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# Tools: use what is given or found locally, otherwise download release builds (checksum-verified).
$x264 = if ($X264) { $X264 } else { Find-Tool 'x264.exe' @($root, (Join-Path $root 'downloaded-tools')) }
if (-not $x264) { $x264 = Get-ReleaseTool 'NTM-3D/x264-mvc' 'windows-x64\.zip$' 'x264.exe' }
if (-not (Test-Path -LiteralPath $x264)) { throw "x264.exe not found at '$x264'." }
$ffDirs = @($FfmpegDir, $root, (Join-Path $root 'downloaded-tools'))
$ffmpeg = Find-Tool 'ffmpeg.exe' $ffDirs
$ffprobe = Find-Tool 'ffprobe.exe' $ffDirs
if (-not $ffmpeg -or -not $ffprobe) {
    $ffmpeg = Get-ReleaseTool 'BtbN/FFmpeg-Builds' '^ffmpeg-master-latest-win64-gpl\.zip$' 'ffmpeg.exe'
    $ffprobe = Join-Path (Split-Path -Parent $ffmpeg) 'ffprobe.exe'
}
if ($Output -eq 'iso') {
    $tsmuxer = if ($TsMuxer) { $TsMuxer } else { Find-Tool 'tsMuxeR.exe' @($root, (Join-Path $root 'downloaded-tools')) }
    if (-not $tsmuxer) { $tsmuxer = Get-ReleaseTool 'teaching-droid/tsMuxer' 'windows-x64\.zip$' 'tsMuxeR.exe' }
    if (-not (Test-Path -LiteralPath $tsmuxer)) { throw "tsMuxeR.exe not found at '$tsmuxer'." }
}

# Probe the source
$probe = & $ffprobe -v error -select_streams v:0 -show_entries stream=width,height,sample_aspect_ratio,avg_frame_rate,r_frame_rate -of json "$inputFull" | ConvertFrom-Json
$vs = $probe.streams | Select-Object -First 1
if (-not $vs -or -not $vs.width -or -not $vs.height) { throw 'No video stream found in input.' }
$srcW = [int]$vs.width
$srcH = [int]$vs.height
$sar = 1.0
if ($vs.sample_aspect_ratio -and $vs.sample_aspect_ratio -match '^(\d+):(\d+)$' -and [int]$matches[1] -gt 0 -and [int]$matches[2] -gt 0) {
    $sar = [double]$matches[1] / [double]$matches[2]
}
$srcFps = ConvertTo-Rational $vs.avg_frame_rate
if ($srcFps -le 0) { $srcFps = ConvertTo-Rational $vs.r_frame_rate }
$duration = 0.0
$durText = & $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$inputFull"
if ($durText) { [void][double]::TryParse(($durText | Select-Object -First 1), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration) }

# Output frame rate (Blu-ray 3D: 1080p24/23.976, 720p 23.976/24/50/59.94)
$fpsMap = @{
    '24000/1001' = @{ Val = 24000 / 1001; Mux = '23.976' }
    '24'         = @{ Val = 24; Mux = '24' }
    '50'         = @{ Val = 50; Mux = '50' }
    '60000/1001' = @{ Val = 60000 / 1001; Mux = '59.94' }
}
# Frame-sequential input interleaves both eyes, so the per-eye rate is half the stream rate.
if ($layout.Layout -eq 'frames') { $srcFps = $srcFps / 2 }
$fpsKey = $Fps.Trim()
if ($fpsKey -eq 'auto') {
    if ([math]::Abs($srcFps - 24) -lt 0.05) { $fpsKey = '24' }
    elseif ($EyeHeight -eq 720 -and $srcFps -ge 55) { $fpsKey = '60000/1001' }
    elseif ($EyeHeight -eq 720 -and $srcFps -ge 45) { $fpsKey = '50' }
    else { $fpsKey = '24000/1001' }
}
elseif ($fpsKey -eq '23.976') { $fpsKey = '24000/1001' }
elseif ($fpsKey -eq '59.94') { $fpsKey = '60000/1001' }
if (-not $fpsMap.ContainsKey($fpsKey)) { throw "Unsupported -Fps '$Fps'. Use auto, 24000/1001, 24, 50 or 60000/1001." }
$fpsX264 = $fpsKey
if ($layout.Layout -eq 'frames') { $fpsX264 = switch ($fpsKey) { '24000/1001' { '48000/1001' } '24' { '48' } '50' { '100' } default { '120000/1001' } } }
$fpsMux = $fpsMap[$fpsKey].Mux
$keyint = [int][math]::Round($fpsMap[$fpsKey].Val)

# Geometry: per-eye canvas is fixed by the Blu-ray profile; the eye picture is fitted into it keeping its display aspect ratio.
$canvasH = $EyeHeight
$canvasW = if ($EyeHeight -eq 1080) { 1920 } else { 1280 }

switch ($layout.Layout) {
    'sbs' {
        $eyeW = [int][math]::Floor($srcW / 2); $eyeH = $srcH
        $dar = if ($layout.Full) { $eyeW * $sar / $eyeH } else { 2 * $eyeW * $sar / $eyeH }
    }
    'tb' {
        $eyeW = $srcW; $eyeH = [int][math]::Floor($srcH / 2)
        $dar = if ($layout.Full) { $eyeW * $sar / $eyeH } else { $eyeW * $sar / (2 * $eyeH) }
    }
    'frames' {
        $eyeW = $srcW; $eyeH = $srcH
        $dar = $srcW * $sar / $srcH
    }
}
if ($dar -ge $canvasW / $canvasH) { $fitW = $canvasW; $fitH = [math]::Min($canvasH, (Get-Even ($canvasW / $dar))) }
else { $fitH = $canvasH; $fitW = [math]::Min($canvasW, (Get-Even ($canvasH * $dar))) }
$fitFilter = "scale=${fitW}:${fitH}:flags=lanczos+accurate_rnd+full_chroma_int,setsar=1,pad=${canvasW}:${canvasH}:(ow-iw)/2:(oh-ih)/2:black"
$tail = "fps=$fpsX264,format=yuv420p"

switch ($layout.Layout) {
    'sbs' {
        $res = "$($canvasW * 2)x$canvasH"
        $vf = "-filter_complex `"[0:v]crop=iw/2:ih:0:0,$fitFilter[l];[0:v]crop=iw/2:ih:iw/2:0,$fitFilter[r];[l][r]hstack,$tail`""
    }
    'tb' {
        $res = "${canvasW}x$($canvasH * 2)"
        $vf = "-filter_complex `"[0:v]crop=iw:ih/2:0:0,$fitFilter[t];[0:v]crop=iw:ih/2:0:ih/2,$fitFilter[b];[t][b]vstack,$tail`""
    }
    'frames' {
        $res = "${canvasW}x$canvasH"
        $vf = "-vf `"$fitFilter,$tail`""
    }
}
Write-Host ("Input : {0}x{1} (SAR {2:N3}), {3:N3} fps" -f $srcW, $srcH, $sar, $srcFps)
Write-Host ("Format: {0}{1}, eye DAR {2:N3} -> fitted {3}x{4} in {5}x{6}, packed {7}, {8} fps" -f $(if ($layout.Full) { 'full ' } else { 'half ' }), $layout.Layout, $dar, $fitW, $fitH, $canvasW, $canvasH, $res, $fpsX264)

if (-not $OutDir) { $OutDir = Split-Path -Parent $inputFull }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("mvc_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$failed = $false

function Format-Bat([string]$s) { $s -replace '%', '%%' }

try {
    $mvcTemp = Join-Path $temp 'stereo.mvc'
    $bat = Join-Path $temp 'encode.bat'
    $pathDirs = (@((Split-Path -Parent $ffmpeg), (Split-Path -Parent $x264)) | Select-Object -Unique) -join ';'
    $viewMax = [math]::Min(40000, $MaxBitrate)
    $viewBuf = [math]::Min(30000, $BufSize)
    $encodeArgs = "--demuxer raw --input-res $res --input-csp i420 --fps $fpsX264 --mvc --mvc-layout $($layout.Layout) --preset $Preset --force-cfr --output-csp i420 $(if ($TargetBitrate -gt 0) { "--mvc-combined-bitrate $TargetBitrate" } else { "--crf $Crf" }) --mvc-combined-vbv-maxrate $MaxBitrate --mvc-combined-vbv-bufsize $BufSize --mvc-view-vbv-maxrate $viewMax --mvc-view-vbv-bufsize $viewBuf --bluray-compat --level 4.1 --keyint $keyint --bframes 3 --ref 4 --slices 4 --aud --colorprim bt709 --transfer bt709 --colormatrix bt709 --rc-lookahead 60"
    $feed = "`"$(Format-Bat $ffmpeg)`" -y -progress `"$(Format-Bat $temp)\ffmpeg_progress.txt`" -i `"$(Format-Bat $inputFull)`" $(Format-Bat $vf) -f rawvideo -pix_fmt yuv420p - 2> `"$(Format-Bat $temp)\ffmpeg.log`""
    $x264Exe = "`"$(Format-Bat $x264)`""
    $lines = @('@echo off', "set `"PATH=$(Format-Bat $pathDirs);%PATH%`"")
    if ($TwoPass) {
        $stats = "$(Format-Bat $temp)\pass.log"
        $lines += "$feed | $x264Exe $encodeArgs --pass 1 --stats `"$stats`" -o NUL - > `"$(Format-Bat $temp)\encode.log`" 2>&1"
        $lines += 'if errorlevel 1 exit /b 1'
        $lines += "$feed | $x264Exe $encodeArgs --pass 2 --stats `"$stats`" -o `"$(Format-Bat $mvcTemp)`" - >> `"$(Format-Bat $temp)\encode.log`" 2>&1"
    } else {
        $lines += "$feed | $x264Exe $encodeArgs -o `"$(Format-Bat $mvcTemp)`" - > `"$(Format-Bat $temp)\encode.log`" 2>&1"
    }
    $batContent = ($lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($bat, $batContent, (New-Object System.Text.UTF8Encoding($false)))
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$bat`"" -PassThru -WindowStyle Hidden
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited) {
        $pf = "$temp\ffmpeg_progress.txt"
        if (Test-Path -LiteralPath $pf) {
            $pl = Get-Content -LiteralPath $pf -Tail 40 -ErrorAction SilentlyContinue
            $fl = $pl | Where-Object { $_ -match '^frame=' } | Select-Object -Last 1
            $ot = $pl | Where-Object { $_ -match '^out_time_ms=' } | Select-Object -Last 1
            $fnum = 0
            if ($fl -match 'frame=(\d+)') { $fnum = [int]$matches[1] }
            $pct = -1
            $status = "frame $fnum"
            if ($ot -and $duration -gt 0) {
                $sec = 0
                try { $sec = [double]($ot -replace 'out_time_ms=', '') / 1000000.0 } catch { }
                $pct = [math]::Max(0, [math]::Min(100, [math]::Round(($sec / $duration) * 100, 1)))
                $status = "frame $fnum, $pct%, elapsed $([int]$sw.Elapsed.TotalSeconds)s"
            }
            Write-Progress -Activity 'Encoding MVC' -Status $status -PercentComplete $pct
        }
        Start-Sleep -Milliseconds 500
    }
    $proc.WaitForExit()
    Write-Progress -Activity 'Encoding MVC' -Completed
    if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $mvcTemp) -or (Get-Item -LiteralPath $mvcTemp).Length -eq 0) {
        $failed = $true
        $msg = "Encoding failed (exit code $($proc.ExitCode)). Logs kept in $temp`n--- x264 ---`n" + ((Get-Content "$temp\encode.log" -Tail 15 -ErrorAction SilentlyContinue) -join "`n") + "`n--- ffmpeg ---`n" + ((Get-Content "$temp\ffmpeg.log" -Tail 15 -ErrorAction SilentlyContinue) -join "`n")
        throw $msg
    }

    if ($Output -eq 'mvc') {
        $finalMvc = Join-Path $OutDir ($baseName + '.mvc')
        Copy-Item -LiteralPath $mvcTemp -Destination $finalMvc -Force
        Write-Host "Created $finalMvc"
        return
    }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $trackOutput = & $tsmuxer $inputFull 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = $prevEap
    $tracks = @()
    $current = $null
    foreach ($line in $trackOutput) {
        if ($line -match 'Track ID:\s*(\d+)') { $current = [ordered]@{ Id = $matches[1]; Type = ''; Codec = ''; Lang = '' }; continue }
        if ($line -match 'Stream type:\s*(.+)') { if ($current) { $current.Type = $matches[1].Trim() }; continue }
        if ($line -match 'Stream lang:\s*(\S+)') { if ($current) { $current.Lang = $matches[1] }; continue }
        if ($line -match 'Stream ID:\s*(.+)') { if ($current) { $current.Codec = $matches[1].Trim(); $tracks += [pscustomobject]$current; $current = $null }; continue }
    }

    $inputFwd = $inputFull -replace '\\', '/'
    $mvcFwd = $mvcTemp -replace '\\', '/'
    $metaPath = Join-Path $temp 'remux.meta'
    $metaLines = @("MUXOPT --blu-ray --maxbitrate=$MaxBitrate")
    $metaLines += "V_MPEG4/ISO/AVC, $mvcFwd, subTrack=2, fps=$fpsMux"
    $metaLines += "V_MPEG4/ISO/MVC, $mvcFwd, subTrack=1, fps=$fpsMux"
    # Audio codecs a Blu-ray player accepts; anything else is converted to AC-3 at its maximum bitrate.
    $bdAudio = 'A_AC3|A_EAC3|A_DTS|A_TRUEHD|A_MLP|A_LPCM'
    foreach ($t in $tracks) {
        if ($t.Type -eq 'H.264') { continue }
        if ($t.Codec -match '^V_') { continue }
        $lang = if ($t.Lang) { ", lang=$($t.Lang)" } else { '' }
        if ($t.Codec -match '^A_' -and $t.Codec -notmatch "^($bdAudio)") {
            $ac3 = Join-Path $temp "audio_$($t.Id).ac3"
            $ErrorActionPreference = 'Continue'
            & $ffmpeg -v error -y -i $inputFull -map "0:$([int]$t.Id - 1)" -c:a ac3 -b:a 640k -ac 6 $ac3 2>&1 | Out-Host
            $ErrorActionPreference = $prevEap
            if (-not (Test-Path -LiteralPath $ac3) -or (Get-Item -LiteralPath $ac3).Length -eq 0) { $failed = $true; throw "Audio conversion failed for track $($t.Id). Files kept in $temp" }
            Write-Host "Converted audio track $($t.Id) ($($t.Codec)) to AC-3"
            $metaLines += "A_AC3, $($ac3 -replace '\\', '/')$lang"
            continue
        }
        $metaLines += "$($t.Codec), $inputFwd, track=$($t.Id)$lang"
    }
    [System.IO.File]::WriteAllText($metaPath, ($metaLines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

    $finalIso = Join-Path $OutDir ($baseName + '.iso')
    $ErrorActionPreference = 'Continue'
    & $tsmuxer $metaPath $finalIso 2>&1 | ForEach-Object { "$_" } | Out-Host
    $muxExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($muxExit -ne 0 -or -not (Test-Path -LiteralPath $finalIso)) { $failed = $true; throw "tsMuxeR failed. Files kept in $temp" }
    Write-Host "Created $finalIso"
}
finally {
    if (-not $failed -and -not $KeepTemp) {
        Start-Sleep -Seconds 1
        for ($retry = 0; $retry -lt 10; $retry++) {
            try { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction Stop }; break } catch { Start-Sleep -Milliseconds 500 }
        }
    }
}
