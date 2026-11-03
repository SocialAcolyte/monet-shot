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
#   6. install  the NSIS installer, silently (/S); the installed exe records
#               with its own ffmpeg sidecar (no MONETSHOT_FFMPEG), with a
#               pause (double-tap Shift, twice) that must become one cut, and
#               the pill's content protection on: the pill must be missing
#               from screen.mp4 (it is there in stage 1's take, where the
#               demo turns protection off). Then the uninstaller (/S).
#   7. window   `monet-shot toggle` (as Waybar/a hotkey) opens our picker; a
#               dev script clicks the card of a window we opened; the take
#               must be that window's size and show it. A short click on the
#               pill's ring must not stop it; holding it (real mouse) must.
#
# Every stage runs even when an earlier one failed; the script exits 1 if
# any failed. Logs, the take, the export and screenshots go to -Out.
#
#   pwsh desktop/tools/windows-run.ps1 [-Out <dir>] [-Stages record,editor,...]
#
# Needs: target/release/monet-shot.exe and bundle/nsis/*-setup.exe (tauri build --bundles nsis),
# target/debug/monet-shot.exe and target/debug/examples/plan_dump.exe,
# desktop/app/node_modules, the core-wasm pkg, and the ffmpeg sidecars in
# desktop/packaging/windows/bin (fetch-ffmpeg.sh).
param(
  [string]$Out = $(if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'ms-run' } else { Join-Path ([IO.Path]::GetTempPath()) 'ms-run' }),
  [string[]]$Stages = @('record', 'editor', 'fixtures', 'hevc', 'export', 'install', 'window')
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
using System.Threading;
using System.Runtime.InteropServices;
public static class MsWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
  static uint Send(params INPUT[] a) { return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT))); }
  static INPUT Mouse(uint flags) { var i = new INPUT(); i.type = 0; i.u.mi.dwFlags = flags; return i; }
  static INPUT Key(ushort vk, bool up) { var i = new INPUT(); i.type = 1; i.u.ki.wVk = vk; i.u.ki.dwFlags = up ? 2u : 0u; return i; }
  /// The left button, as a person's (where the pointer is).
  public static uint Down() { return Send(Mouse(0x0002)); }
  public static uint Up() { return Send(Mouse(0x0004)); }
  public static uint Click() { return Send(Mouse(0x0002), Mouse(0x0004)); }
  /// Two quick taps of Shift alone: Monet Shot's pause/resume.
  public static void DoubleShift() {
    Send(Key(0x10, false)); Thread.Sleep(60); Send(Key(0x10, true));
    Thread.Sleep(120);
    Send(Key(0x10, false)); Thread.Sleep(60); Send(Key(0x10, true));
  }
  /// A window's visible frame (DWM's, without the invisible resize borders).
  public static RECT Frame(IntPtr h) {
    RECT r;
    if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) GetWindowRect(h, out r);
    return r;
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
    $p
  } catch { Write-Host "::warning::screenshot $name failed: $_" }
}

function Stop-App {
  Get-Process monet-shot -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 800
}

# Starts an exe with extra environment variables, set for it alone (never
# in this process: PowerShell passes $null to .NET as "", and an empty
# MONETSHOT_DEMO_RECORD still counts as set). No console window for the
# debug exe; its log file has everything it prints.
# -Unset drops variables this process has (the installed exe must find its
# own ffmpeg); -Second leaves the running app alone (a second launch hands
# its arguments to the first).
function Start-App([string]$exe, [hashtable]$vars, [string[]]$appArgs = @(), [string[]]$Unset = @(), [switch]$Second) {
  if (-not $Second) {
    Stop-App
    # The runner's own console windows sit on top: put everything away first.
    try { (New-Object -ComObject Shell.Application).MinimizeAll() } catch {}
    Start-Sleep -Milliseconds 500
  }
  $psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = Split-Path $exe
  foreach ($a in $appArgs) { $psi.ArgumentList.Add($a) }
  foreach ($k in $Unset) { [void]$psi.Environment.Remove($k) }
  foreach ($k in $vars.Keys) { $psi.Environment[$k] = [string]$vars[$k] }
  $p = [System.Diagnostics.Process]::Start($psi)
  Write-Host "started $exe (pid $($p.Id)) $($appArgs -join ' ') with $(($vars.Keys | Sort-Object) -join ', ')"
  $p
}

# A property that may not be there (strict mode throws on a missing one).
function Prop($o, [string]$name) { if ($null -ne $o -and $o.PSObject.Properties[$name]) { $o.$name } else { $null } }

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

# Waits for a finished take (its meta.json) under <home>/recordings.
function Wait-Take([string]$home_, [int]$seconds) {
  $until = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $until) {
    $m = Get-ChildItem -Path (Join-Path $home_ 'recordings') -Recurse -Filter meta.json -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { return $m.Directory.FullName }
    Start-Sleep -Milliseconds 500
  }
  $null
}

# A window's rectangle as @{x; y; w; h}, or $null.
function Window-Rect([string]$title) {
  $h = [MsWin]::FindWindow($null, $title)
  if ($h -eq [IntPtr]::Zero) { return $null }
  $r = [MsWin]::Frame($h)
  @{ x = $r.Left; y = $r.Top; w = $r.Right - $r.Left; h = $r.Bottom - $r.Top }
}

# The RGB bytes of a rectangle of a video frame at $t s (or of an image).
function Crop-Rgb([string]$src, [double]$t, [hashtable]$r) {
  $tmp = Join-Path $Out ("crop-" + [guid]::NewGuid().ToString('N') + '.rgb')
  $seek = if ($t -ge 0) { @('-ss', "$t") } else { @() }
  & $ffmpeg -v error -y @seek -i $src -frames:v 1 -vf "crop=$($r.w):$($r.h):$($r.x):$($r.y)" -f rawvideo -pix_fmt rgb24 $tmp
  if (-not (Test-Path $tmp)) { return , ([byte[]]@()) }
  $b = [IO.File]::ReadAllBytes($tmp); Remove-Item $tmp
  , $b
}
function Mean-Diff([byte[]]$a, [byte[]]$b) {
  if ($a.Length -eq 0 -or $a.Length -ne $b.Length) { return 999.0 }
  $sum = 0L
  for ($i = 0; $i -lt $a.Length; $i++) { $sum += [math]::Abs([int]$a[$i] - [int]$b[$i]) }
  $sum / $a.Length
}
function Mean-Rgb([byte[]]$a) {
  $s = @(0L, 0L, 0L)
  for ($i = 0; $i -lt $a.Length; $i += 3) { $s[0] += $a[$i]; $s[1] += $a[$i + 1]; $s[2] += $a[$i + 2] }
  $n = [math]::Max(1, $a.Length / 3)
  @([math]::Round($s[0] / $n), [math]::Round($s[1] / $n), [math]::Round($s[2] / $n))
}
# The pill's window less its transparent margin.
function Inset([hashtable]$r) { @{ x = $r.x + 8; y = $r.y + 4; w = [math]::Max(8, $r.w - 16); h = [math]::Max(8, $r.h - 8) } }

$script:take = $null      # the recorded .reel
$script:pillOff = $null   # the pill's rect during stage 1 (protection off)
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
  [MsWin]::SetCursorPos($cx, $cy) | Out-Null

  $p = Start-App $release @{ MONETSHOT_HOME = $h; MONETSHOT_DEMO_RECORD = '1'; MONETSHOT_DEMO_STOP = '5' }
  # Tap at 1 s, the 3-2-1, then 5 s of recording: move the pointer in a
  # circle the whole time, and click once recording is surely on (the
  # app's windows are put away by then, so the clicks land on the desktop).
  $t0 = Get-Date
  $clicks = 0
  $started = $null
  while (((Get-Date) - $t0).TotalSeconds -lt 20) {
    $s = ((Get-Date) - $t0).TotalSeconds
    $a = $s * 2.0
    [MsWin]::SetCursorPos([int]($cx + 220 * [math]::Cos($a)), [int]($cy + 160 * [math]::Sin($a))) | Out-Null
    if ($null -eq $started -and (Read-Log $h) -match 'recording into') { $started = $s }
    # Two clicks mid-take (~2.5 s and ~2.8 s in): one auto-zoom of about
    # 1.6-4.5 s, leaving room around it for the editor check's Z and drag.
    if ($null -ne $started -and $clicks -lt 2 -and $s -gt $started + 2.5 + 0.3 * $clicks) {
      [MsWin]::Click() | Out-Null; $clicks++
    }
    if ($null -ne $started -and $null -eq $script:pillOff -and $s -gt $started + 2.0) {
      $script:pillOff = Window-Rect 'Monet Shot Pill'
      Write-Host "pill (protection off) at $($script:pillOff | ConvertTo-Json -Compress)"
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
  if ($m.Success) {
    $script:exported = $m.Groups[1].Value.Trim()
    # The editor shows this path and hands it to Explorer: no \\?\ form.
    if ($script:exported.StartsWith('\\?\')) {
      Fail "editor: the export path is in verbatim form ($($script:exported))"
      $script:exported = $script:exported.Substring(4)
    }
  }
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

# MARK: 6. install (NSIS) + pause + content protection

function Stage-Install {
  Section '6. install (NSIS /S; the installed exe records with a pause and a protected pill; uninstall)'
  $setup = Get-ChildItem (Join-Path $target 'release\bundle\nsis') -Filter '*-setup.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $setup) { Fail 'install: no NSIS installer in target\release\bundle\nsis'; return }
  Write-Host "installer $($setup.Name) ($([math]::Round($setup.Length / 1MB, 1)) MB)"
  $p = Start-Process $setup.FullName -ArgumentList '/S' -PassThru -Wait
  if ($p.ExitCode -ne 0) { Fail "install: the installer exited with $($p.ExitCode)"; return }
  $key = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
    Where-Object { "$(Prop (Get-ItemProperty $_.PSPath) 'DisplayName')" -like 'Monet Shot*' } | Select-Object -First 1
  $dir = $null
  if ($key) {
    $props = Get-ItemProperty $key.PSPath
    $loc = Prop $props 'InstallLocation'
    Write-Host "uninstall entry: $(Prop $props 'DisplayName') $(Prop $props 'DisplayVersion') at $loc (uninstall: $(Prop $props 'UninstallString'))"
    if ($loc) { $dir = $loc.Trim('"') }
  }
  if (-not $dir -and $key) {
    $un = Prop (Get-ItemProperty $key.PSPath) 'UninstallString'
    if ($un) { $dir = Split-Path $un.Trim('"') }
  }
  if (-not $dir) {
    $found = Get-ChildItem $env:LOCALAPPDATA -Filter monet-shot.exe -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $dir = $found.DirectoryName }
  }
  $exe = if ($dir) { Join-Path $dir 'monet-shot.exe' } else { $null }
  if (-not $exe -or -not (Test-Path $exe)) { Fail 'install: no installed monet-shot.exe found'; return }
  Get-ChildItem $dir | Format-Table Name, Length | Out-String | Write-Host
  Ok "installed to $dir"
  foreach ($f in 'ffmpeg.exe', 'ffprobe.exe') {
    if (Test-Path (Join-Path $dir $f)) { Ok "installed $f beside the app" } else { Fail "install: no $f beside the installed app" }
  }
  $paintings = @(Get-ChildItem (Join-Path $dir 'Backdrops') -Recurse -Include *.jpg, *.png -ErrorAction SilentlyContinue).Count
  if ($paintings -ge 20) { Ok "installed $paintings backdrop images" } else { Fail "install: $paintings backdrop images installed" }

  # The desktop with nothing on it, where the pill will be.
  try { (New-Object -ComObject Shell.Application).MinimizeAll() } catch {}
  Start-Sleep 2
  $ref = Shot '6-desktop-before'

  $h = Join-Path $Out 'home-install'
  New-Item -ItemType Directory -Force $h | Out-Null
  Start-App $exe @{ MONETSHOT_HOME = $h; MONETSHOT_DEMO_RECORD = '1'; MONETSHOT_DEMO_STOP = '6'; MONETSHOT_DEMO_PROTECT = '1' } -Unset MONETSHOT_FFMPEG, MONETSHOT_FFPROBE | Out-Null
  $m = Wait-Log $h 'recording into' 40
  $pillOn = $null
  if ($m) {
    $t0 = Get-Date
    $at = { ((Get-Date) - $t0).TotalSeconds }
    while ((& $at) -lt 1.5) { Start-Sleep -Milliseconds 20 }
    [MsWin]::DoubleShift(); $pauseAt = & $at
    while ((& $at) -lt 2.5) { Start-Sleep -Milliseconds 20 }
    $pillOn = Window-Rect 'Monet Shot Pill'
    Write-Host "pill (protection on) at $($pillOn | ConvertTo-Json -Compress)"
    Shot '6-installed-recording-paused' | Out-Null
    while ((& $at) -lt 3.5) { Start-Sleep -Milliseconds 20 }
    [MsWin]::DoubleShift(); $resumeAt = & $at
    Write-Host ("double-tapped Shift at {0:N2} s and {1:N2} s after 'recording into'" -f $pauseAt, $resumeAt)
  }
  $reel = Wait-Take $h 60
  Stop-App
  Save-Log $h '6-install'
  Write-Host (Read-Log $h)
  if (-not $m) { Fail 'install: the installed app never started recording' }
  elseif (-not $reel) { Fail 'install: the installed app made no take' }
  else {
    Copy-Reel $reel (Join-Path $Out 'take-installed.reel') | Out-Null
    $video = Join-Path $reel 'screen.mp4'
    $v = Probe $video
    $meta = Get-Content -Raw (Join-Path $reel 'meta.json') | ConvertFrom-Json
    $edit = Get-Content -Raw (Join-Path $reel 'edit.json') | ConvertFrom-Json
    $cuts = @($edit.cuts)
    Write-Host "installed take: $($v.frames) frames, $($v.duration) s; meta.duration $($meta.duration); cuts $($edit.cuts | ConvertTo-Json -Compress)"
    if ($v.frames -gt 0 -and [math]::Abs($meta.duration - 6) -lt 0.8) { Ok "the installed exe recorded with its own ffmpeg: $($v.frames) frames, $($meta.duration) s" }
    else { Fail "install: take of $($v.frames) frames, $($meta.duration) s (want ~6 s)" }
    if ($cuts.Count -eq 1) {
      $c = $cuts[0]; $len = $c.end - $c.start
      $kept = $meta.duration - $len
      if ([math]::Abs($len - 2.0) -lt 0.6 -and [math]::Abs($c.start - 1.5) -lt 0.8 -and [math]::Abs($kept - 4.0) -lt 0.9) {
        Ok ("pause: one cut {0:N2}-{1:N2} s ({2:N2} s); {3:N2} s of {4:N2} s kept" -f $c.start, $c.end, $len, $kept, $meta.duration)
      } else { Fail ("pause: cut {0:N2}-{1:N2} s, {2:N2} s kept of {3:N2} (want ~1.5-3.5 s, ~4 s kept)" -f $c.start, $c.end, $kept, $meta.duration) }
    } else { Fail "pause: $($cuts.Count) cuts in edit.json (want 1 from double-tapping Shift twice)" }

    # Content protection: the pill's place in the take is the bare desktop
    # here, and the pill in stage 1's take (protection off).
    if (-not $pillOn -or -not $ref) { Fail 'protection: no pill window found during the take (or no reference shot)' }
    else {
      $r = Inset $pillOn
      $on = Mean-Diff (Crop-Rgb $video 2.5 $r) (Crop-Rgb $ref -1 $r)
      Write-Host ("pill region, protected take vs the bare desktop: mean diff {0:N1}" -f $on)
      if ($on -lt 20) { Ok ("protection: the pill is not in the take (diff {0:N1} from the bare desktop)" -f $on) }
      else { Fail ("protection: the pill's region differs from the bare desktop by {0:N1} (pill captured?)" -f $on) }
      if ($script:pillOff -and $script:take) {
        $r0 = Inset $script:pillOff
        $off = Mean-Diff (Crop-Rgb (Join-Path $script:take 'screen.mp4') 2.5 $r0) (Crop-Rgb $ref -1 $r0)
        Write-Host ("pill region, stage 1's take (protection off) vs the bare desktop: mean diff {0:N1}" -f $off)
        if ($off -gt 40) { Ok ("protection off (stage 1): the pill is in the take (diff {0:N1}), so the check sees it" -f $off) }
        else { Fail ("protection: stage 1's unprotected take doesn't show the pill either (diff {0:N1}); the check proves nothing" -f $off) }
      } else { Fail 'protection: no stage 1 pill to compare with' }
    }
  }

  # Uninstall (the uninstaller copies itself away and finishes in the background).
  $un = Join-Path $dir 'uninstall.exe'
  if (-not (Test-Path $un)) { Fail "install: no uninstall.exe in $dir"; return }
  Start-Process $un -ArgumentList '/S' -Wait
  $until = (Get-Date).AddSeconds(60)
  while ((Test-Path $exe) -and (Get-Date) -lt $until) { Start-Sleep 1 }
  if (Test-Path $exe) { Fail "uninstall: $exe is still there after 60 s" } else { Ok 'uninstalled: the app is gone' }
}

# MARK: 7. window (our picker) + hold-to-stop

function Stage-Window {
  Section '7. window (monet-shot toggle -> our picker -> a window; hold-to-stop on the pill)'
  Start-Vite
  $h = Join-Path $Out 'home-window'
  New-Item -ItemType Directory -Force $h | Out-Null
  $devScript = Join-Path $PSScriptRoot 'windows-window-check.js'
  $vars = @{ MONETSHOT_HOME = $h; MONETSHOT_DEV_SCRIPT = $devScript }
  Start-App $debug $vars | Out-Null
  if (-not (Wait-Log $h 'capture backend' 60)) { Fail 'window: the app never started'; return }

  # The window to record: ours, at a known place and size, one flat colour.
  $title = 'MS Target Window'
  $form = @"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
`$f = New-Object System.Windows.Forms.Form
`$f.Text = '$title'
`$f.StartPosition = 'Manual'
`$f.Location = New-Object System.Drawing.Point(120, 160)
`$f.ClientSize = New-Object System.Drawing.Size(640, 400)
`$f.BackColor = [System.Drawing.Color]::FromArgb(200, 90, 60)
`$f.TopMost = `$true
[System.Windows.Forms.Application]::Run(`$f)
"@
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($form))
  $formProc = Start-Process pwsh -ArgumentList '-NoProfile', '-EncodedCommand', $enc -PassThru
  try {
    $until = (Get-Date).AddSeconds(30)
    $win = $null
    while (-not $win -and (Get-Date) -lt $until) { $win = Window-Rect $title; if (-not $win) { Start-Sleep -Milliseconds 300 } }
    if (-not $win) { Fail "window: our test window never appeared"; return }
    Start-Sleep 1
    $win = Window-Rect $title
    Write-Host "test window at $($win | ConvertTo-Json -Compress)"

    # A second launch with "toggle" hands it to the running app: the ring's tap.
    Start-App $debug $vars @('toggle') -Second | Out-Null
    $picked = Wait-Log $h 'window: (picked the card|FAIL)[^\n]*' 40
    if ($picked) { Write-Host $picked.Value }
    if (-not $picked -or $picked.Value -match 'FAIL') { Shot '7-picker' | Out-Null; Fail "window: our picker didn't pick the window ($(if ($picked) { $picked.Value } else { 'no picker' }))"; return }
    if (-not (Wait-Log $h 'recording into' 30)) { Fail 'window: no recording after the pick'; return }
    $hold = Wait-Log $h 'window: hold at (\d+),(\d+)' 30
    Start-Sleep 2
    Shot '7-window-recording' | Out-Null
    if (-not $hold) { Fail 'window: the pill never showed its stop ring'; return }
    $x = [int]$hold.Groups[1].Value; $y = [int]$hold.Groups[2].Value

    # A stray click on the ring must not stop the take...
    [MsWin]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 300
    [MsWin]::Down() | Out-Null; Start-Sleep -Milliseconds 120; [MsWin]::Up() | Out-Null
    Start-Sleep 2
    if ((Read-Log $h) -match 'stop requested') { Fail 'hold-to-stop: a 0.12 s click stopped the take' }
    else { Ok 'hold-to-stop: a short click on the ring leaves the take running' }
    # ...holding it does.
    [MsWin]::Down() | Out-Null; Start-Sleep -Milliseconds 1300; [MsWin]::Up() | Out-Null
    if (Wait-Log $h 'stop requested' 5) { Ok 'hold-to-stop: holding the ring 1.3 s stops the take' }
    else { Fail 'hold-to-stop: holding the ring 1.3 s did not stop the take'; [void](Start-App $debug $vars @('toggle') -Second) }
    $reel = Wait-Take $h 60
  } finally {
    Stop-App
    if ($formProc -and -not $formProc.HasExited) { $formProc.Kill() }
    Save-Log $h '7-window'
  }
  ((Read-Log $h) -split "`n" | Where-Object { $_ -match 'window:|picked|recording into|stop|ERROR' }) -join "`n" | Write-Host
  if (-not $reel) { Fail 'window: no take'; return }
  Copy-Reel $reel (Join-Path $Out 'take-window.reel') | Out-Null
  $meta = Get-Content -Raw (Join-Path $reel 'meta.json') | ConvertFrom-Json
  $video = Join-Path $reel 'screen.mp4'
  $v = Probe $video
  Write-Host "window take: source $($meta.source), meta $($meta.pixelWidth)x$($meta.pixelHeight), video $($v.width)x$($v.height), $($v.frames) frames; window frame $($win.w)x$($win.h)"
  if ($meta.source -eq 'window') { Ok 'the take is a window recording' } else { Fail "window: meta.source is $($meta.source)" }
  if ([math]::Abs($meta.pixelWidth - $win.w) -le 2 -and [math]::Abs($meta.pixelHeight - $win.h) -le 2) { Ok "the take is the window's size: $($meta.pixelWidth)x$($meta.pixelHeight) (window $($win.w)x$($win.h))" }
  else { Fail "window: take $($meta.pixelWidth)x$($meta.pixelHeight), window $($win.w)x$($win.h)" }
  if ($v.width -ne [int]$meta.pixelWidth -or $v.height -ne [int]$meta.pixelHeight) { Fail "window: screen.mp4 is $($v.width)x$($v.height), meta says $($meta.pixelWidth)x$($meta.pixelHeight)" }
  # And it shows that window: its middle is the form's colour.
  $mid = @{ x = [int]($v.width / 2) - 40; y = [int]($v.height / 2) - 40; w = 80; h = 80 }
  $c = Mean-Rgb (Crop-Rgb $video 1.0 $mid)
  if ([math]::Abs($c[0] - 200) -lt 30 -and [math]::Abs($c[1] - 90) -lt 30 -and [math]::Abs($c[2] - 60) -lt 30) { Ok "the take shows the window (middle rgb $($c -join ','))" }
  else { Fail "window: the take's middle is rgb $($c -join ','), not the window's 200,90,60" }
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
        'install' { Stage-Install }
        'window' { Stage-Window }
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
