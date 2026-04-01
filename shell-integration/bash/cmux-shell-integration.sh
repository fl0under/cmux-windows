#!/bin/bash
# cmux-windows Shell Integration for Bash/Zsh (WSL & Git Bash)
# Source this in your .bashrc or .zshrc to enable:
#   - CWD tracking (OSC 7) for sidebar display
#   - Notification support (OSC 9/99/777) for agent-waiting detection
#   - Prompt marking (OSC 133) for semantic zones

# Detect shell
_cmux_shell="${ZSH_VERSION:+zsh}"
_cmux_shell="${_cmux_shell:-bash}"

# --- OSC helpers ---

_cmux_osc7() {
    # Report current directory via OSC 7
    printf '\e]7;file://%s%s\a' "${HOSTNAME}" "${PWD}"
}

_cmux_osc133() {
    # Prompt marking via OSC 133
    printf '\e]133;%s\a' "$1"
}

_cmux_osc9() {
    # Send notification via OSC 9
    printf '\e]9;%s\a' "$1"
}

_cmux_osc777() {
    # Send notification via OSC 777 (rxvt format)
    printf '\e]777;notify;%s;%s\a' "$1" "$2"
}

# --- Notification helper ---

cmux-notify() {
    local title="${1:-Notification}"
    local body="${2:-}"
    _cmux_osc777 "$title" "$body"
}

# --- Prompt integration ---

if [ "$_cmux_shell" = "zsh" ]; then
    # Zsh hooks
    _cmux_precmd() {
        local exit_code=$?
        # Report CWD
        _cmux_osc7
        # Mark previous command end (OSC 133;D)
        _cmux_osc133 "D;${exit_code}"
        # Mark prompt start (OSC 133;A)
        _cmux_osc133 "A"
    }

    _cmux_preexec() {
        # Mark command start (OSC 133;C)
        _cmux_osc133 "C"
    }

    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _cmux_precmd
    add-zsh-hook preexec _cmux_preexec

    # Mark prompt end (OSC 133;B) — injected into PS1
    PS1="%{$(_cmux_osc133 'B')%}${PS1}"
else
    # Bash hooks via PROMPT_COMMAND and DEBUG trap
    _cmux_prompt_command() {
        local exit_code=$?
        # Report CWD
        _cmux_osc7
        # Mark previous command end (OSC 133;D)
        _cmux_osc133 "D;${exit_code}"
        # Mark prompt start (OSC 133;A)
        _cmux_osc133 "A"
    }

    _cmux_preexec_bash() {
        # Only fire once per command (not for PROMPT_COMMAND itself)
        if [ -n "$_cmux_preexec_ready" ]; then
            unset _cmux_preexec_ready
            _cmux_osc133 "C"
        fi
    }

    # Append to PROMPT_COMMAND
    PROMPT_COMMAND="_cmux_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

    # Inject OSC 133;B into PS1
    PS1="\[$(_cmux_osc133 'B')\]${PS1}"

    # Use DEBUG trap for preexec
    trap '_cmux_preexec_bash' DEBUG
    _cmux_preexec_ready=1
fi

# --- Long-running command notification ---

# Notify when a command takes longer than N seconds
CMUX_NOTIFY_THRESHOLD=${CMUX_NOTIFY_THRESHOLD:-30}

_cmux_command_start=0

if [ "$_cmux_shell" = "zsh" ]; then
    _cmux_timer_preexec() {
        _cmux_command_start=$SECONDS
    }
    add-zsh-hook preexec _cmux_timer_preexec

    _cmux_timer_precmd() {
        if [ "$_cmux_command_start" -gt 0 ]; then
            local elapsed=$(( SECONDS - _cmux_command_start ))
            if [ "$elapsed" -ge "$CMUX_NOTIFY_THRESHOLD" ]; then
                cmux-notify "Command finished" "Took ${elapsed}s (exit $?)"
            fi
            _cmux_command_start=0
        fi
    }
    add-zsh-hook precmd _cmux_timer_precmd
fi

echo "cmux shell integration loaded ($_cmux_shell)" >&2
