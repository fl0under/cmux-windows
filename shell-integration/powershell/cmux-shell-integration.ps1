# cmux-windows Shell Integration for PowerShell
# Source this in your PowerShell profile ($PROFILE) to enable:
#   - CWD tracking (OSC 7) for sidebar display
#   - Notification support (OSC 9/99/777) for agent-waiting detection
#   - Prompt marking (OSC 133) for semantic zones

function Set-CmuxOsc7 {
    # Report current directory via OSC 7
    $uri = "file:///$($env:COMPUTERNAME)/$($PWD.Path -replace '\\','/')"
    $osc = [char]0x1b + "]7;$uri" + [char]0x07
    Write-Host -NoNewline $osc
}

function Set-CmuxOsc133 {
    param([string]$Type)
    # Prompt marking via OSC 133
    $osc = [char]0x1b + "]133;$Type" + [char]0x07
    Write-Host -NoNewline $osc
}

function Send-CmuxNotification {
    param(
        [string]$Title = "cmux",
        [string]$Body = ""
    )
    # Send notification via OSC 9
    $osc = [char]0x1b + "]9;$Title`: $Body" + [char]0x07
    Write-Host -NoNewline $osc
}

# Override prompt function to inject OSC sequences
$_cmux_original_prompt = $function:prompt

function prompt {
    # Mark prompt start (OSC 133;A)
    Set-CmuxOsc133 "A"

    # Report CWD (OSC 7)
    Set-CmuxOsc7

    # Call original prompt
    $result = & $_cmux_original_prompt

    # Mark prompt end / command start (OSC 133;B)
    Set-CmuxOsc133 "B"

    return $result
}

# Hook into command completion to mark command end
$ExecutionContext.InvokeCommand.PostCommandLookupAction = {
    param($CommandName, $CommandLookupEventArgs)
    # Mark command end (OSC 133;D) with exit code
    Set-CmuxOsc133 "D;$LASTEXITCODE"
}

# Notify helper for long-running commands
function Invoke-CmuxNotifyOnComplete {
    param(
        [scriptblock]$Command,
        [string]$Title = "Command Complete"
    )
    & $Command
    $exitCode = $LASTEXITCODE
    $status = if ($exitCode -eq 0) { "succeeded" } else { "failed (exit $exitCode)" }
    Send-CmuxNotification -Title $Title -Body "Command $status"
}

# Export aliases
Set-Alias -Name cmux-notify -Value Send-CmuxNotification
Set-Alias -Name cmux-run -Value Invoke-CmuxNotifyOnComplete

Write-Host "cmux shell integration loaded" -ForegroundColor DarkGray
