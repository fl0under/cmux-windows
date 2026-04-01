# cmux-windows Shell Integration for Fish (WSL)
# Place in ~/.config/fish/conf.d/cmux-shell-integration.fish

# --- OSC helpers ---

function _cmux_osc7
    # Report current directory via OSC 7
    printf '\e]7;file://%s%s\a' (hostname) (pwd)
end

function _cmux_osc133
    # Prompt marking via OSC 133
    printf '\e]133;%s\a' $argv[1]
end

function _cmux_osc9
    # Send notification via OSC 9
    printf '\e]9;%s\a' $argv[1]
end

function _cmux_osc777
    # Send notification via OSC 777
    printf '\e]777;notify;%s;%s\a' $argv[1] $argv[2]
end

# --- Notification helper ---

function cmux-notify -d "Send a notification to cmux"
    set -l title "Notification"
    set -l body ""

    if test (count $argv) -ge 1
        set title $argv[1]
    end
    if test (count $argv) -ge 2
        set body $argv[2]
    end

    _cmux_osc777 $title $body
end

# --- Prompt integration ---

# Fish uses event handlers for prompt hooks

function _cmux_postexec --on-event fish_postexec
    set -l exit_code $status
    _cmux_osc133 "D;$exit_code"
end

function _cmux_preexec --on-event fish_preexec
    _cmux_osc133 "C"
end

function _cmux_prompt --on-event fish_prompt
    _cmux_osc7
    _cmux_osc133 "A"
end

# Inject OSC 133;B at the end of the prompt
function fish_prompt_cmux_suffix
    _cmux_osc133 "B"
end

# Override right prompt to include our suffix if not already set
if not functions -q _cmux_original_fish_prompt
    if functions -q fish_prompt
        functions -c fish_prompt _cmux_original_fish_prompt
    end
end

function fish_prompt
    if functions -q _cmux_original_fish_prompt
        _cmux_original_fish_prompt
    end
    fish_prompt_cmux_suffix
end

# --- Long-running command notification ---

set -g CMUX_NOTIFY_THRESHOLD 30
set -g _cmux_command_start 0

function _cmux_timer_preexec --on-event fish_preexec
    set -g _cmux_command_start (date +%s)
end

function _cmux_timer_postexec --on-event fish_postexec
    if test $_cmux_command_start -gt 0
        set -l now (date +%s)
        set -l elapsed (math $now - $_cmux_command_start)
        if test $elapsed -ge $CMUX_NOTIFY_THRESHOLD
            cmux-notify "Command finished" "Took {$elapsed}s (exit $status)"
        end
        set -g _cmux_command_start 0
    end
end

echo "cmux shell integration loaded (fish)" >&2
