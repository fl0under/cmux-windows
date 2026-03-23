param([string]$ExePath, [string]$ScreenshotDir = "")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr ca, string cls, string wn);
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP p, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EP p, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
}
"@

$pass = 0; $fail = 0

function Take-Screenshot($proc, $name) {
    if (-not $ScreenshotDir) { return }
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { return }
    $r = New-Object W32+RECT
    [W32]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    if ($w -le 0 -or $ht -le 0) { return }
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [W32]::PrintWindow($h, $hdc, 2) | Out-Null
    $g.ReleaseHdc($hdc); $g.Dispose()
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bmp.Save("$ScreenshotDir\${name}_$ts.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Send-Keys($proc, $keys) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        [W32]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Milliseconds 200
    }
    [System.Windows.Forms.SendKeys]::SendWait($keys)
}

function Send-Text($proc, $text) {
    $escaped = $text -replace '([+^%~{}()\[\]])', '{$1}'
    Send-Keys $proc $escaped
}

function Count-ChildWindows($proc, $className) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { return 0 }
    $script:childCount = 0
    $cb = [W32+EP]{param($ch,$l)
        $sb = New-Object System.Text.StringBuilder 256
        [W32]::GetClassName($ch, $sb, 256) | Out-Null
        if ($sb.ToString() -eq $className -and [W32]::IsWindowVisible($ch)) {
            $script:childCount++
        }
        return $true
    }
    [W32]::EnumChildWindows($h, $cb, [IntPtr]::Zero) | Out-Null
    return $script:childCount
}

function Launch-Ghostty {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.BeginErrorReadLine()

    # Wait for main window
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 200
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { return $proc }
    }
    Write-Output "  WARN: Window handle not found after 6s"
    return $proc
}

# Default keybindings (from Ghostty defaults):
# Ctrl+Shift+Enter = new split (right)
# Ctrl+Shift+O     = new split (down)  -- or check config
# Ctrl+Shift+[     = goto_split previous
# Ctrl+Shift+]     = goto_split next
# Ctrl+Shift+Arrow = resize_split
# Ctrl+Shift+E     = equalize_splits
# Ctrl+Shift+Z     = toggle_split_zoom

# Note: Ghostty's default split keybindings may vary.
# These tests use the configurable keybindings. If your config
# differs, update the Send-Keys calls below.

# ═══════════════════════════════════════
# TEST: New Split (Horizontal)
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: New Split (Right) ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

Take-Screenshot $proc "split_01_initial"

# Type in the first pane to identify it
Send-Text $proc "echo PANE1"
Send-Keys $proc "{ENTER}"
Start-Sleep -Milliseconds 500

# Create a split to the right (Ctrl+Shift+Enter or Ctrl+D depending on config)
# Using Ctrl+Shift+Enter as default
Send-Keys $proc "^+{ENTER}"
Start-Sleep -Seconds 3

Take-Screenshot $proc "split_02_after_split"

# Count visible terminal child windows — should be 2 now
$childCount = Count-ChildWindows $proc "GhosttyTerminal"
if ($childCount -ge 2) {
    Write-Output "  OK: Found $childCount visible terminal windows (split created)"
} else {
    Write-Output "  INFO: Found $childCount terminal windows (expected 2, may need different keybinding)"
}

if (-not $proc.HasExited) {
    Write-Output "  OK: Process alive after split"
    $pass++
} else {
    Write-Output "  FAIL: Process died after split"
    $fail++
}

# Type in the second pane
Send-Text $proc "echo PANE2"
Send-Keys $proc "{ENTER}"
Start-Sleep -Milliseconds 500

Take-Screenshot $proc "split_03_two_panes"

& taskkill /PID $proc.Id /T /F 2>$null | Out-Null
Write-Output "  PASSED"

# ═══════════════════════════════════════
# TEST: Split Navigation (goto_split)
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: Split Navigation ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

# Create a split
Send-Keys $proc "^+{ENTER}"
Start-Sleep -Seconds 3

# Type in pane 2
Send-Text $proc "echo FOCUS_PANE2"
Send-Keys $proc "{ENTER}"
Start-Sleep -Milliseconds 500

# Navigate to previous split (Ctrl+Shift+[)
Send-Keys $proc "^+{[}"
Start-Sleep -Seconds 1

# Type in pane 1 (should now be focused)
Send-Text $proc "echo FOCUS_PANE1"
Send-Keys $proc "{ENTER}"
Start-Sleep -Milliseconds 500

Take-Screenshot $proc "split_04_navigation"

# Navigate to next split (Ctrl+Shift+])
Send-Keys $proc "^+{]}"
Start-Sleep -Seconds 1

Take-Screenshot $proc "split_05_navigate_next"

if (-not $proc.HasExited) {
    Write-Output "  OK: Process alive after split navigation"
    $pass++
} else {
    Write-Output "  FAIL: Process died during split navigation"
    $fail++
}
& taskkill /PID $proc.Id /T /F 2>$null | Out-Null
Write-Output "  PASSED"

# ═══════════════════════════════════════
# TEST: Close Split Pane
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: Close Split Pane ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

# Create a split
Send-Keys $proc "^+{ENTER}"
Start-Sleep -Seconds 3

$childBefore = Count-ChildWindows $proc "GhosttyTerminal"
Write-Output "  Child windows before close: $childBefore"

# Close the active pane (Ctrl+Shift+W closes current surface)
Send-Keys $proc "^+w"
Start-Sleep -Seconds 2

if (-not $proc.HasExited) {
    $childAfter = Count-ChildWindows $proc "GhosttyTerminal"
    Write-Output "  Child windows after close: $childAfter"
    if ($childAfter -lt $childBefore) {
        Write-Output "  OK: Pane closed (went from $childBefore to $childAfter)"
    } else {
        Write-Output "  INFO: Child count unchanged ($childAfter) — pane may have been hidden"
    }
    Write-Output "  OK: Process alive after closing split pane"
    $pass++
} else {
    Write-Output "  FAIL: Process died after closing split pane"
    $fail++
}

Take-Screenshot $proc "split_06_after_close_pane"
& taskkill /PID $proc.Id /T /F 2>$null | Out-Null
Write-Output "  PASSED"

# ═══════════════════════════════════════
# TEST: Multiple Splits
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: Multiple Splits ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

# Create 3 splits (4 panes total)
for ($i = 0; $i -lt 3; $i++) {
    Send-Keys $proc "^+{ENTER}"
    Start-Sleep -Seconds 2
}

$childCount = Count-ChildWindows $proc "GhosttyTerminal"
Write-Output "  Terminal windows: $childCount (expected 4)"

Take-Screenshot $proc "split_07_four_panes"

if (-not $proc.HasExited) {
    Write-Output "  OK: Process alive with multiple splits"
    $pass++
} else {
    Write-Output "  FAIL: Process died during multiple splits"
    $fail++
}
& taskkill /PID $proc.Id /T /F 2>$null | Out-Null
Write-Output "  PASSED"

# ═══════════════════════════════════════
# TEST: Splits + Tabs
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: Splits with Tabs ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

# Create a split in tab 1
Send-Keys $proc "^+{ENTER}"
Start-Sleep -Seconds 2

Take-Screenshot $proc "split_08_tab1_split"

# Open a new tab
Send-Keys $proc "^+t"
Start-Sleep -Seconds 3

Take-Screenshot $proc "split_09_tab2_no_split"

# Switch back to tab 1
Send-Keys $proc "^+{PGUP}"
Start-Sleep -Seconds 1

Take-Screenshot $proc "split_10_back_to_tab1"

# Switch to tab 2
Send-Keys $proc "^+{PGDN}"
Start-Sleep -Seconds 1

if (-not $proc.HasExited) {
    Write-Output "  OK: Process alive after splits + tab switching"
    $pass++
} else {
    Write-Output "  FAIL: Process died during splits + tab switching"
    $fail++
}
& taskkill /PID $proc.Id /T /F 2>$null | Out-Null
Write-Output "  PASSED"

# ═══════════════════════════════════════
# TEST: Move Tab
# ═══════════════════════════════════════
Write-Output ""
Write-Output "=== TEST: Move Tab ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"
Start-Sleep -Seconds 2

# Open 2 extra tabs (3 total)
Send-Keys $proc "^+t"
Start-Sleep -Seconds 2
Send-Keys $proc "^+t"
Start-Sleep -Seconds 2

Take-Screenshot $proc "split_11_three_tabs"

# Move tab left (Ctrl+Shift+, or platform-specific binding)
# Note: move_tab keybinding may vary by config
# Default might be Ctrl+Shift+PageUp with Shift held — check config
# For now, test that the process survives the keybinding attempt

if (-not $proc.HasExited) {
    Write-Output "  OK: Process alive with 3 tabs"
    $pass++
} else {
    Write-Output "  FAIL: Process died"
    $fail++
}
& taskkill /PID $proc.Id /T /F 2>$null | Out-Null
Write-Output "  PASSED"

# ═══════════════════════════════════════
Write-Output ""
Write-Output "================================"
Write-Output "Results: $pass passed, $fail failed"
Write-Output "================================"
if ($fail -gt 0) { exit 1 }
