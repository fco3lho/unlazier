#!/bin/bash
# shellcheck disable=SC2016  # jq programs use $variables inside single quotes on purpose
# Unlazier installer for Linux and macOS.
#
# Usage:
#   ./install.sh [--harness <names|all>] [--yes] [--uninstall]
#   curl -fsSL https://github.com/fco3lho/unlazier/releases/latest/download/install.sh | bash
#
#   --harness    comma-separated names (claude,opencode,codex,copilot,gemini,amp,kiro,cline,devin)
#                or "all". Without it, an interactive menu is shown.
#   --yes        answer "yes" to confirmations (removal of files left by version 1).
#   --uninstall  remove Unlazier from the selected harnesses.
#
# Every harness receives the same three layers: the rules (a marked block in its global
# instructions file), a reinforcement hook that re-injects a short reminder, and a usage
# line inside that reminder. Existing user content is never replaced and no backups are made.

set -euo pipefail

REPO="fco3lho/unlazier"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

ALL_HARNESSES="claude opencode codex copilot gemini amp kiro cline devin"
RULE_NAMES="structure correctness style completeness performance testability async naming documentation parallelism"
PAYLOAD_FILES="AGENTS.md reminder.md hooks/inject.sh hooks/alert.sh statusline/claude-statusline.sh plugins/opencode.ts plugins/amp.ts"
MARKER_START="<!-- unlazier:start -->"
MARKER_END="<!-- unlazier:end -->"
PAYLOAD_DIR_NAME="unlazier"

# Version 2.0 used the name "unlazier-ai" for its markers, folders, and files.
LEGACY_NAME="unlazier-ai"
LEGACY_MARKER_START="<!-- unlazier-ai:start -->"
LEGACY_MARKER_END="<!-- unlazier-ai:end -->"

# Version 1 files are recognized by checksum (POSIX cksum: CRC and size) so that files the
# user edited are never removed.
V1_RULE_CHECKSUMS="structure 777963179 1423
correctness 1739082089 1122
style 1567952051 1306
completeness 113781707 1096
performance 1314288283 723
testability 3565322618 948
async 3753529978 969
naming 1175597733 1247
documentation 927091628 979"
V1_SKILL_CHECKSUMS="bugfix 1429495546 1065
code-review 4077940051 2292
refactoring 3722468995 1349"
V1_OPENCODE_CONFIG='{"$schema":"https://opencode.ai/config.json","instructions":["~/.config/opencode/AGENTS.md","~/.config/opencode/rules/*.md"],"skills":{"paths":["~/.config/opencode/skills"]}}'
V1_GLOBAL_CHECKSUM="2969683781 6213"

# Hook entries, the status line, and Cline hook scripts are ours when they run one of the payload
# scripts, under the current folder name or the 2.0 one; a user's own path that only mentions
# unlazier (a fork, for example) is not. The pattern also fits raw JSON, where a separator may be
# written as \\ or \/.
OWNED_SCRIPT_PATTERN='[/\\]unlazier(-ai)?[/\\]+(inject|alert|claude-statusline)\.(sh|ps1)'

MODE="install"
ASSUME_YES=false
REQUESTED_HARNESSES=""
SOURCE_DIR=""
DOWNLOAD_DIR=""
HAS_JQ=false
NOTICES=""

log() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
add_notice() { NOTICES="${NOTICES}  - $*
"; }

# ---------------------------------------------------------------------------
# Harness adapters: the only part that differs between harnesses.
# ---------------------------------------------------------------------------

harness_label() {
    case "$1" in
        claude) echo "Claude Code" ;;
        opencode) echo "OpenCode" ;;
        codex) echo "Codex CLI" ;;
        copilot) echo "GitHub Copilot CLI" ;;
        gemini) echo "Gemini CLI" ;;
        amp) echo "Amp" ;;
        kiro) echo "Kiro" ;;
        cline) echo "Cline" ;;
        devin) echo "Devin Desktop (formerly Windsurf)" ;;
        *) die "unknown harness '$1'" ;;
    esac
}

harness_home() {
    case "$1" in
        claude) echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
        opencode) echo "${XDG_CONFIG_HOME:-$HOME/.config}/opencode" ;;
        codex) echo "${CODEX_HOME:-$HOME/.codex}" ;;
        copilot) echo "${COPILOT_HOME:-$HOME/.copilot}" ;;
        gemini) echo "${GEMINI_CLI_HOME:-$HOME}/.gemini" ;;
        amp) echo "${XDG_CONFIG_HOME:-$HOME/.config}/amp" ;;
        kiro) echo "${KIRO_HOME:-$HOME/.kiro}" ;;
        cline) echo "$HOME/Documents/Cline" ;;
        devin) echo "$HOME/.devin" ;;
        *) die "unknown harness '$1'" ;;
    esac
}

# Hook commands carry the harness home inside double quotes, where these characters would run
# code or end the quoting each time the hook runs.
assert_safe_home() {
    local home
    home="$(harness_home "$1")"
    case "$home" in
        *'$'* | *'`'* | *'"'* | *\\*)
            die "$(harness_label "$1"): the folder $home contains \$, \`, \", or \\, which a hook command cannot carry safely; nothing was installed. Use a folder without these characters."
            ;;
    esac
}

harness_binaries() {
    case "$1" in
        kiro) echo "kiro-cli kiro" ;;
        devin) echo "devin-desktop devin windsurf" ;;
        *) echo "$1" ;;
    esac
}

# Harnesses that always load every file in a rules folder get one small file per rule there,
# which keeps each file short (Claude Code recommends under 200 lines per file) and leaves the
# user's own instructions file untouched. Prints nothing for the other harnesses.
rules_folder() {
    local home
    home="$(harness_home "$1")"
    case "$1" in
        claude|devin) echo "$home/rules" ;;
        kiro) echo "$home/steering" ;;
        cline) echo "$home/Rules" ;;
        # Copilot's instructions folder holds path-specific files, so it is not used.
        opencode|codex|amp|copilot|gemini) ;;
        *) die "unknown harness '$1'" ;;
    esac
}

# The single global instructions file that holds the rules block, for harnesses without a
# rules folder.
rules_file() {
    local home
    home="$(harness_home "$1")"
    case "$1" in
        opencode|codex|amp) echo "$home/AGENTS.md" ;;
        copilot) echo "$home/copilot-instructions.md" ;;
        gemini) echo "$home/GEMINI.md" ;;
        *) die "'$1' uses a rules folder, not a single rules file" ;;
    esac
}

is_detected() {
    local binary
    for binary in $(harness_binaries "$1"); do
        command -v "$binary" >/dev/null 2>&1 && return 0
    done
    [ -d "$(harness_home "$1")" ]
}

hook_command() {
    printf 'bash "%s/%s/inject.sh" %s %s' "$(harness_home "$1")" "$PAYLOAD_DIR_NAME" "$1" "$2"
}

alert_command() {
    printf 'bash "%s/%s/alert.sh"' "$(harness_home "$1")" "$PAYLOAD_DIR_NAME"
}

# Claude Code, Codex, Gemini CLI, and Devin share the same hook layout:
# {"hooks": {"<Event>": [{"matcher": "...", "hooks": [{"type": "command", "command": "..."}]}]}}.
# Entries whose command matches $owned (OWNED_SCRIPT_PATTERN) are ours; everything else is left
# untouched. add_hook replaces only our entry for the same matcher, because one event can carry
# several of ours (Claude Code PreToolUse has both the question alert and the subagent gate).
JQ_HOOK_HELPERS='
def without_ours_where(targeted):
    if type == "array" then
        map(if (targeted) and (.hooks | type) == "array"
            then .hooks |= map(select((.command // "") | tostring | test($owned) | not))
            else . end)
        | map(select((.hooks | type) != "array" or (.hooks | length) > 0))
    else . end;
def without_ours: without_ours_where(true);
def add_hook($event; $matcher; $command):
    .hooks[$event] = (((.hooks // {})[$event] // []) | without_ours_where((.matcher // "") == $matcher))
        + [(if $matcher == "" then {} else {matcher: $matcher} end)
           + {hooks: [{type: "command", command: $command}]}];
def remove_ours:
    if (.hooks | type) == "object" then
        .hooks |= (with_entries(.value |= without_ours)
            | with_entries(select((.value | type) != "array" or (.value | length) > 0)))
        | if .hooks == {} then del(.hooks) else . end
    else . end;
'

# Replaces the file's content with the output of a command, which may read the file. The output
# goes to a private temporary file first, so a failing command leaves the file as it was; it is
# then copied into the file rather than moved over it, so the file keeps its mode, owner, and
# symbolic link (dotfiles managers link these configs).
rewrite_file() {
    local file="$1" temporary_file
    shift
    temporary_file="$(mktemp "$(dirname "$file")/.unlazier.XXXXXX")" || return 1
    if "$@" > "$temporary_file" && cat "$temporary_file" > "$file"; then
        rm -f "$temporary_file"
        return 0
    fi
    rm -f "$temporary_file"
    return 1
}

jq_on_text() {
    local text="$1"
    shift
    printf '%s' "$text" | jq "$@"
}

# Applies a jq program to a JSON config file in place. A missing file starts as {}; an
# unreadable one is left untouched so a hand-edited config is never damaged.
update_json_file() {
    local file="$1" program="$2"
    shift 2
    local input="{}"
    if [ -f "$file" ]; then
        if ! jq empty "$file" >/dev/null 2>&1; then
            warn "$file is not valid JSON; skipped. Add the Unlazier hook by hand (see README)."
            return 1
        fi
        input="$(cat "$file")"
        # jq reads a blank file as no input at all, which would empty it on write.
        [ -n "$(printf '%s' "$input" | tr -d '[:space:]')" ] || input="{}"
    fi
    mkdir -p "$(dirname "$file")"
    # Explicit checks: callers run this inside conditions, where errexit does not apply.
    if ! rewrite_file "$file" jq_on_text "$input" --arg owned "$OWNED_SCRIPT_PATTERN" "$@" "$JQ_HOOK_HELPERS $program"; then
        warn "could not update $file; it was left unchanged."
        return 1
    fi
}

# Removes our entries; deletes the file if nothing else remains in it. A file without our
# entries is not rewritten, so its formatting stays as the user left it.
clean_json_file() {
    local file="$1" program="$2"
    [ -f "$file" ] && grep -Eq "$OWNED_SCRIPT_PATTERN" "$file" || return 0
    update_json_file "$file" "$program" || return 0
    if [ "$(jq -c . "$file")" = "{}" ]; then
        rm -f "$file"
    fi
}

register_hooks() {
    local harness="$1" home
    home="$(harness_home "$harness")"
    case "$harness" in
        claude)
            # The reminder reaches the model only with a prompt; the PostToolUse hook refreshes the
            # usage line after each subagent, the long step of a turn, and the PreToolUse hook
            # blocks a new subagent while the usage ladder forbids one.
            update_json_file "$home/settings.json" \
                'add_hook("UserPromptSubmit"; ""; $prompt) | add_hook("SessionStart"; "compact"; $compact)
                 | add_hook("PostToolUse"; "Agent"; $subagent) | add_hook("PreToolUse"; "Agent"; $dispatch)' \
                --arg prompt "$(hook_command claude prompt)" --arg compact "$(hook_command claude compact)" \
                --arg subagent "$(hook_command claude subagent)" --arg dispatch "$(hook_command claude dispatch)"
            ;;
        codex)
            # Same usage hooks as Claude Code. The matcher is unanchored so it also matches the
            # namespaced spawn_agent of Codex's opt-in multi_agent_v2.
            update_json_file "$home/hooks.json" \
                'add_hook("UserPromptSubmit"; ""; $prompt) | add_hook("SessionStart"; "compact"; $compact)
                 | add_hook("PostToolUse"; "spawn_agent"; $subagent) | add_hook("PreToolUse"; "spawn_agent"; $dispatch)' \
                --arg prompt "$(hook_command codex prompt)" --arg compact "$(hook_command codex compact)" \
                --arg subagent "$(hook_command codex subagent)" --arg dispatch "$(hook_command codex dispatch)" \
                && add_notice "Codex: open Codex and run /hooks once to trust the Unlazier hooks."
            ;;
        gemini)
            update_json_file "$home/settings.json" \
                'add_hook("BeforeAgent"; ""; $prompt)' \
                --arg prompt "$(hook_command gemini prompt)"
            ;;
        devin)
            # Devin documents no output format for PostCompaction, so only the prompt hook is used.
            update_json_file "$(devin_hooks_file)" \
                'add_hook("UserPromptSubmit"; ""; $prompt)' \
                --arg prompt "$(hook_command devin prompt)"
            ;;
        kiro)
            mkdir -p "$home/hooks"
            jq -n --arg prompt "$(hook_command kiro prompt)" --arg compact "$(hook_command kiro compact)" '
                {version: "v1", hooks: [
                    {name: "unlazier-prompt", trigger: "UserPromptSubmit",
                     action: {type: "command", command: $prompt}, timeout: 30},
                    {name: "unlazier-compact", trigger: "PostCompact",
                     action: {type: "command", command: $compact}, timeout: 30}]}' \
                > "$home/hooks/unlazier.json"
            ;;
        cline)
            write_cline_hook "$home/Hooks/UserPromptSubmit" "exec $(hook_command cline prompt)" \
                && add_notice "Cline: turn on 'Enable Hooks' in Cline Feature Settings so the reminder and alerts run."
            ;;
        opencode|amp)
            install_plugin "$harness"
            ;;
        copilot)
            add_notice "Copilot CLI: Copilot ignores prompt-hook output, so there is no reminder hook."
            return 1
            ;;
        *) die "unknown harness '$harness'" ;;
    esac
}

# Layer 4: three beeps when the agent asks for permission, asks a question, or finishes its
# turn, using each harness's own events. OpenCode and Amp get it from their plugin.
register_alerts() {
    local harness="$1" home alert
    home="$(harness_home "$harness")"
    alert="$(alert_command "$harness")"
    case "$harness" in
        claude)
            update_json_file "$home/settings.json" \
                'add_hook("Notification"; "permission_prompt"; $alert)
                 | add_hook("PreToolUse"; "AskUserQuestion"; $alert) | add_hook("Stop"; ""; $alert)' \
                --arg alert "$alert"
            ;;
        codex)
            update_json_file "$home/hooks.json" \
                'add_hook("PermissionRequest"; ""; $alert)
                 | add_hook("PreToolUse"; "^request_user_input$"; $alert) | add_hook("Stop"; ""; $alert)' \
                --arg alert "$alert"
            ;;
        gemini)
            # Gemini's Notification event covers both permission prompts and questions.
            update_json_file "$home/settings.json" \
                'add_hook("Notification"; ""; $alert) | add_hook("AfterAgent"; ""; $alert)' \
                --arg alert "$alert"
            ;;
        devin)
            update_json_file "$(devin_hooks_file)" \
                'add_hook("PermissionRequest"; ""; $alert)
                 | add_hook("PreToolUse"; "^ask_user_question$"; $alert) | add_hook("Stop"; ""; $alert)' \
                --arg alert "$alert"
            ;;
        kiro)
            # Kiro has no permission or question event; only the end of the turn beeps.
            mkdir -p "$home/hooks"
            jq -n --arg alert "$alert" '{version: "v1", hooks: [{name: "unlazier-alert", trigger: "Stop",
                action: {type: "command", command: $alert}, timeout: 10}]}' > "$home/hooks/unlazier-alert.json"
            ;;
        copilot)
            mkdir -p "$home/hooks"
            jq -n --arg alert "$alert" '{version: 1, hooks: {
                notification: [{matcher: "permission_prompt|elicitation_dialog", type: "command", bash: $alert, timeoutSec: 10}],
                agentStop: [{type: "command", bash: $alert, timeoutSec: 10}]}}' > "$home/hooks/unlazier.json"
            ;;
        cline)
            # Cline wires no permission event; its PreToolUse hook sees every tool, so the script
            # beeps only for the question tools.
            write_cline_hook "$home/Hooks/PreToolUse" "input=\"\$(cat)\"
if printf '%s' \"\$input\" | grep -Eq '\"toolName\" *: *\"ask_(question|followup_question)\"'; then
    $alert
fi
echo '{\"cancel\":false}'" \
                && write_cline_hook "$home/Hooks/TaskComplete" "$alert
echo '{\"cancel\":false}'"
            ;;
        opencode|amp) ;;
        *) die "unknown harness '$harness'" ;;
    esac
}

unregister_hooks() {
    local harness="$1" home
    home="$(harness_home "$harness")"
    case "$harness" in
        claude|gemini) clean_json_file "$home/settings.json" 'remove_ours' ;;
        codex) clean_json_file "$home/hooks.json" 'remove_ours' ;;
        devin) clean_json_file "$(devin_hooks_file)" 'remove_ours' ;;
        kiro) rm -f "$home/hooks/unlazier.json" "$home/hooks/unlazier-alert.json" ;;
        cline)
            remove_cline_hook "$home/Hooks/UserPromptSubmit"
            remove_cline_hook "$home/Hooks/PreToolUse"
            remove_cline_hook "$home/Hooks/TaskComplete"
            ;;
        opencode) rm -f "$home/plugins/unlazier.ts" ;;
        amp) rm -f "$home/plugins/unlazier.ts" ;;
        copilot) rm -f "$home/hooks/unlazier.json" ;;
        *) die "unknown harness '$harness'" ;;
    esac
}

devin_hooks_file() {
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/devin/config.json"
}

# Cline runs an executable named after the event; if the user already has one, it is kept
# and ours is not wired in, because one event can only have one script.
write_cline_hook() {
    local hook_file="$1" body="$2"
    if [ -f "$hook_file" ] && ! grep -Eq "$OWNED_SCRIPT_PATTERN" "$hook_file"; then
        warn "$hook_file already exists; the Unlazier hook for that event was not installed."
        return 1
    fi
    mkdir -p "$(dirname "$hook_file")"
    printf '#!/bin/bash\n%s\n' "$body" > "$hook_file"
    chmod +x "$hook_file"
}

remove_cline_hook() {
    local hook_file="$1"
    if [ -f "$hook_file" ] && grep -Eq "$OWNED_SCRIPT_PATTERN" "$hook_file"; then
        rm -f "$hook_file"
    fi
}

install_plugin() {
    local harness="$1" home
    home="$(harness_home "$harness")"
    mkdir -p "$home/plugins"
    case "$harness" in
        opencode) cp "$SOURCE_DIR/plugins/opencode.ts" "$home/plugins/unlazier.ts" ;;
        amp) cp "$SOURCE_DIR/plugins/amp.ts" "$home/plugins/unlazier.ts" ;;
        *) die "no plugin for '$harness'" ;;
    esac
}

# Claude Code passes usage windows only to the status line, so the status line is the usage
# source. An existing status line is never replaced. The 60-second refresh keeps the saved
# usage fresh while no message is sent; a reading older than 15 minutes counts as unknown.
install_statusline() {
    local home settings
    home="$(harness_home claude)"
    settings="$home/settings.json"
    # A status line that is not ours is the user's and stays. One installed by an earlier version is
    # ours: it gets the current script and command, and keeps any field the user added.
    if [ -f "$settings" ] && [ "$(jq --arg owned "$OWNED_SCRIPT_PATTERN" \
        'has("statusLine") and ((.statusLine | type) != "object"
            or ((.statusLine.command // "") | tostring | test($owned) | not))' "$settings" 2>/dev/null)" = "true" ]; then
        [ -f "$home/state/rate_limits.json" ] \
            || add_notice "Claude Code: you already have a status line, so it was kept. To give the agent its usage, make it save the 'rate_limits' it receives to $home/state/rate_limits.json (see README)."
        return 1
    fi
    cp "$SOURCE_DIR/statusline/claude-statusline.sh" "$home/$PAYLOAD_DIR_NAME/"
    chmod +x "$home/$PAYLOAD_DIR_NAME/claude-statusline.sh"
    update_json_file "$settings" \
        '.statusLine = ((.statusLine // {}) + {type: "command", command: $command}) | .statusLine.refreshInterval //= 60' \
        --arg command "bash \"$home/$PAYLOAD_DIR_NAME/claude-statusline.sh\""
}

uninstall_statusline() {
    local settings
    settings="$(harness_home claude)/settings.json"
    clean_json_file "$settings" \
        'if ((.statusLine.command // "") | tostring | test($owned)) then del(.statusLine) else . end'
}

# ---------------------------------------------------------------------------
# Rules layer: one file per rule in a rules folder, or a marked block inside the
# harness's single instructions file.
# ---------------------------------------------------------------------------

render_rules() {
    local name
    cat "$SOURCE_DIR/AGENTS.md"
    for name in $RULE_NAMES; do
        echo
        cat "$SOURCE_DIR/rules/$name.md"
    done
}

# A block runs from a start marker line to the next end marker line. A start marker followed by
# another start marker, or by none, opens no block: it stays as text, with the user's lines after
# it, which a broken block would otherwise swallow up to the end of the file.

# Prints the number of blocks and the number of start markers that open none.
count_markers() {
    awk -v start="$2" -v end="$3" '
        $0 == start { unclosed += open; open = 1; next }
        open && $0 == end { blocks++; open = 0 }
        END { print blocks + 0, unclosed + open }
    ' "$1"
}

# Prints the file with each block replaced by the block file's content (only the first block
# receives it, so duplicates collapse into one), or removed when no block file is given.
rewrite_blocks() {
    local file="$1" start="$2" end="$3" block_file="${4:-}"
    awk -v start="$start" -v end="$end" -v block="$block_file" '
        function release(   i) { for (i = 1; i <= held; i++) print lines[i]; held = 0 }
        $0 == start { release(); held = 1; lines[1] = $0; next }
        held && $0 == end {
            held = 0
            if (block != "") while ((getline line < block) > 0) print line
            next
        }
        held { lines[++held] = $0; next }
        { print }
        END { release() }
    ' "$file"
}

report_unclosed_marker() {
    add_notice "$1 has a '$2' line with no '$3' line after it; that line and the text after it were kept. Delete the stray line by hand."
}

# Replaces the block, or appends one when the file has none.
write_block() {
    local file="$1" block_file blocks=0 unclosed=0
    mkdir -p "$(dirname "$file")"
    block_file="$(mktemp)"
    {
        echo "$MARKER_START"
        render_rules
        echo "$MARKER_END"
    } > "$block_file"

    if [ -f "$file" ]; then
        read -r blocks unclosed < <(count_markers "$file" "$MARKER_START" "$MARKER_END")
    fi
    if [ "$unclosed" -gt 0 ]; then
        report_unclosed_marker "$file" "$MARKER_START" "$MARKER_END"
    fi
    if [ "$blocks" -gt 0 ]; then
        rewrite_file "$file" rewrite_blocks "$file" "$MARKER_START" "$MARKER_END" "$block_file" \
            || { rm -f "$block_file"; die "could not update $file"; }
    else
        # A file without a final newline would glue the marker to its last line.
        if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
            echo >> "$file"
        fi
        cat "$block_file" >> "$file"
    fi
    rm -f "$block_file"
}

# Removes the block (marked with the current markers unless others are given); deletes the
# file when only whitespace is left.
remove_block() {
    local file="$1" start="${2:-$MARKER_START}" end="${3:-$MARKER_END}" blocks unclosed
    [ -f "$file" ] && grep -qxF "$start" "$file" || return 0
    read -r blocks unclosed < <(count_markers "$file" "$start" "$end")
    if [ "$unclosed" -gt 0 ]; then
        report_unclosed_marker "$file" "$start" "$end"
    fi
    [ "$blocks" -gt 0 ] || return 0
    rewrite_file "$file" rewrite_blocks "$file" "$start" "$end" || die "could not update $file"
    if ! grep -q '[^[:space:]]' "$file"; then
        rm -f "$file"
    fi
}

# Our files are recognized by the "unlazier" prefix; the pattern also covers the
# unlazier-ai*.md files that version 2.0 wrote to these folders.
remove_rule_files() {
    local folder="$1" file
    for file in "$folder"/unlazier*.md; do
        if [ -f "$file" ]; then
            rm -f "$file"
        fi
    done
}

write_rule_files() {
    local folder="$1" name
    remove_rule_files "$folder"
    mkdir -p "$folder"
    cp "$SOURCE_DIR/AGENTS.md" "$folder/unlazier-principles.md"
    for name in $RULE_NAMES; do
        cp "$SOURCE_DIR/rules/$name.md" "$folder/unlazier-$name.md"
    done
}

install_rules() {
    local harness="$1" folder file
    folder="$(rules_folder "$harness")"
    if [ -z "$folder" ]; then
        file="$(rules_file "$harness")"
        write_block "$file"
        log "  rules      -> $file"
        return 0
    fi
    write_rule_files "$folder"
    log "  rules      -> $folder/unlazier-*.md"
}

uninstall_rules() {
    local harness="$1" folder
    folder="$(rules_folder "$harness")"
    if [ -z "$folder" ]; then
        remove_block "$(rules_file "$harness")"
        return 0
    fi
    remove_rule_files "$folder"
}

# Removes what version 2.0 installed under its old name, so it does not load next to the
# renamed files. Hook entries and the status line need nothing extra, because
# OWNED_SCRIPT_PATTERN matches both folder names, and neither do rule files, because
# "unlazier*.md" matches both prefixes.
remove_legacy_names() {
    local harness="$1" home folder
    home="$(harness_home "$harness")"
    folder="$(rules_folder "$harness")"
    if [ -z "$folder" ]; then
        remove_block "$(rules_file "$harness")" "$LEGACY_MARKER_START" "$LEGACY_MARKER_END"
    elif [ "$harness" = "claude" ]; then
        # Version 2.0 put the Claude Code rules in a block inside CLAUDE.md.
        remove_block "$home/CLAUDE.md" "$LEGACY_MARKER_START" "$LEGACY_MARKER_END"
    fi
    case "$harness" in
        opencode|amp) rm -f "$home/plugins/$LEGACY_NAME.ts" ;;
        kiro) rm -f "$home/hooks/$LEGACY_NAME.json" ;;
    esac
    if [ -d "$home/$LEGACY_NAME" ]; then
        rm -rf "${home:?}/$LEGACY_NAME"
    fi
}

# Copies the files the hook reads into <harness home>/unlazier/.
install_payload() {
    local harness="$1" target
    target="$(harness_home "$harness")/$PAYLOAD_DIR_NAME"
    mkdir -p "$target"
    cp "$SOURCE_DIR/AGENTS.md" "$SOURCE_DIR/reminder.md" "$SOURCE_DIR/hooks/inject.sh" "$SOURCE_DIR/hooks/alert.sh" "$target/"
    chmod +x "$target/inject.sh" "$target/alert.sh"
}

# Builds from main before 2.2.0 installed background waiters into the payload folder. They are
# deleted only after the new rules are written, so the rules on disk never call a missing script;
# sessions opened before the upgrade still hold the old rules, hence the notice.
remove_obsolete_waiters() {
    local harness="$1" target name found=false
    target="$(harness_home "$harness")/$PAYLOAD_DIR_NAME"
    for name in wait-usage.sh wait-usage.ps1; do
        if [ -f "$target/$name" ]; then
            rm -f "$target/$name"
            found=true
        fi
    done
    if [ "$found" = true ]; then
        add_notice "$(harness_label "$harness"): restart sessions opened before this install; their rules still call the removed wait-usage script."
    fi
}

remove_payload() {
    local target
    target="$(harness_home "$1")/$PAYLOAD_DIR_NAME"
    # The folder holds only files this installer copied, so removing it whole is safe.
    if [ -d "$target" ]; then
        rm -rf "$target"
    fi
}

# ---------------------------------------------------------------------------
# Version 1 leftovers (Claude Code and OpenCode only).
# ---------------------------------------------------------------------------

matches_checksum() {
    local file="$1" expected="$2"
    [ -f "$file" ] && [ "$(cksum < "$file" | awk '{print $1" "$2}')" = "$expected" ]
}

find_v1_leftovers() {
    local harness="$1" home global_file name crc size
    [ "$harness" = "claude" ] || [ "$harness" = "opencode" ] || return 0
    home="$(harness_home "$harness")"

    global_file="$home/AGENTS.md"
    [ "$harness" = "claude" ] && global_file="$home/CLAUDE.md"
    # Version 1 made the rules/ paths in the Claude Code copy absolute; they are made relative
    # again so the copy matches the checksum of the shipped file.
    if [ -f "$global_file" ] && [ "$(sed 's|`[^`]*/\.claude/rules/|`rules/|g' "$global_file" \
        | cksum | awk '{print $1" "$2}')" = "$V1_GLOBAL_CHECKSUM" ]; then
        echo "$global_file"
    fi

    while read -r name crc size; do
        matches_checksum "$home/rules/$name.md" "$crc $size" && echo "$home/rules/$name.md"
    done <<EOF
$V1_RULE_CHECKSUMS
EOF

    while read -r name crc size; do
        if matches_checksum "$home/skills/$name/SKILL.md" "$crc $size" \
            && [ "$(find "$home/skills/$name" -type f | wc -l | tr -d ' ')" = "1" ]; then
            echo "$home/skills/$name"
        fi
    done <<EOF
$V1_SKILL_CHECKSUMS
EOF

    if [ "$harness" = "opencode" ] && [ "$HAS_JQ" = true ] && [ -f "$home/opencode.json" ] \
        && [ "$(jq -cS . "$home/opencode.json" 2>/dev/null)" = "$(printf '%s' "$V1_OPENCODE_CONFIG" | jq -cS .)" ]; then
        echo "$home/opencode.json"
    fi
    return 0
}

remove_v1_leftovers() {
    local leftovers="$1" path
    [ -n "$leftovers" ] || return 0
    log ""
    log "Files from Unlazier version 1 were found:"
    printf '%s\n' "$leftovers" | sed 's/^/  - /'
    log "Version 2 replaces them. If you added your own notes to any of these files, answer 'n'."
    if ! confirm "Remove these files?"; then
        add_notice "Version 1 files were kept; rules may load twice until you remove them."
        return 0
    fi
    while IFS= read -r path; do
        rm -rf "$path"
        rmdir "$(dirname "$path")" 2>/dev/null || true
    done <<EOF
$leftovers
EOF
}

# ---------------------------------------------------------------------------
# Interaction and setup.
# ---------------------------------------------------------------------------

# Reads one line from the terminal even when the script itself arrives through a pipe.
# UNLAZIER_NO_PROMPT=1 behaves as if no terminal were attached (used by automation and tests).
read_from_terminal() {
    local answer
    [ "${UNLAZIER_NO_PROMPT:-}" = "1" ] && return 1
    { exec 3</dev/tty; } 2>/dev/null || return 1
    IFS= read -r answer <&3 || answer=""
    exec 3<&-
    printf '%s' "$answer"
}

confirm() {
    local answer
    if [ "$ASSUME_YES" = true ]; then
        return 0
    fi
    printf '%s [y/N] ' "$1"
    answer="$(read_from_terminal)" || { echo; return 1; }
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

validate_harnesses() {
    local name
    for name in $1; do
        case " $ALL_HARNESSES " in
            *" $name "*) ;;
            *) die "unknown harness '$name'. Valid names: $ALL_HARNESSES" ;;
        esac
    done
}

select_harnesses() {
    local detected="" harness index=1 marker answer chosen="" number
    if [ -n "$REQUESTED_HARNESSES" ]; then
        if [ "$REQUESTED_HARNESSES" = "all" ]; then
            echo "$ALL_HARNESSES"
        else
            validate_harnesses "$(echo "$REQUESTED_HARNESSES" | tr ',' ' ')"
            echo "$REQUESTED_HARNESSES" | tr ',' ' '
        fi
        return 0
    fi

    for harness in $ALL_HARNESSES; do
        is_detected "$harness" && detected="$detected $harness"
    done

    {
        log ""
        log "Choose the tools to $MODE Unlazier for (* = found on this computer):"
        for harness in $ALL_HARNESSES; do
            marker=" "
            case " $detected " in *" $harness "*) marker="*" ;; esac
            log "  $index) $marker $(harness_label "$harness")"
            index=$((index + 1))
        done
        printf 'Type numbers separated by spaces, "all", or press Enter for the tools marked with *: '
    } >&2
    if ! answer="$(read_from_terminal)"; then
        echo >&2
        [ -n "$detected" ] || die "no tool was found and no terminal is available; pass --harness <names>."
        echo "$detected"
        return 0
    fi

    case "$answer" in
        "") chosen="$detected" ;;
        all) chosen="$ALL_HARNESSES" ;;
        *)
            for number in $answer; do
                case "$number" in
                    *[!0-9]*|"") die "'$number' is not a number from the list." ;;
                esac
                # awk's field 0 is the whole line, so 0 would select every tool.
                [ "$number" -ge 1 ] || die "$number is not in the list."
                harness="$(echo "$ALL_HARNESSES" | awk -v position="$number" '{print $position}')"
                [ -n "$harness" ] || die "$number is not in the list."
                chosen="$chosen $harness"
            done
            ;;
    esac
    [ -n "$chosen" ] || die "no tool selected."
    echo "$chosen"
}

prepare_source() {
    local script_path="${BASH_SOURCE[0]:-}" relative_path
    if [ -n "$script_path" ] && [ -f "$script_path" ]; then
        SOURCE_DIR="$(cd "$(dirname "$script_path")" && pwd)"
        if [ -f "$SOURCE_DIR/AGENTS.md" ] && [ -f "$SOURCE_DIR/hooks/inject.sh" ]; then
            return 0
        fi
    fi
    command -v curl >/dev/null 2>&1 || die "curl is required but not installed."
    DOWNLOAD_DIR="$(mktemp -d)"
    trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
    log "Downloading Unlazier from $RAW_BASE..."
    for relative_path in $PAYLOAD_FILES $(for name in $RULE_NAMES; do echo "rules/$name.md"; done); do
        mkdir -p "$DOWNLOAD_DIR/$(dirname "$relative_path")"
        curl -fsSL "$RAW_BASE/$relative_path" -o "$DOWNLOAD_DIR/$relative_path" \
            || die "failed to download $relative_path"
    done
    SOURCE_DIR="$DOWNLOAD_DIR"
}

print_jq_help() {
    local command="your package manager"
    if command -v brew >/dev/null 2>&1; then command="brew install jq"
    elif command -v apt-get >/dev/null 2>&1; then command="sudo apt-get install -y jq"
    elif command -v dnf >/dev/null 2>&1; then command="sudo dnf install -y jq"
    elif command -v pacman >/dev/null 2>&1; then command="sudo pacman -S jq"
    elif command -v zypper >/dev/null 2>&1; then command="sudo zypper install -y jq"
    elif command -v apk >/dev/null 2>&1; then command="sudo apk add jq"
    fi
    add_notice "jq is not installed, so the reminder hooks and the Claude Code status line were skipped. Install it with: $command - then run this installer again."
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --harness)
                [ "$#" -ge 2 ] || die "--harness needs a value"
                REQUESTED_HARNESSES="$2"
                shift 2
                ;;
            --yes) ASSUME_YES=true; shift ;;
            --uninstall) MODE="uninstall"; shift ;;
            -h|--help)
                sed -n '2,15p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//'
                exit 0
                ;;
            *) die "unknown option '$1' (see --help)" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Per-harness pipelines: identical steps for every harness.
# ---------------------------------------------------------------------------

harness_warnings() {
    local harness="$1" home
    home="$(harness_home "$harness")"
    case "$harness" in
        claude)
            # Read only to explain what happens at the usage limit; the user's choice is never
            # changed. A settings file jq cannot read is reported when the hooks are registered.
            [ "$HAS_JQ" = true ] && [ -f "$home/settings.json" ] \
                && [ "$(jq '.autoContinueAtUsageLimit == false' "$home/settings.json" 2>/dev/null)" = "true" ] \
                && add_notice "Claude Code: autoContinueAtUsageLimit is off, so after a usage limit the session waits for you instead of continuing the task on its own. Unlazier keeps your choice; turn it on in /config, or start a single wait from /rate-limit-options."
            ;;
        codex)
            [ -f "$home/AGENTS.override.md" ] \
                && add_notice "Codex: $home/AGENTS.override.md exists, and Codex ignores AGENTS.md while it does."
            ;;
        opencode)
            [ -f "$(harness_home claude)/CLAUDE.md" ] && [ ! -f "$home/AGENTS.md" ] \
                && add_notice "OpenCode: it stops reading ~/.claude/CLAUDE.md once $home/AGENTS.md exists."
            ;;
    esac
    return 0
}

install_harness() {
    local harness="$1"
    log ""
    log "$(harness_label "$harness"):"
    harness_warnings "$harness"
    remove_legacy_names "$harness"
    install_payload "$harness"
    install_rules "$harness"
    remove_obsolete_waiters "$harness"
    case "$harness" in
        opencode|amp)
            # One plugin carries both the reminder and the alerts, and needs no jq.
            register_hooks "$harness"
            log "  reminder   -> plugin"
            log "  alerts     -> plugin"
            ;;
        *)
            if [ "$HAS_JQ" = true ] && register_hooks "$harness"; then
                log "  reminder   -> hook registered"
            fi
            if [ "$HAS_JQ" = true ] && register_alerts "$harness"; then
                log "  alerts     -> hook registered"
            fi
            ;;
    esac
    if [ "$harness" = "claude" ] && [ "$HAS_JQ" = true ] && install_statusline; then
        log "  usage      -> status line"
    fi
}

uninstall_harness() {
    local harness="$1"
    log ""
    log "$(harness_label "$harness"):"
    remove_legacy_names "$harness"
    uninstall_rules "$harness"
    case "$harness" in
        claude|codex|gemini|devin)
            if [ "$HAS_JQ" = true ]; then
                unregister_hooks "$harness"
                [ "$harness" = "claude" ] && uninstall_statusline
            else
                add_notice "$(harness_label "$harness"): install jq and run the uninstaller again to remove the hook entries."
            fi
            ;;
        *) unregister_hooks "$harness" ;;
    esac
    remove_payload "$harness"
    log "  removed"
}

main() {
    local harnesses harness leftovers=""
    parse_args "$@"
    command -v jq >/dev/null 2>&1 && HAS_JQ=true
    harnesses="$(select_harnesses)"

    if [ "$MODE" = "uninstall" ]; then
        for harness in $harnesses; do
            uninstall_harness "$harness"
        done
    else
        for harness in $harnesses; do
            assert_safe_home "$harness"
        done
        prepare_source
        [ "$HAS_JQ" = true ] || print_jq_help
        for harness in $harnesses; do
            leftovers="$leftovers$(find_v1_leftovers "$harness")
"
        done
        remove_v1_leftovers "$(printf '%s' "$leftovers" | sed '/^$/d')"
        for harness in $harnesses; do
            install_harness "$harness"
        done
    fi

    if [ -n "$NOTICES" ]; then
        log ""
        log "Notes:"
        printf '%s' "$NOTICES"
    fi
    log ""
    log "Done. Restart your tools for the changes to take effect."
}

main "$@"
