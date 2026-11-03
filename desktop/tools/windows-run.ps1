# Runs Monet Shot on a real Windows desktop (GitHub's windows-latest VM, job
# `windows-run` in .github/workflows/desktop.yml) and checks what it made:
#
#   1. record   the release exe records the first display for 5 s
#               (MONETSHOT_DEMO_RECORD/STOP) while we move and click the
#               mouse; screen.mp4 plays, cursor.json has samples and clicks,
#               meta.json loads with core's Project loader (plan_dump).
#   2. editor   the debug exe (WebView2 on the Vite dev server) opened on a
#               copy of that take runs ui/devchecks/editor.js: 0 failed.
#   3. fixtures the preview painter vs the Mac's frames (fixtures-test.html):
#               every case within mean 1/255.
#   4. hevc     a copy of the take re-encoded to HEVC (as the Mac records)
#               shows a picture (via the H.264 video_proxy) and plays.
#   5. export   the export the editor check made (Ctrl+E) probes as video.
#
# Every stage runs even when an earlier one failed; the script exits 1 if
# any failed. Logs, the take, the export and screenshots go to -Out.
#
#   pwsh desktop/tools/windows-run.ps1 [-Out <dir>] [-Stages record,editor,...]
#
# Needs: target/release/monet-shot.exe (tauri build --no-bundle),
# target/debug/monet-shot.exe and target/debug/examples/plan_dump.exe,
# desktop/app/node_modules, the core-wasm pkg, and the ffmpeg sidecars in
# desktop/packaging/windows/bin (fetch-ffmpeg.sh).
param(
  [string]$Out = $(if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'ms-run' } else { Join-Path ([IO.Path]::GetTempPath()) 'ms-run' }),
  [string[]]$Stages = @('record', 'editor', 'fixtures', 'hevc', 'export')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$desktop = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repo = Split-Path $desktop
$target = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $desktop 'target' }
$release = Join-Path $target 'release\monet-shot.exe'
$debug = Join-Path $target 'debug\monet-shot.exe'
$planDump = Join-Path $target 'debug\examples\plan_dump.exe'
$bin = Join-Path $desktop 'packaging\windows\bin'
$ffmpeg = Join-Path $bin 'ffmpeg-x86_64-pc-windows-msvc.exe'
$ffprobe = Join-Path $bin 'ffprobe-x86_64-pc-windows-msvc.exe'
$env:MONETSHOT_FFMPEG = $ffmpeg
$env:MONETSHOT_FFPROBE = $ffprobe
# As installed: ffmpeg.exe and ffprobe.exe next to monet-shot.exe.
foreach ($dir in @((Split-Path $release), (Split-Path $debug))) {
  if (Test-Path $dir) {
    Copy-Item $ffmpeg (Join-Path $dir 'ffmpeg.exe') -Force
    Copy-Item $ffprobe (Join-Path $dir 'ffprobe.exe') -Force
  }
}

New-Item -ItemType Directory -Force $Out | Out-Null
$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string]$m) { Write-Host "::error::$m"; $failures.Add($m) }
function Ok([string]$m) { Write-Host "ok: $m" }
function Section([string]$m) { Write-Host ""; Write-Host "=== $m ===" }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MsMouse {
  [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public MOUSEINPUT mi; }
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
  /// A left click where the pointer is (down + up), as a person's.
  public static uint Click() {
    var a = new INPUT[2];
    a[0].type = 0; a[0].mi.dwFlags = 0x0002; // MOUSEEVENTF_LEFTDOWN
    a[1].type = 0; a[1].mi.dwFlags = 0x0004; // MOUSEEVENTF_LEFTUP
    return SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
  }
}
'@

function Shot([string]$name) {
  try {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $p = Join-Path $Out "$name.png"
    $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "screenshot $p ($($b.Width)x$($b.Height))"
  } catch { Write-Host "::warning::screenshot $name failed: $_" }
}

function Stop-App {
  Get-Process monet-shot -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 800
}

# Starts an exe with extra environment variables (only for it).
function Start-App([string]$exe, [hashtable]$vars, [string[]]$appArgs = @()) {
  Stop-App
  $saved = @{}
  foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
  try {
    $quoted = $appArgs | ForEach-Object { '"' + $_ + '"' }
    $p = if ($quoted) { Start-Process -FilePath $exe -ArgumentList $quoted -PassThru } else { Start-Process -FilePath $exe -PassThru }
  } finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
  Write-Host "started $exe (pid $($p.Id)) $($appArgs -join ' ')"
  $p
}

function Log-Of([string]$home_) { Join-Path $home_ 'logs\monetshot.log' }
function Read-Log([string]$home_) {
  $f = Log-Of $home_
  if (Test-Path $f) { Get-Content -Raw $f } else { '' }
}
# Waits until the app log matches a pattern; returns the match or $null.
function Wait-Log([string]$home_, [string]$pattern, [int]$seconds) {
  $until = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $until) {
    $m = [regex]::Match((Read-Log $home_), $pattern)
    if ($m.Success) { return $m }
    Start-Sleep -Milliseconds 500
  }
  $null
}
function Save-Log([string]$home_, [string]$name) {
  $f = Log-Of $home_
  if (Test-Path $f) { Copy-Item $f (Join-Path $Out "$name.log") -Force }
}

function Probe([string]$file) {
  $j = & $ffprobe -v error -count_frames -select_streams v:0 `
    -show_entries 'stream=codec_name,width,height,nb_read_frames:format=duration' -of json $file | ConvertFrom-Json
  [pscustomobject]@{
    codec = $j.streams[0].codec_name; width = [int]$j.streams[0].width; height = [int]$j.streams[0].height
    frames = [int]$j.streams[0].nb_read_frames; duration = [double]$j.format.duration
  }
}

# Copies a .reel folder (without the editor's edits, if asked).
function Copy-Reel([string]$from, [string]$to) {
  if (Test-Path $to) { Remove-Item -Recurse -Force $to }
  Copy-Item -Recurse $from $to
  $to
}

$script:take = $null      # the recorded .reel
$script:exported = $null  # the editor check's export
$script:vite = $null

function Start-Vite {
  if ($script:vite -and -not $script:vite.HasExited) { return }
  $app = Join-Path $desktop 'app'
  $log = Join-Path $Out 'vite.log'
  $script:vite = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "npm run dev > `"$log`" 2>&1" -WorkingDirectory $app -PassThru -WindowStyle Hidden
  $until = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $until) {
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 http://localhost:5183/ | Out-Null; Write-Host "vite is up"; return } catch { Start-Sleep 1 }
  }
  throw "the Vite dev server didn't come up (vite.log)"
}

# MARK: 1. record

function Stage-Record {
  Section '1. record (release exe, WGC)'
  if (-not (Test-Path $release)) { throw "no $release" }
  $h = Join-Path $Out 'home-record'
  if (Test-Path $h) { Remove-Item -Recurse -Force $h }
  New-Item -ItemType Directory -Force $h | Out-Null
  $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  Write-Host "screen $($scr.Width)x$($scr.Height)"
  $cx = [int]($scr.Width / 2); $cy = [int]($scr.Height / 2)
  [MsMouse]::SetCursorPos($cx, $cy) | Out-Null

  $p = Start-App $release @{ MONETSHOT_HOME = $h; MONETSHOT_DEMO_RECORD = '1'; MONETSHOT_DEMO_STOP = '5' }
  # Tap at 1 s, the 3-2-1, then 5 s of recording: move the pointer in a
  # circle the whole time, and click once recording is surely on (the
  # app's windows are put away by then, so the clicks land on the desktop).
  $t0 = Get-Date
  $clicks = 0
  $started = $null
  $lastClick = 0.0
  while (((Get-Date) - $t0).TotalSeconds -lt 20) {
    $s = ((Get-Date) - $t0).TotalSeconds
    $a = $s * 2.0
    [MsMouse]::SetCursorPos([int]($cx + 220 * [math]::Cos($a)), [int]($cy + 160 * [math]::Sin($a))) | Out-Null
    if ($null -eq $started -and (Read-Log $h) -match 'recording into') { $started = $s }
    if ($null -ne $started -and $s -gt $started + 1 -and $s -lt $started + 4.5 -and $s - $lastClick -gt 0.8) {
      [MsMouse]::Click() | Out-Null; $clicks++; $lastClick = $s
    }
    if ((Get-ChildItem -Path (Join-Path $h 'recordings') -Recurse -Filter meta.json -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 30
  }
  Write-Host "clicked $clicks times; recording seen in the log at $started s"
  $meta = $null
  $until = (Get-Date).AddSeconds(60)
  while (-not $meta -and (Get-Date) -lt $until) {
    $meta = Get-ChildItem -Path (Join-Path $h 'recordings') -Recurse -Filter meta.json -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $meta) { Start-Sleep 1 }
  }
  # The editor opens on the take when it's done: let it paint, then look.
  if ($meta) { Start-Sleep 8; Shot '1-release-editor' }
  else { Shot '1-no-take' }
  Stop-App
  Save-Log $h '1-record'
  Write-Host (Read-Log $h)
  if (-not $meta) { Fail 'record: no take (no meta.json under recordings) within 80 s'; return }

  $reel = $meta.Directory.FullName
  $script:take = Copy-Reel $reel (Join-Path $Out 'take.reel')
  Get-ChildItem $reel | Format-Table Name, Length | Out-String | Write-Host
  $video = Join-Path $reel 'screen.mp4'
  if (-not (Test-Path $video)) { Fail 'record: no screen.mp4'; return }
  $v = Probe $video
  Write-Host "screen.mp4: $($v.codec) $($v.width)x$($v.height), $($v.frames) frames, $($v.duration) s"
  if ($v.frames -gt 0 -and $v.duration -ge 3.5 -and $v.duration -le 7.5) { Ok "screen.mp4 plays: $($v.frames) frames, $($v.duration) s" }
  else { Fail "record: screen.mp4 has $($v.frames) frames, $($v.duration) s (want > 0 frames, ~5 s)" }

  $cur = Get-Content -Raw (Join-Path $reel 'cursor.json') | ConvertFrom-Json
  $ns = @($cur.samples).Count; $nc = @($cur.clicks).Count
  Write-Host "cursor.json: $ns samples, $nc clicks"
  if ($ns -gt 50) { Ok "cursor.json has $ns samples" } else { Fail "record: cursor.json has $ns samples" }
  if ($nc -gt 0) { Ok "cursor.json has $nc clicks" } else { Fail "record: cursor.json has no clicks ($clicks sent)" }
  if ($ns -gt 1) {
    $xs = @($cur.samples | ForEach-Object { $_.x }); $span = ($xs | Measure-Object -Maximum -Minimum)
    $distinct = @($xs | Sort-Object -Unique).Count
    if ($distinct -gt 10) { Ok "the pointer moved: $distinct distinct x in $($span.Minimum)..$($span.Maximum)" } else { Fail "record: the pointer log barely moves ($distinct distinct x)" }
  }

  Get-Content -Raw (Join-Path $reel 'meta.json') | Write-Host
  $plan = & $planDump $reel 1.0 2>&1
  if ($LASTEXITCODE -eq 0) { Ok "meta.json loads with core's Project loader (plan at 1 s: $(([string]$plan).Length) bytes)" }
  else { Fail "record: core's Project loader refused the take: $plan" }
}

# MARK: 2 + 5. editor (and its export)

function Stage-Editor {
  Section '2. editor (debug exe, WebView2, devchecks/editor.js)'
  if (-not $script:take) { Fail 'editor: no take to open (record failed)'; return }
  Start-Vite
  $h = Join-Path $Out 'home-editor'
  New-Item -ItemType Directory -Force (Join-Path $h 'recordings') | Out-Null
  $copy = Copy-Reel $script:take (Join-Path $h 'recordings\editor-check.reel')
  $devScript = Join-Path $desktop 'app\ui\devchecks\editor.js'
  Start-App $debug @{ MONETSHOT_HOME = $h; MONETSHOT_DEV_SCRIPT = $devScript } @($copy) | Out-Null
  # The screenshot: once the check says the editor opened.
  if (Wait-Log $h 'check: opened' 120) { Start-Sleep 3; Shot '2-editor' } else { Shot '2-editor-not-open' }
  $done = Wait-Log $h 'check: done (\d+) ok, (\d+) failed' 900
  Stop-App
  Save-Log $h '2-editor'
  $log = Read-Log $h
  ($log -split "`n" | Where-Object { $_ -match 'check:|ERROR|export' }) -join "`n" | Write-Host
  if (-not $done) { Fail 'editor: the check never finished (no "check: done" in 15 min)'; return }
  $good = [int]$done.Groups[1].Value; $bad = [int]$done.Groups[2].Value
  if ($bad -eq 0 -and $good -gt 0) { Ok "editor check: $good ok, 0 failed" } else { Fail "editor: check: done $good ok, $bad failed" }
  $m = [regex]::Match($log, 'export finished (.+?)\r?\n')
  if ($m.Success) { $script:exported = $m.Groups[1].Value.Trim() }
}

function Stage-Export {
  Section '5. export (the editor check''s Ctrl+E)'
  if (-not $script:exported) { Fail 'export: the editor check made no export ("export finished" not in its log)'; return }
  if (-not (Test-Path $script:exported)) { Fail "export: $($script:exported) is not there"; return }
  Copy-Item $script:exported (Join-Path $Out 'export.mp4') -Force
  $v = Probe $script:exported
  Write-Host "export: $($v.codec) $($v.width)x$($v.height), $($v.frames) frames, $($v.duration) s"
  if ($v.frames -gt 0 -and $v.duration -gt 1 -and $v.width -gt 0) { Ok "export plays: $($v.codec) $($v.width)x$($v.height), $($v.frames) frames, $($v.duration) s" }
  else { Fail "export: $($v.frames) frames, $($v.duration) s" }
}

# MARK: 3. fixtures

function Stage-Fixtures {
  Section '3. fixtures (WebGL2 preview painter vs the Mac''s frames)'
  Start-Vite
  $h = Join-Path $Out 'home-fixtures'
  New-Item -ItemType Directory -Force $h | Out-Null
  $cases = @((Get-Content -Raw (Join-Path $repo 'shared\fixtures\render\cases.json') | ConvertFrom-Json).cases).Count
  Start-App $debug @{ MONETSHOT_HOME = $h; MONETSHOT_DEV_PAGE = 'fixtures-test.html' } | Out-Null
  $until = (Get-Date).AddSeconds(300)
  $lines = @()
  while ((Get-Date) -lt $until) {
    $lines = @([regex]::Matches((Read-Log $h), 'fixtures: (\S+)\s+mean\s+([\d.]+)'))
    if ($lines.Count -ge $cases) { break }
    Start-Sleep 1
  }
  Start-Sleep 2
  Shot '3-fixtures'
  Stop-App
  Save-Log $h '3-fixtures'
  ((Read-Log $h) -split "`n" | Where-Object { $_ -match 'fixtures:|ERROR' }) -join "`n" | Write-Host
  if ($lines.Count -lt $cases) { Fail "fixtures: $($lines.Count) of $cases cases reported in 5 min"; return }
  $worst = 0.0
  foreach ($l in $lines) {
    $mean = [double]$l.Groups[2].Value
    $worst = [math]::Max($worst, $mean)
    if ($mean -gt 1.0) { Fail "fixtures: $($l.Groups[1].Value) mean $mean/255 (> 1)" }
  }
  Write-Host "fixtures: worst mean $worst/255 over $($lines.Count) cases"
}

# MARK: 4. HEVC take -> H.264 proxy

function Stage-Hevc {
  Section '4. hevc (a Mac-like HEVC take falls back to video_proxy)'
  if (-not $script:take) { Fail 'hevc: no take to convert (record failed)'; return }
  Start-Vite
  $h = Join-Path $Out 'home-hevc'
  New-Item -ItemType Directory -Force (Join-Path $h 'recordings') | Out-Null
  $copy = Copy-Reel $script:take (Join-Path $h 'recordings\hevc-check.reel')
  Remove-Item -Force (Join-Path $copy 'edit.json') -ErrorAction SilentlyContinue
  $src = Join-Path $script:take 'screen.mp4'
  $dst = Join-Path $copy 'screen.mp4'
  & $ffmpeg -hide_banner -loglevel error -y -i $src -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p -x265-params log-level=error -an $dst
  if ($LASTEXITCODE -ne 0) { Fail 'hevc: ffmpeg could not make the HEVC copy'; return }
  $v = Probe $dst
  Write-Host "HEVC copy: $($v.codec) $($v.width)x$($v.height), $($v.frames) frames"
  $devScript = Join-Path $PSScriptRoot 'windows-hevc-check.js'
  Start-App $debug @{ MONETSHOT_HOME = $h; MONETSHOT_DEV_SCRIPT = $devScript } @($copy) | Out-Null
  $done = Wait-Log $h 'hevc: done (.*)' 300
  Shot '4-hevc'
  Stop-App
  Save-Log $h '4-hevc'
  $log = Read-Log $h
  ($log -split "`n" | Where-Object { $_ -match 'hevc:|proxy|ERROR' }) -join "`n" | Write-Host
  if (-not $done) { Fail 'hevc: the check never finished'; return }
  $proxied = $log -match 'preview proxy for' -and $log -match 'hevc: proxy yes'
  if ($done.Groups[1].Value -like 'plays*') {
    if ($proxied) { Ok "HEVC take plays through the H.264 proxy: $($done.Groups[1].Value)" }
    else { Fail "hevc: plays, but not through video_proxy (WebView2 decoded HEVC itself?): $($done.Groups[1].Value)" }
  } else { Fail "hevc: $($done.Groups[1].Value)" }
}

# MARK: run

try {
  foreach ($s in $Stages) {
    try {
      switch ($s) {
        'record' { Stage-Record }
        'editor' { Stage-Editor }
        'fixtures' { Stage-Fixtures }
        'hevc' { Stage-Hevc }
        'export' { Stage-Export }
        default { throw "unknown stage $s" }
      }
    } catch {
      Fail "${s}: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
      Stop-App
    }
  }
} finally {
  Stop-App
  if ($script:vite -and -not $script:vite.HasExited) { & taskkill /PID $script:vite.Id /T /F | Out-Null }
}

Section 'result'
if ($failures.Count) {
  $failures | ForEach-Object { Write-Host "FAILED: $_" }
  exit 1
}
Write-Host "all stages passed: $($Stages -join ', ')"
