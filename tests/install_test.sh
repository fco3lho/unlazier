#!/bin/bash
# Tests for install.sh, uninstall.sh, hooks/inject.sh, and the Claude Code status line.
#
# Usage: bash tests/install_test.sh
# Requires bash, jq, and standard POSIX tools. Every scenario runs inside a temporary HOME,
# so the real configuration of the machine is never touched.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$REPO_DIR/tests/fixtures"
ALL_HARNESSES="claude,opencode,codex,copilot,gemini,amp,kiro,cline,devin"
PASSED=0
FAILED=0
TEMPORARY_HOMES=""

cleanup() {
    local home
    for home in $TEMPORARY_HOMES; do
        rm -rf "$home"
    done
}
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; }

check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}

new_home() {
    local home
    home="$(mktemp -d)"
    TEMPORARY_HOMES="$TEMPORARY_HOMES $home"
    echo "$home"
}

run_installer() {
    local home="$1"
    shift
    HOME="$home" XDG_CONFIG_HOME="" CLAUDE_CONFIG_DIR="" CODEX_HOME="" COPILOT_HOME="" \
        GEMINI_CLI_HOME="" KIRO_HOME="" CLINE_DIR="" UNLAZIER_NO_PROMPT=1 \
        bash "$REPO_DIR/install.sh" "$@"
}

run_uninstaller() {
    local home="$1"
    shift
    HOME="$home" XDG_CONFIG_HOME="" CLAUDE_CONFIG_DIR="" CODEX_HOME="" COPILOT_HOME="" \
        GEMINI_CLI_HOME="" KIRO_HOME="" CLINE_DIR="" UNLAZIER_NO_PROMPT=1 \
        bash "$REPO_DIR/uninstall.sh" "$@"
}

# Lists every file with its checksum; JSON files are normalized because the installer
# rewrites them with jq formatting.
snapshot() {
    local home="$1" file
    (cd "$home" && find . -type f | sort) | while IFS= read -r file; do
        case "$file" in
            *.json) printf '%s %s\n' "$file" "$(jq -cS . "$home/$file" | cksum)" ;;
            *) printf '%s %s\n' "$file" "$(cksum < "$home/$file")" ;;
        esac
    done
}

block_count() {
    grep -cxF '<!-- unlazier:start -->' "$1" 2>/dev/null || true
}

has_one_block() { [ "$(block_count "$1")" = "1" ]; }
contains_line() { grep -qxF "$2" "$1"; }
json_has() { [ "$(jq -r "$2" "$1")" = "true" ]; }
file_absent() { [ ! -e "$1" ]; }
has_mode() { [ -n "$(find "$1" -perm "$2")" ]; }

# True when the hook config has exactly one Unlazier alert for the event (and matcher).
has_alert_hook() {
    local file="$1" event="$2" matcher="${3:-}"
    [ "$(jq -r --arg event "$event" --arg matcher "$matcher" '
        [(.hooks[$event] // [])[] | select((.matcher // "") == $matcher)
         | .hooks[].command | select(endswith("/unlazier/alert.sh\""))] | length == 1' "$file")" = "true" ]
}

# Principles plus one file per topic rule.
EXPECTED_RULE_FILES=11

rule_file_count() {
    find "$1" -maxdepth 1 -type f -name 'unlazier*.md' | wc -l | tr -d ' '
}

has_all_rule_files() { [ "$(rule_file_count "$1")" = "$EXPECTED_RULE_FILES" ]; }

# Every rule file stays below a character limit and a line limit.
rule_files_within() {
    local folder="$1" max_characters="$2" max_lines="$3" file
    for file in "$folder"/unlazier*.md; do
        [ "$(wc -m < "$file")" -lt "$max_characters" ] || return 1
        [ "$(wc -l < "$file")" -lt "$max_lines" ] || return 1
    done
}

seed_user_configuration() {
    local home="$1"
    mkdir -p "$home/.claude" "$home/.codex" "$home/.gemini" "$home/.copilot" "$home/.config/opencode" \
        "$home/.config/amp" "$home/.config/devin" "$home/.kiro/steering" "$home/Documents/Cline/Rules" "$home/.devin/rules"
    printf '# My notes\nAlways use tabs.\n' > "$home/.claude/CLAUDE.md"
    printf '# Codex notes\n' > "$home/.codex/AGENTS.md"
    printf '# Gemini notes\n' > "$home/.gemini/GEMINI.md"
    jq -n '{model: "opus", statusLine: {type: "command", command: "my-status"},
        hooks: {Stop: [{hooks: [{type: "command", command: "beep"}]}]}}' > "$home/.claude/settings.json"
    jq -n '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: "my-codex-hook"}]}]}}' \
        > "$home/.codex/hooks.json"
    jq -n '{theme: "dark"}' > "$home/.gemini/settings.json"
}

test_install_preserves_user_content() {
    local home
    echo "install preserves existing configuration"
    home="$(new_home)"
    seed_user_configuration "$home"
    run_installer "$home" --harness "$ALL_HARNESSES" >/dev/null 2>&1

    check "CLAUDE.md untouched" test "$(cat "$home/.claude/CLAUDE.md")" = "$(printf '# My notes\nAlways use tabs.')"
    check "Codex notes kept" contains_line "$home/.codex/AGENTS.md" "# Codex notes"
    check "existing Claude hook kept" json_has "$home/.claude/settings.json" \
        '[.hooks.Stop[].hooks[].command] | index("beep") != null'
    check "existing Claude status line kept" json_has "$home/.claude/settings.json" \
        '.statusLine.command == "my-status"'
    check "unused status line script not copied" file_absent "$home/.claude/unlazier/claude-statusline.sh"
    check "existing Codex hook kept" json_has "$home/.codex/hooks.json" \
        '[.hooks.UserPromptSubmit[].hooks[].command] | index("my-codex-hook") != null'
    check "Gemini setting kept" json_has "$home/.gemini/settings.json" '.theme == "dark"'
}

test_install_adds_all_layers() {
    local home file
    echo "install adds the three layers to every harness"
    home="$(new_home)"
    run_installer "$home" --harness "$ALL_HARNESSES" >/dev/null 2>&1

    for file in .config/opencode/AGENTS.md .codex/AGENTS.md .copilot/copilot-instructions.md \
        .gemini/GEMINI.md .config/amp/AGENTS.md; do
        check "rules block in $file" has_one_block "$home/$file"
    done
    for file in .claude/rules .kiro/steering Documents/Cline/Rules .devin/rules; do
        check "rule files in $file" has_all_rule_files "$home/$file"
        check "rule files in $file are short" rule_files_within "$home/$file" 12000 200
    done
    check "no CLAUDE.md created" file_absent "$home/.claude/CLAUDE.md"
    for file in .claude .config/opencode .codex .copilot .gemini .config/amp .kiro Documents/Cline .devin; do
        check "payload in $file/unlazier" test -f "$home/$file/unlazier/reminder.md"
    done
    check "Claude prompt hook" json_has "$home/.claude/settings.json" \
        '[.hooks.UserPromptSubmit[].hooks[].command] | any(contains("inject.sh\" claude prompt"))'
    check "Claude compaction hook" json_has "$home/.claude/settings.json" \
        '.hooks.SessionStart | any(.matcher == "compact")'
    check "Claude subagent usage hook" json_has "$home/.claude/settings.json" \
        '.hooks.PostToolUse | any(.matcher == "Agent" and (.hooks | any(.command | contains("inject.sh\" claude subagent"))))'
    check "Claude subagent gate hook" json_has "$home/.claude/settings.json" \
        '.hooks.PreToolUse | any(.matcher == "Agent" and (.hooks | any(.command | contains("inject.sh\" claude dispatch"))))'
    check "Claude status line installed" json_has "$home/.claude/settings.json" \
        '.statusLine.command | contains("claude-statusline.sh")'
    check "Claude status line refreshes every minute" json_has "$home/.claude/settings.json" \
        '.statusLine.refreshInterval == 60'
    check "Codex hooks registered" json_has "$home/.codex/hooks.json" \
        '[.hooks.UserPromptSubmit[].hooks[].command] | any(contains("inject.sh\" codex prompt"))'
    check "Codex subagent usage hook" json_has "$home/.codex/hooks.json" \
        '.hooks.PostToolUse | any(.matcher == "spawn_agent" and (.hooks | any(.command | contains("inject.sh\" codex subagent"))))'
    check "Codex subagent gate hook" json_has "$home/.codex/hooks.json" \
        '.hooks.PreToolUse | any(.matcher == "spawn_agent" and (.hooks | any(.command | contains("inject.sh\" codex dispatch"))))'
    check "Gemini hook registered" json_has "$home/.gemini/settings.json" \
        '[.hooks.BeforeAgent[].hooks[].command] | any(contains("inject.sh\" gemini prompt"))'
    check "Devin hook registered" json_has "$home/.config/devin/config.json" \
        '[.hooks.UserPromptSubmit[].hooks[].command] | any(contains("inject.sh\" devin prompt"))'
    check "Kiro hooks" json_has "$home/.kiro/hooks/unlazier.json" \
        '[.hooks[].trigger] == ["UserPromptSubmit", "PostCompact"]'
    check "Cline hook executable" test -x "$home/Documents/Cline/Hooks/UserPromptSubmit"
    check "OpenCode plugin" test -f "$home/.config/opencode/plugins/unlazier.ts"
    check "Amp plugin" test -f "$home/.config/amp/plugins/unlazier.ts"
    check "no backup folders" test -z "$(find "$home" -maxdepth 2 -name '*.bak*')"
    check "alert script in payload" test -x "$home/.claude/unlazier/alert.sh"
    check "Claude permission alert" has_alert_hook "$home/.claude/settings.json" Notification permission_prompt
    check "Claude question alert" has_alert_hook "$home/.claude/settings.json" PreToolUse AskUserQuestion
    check "Claude end-of-turn alert" has_alert_hook "$home/.claude/settings.json" Stop
    check "Codex permission alert" has_alert_hook "$home/.codex/hooks.json" PermissionRequest
    check "Codex question alert" has_alert_hook "$home/.codex/hooks.json" PreToolUse '^request_user_input$'
    check "Codex end-of-turn alert" has_alert_hook "$home/.codex/hooks.json" Stop
    check "Gemini attention alert" has_alert_hook "$home/.gemini/settings.json" Notification
    check "Gemini end-of-turn alert" has_alert_hook "$home/.gemini/settings.json" AfterAgent
    check "Devin permission alert" has_alert_hook "$home/.config/devin/config.json" PermissionRequest
    check "Devin question alert" has_alert_hook "$home/.config/devin/config.json" PreToolUse '^ask_user_question$'
    check "Devin end-of-turn alert" has_alert_hook "$home/.config/devin/config.json" Stop
    check "Kiro end-of-turn alert" json_has "$home/.kiro/hooks/unlazier-alert.json" '[.hooks[].trigger] == ["Stop"]'
    check "Copilot alerts" json_has "$home/.copilot/hooks/unlazier.json" \
        '(.hooks.notification[0].matcher == "permission_prompt|elicitation_dialog") and (.hooks.agentStop | length == 1)'
    check "Cline question alert executable" test -x "$home/Documents/Cline/Hooks/PreToolUse"
    check "Cline end-of-turn alert executable" test -x "$home/Documents/Cline/Hooks/TaskComplete"
}

test_cline_question_alert_filters_tools() {
    local home alert_log
    echo "the Cline question alert beeps only for question tools"
    home="$(new_home)"
    run_installer "$home" --harness cline >/dev/null 2>&1
    alert_log="$home/alerts.log"
    # A stub replaces the beep so the test is silent and countable.
    printf '#!/bin/bash\necho alert >> "%s"\n' "$alert_log" > "$home/Documents/Cline/unlazier/alert.sh"

    check "hook answers cancel false" test "$(echo '{"preToolUse":{"toolName":"read_file"}}' \
        | bash "$home/Documents/Cline/Hooks/PreToolUse")" = '{"cancel":false}'
    check "no alert for other tools" file_absent "$alert_log"
    echo '{"preToolUse":{"toolName":"ask_question"}}' | bash "$home/Documents/Cline/Hooks/PreToolUse" >/dev/null
    check "alert for a question" test "$(wc -l < "$alert_log" | tr -d ' ')" = "1"
}

test_reinstall_is_idempotent() {
    local home
    echo "reinstalling keeps a single copy"
    home="$(new_home)"
    seed_user_configuration "$home"
    run_installer "$home" --harness "$ALL_HARNESSES" >/dev/null 2>&1
    run_installer "$home" --harness "$ALL_HARNESSES" >/dev/null 2>&1

    check "Claude rule files written once" has_all_rule_files "$home/.claude/rules"
    check "one block in Codex AGENTS.md" has_one_block "$home/.codex/AGENTS.md"
    check "one Claude prompt hook" json_has "$home/.claude/settings.json" \
        '[.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("unlazier"))] | length == 1'
    check "one Claude subagent usage hook" json_has "$home/.claude/settings.json" \
        '[.hooks.PostToolUse[].hooks[] | select(.command | contains("unlazier"))] | length == 1'
    check "one Claude subagent gate hook" json_has "$home/.claude/settings.json" \
        '[.hooks.PreToolUse[] | select(.matcher == "Agent") | .hooks[] | select(.command | contains("unlazier"))] | length == 1'
    check "one Claude question alert next to the gate" has_alert_hook "$home/.claude/settings.json" PreToolUse AskUserQuestion
    check "one Claude end-of-turn alert" has_alert_hook "$home/.claude/settings.json" Stop
    check "one Codex end-of-turn alert" has_alert_hook "$home/.codex/hooks.json" Stop
    check "one Codex prompt hook" json_has "$home/.codex/hooks.json" \
        '[.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("unlazier"))] | length == 1'
    check "one Codex subagent gate hook" json_has "$home/.codex/hooks.json" \
        '[.hooks.PreToolUse[] | select(.matcher == "spawn_agent") | .hooks[] | select(.command | contains("unlazier"))] | length == 1'
    check "one Codex question alert next to the gate" has_alert_hook "$home/.codex/hooks.json" PreToolUse '^request_user_input$'
}

test_uninstall_restores_original_files() {
    local home before after
    echo "uninstall removes only what was added"
    home="$(new_home)"
    seed_user_configuration "$home"
    before="$(snapshot "$home")"
    run_installer "$home" --harness "$ALL_HARNESSES" >/dev/null 2>&1
    run_uninstaller "$home" --harness "$ALL_HARNESSES" >/dev/null 2>&1
    after="$(snapshot "$home")"

    check "files identical to the original" test "$before" = "$after"
}

# Dotfiles managers keep these configs elsewhere and link them; settings may hold secrets.
test_config_files_rewritten_in_place() {
    local home dotfiles
    echo "config files keep their mode and symbolic links"
    home="$(new_home)"
    dotfiles="$home/dotfiles"
    mkdir -p "$home/.claude" "$home/.codex" "$dotfiles"
    jq -n '{model: "opus"}' > "$home/.claude/settings.json"
    chmod 600 "$home/.claude/settings.json"
    jq -n '{hooks: {Stop: [{hooks: [{type: "command", command: "beep"}]}]}}' > "$dotfiles/hooks.json"
    printf '# Codex notes\n' > "$dotfiles/AGENTS.md"
    ln -s "$dotfiles/hooks.json" "$home/.codex/hooks.json"
    ln -s "$dotfiles/AGENTS.md" "$home/.codex/AGENTS.md"
    # The second run replaces the rules block instead of appending it.
    run_installer "$home" --harness claude,codex >/dev/null 2>&1
    run_installer "$home" --harness claude,codex >/dev/null 2>&1

    check "settings.json stays private" has_mode "$home/.claude/settings.json" 600
    check "hooks.json stays a link" test -L "$home/.codex/hooks.json"
    check "the linked hooks.json gets the hooks" json_has "$dotfiles/hooks.json" '.hooks.UserPromptSubmit | length == 1'
    check "AGENTS.md stays a link" test -L "$home/.codex/AGENTS.md"
    check "the linked AGENTS.md gets one block" has_one_block "$dotfiles/AGENTS.md"
    run_uninstaller "$home" --harness codex >/dev/null 2>&1
    check "uninstall keeps the hooks.json link" test -L "$home/.codex/hooks.json"
    check "uninstall leaves the user's hook in the linked file" json_has "$dotfiles/hooks.json" \
        '. == {hooks: {Stop: [{hooks: [{type: "command", command: "beep"}]}]}}'
    check "uninstall keeps the AGENTS.md link" test -L "$home/.codex/AGENTS.md"
    check "uninstall removes the block from the linked file" test "$(cat "$dotfiles/AGENTS.md")" = "# Codex notes"
}

test_temporary_file_names_unpredictable() {
    local home
    echo "a file at a guessable temporary name is left alone"
    home="$(new_home)"
    mkdir -p "$home/.claude"
    printf 'planted\n' > "$home/.claude/settings.json.unlazier.tmp"
    run_installer "$home" --harness claude >/dev/null 2>&1

    check "planted file unchanged" test "$(cat "$home/.claude/settings.json.unlazier.tmp" 2>/dev/null)" = "planted"
    check "settings.json written" json_has "$home/.claude/settings.json" '.hooks.UserPromptSubmit | length == 1'
    check "no temporary files left" test -z "$(find "$home/.claude" -name '.unlazier.*')"
}

# A user's own scripts may live under a path that only mentions unlazier, such as a fork.
seed_foreign_unlazier_paths() {
    local home="$1"
    local fork="$home/unlazier-fork"
    mkdir -p "$home/.claude" "$home/Documents/Cline/Hooks"
    jq -n --arg guard "bash \"$fork/guard.sh\"" --arg notify "bash \"$fork/notify.sh\"" \
        --arg status "bash \"$fork/status.sh\"" '{statusLine: {type: "command", command: $status},
        hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $guard}]}],
            Stop: [{hooks: [{type: "command", command: $notify}]}]}}' > "$home/.claude/settings.json"
    printf '#!/bin/bash\nexec bash "%s/prompt.sh"\n' "$fork" > "$home/Documents/Cline/Hooks/UserPromptSubmit"
    chmod +x "$home/Documents/Cline/Hooks/UserPromptSubmit"
}

test_foreign_unlazier_paths_kept() {
    local home settings cline_hook seeded_settings seeded_json seeded_hook
    echo "entries whose path only mentions unlazier are left alone"
    home="$(new_home)"
    seed_foreign_unlazier_paths "$home"
    settings="$home/.claude/settings.json"
    cline_hook="$home/Documents/Cline/Hooks/UserPromptSubmit"
    seeded_settings="$(cksum < "$settings")"
    seeded_json="$(jq -cS . "$settings")"
    seeded_hook="$(cksum < "$cline_hook")"
    run_uninstaller "$home" --harness claude,cline >/dev/null 2>&1

    check "uninstall leaves settings.json as it was" test "$(cksum 2>/dev/null < "$settings")" = "$seeded_settings"
    check "uninstall leaves the user's Cline hook" test "$(cksum 2>/dev/null < "$cline_hook")" = "$seeded_hook"
    run_installer "$home" --harness claude,cline >/dev/null 2>&1
    check "install keeps the user's guard and end-of-turn hook" json_has "$settings" \
        '[.hooks[][].hooks[].command | select(contains("unlazier-fork/"))] | length == 2'
    check "install keeps the user's status line" json_has "$settings" '.statusLine.command | endswith("unlazier-fork/status.sh\"")'
    check "install does not replace the user's Cline hook" test "$(cksum < "$cline_hook")" = "$seeded_hook"
    run_uninstaller "$home" --harness claude,cline >/dev/null 2>&1
    check "uninstall after install restores the user's settings" test "$(jq -cS . "$settings" 2>/dev/null)" = "$seeded_json"
}

test_unclosed_marker_keeps_text() {
    local home file original output notice
    echo "a start marker without an end marker keeps the text after it"
    home="$(new_home)"
    file="$home/.codex/AGENTS.md"
    mkdir -p "$home/.codex"
    printf '# Codex notes\n<!-- unlazier:start -->\nKeep this line.\n' > "$file"
    original="$(cksum < "$file")"
    notice="$file has a '<!-- unlazier:start -->' line with no '<!-- unlazier:end -->' line after it"
    output="$(run_installer "$home" --harness codex 2>&1)"

    check "install keeps the text after the marker" contains_line "$file" "Keep this line."
    check "install appends a rules block" test "$(tail -n 1 "$file")" = "<!-- unlazier:end -->"
    check "install names the file in a notice" test -n "$(printf '%s' "$output" | grep -F "$notice")"
    run_installer "$home" --harness codex >/dev/null 2>&1
    check "reinstall keeps the text" contains_line "$file" "Keep this line."
    check "reinstall keeps one complete block" test "$(grep -cxF '<!-- unlazier:end -->' "$file")" = "1"
    output="$(run_uninstaller "$home" --harness codex 2>&1)"
    check "uninstall removes only the complete block" test "$(cksum < "$file")" = "$original"
    check "uninstall names the file in a notice" test -n "$(printf '%s' "$output" | grep -F "$notice")"
    output="$(run_uninstaller "$home" --harness codex 2>&1)"
    check "uninstall without a complete block leaves the file unchanged" test "$(cksum < "$file")" = "$original"
    check "and names the file in a notice" test -n "$(printf '%s' "$output" | grep -F "$notice")"
}

seed_v1_installation() {
    local home="$1"
    mkdir -p "$home/.claude/rules" "$home/.claude/skills"
    sed "s|rules/|$home/.claude/rules/|g" "$FIXTURES_DIR/v1/AGENTS.md" > "$home/.claude/CLAUDE.md"
    cp "$FIXTURES_DIR/v1/rules/"*.md "$home/.claude/rules/"
    cp -R "$FIXTURES_DIR/v1/skills/"* "$home/.claude/skills/"
    printf '# edited by the user\n' >> "$home/.claude/rules/style.md"
    mkdir -p "$home/.claude/skills/my-skill"
    printf 'mine\n' > "$home/.claude/skills/my-skill/SKILL.md"
    mkdir -p "$home/.config/opencode"
    cp "$FIXTURES_DIR/v1/AGENTS.md" "$home/.config/opencode/AGENTS.md"
    cp "$FIXTURES_DIR/v1/opencode.json" "$home/.config/opencode/opencode.json"
    mkdir -p "$home/.config/opencode/skills/bugfix"
    cp "$FIXTURES_DIR/v1/skills/bugfix/SKILL.md" "$home/.config/opencode/skills/bugfix/"
}

test_v1_leftovers_removed_with_yes() {
    local home
    echo "version 1 files are removed after confirmation"
    home="$(new_home)"
    seed_v1_installation "$home"
    run_installer "$home" --harness claude,opencode --yes >/dev/null 2>&1

    check "v1 rule removed" file_absent "$home/.claude/rules/async.md"
    check "edited v1 rule kept" test -f "$home/.claude/rules/style.md"
    check "v1 skill removed" file_absent "$home/.claude/skills/bugfix"
    check "user skill kept" test -f "$home/.claude/skills/my-skill/SKILL.md"
    check "v1 OpenCode config removed" file_absent "$home/.config/opencode/opencode.json"
    check "v1 CLAUDE.md removed" file_absent "$home/.claude/CLAUDE.md"
    check "v1 OpenCode AGENTS.md replaced by the block" \
        test "$(head -n 1 "$home/.config/opencode/AGENTS.md")" = "<!-- unlazier:start -->"
    check "v2 rule files installed" has_all_rule_files "$home/.claude/rules"
}

test_own_global_rules_file_kept() {
    local home own_rules
    echo "a user's own rules file with the version 1 heading is kept"
    home="$(new_home)"
    own_rules='# Global Agent Rules\n\nMy own rules.\n'
    mkdir -p "$home/.claude" "$home/.config/opencode"
    # shellcheck disable=SC2059  # the text is a printf format on purpose, for its newlines
    printf "$own_rules" > "$home/.claude/CLAUDE.md"
    # shellcheck disable=SC2059
    printf "$own_rules" > "$home/.config/opencode/AGENTS.md"
    run_installer "$home" --harness claude,opencode --yes >/dev/null 2>&1

    check "own CLAUDE.md kept" contains_line "$home/.claude/CLAUDE.md" "My own rules."
    check "own OpenCode AGENTS.md kept" contains_line "$home/.config/opencode/AGENTS.md" "My own rules."
}

test_v1_leftovers_kept_without_confirmation() {
    local home
    echo "version 1 files are kept without confirmation"
    home="$(new_home)"
    seed_v1_installation "$home"
    run_installer "$home" --harness claude >/dev/null 2>&1

    check "v1 rule kept" test -f "$home/.claude/rules/async.md"
    check "v1 skill kept" test -d "$home/.claude/skills/bugfix"
}

# Version 2.0 was named "unlazier-ai": it wrote a block into CLAUDE.md and the single-file
# harnesses, single or split files into the rules folders, and its own folders and plugins.
seed_v2_0_installation() {
    local home="$1" old_block
    old_block='<!-- unlazier-ai:start -->\nold rules\n<!-- unlazier-ai:end -->\n'
    mkdir -p "$home/.claude/unlazier-ai" "$home/.codex" "$home/.kiro/steering" "$home/.kiro/hooks" \
        "$home/.devin/rules" "$home/.config/opencode/plugins"
    # shellcheck disable=SC2059  # the block is a printf format on purpose, for its newlines
    printf "# My notes\n$old_block" > "$home/.claude/CLAUDE.md"
    # shellcheck disable=SC2059
    printf "# Codex notes\n$old_block" > "$home/.codex/AGENTS.md"
    # shellcheck disable=SC2059
    printf "$old_block" > "$home/.kiro/steering/unlazier-ai.md"
    # shellcheck disable=SC2059
    printf "$old_block" > "$home/.devin/rules/unlazier-ai-rules.md"
    printf 'old\n' > "$home/.claude/unlazier-ai/inject.sh"
    printf '{}\n' > "$home/.kiro/hooks/unlazier-ai.json"
    printf 'old\n' > "$home/.config/opencode/plugins/unlazier-ai.ts"
    jq -n '{hooks: {UserPromptSubmit: [{hooks: [{type: "command",
        command: "bash \"/old/.claude/unlazier-ai/inject.sh\" claude prompt"}]}]}}' > "$home/.claude/settings.json"
}

test_upgrade_from_v2_0_layout() {
    local home
    echo "version 2.0 (unlazier-ai) moves to the current names and layout"
    home="$(new_home)"
    seed_v2_0_installation "$home"
    run_installer "$home" --harness claude,codex,kiro,devin,opencode >/dev/null 2>&1

    check "old block removed from CLAUDE.md" test "$(cat "$home/.claude/CLAUDE.md")" = "# My notes"
    check "Claude rule files installed" has_all_rule_files "$home/.claude/rules"
    check "old Codex block replaced" test "$(grep -c 'unlazier-ai' "$home/.codex/AGENTS.md")" = "0"
    check "new Codex block added" has_one_block "$home/.codex/AGENTS.md"
    check "old Kiro rules file removed" file_absent "$home/.kiro/steering/unlazier-ai.md"
    check "old Kiro hook file removed" file_absent "$home/.kiro/hooks/unlazier-ai.json"
    check "old Devin split file removed" file_absent "$home/.devin/rules/unlazier-ai-rules.md"
    check "Devin rule files installed" has_all_rule_files "$home/.devin/rules"
    check "old Claude folder removed" file_absent "$home/.claude/unlazier-ai"
    check "old OpenCode plugin removed" file_absent "$home/.config/opencode/plugins/unlazier-ai.ts"
    check "old Claude hook replaced" json_has "$home/.claude/settings.json" \
        '[.hooks.UserPromptSubmit[].hooks[].command] == ["bash \"'"$home"'/.claude/unlazier/inject.sh\" claude prompt"]'
}

test_unsafe_home_refused() {
    local unsafe_home output status
    echo "a home path the hook command cannot carry is refused"
    unsafe_home="$(new_home)/user\$(touch ran)"
    mkdir -p "$unsafe_home"
    output="$(run_installer "$unsafe_home" --harness claude 2>&1)"
    status=$?

    check "install fails" test "$status" -ne 0
    check "the error names the path" test -n "$(printf '%s' "$output" | grep '^Error:' | grep -F "$unsafe_home/.claude")"
    check "nothing written" file_absent "$unsafe_home/.claude"
}

test_invalid_json_left_untouched() {
    local home before
    echo "an unreadable config file is never rewritten"
    home="$(new_home)"
    mkdir -p "$home/.claude"
    printf '{ "model": "opus", // comment\n}\n' > "$home/.claude/settings.json"
    before="$(cksum < "$home/.claude/settings.json")"
    run_installer "$home" --harness claude >/dev/null 2>&1

    check "settings.json unchanged" test "$before" = "$(cksum < "$home/.claude/settings.json")"
    check "rules still installed" has_all_rule_files "$home/.claude/rules"
}

# install.ps1 once flattened settings nested deeper than 20 levels; both installers must keep them.
test_deep_config_kept() {
    local home deepest
    echo "deeply nested user settings survive install and uninstall"
    home="$(new_home)"
    mkdir -p "$home/.claude"
    jq -n '{deep: (reduce range(30) as $level ("kept"; {n: .}))}' > "$home/.claude/settings.json"
    deepest='.deep | getpath([range(30) | "n"]) == "kept"'
    run_installer "$home" --harness claude >/dev/null 2>&1

    check "install keeps the deepest value" json_has "$home/.claude/settings.json" "$deepest"
    run_uninstaller "$home" --harness claude >/dev/null 2>&1
    check "uninstall keeps the deepest value" json_has "$home/.claude/settings.json" "$deepest"
}

# Builds a PATH with the tools the installer needs, minus jq.
path_without_jq() {
    local directory tool
    directory="$(new_home)"
    for tool in bash cat mkdir cp chmod rm mv awk grep sed tr head tail find sort cksum wc dirname mktemp rmdir; do
        ln -s "$(command -v "$tool")" "$directory/$tool"
    done
    echo "$directory"
}

test_missing_jq_installs_rules_only() {
    local home tools output
    echo "without jq, rules are installed and hooks are skipped"
    home="$(new_home)"
    tools="$(path_without_jq)"
    output="$(PATH="$tools" run_installer "$home" --harness claude,kiro 2>&1)"

    check "Claude rules installed" has_all_rule_files "$home/.claude/rules"
    check "Claude hooks skipped" file_absent "$home/.claude/settings.json"
    check "jq install hint shown" test -n "$(printf '%s' "$output" | grep 'jq is not installed')"
}

write_codex_rollout() {
    local home="$1" now="$2" timestamp
    timestamp="$(jq -rn --argjson epoch "$((now - 60))" '$epoch | todate')"
    mkdir -p "$home/.codex/sessions/2026/11/13" "$home/.codex/sessions/2026/11/14"
    printf '%s\n' '{"timestamp":"2026-11-13T00:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1,"window_minutes":300}}}}' \
        > "$home/.codex/sessions/2026/11/13/rollout-2026-11-13T00-00-00-a.jsonl"
    jq -cn --arg timestamp "$timestamp" --argjson resets "$((now + 999))" '
        {timestamp: $timestamp, type: "event_msg", payload: {type: "token_count", rate_limits: {
            primary: {used_percent: 42.6, window_minutes: 300, resets_at: $resets},
            secondary: {used_percent: 61.2, window_minutes: 10080, resets_in_seconds: 5000}}}},
        {timestamp: $timestamp, type: "event_msg", payload: {type: "token_count", rate_limits: null}}' \
        > "$home/.codex/sessions/2026/11/14/rollout-2026-11-14T10-00-00-b.jsonl"
}

last_line() { "$@" | tail -n 1; }

test_inject_usage_lines() {
    local home now
    echo "inject reports usage from each source"
    home="$(new_home)"
    now="$(date +%s)"
    run_installer "$home" --harness claude,codex,gemini,devin,cline,kiro >/dev/null 2>&1
    mkdir -p "$home/.claude/state"
    jq -n --argjson now "$now" '{captured_at: ($now - 120),
        five_hour: {used_percentage: 24.4, resets_at: ($now + 3600)},
        seven_day: {used_percentage: 94, resets_at: ($now - 5)}}' > "$home/.claude/state/rate_limits.json"
    write_codex_rollout "$home" "$now"

    check "Claude usage line" test "$(last_line bash "$home/.claude/unlazier/inject.sh" claude prompt)" \
        = "Usage: 5h 24% | weekly unknown (source: Claude Code status line, 2 min old)"
    check "Claude subagent context is only the usage line" json_has <(bash "$home/.claude/unlazier/inject.sh" claude subagent) \
        '.hookSpecificOutput == {hookEventName: "PostToolUse",
            additionalContext: "Usage: 5h 24% | weekly unknown (source: Claude Code status line, 2 min old)"}'
    check "Codex usage line" test "$(last_line bash "$home/.codex/unlazier/inject.sh" codex prompt)" \
        = "Usage: 5h 43% | weekly 61% (source: Codex session log, 1 min old)"
    check "Codex subagent context is only the usage line" json_has <(bash "$home/.codex/unlazier/inject.sh" codex subagent) \
        '.hookSpecificOutput == {hookEventName: "PostToolUse",
            additionalContext: "Usage: 5h 43% | weekly 61% (source: Codex session log, 1 min old)"}'
    check "Kiro usage unknown" test "$(last_line bash "$home/.kiro/unlazier/inject.sh" kiro prompt)" \
        = "Usage: unknown (this tool does not expose usage windows)"

    jq --argjson old "$((now - 3600))" '.captured_at = $old' "$home/.claude/state/rate_limits.json" \
        > "$home/stale.json" && mv "$home/stale.json" "$home/.claude/state/rate_limits.json"
    check "stale Claude reading is unknown" test "$(last_line bash "$home/.claude/unlazier/inject.sh" claude prompt)" \
        = "Usage: unknown (no usage reading from the last 15 minutes)"

    jq --argjson future "$((now * 1000))" '.captured_at = $future' "$home/.claude/state/rate_limits.json" \
        > "$home/future.json" && mv "$home/future.json" "$home/.claude/state/rate_limits.json"
    check "a reading from the future (milliseconds) is unknown" \
        test "$(last_line bash "$home/.claude/unlazier/inject.sh" claude prompt)" \
        = "Usage: unknown (no usage reading from the last 15 minutes)"
}

# Prints one Codex token_count event with a 5-hour window, as the session log stores it.
codex_reading() {
    jq -cn --arg timestamp "$1" --argjson percent "$2" --argjson resets "$3" '{timestamp: $timestamp,
        type: "event_msg", payload: {type: "token_count", rate_limits: {
            primary: {used_percent: $percent, window_minutes: 300, resets_at: $resets}}}}'
}

test_inject_codex_damaged_log() {
    local home now timestamp cut
    echo "a damaged Codex log keeps its latest reading"
    home="$(new_home)"
    now="$(date +%s)"
    run_installer "$home" --harness codex >/dev/null 2>&1
    timestamp="$(jq -rn --argjson epoch "$((now - 60))" '$epoch | todate')"
    cut="{\"timestamp\":\"$timestamp\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_li"
    mkdir -p "$home/.codex/sessions/2026/11/14"
    # A write cut short by a crash is followed on the same line by the next event, and the last
    # line is half-written while Codex appends to the log.
    {
        codex_reading "$timestamp" 10 "$((now + 999))"
        printf '%s' "$cut"
        codex_reading "$timestamp" 30 "$((now + 999))"
        printf '%s\n' '{"type":"response_item","payload":{"type":"message","content":"cut'
        codex_reading "$timestamp" 42 "$((now + 999))"
        printf '%s' "$cut"
    } > "$home/.codex/sessions/2026/11/14/rollout-2026-11-14T10-00-00-b.jsonl"
    check "broken lines before the reading and a half-written last line are skipped" \
        test "$(last_line bash "$home/.codex/unlazier/inject.sh" codex prompt)" \
        = "Usage: 5h 42% | weekly unknown (source: Codex session log, 1 min old)"
}

# A damaged reading must degrade to the expected usage line: the prompt keeps its reminder and
# exits 0, the subagent event still reports usage, and the gate allows the call.
check_degraded_usage() {
    local home="$1" folder="$2" harness="$3" description="$4" expected="$5" inject output status
    inject="$home/$folder/unlazier/inject.sh"
    output="$(bash "$inject" "$harness" prompt 2>/dev/null)"
    status=$?
    check "$description: the prompt exits 0 with the reminder" \
        test "$status $(printf '%s\n' "$output" | head -n 1)" = "0 Unlazier rules are active for this session."
    check "$description: usage line" test "$(printf '%s\n' "$output" | tail -n 1)" = "$expected"
    check "$description: the subagent event reports it" \
        json_has <(bash "$inject" "$harness" subagent </dev/null 2>/dev/null) ".hookSpecificOutput.additionalContext == \"$expected\""
    check "$description: the gate allows silently" \
        test "$(bash "$inject" "$harness" dispatch 2>/dev/null; echo "exit $?")" = "exit 0"
}

test_inject_malformed_usage() {
    local home now state_file output status
    echo "a malformed usage reading never blocks the hook"
    home="$(new_home)"
    now="$(date +%s)"
    run_installer "$home" --harness claude,codex >/dev/null 2>&1
    mkdir -p "$home/.claude/state"
    state_file="$home/.claude/state/rate_limits.json"

    printf '{"captured_at":"oops","five_hour":{"used_percentage":40,"resets_at":%s}}\n' "$((now + 3600))" > "$state_file"
    check_degraded_usage "$home" .claude claude "captured_at as a string" \
        "Usage: unknown (no usage reading from the last 15 minutes)"
    output="$(bash "$home/.claude/unlazier/inject.sh" claude compact 2>/dev/null)"
    status=$?
    check "captured_at as a string: compaction exits 0 with the principles" \
        test "$status $(printf '%s\n' "$output" | head -n 1)" = "0 # Global Agent Rules"
    printf '{"captured_at":%s,"five_hour":{"used_percentage":"40","resets_at":%s},%s}\n' "$now" "$((now + 3600))" \
        '"seven_day":{"used_percentage":61.2,"resets_at":"oops"}' > "$state_file"
    check_degraded_usage "$home" .claude claude "percentages and reset times as strings" \
        "Usage: 5h unknown | weekly 61% (source: Claude Code status line, 0 min old)"
    printf '[{"captured_at":%s,"five_hour":{"used_percentage":40,"resets_at":%s}}]\n' "$now" "$((now + 3600))" > "$state_file"
    check_degraded_usage "$home" .claude claude "a JSON array" "Usage: unknown (no usage reading available)"
    printf '{"captured_at":%s,' "$now" > "$state_file"
    check_degraded_usage "$home" .claude claude "invalid JSON" "Usage: unknown (no usage reading available)"
    : > "$state_file"
    check_degraded_usage "$home" .claude claude "an empty file" "Usage: unknown (no usage reading available)"
    printf '{"captured_at":%s}\n{"captured_at":%s}\n' "$now" "$now" > "$state_file"
    check_degraded_usage "$home" .claude claude "two JSON documents" "Usage: unknown (no usage reading available)"

    mkdir -p "$home/.codex/sessions/2026/11/14"
    jq -cn --arg timestamp "$(jq -rn --argjson epoch "$((now - 60))" '$epoch | todate')" '
        {timestamp: $timestamp, type: "event_msg", payload: {type: "token_count", rate_limits: {
            primary: {used_percent: "40", window_minutes: 300, resets_at: "oops"},
            secondary: {used_percent: 61.2, window_minutes: 10080, resets_at: "oops", resets_in_seconds: "soon"}}}}' \
        > "$home/.codex/sessions/2026/11/14/rollout-2026-11-14T10-00-00-b.jsonl"
    check_degraded_usage "$home" .codex codex "Codex percentages and reset times as strings" \
        "Usage: 5h unknown | weekly 61% (source: Codex session log, 1 min old)"
}

# Runs inject.sh for the harness from the given directory, as the harness does from the project.
inject_from() {
    local home="$1" folder="$2" harness="$3" event="$4" directory="$5"
    (cd "$directory" && bash "$home/$folder/unlazier/inject.sh" "$harness" "$event")
}

project_rules_of() { inject_from "$@" | grep '^- Project rules:'; }

has_no_project_rules() { ! inject_from "$@" | grep -q 'Project rules:'; }

test_inject_project_rules() {
    local home repository plain wide expected
    echo "inject names the project's own rules file"
    home="$(new_home)"
    run_installer "$home" --harness claude,codex,gemini,kiro >/dev/null 2>&1

    repository="$home/repository"
    mkdir -p "$repository/sub"
    git -C "$repository" init -q
    repository="$(cd "$repository" && pwd -P)"
    # shellcheck disable=SC2016  # the backticks are a literal code fence
    printf '# Rules\n\n## Alpha\n\ntext\n\n```bash\n## not a section\n```\n\n## Beta  \n' > "$repository/CLAUDE.md"
    expected="- Project rules: $repository/CLAUDE.md apply (Alpha, Beta); re-read the relevant section before acting on it."
    check "Claude names the repository CLAUDE.md and its sections" \
        test "$(project_rules_of "$home" .claude claude prompt "$repository/sub")" = "$expected"
    check "the usage line stays last" \
        test -n "$(inject_from "$home" .claude claude prompt "$repository" | tail -n 1 | grep '^Usage:')"
    check "compaction adds no project line" has_no_project_rules "$home" .claude claude compact "$repository"
    check "a harness without a project file adds no line" has_no_project_rules "$home" .kiro kiro prompt "$repository"

    plain="$home/plain"
    mkdir -p "$plain/.claude"
    plain="$(cd "$plain" && pwd -P)"
    printf 'No sections here.\n' > "$plain/.claude/CLAUDE.md"
    check "Claude falls back to .claude/CLAUDE.md, without sections" \
        test "$(project_rules_of "$home" .claude claude prompt "$plain")" \
        = "- Project rules: $plain/.claude/CLAUDE.md apply; re-read the relevant section before acting on it."
    check "Codex without AGENTS.md adds no line" has_no_project_rules "$home" .codex codex prompt "$plain"

    wide="$home/wide"
    mkdir -p "$wide"
    wide="$(cd "$wide" && pwd -P)"
    for number in 1 2 3 4 5 6 7 8 9 10 11 12 13; do printf '## S%s\n' "$number"; done > "$wide/AGENTS.md"
    printf '## Gemini\n' > "$wide/GEMINI.md"

    chmod 000 "$plain/.claude/CLAUDE.md"
    check "an unreadable file keeps the reminder and drops the sections" \
        test "$(inject_from "$home" .claude claude prompt "$plain" 2>&1 | sed -n '1p;/Project rules/p' | tr '\n' '|')" \
        = "Unlazier rules are active for this session.|- Project rules: $plain/.claude/CLAUDE.md apply; re-read the relevant section before acting on it.|"
    chmod 644 "$plain/.claude/CLAUDE.md"
    check "Codex lists at most 12 sections of AGENTS.md" \
        test "$(project_rules_of "$home" .codex codex prompt "$wide")" \
        = "- Project rules: $wide/AGENTS.md apply (S1, S2, S3, S4, S5, S6, S7, S8, S9, S10, S11, S12, ...); re-read the relevant section before acting on it."
    check "Gemini carries the GEMINI.md line in its JSON" json_has <(inject_from "$home" .gemini gemini prompt "$wide") \
        ".hookSpecificOutput.additionalContext | contains(\"- Project rules: $wide/GEMINI.md apply (Gemini);\")"
}

test_inject_output_formats() {
    local home
    echo "inject prints the shape each harness expects"
    home="$(new_home)"
    run_installer "$home" --harness claude,gemini,devin,cline >/dev/null 2>&1

    check "Claude prompt is the reminder text" test "$(bash "$home/.claude/unlazier/inject.sh" claude prompt | head -n 1)" \
        = "Unlazier rules are active for this session."
    check "Claude compaction starts with the principles" test \
        "$(bash "$home/.claude/unlazier/inject.sh" claude compact | head -n 1)" = "# Global Agent Rules"
    check "Gemini output is JSON" json_has <(bash "$home/.gemini/unlazier/inject.sh" gemini prompt) \
        '.hookSpecificOutput.additionalContext | startswith("Unlazier rules")'
    check "Devin output is JSON" json_has <(bash "$home/.devin/unlazier/inject.sh" devin prompt) \
        '.hookSpecificOutput.additionalContext | startswith("Unlazier rules")'
    check "Cline output is JSON" json_has <(bash "$home/Documents/Cline/unlazier/inject.sh" cline prompt) \
        '.contextModification | startswith("Unlazier rules")'
    check "unknown event fails" test "$(bash "$home/.claude/unlazier/inject.sh" claude other >/dev/null 2>&1; echo $?)" = "2"
    check "subagent event fails outside Claude" \
        test "$(bash "$home/.gemini/unlazier/inject.sh" gemini subagent >/dev/null 2>&1; echo $?)" = "2"
}

# Writes a fresh Claude usage reading, or one captured the given number of seconds ago.
write_claude_usage() {
    local home="$1" five_hour="$2" weekly="$3" age="${4:-0}"
    mkdir -p "$home/.claude/state"
    jq -n --argjson now "$(date +%s)" --argjson five_hour "$five_hour" --argjson weekly "$weekly" \
        --argjson age "$age" '{captured_at: ($now - $age),
        five_hour: {used_percentage: $five_hour, resets_at: ($now + 3600)},
        seven_day: {used_percentage: $weekly, resets_at: ($now + 86400)}}' > "$home/.claude/state/rate_limits.json"
}

dispatch_of() { bash "$1/.claude/unlazier/inject.sh" claude dispatch; }

test_inject_dispatch_gate() {
    local home now
    echo "the subagent gate blocks only where the usage ladder forbids subagents"
    home="$(new_home)"
    now="$(date +%s)"
    run_installer "$home" --harness claude,codex,gemini >/dev/null 2>&1

    write_claude_usage "$home" 84.4 40
    check "below 85% the gate allows" dispatch_of "$home"
    check "below 85% the gate prints nothing" test -z "$(dispatch_of "$home")"
    write_claude_usage "$home" 84.6 40
    check "85% after rounding is denied" json_has <(dispatch_of "$home") \
        '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "deny"
            and (.permissionDecisionReason | startswith("Usage: 5h 85%") and contains("continue the work sequentially"))'
    write_claude_usage "$home" 10 99
    check "weekly 99% is denied with a pause" json_has <(dispatch_of "$home") \
        '.hookSpecificOutput.permissionDecisionReason | contains("weekly window is at 99% or more")'
    write_claude_usage "$home" 96 40 3600
    check "a stale reading never blocks" test -z "$(dispatch_of "$home")"
    write_claude_usage "$home" 96 40 -600
    check "a reading from the future never blocks" test -z "$(dispatch_of "$home")"
    write_claude_usage "$home" 96 40 -60
    check "a reading a minute ahead still counts" json_has <(dispatch_of "$home") \
        '.hookSpecificOutput.permissionDecision == "deny"'
    rm -f "$home/.claude/state/rate_limits.json"
    check "a missing reading never blocks" test -z "$(dispatch_of "$home")"

    write_codex_rollout "$home" "$now"
    check "Codex at 43% allows silently" test -z "$(bash "$home/.codex/unlazier/inject.sh" codex dispatch)"
    mkdir -p "$home/.codex/sessions/2026/11/15"
    jq -cn --arg timestamp "$(jq -rn --argjson epoch "$now" '$epoch | todate')" --argjson resets "$((now + 999))" \
        '{timestamp: $timestamp, type: "event_msg", payload: {type: "token_count",
            rate_limits: {primary: {used_percent: 90, window_minutes: 300, resets_at: $resets}}}}' \
        > "$home/.codex/sessions/2026/11/15/rollout-2026-11-15T10-00-00-c.jsonl"
    check "Codex at 90% is denied" json_has <(bash "$home/.codex/unlazier/inject.sh" codex dispatch) \
        '.hookSpecificOutput | .permissionDecision == "deny"
            and (.permissionDecisionReason | startswith("Usage: 5h 90%") and contains("source: Codex session log"))'
    check "the gate is only for Claude and Codex" \
        test "$(bash "$home/.gemini/unlazier/inject.sh" gemini dispatch >/dev/null 2>&1; echo $?)" = "2"
}

test_auto_continue_notice() {
    local home output
    echo "the installer reports auto-continue turned off without changing it"
    home="$(new_home)"
    mkdir -p "$home/.claude"
    jq -n '{autoContinueAtUsageLimit: false}' > "$home/.claude/settings.json"
    output="$(run_installer "$home" --harness claude 2>&1)"

    check "the notice names the setting" test -n "$(printf '%s' "$output" | grep 'autoContinueAtUsageLimit is off')"
    check "the setting stays off" json_has "$home/.claude/settings.json" '.autoContinueAtUsageLimit == false'
    jq '.autoContinueAtUsageLimit = true' "$home/.claude/settings.json" > "$home/on.json" \
        && mv "$home/on.json" "$home/.claude/settings.json"
    output="$(run_installer "$home" --harness claude 2>&1)"
    check "no notice when it is on" test -z "$(printf '%s' "$output" | grep 'autoContinueAtUsageLimit is off')"
}

test_upgrade_removes_obsolete_payload() {
    local home output
    echo "install removes obsolete payload files"
    home="$(new_home)"
    mkdir -p "$home/.claude/unlazier"
    printf 'old\n' > "$home/.claude/unlazier/wait-usage.sh"
    printf 'old\n' > "$home/.claude/unlazier/wait-usage.ps1"
    printf 'keep\n' > "$home/.claude/unlazier/other.txt"
    output="$(run_installer "$home" --harness claude 2>&1)"

    check "obsolete shell waiter removed" file_absent "$home/.claude/unlazier/wait-usage.sh"
    check "obsolete PowerShell waiter removed" file_absent "$home/.claude/unlazier/wait-usage.ps1"
    check "other files in the folder kept" test -f "$home/.claude/unlazier/other.txt"
    check "open sessions told to restart" test -n "$(printf '%s' "$output" | grep 'restart sessions opened before')"
    output="$(run_installer "$home" --harness claude 2>&1)"
    check "no restart notice without waiters" test -z "$(printf '%s' "$output" | grep 'restart sessions opened before')"
}

test_statusline_saves_usage() {
    local home now output
    echo "Claude status line shows and saves usage"
    home="$(new_home)"
    run_installer "$home" --harness claude >/dev/null 2>&1
    now="$(date +%s)"
    output="$(jq -cn --argjson now "$now" '{rate_limits: {
        five_hour: {used_percentage: 24, resets_at: ($now + 600)},
        seven_day: {used_percentage: 94, resets_at: ($now + 3 * 86400 + 11 * 3600 + 30 * 60 + 30)}}}' \
        | bash "$home/.claude/unlazier/claude-statusline.sh")"

    check "status line shows the 5-hour window" test -n "$(printf '%s' "$output" | grep 'Session 5h: .* 24%')"
    check "reset time shows days" test -n "$(printf '%s' "$output" | grep 'Weekly .* resets in 3d 11h 30m$')"
    check "usage saved for the hook" json_has "$home/.claude/state/rate_limits.json" \
        '.five_hour.used_percentage == 24 and (.captured_at | type) == "number"'
    check "broken input degrades" test "$(printf 'garbage' | bash "$home/.claude/unlazier/claude-statusline.sh")" \
        = "Usage: no data"
}

test_statusline_temporary_file_unpredictable() {
    local home state_folder
    echo "the status line leaves a file at a guessable temporary name alone"
    home="$(new_home)"
    run_installer "$home" --harness claude >/dev/null 2>&1
    state_folder="$home/.claude/state"
    mkdir -p "$state_folder"
    printf 'planted\n' > "$state_folder/rate_limits.json.tmp"
    jq -cn '{rate_limits: {five_hour: {used_percentage: 24}}}' | bash "$home/.claude/unlazier/claude-statusline.sh" >/dev/null

    check "planted file unchanged" test "$(cat "$state_folder/rate_limits.json.tmp" 2>/dev/null)" = "planted"
    check "usage saved" json_has "$state_folder/rate_limits.json" '.five_hour.used_percentage == 24'
    check "no temporary files left" test "$(find "$state_folder" -type f | wc -l | tr -d ' ')" = "2"
}

main() {
    command -v jq >/dev/null 2>&1 || { echo "jq is required to run these tests" >&2; exit 1; }
    test_install_preserves_user_content
    test_install_adds_all_layers
    test_reinstall_is_idempotent
    test_uninstall_restores_original_files
    test_config_files_rewritten_in_place
    test_temporary_file_names_unpredictable
    test_foreign_unlazier_paths_kept
    test_unclosed_marker_keeps_text
    test_v1_leftovers_removed_with_yes
    test_v1_leftovers_kept_without_confirmation
    test_own_global_rules_file_kept
    test_upgrade_from_v2_0_layout
    test_unsafe_home_refused
    test_invalid_json_left_untouched
    test_deep_config_kept
    test_missing_jq_installs_rules_only
    test_inject_usage_lines
    test_inject_malformed_usage
    test_inject_codex_damaged_log
    test_inject_output_formats
    test_inject_project_rules
    test_inject_dispatch_gate
    test_auto_continue_notice
    test_upgrade_removes_obsolete_payload
    test_statusline_saves_usage
    test_statusline_temporary_file_unpredictable
    test_cline_question_alert_filters_tools
    echo
    echo "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}

main
