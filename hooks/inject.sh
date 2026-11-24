#!/bin/bash
# Unlazier context hook for Linux and macOS.
#
# Usage: inject.sh <harness> <prompt|compact|subagent|dispatch>
#   prompt   prints the short reminder and the usage line; runs on every user prompt.
#   compact  prints the core principles, the reminder, and the usage line; runs after
#            context compaction, when the original instructions may have been summarized away.
#   subagent prints only the usage line, as Claude Code or Codex PostToolUse context; runs after
#            each subagent call, so a long turn sees usage change between prompts.
#   dispatch denies a Claude Code or Codex subagent call while the usage ladder forbids
#            subagents (5-hour window at 85% or more, weekly at 99% or more) and prints nothing
#            otherwise.
#
# Rules loaded at session start lose weight as the context window fills, so the harness
# calls this hook to place a compact copy near the end of the context. Installed at
# <harness home>/unlazier/inject.sh next to reminder.md and AGENTS.md; requires jq.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_HOME="$(dirname "$SCRIPT_DIR")"
MAX_READING_AGE_SECONDS=900
# A reading further ahead than this (milliseconds instead of seconds, or a wrong clock) would never
# go stale, so it counts as stale at once.
MAX_CLOCK_SKEW_SECONDS=300
MAX_SECTION_TITLES=12

# The "## " titles of a Markdown file, comma-separated, skipping fenced code blocks.
# shellcheck disable=SC2016  # awk program, not a shell expansion
SECTION_TITLES_PROGRAM='
/^(```|~~~)/ { fenced = !fenced; next }
!fenced && /^## / {
    title = $0
    sub(/^## +/, "", title)
    sub(/[ \t\r]+$/, "", title)
    count++
    if (count <= max) titles = titles (count > 1 ? ", " : "") title
}
END { if (count > max) titles = titles ", ..."; print titles }
'

# Normalized usage reading: {"five_hour": <percent|null>, "weekly": <percent|null>, "captured_at": <epoch|null>}.
# A window counts only while its reset time is still in the future. A field that is not a number
# counts as missing, so a damaged reading becomes unknown usage instead of a jq error. The Claude
# file is slurped so that anything but a single JSON object is rejected.
# shellcheck disable=SC2016  # jq programs, not shell expansions
CLAUDE_USAGE_PROGRAM='
def number: if type == "number" then . else null end;
def live: if type != "object" then null
    else (.used_percentage | number) as $percent
        | if $percent != null and (((.resets_at | number) // now + 1) > now) then $percent else null end
    end;
if length == 1 and (.[0] | type) == "object" then
    .[0] | {five_hour: (.five_hour | live), weekly: (.seven_day | live), captured_at: (.captured_at | number)}
else error("the usage file is not one JSON object") end
'

# shellcheck disable=SC2016
CODEX_USAGE_PROGRAM='
def number: if type == "number" then . else null end;
def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
(.timestamp | epoch) as $captured_at
| [.payload.rate_limits.primary, .payload.rate_limits.secondary] | map(objects)
| map(. + {resets_epoch: ((.resets_at | number)
    // (if (.resets_in_seconds | number) != null then $captured_at + .resets_in_seconds else null end))})
| def pick($minutes): (map(select(.window_minutes == $minutes and (.used_percent | number) != null
        and ((.resets_epoch // now + 1) > now))) | first | .used_percent) // null;
{five_hour: pick(300), weekly: pick(10080), captured_at: $captured_at}
'

# shellcheck disable=SC2016
FORMAT_USAGE_PROGRAM='
def percent: if . == null then "unknown" else "\(. + 0.5 | floor)%" end;
if .captured_at == null or (now - .captured_at) > $max_age or (.captured_at - now) > $max_skew then
    "Usage: unknown (no usage reading from the last 15 minutes)"
else
    "Usage: 5h \(.five_hour | percent) | weekly \(.weekly | percent) (source: \($source), \((now - .captured_at) / 60 | floor) min old)"
end
'

# Why the usage ladder forbids a new subagent, or nothing when it allows one. Percentages are
# rounded as in the usage line, so the gate agrees with what the model reads. Only a fresh
# reading can deny: with unknown usage the ladder still allows 2-3 concurrent tasks.
# shellcheck disable=SC2016
DISPATCH_BLOCK_PROGRAM='
def rounded: if . == null then -1 else (. + 0.5 | floor) end;
if .captured_at == null or (now - .captured_at) > $max_age or (.captured_at - now) > $max_skew then empty
elif (.weekly | rounded) >= 99 then
    "\($usage). The weekly window is at 99% or more: start no subagent; finish the current step, report, and wait for the user."
elif (.five_hour | rounded) >= 85 then
    "\($usage). The 5-hour window is at 85% or more: start no subagent; continue the work sequentially in this session."
else empty end
'

read_claude_usage() {
    local state_file="$HARNESS_HOME/state/rate_limits.json"
    [ -f "$state_file" ] || return 1
    jq -cs "$CLAUDE_USAGE_PROGRAM" "$state_file" 2>/dev/null
}

read_codex_usage() {
    local sessions_dir="$HARNESS_HOME/sessions" newest_rollout last_event
    [ -d "$sessions_dir" ] || return 1
    # Rollout paths are sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl, so the
    # lexicographic maximum is the most recent session.
    newest_rollout="$(find "$sessions_dir" -type f -name 'rollout-*.jsonl' | sort | tail -n 1)"
    [ -n "$newest_rollout" ] || return 1
    # The log grows with the session and is read before and after every subagent call, so grep keeps
    # only token_count lines and awk puts the newest first, letting jq stop at the first reading.
    # Each line is parsed on its own: one broken by a crash or still being written hides no other.
    last_event="$(grep -F '"token_count"' "$newest_rollout" 2>/dev/null \
        | awk '{ lines[NR] = $0 } END { for (number = NR; number > 0; number--) print lines[number] }' \
        | jq -cnR 'first(inputs | (fromjson | select(.type == "event_msg" and .payload.type == "token_count"
            and .payload.rate_limits != null))?)')"
    [ -n "$last_event" ] || return 1
    printf '%s' "$last_event" | jq -c "$CODEX_USAGE_PROGRAM" 2>/dev/null
}

# The normalized usage reading of a harness that exposes one; fails for the others.
read_usage() {
    case "$1" in
        claude) read_claude_usage ;;
        codex) read_codex_usage ;;
        *) return 1 ;;
    esac
}

usage_line() {
    local harness="$1" reading="" source=""
    case "$harness" in
        claude) source="Claude Code status line" ;;
        codex) source="Codex session log" ;;
        *)
            echo "Usage: unknown (this tool does not expose usage windows)"
            return 0
            ;;
    esac
    reading="$(read_usage "$harness")" || reading=""
    if [ -z "$reading" ]; then
        echo "Usage: unknown (no usage reading available)"
        return 0
    fi
    # A failing usage line would make Claude Code block the prompt, so usage data never fails the hook.
    printf '%s' "$reading" | jq -r --arg source "$source" --argjson max_age "$MAX_READING_AGE_SECONDS" \
        --argjson max_skew "$MAX_CLOCK_SKEW_SECONDS" "$FORMAT_USAGE_PROGRAM" 2>/dev/null \
        || echo "Usage: unknown (no usage reading available)"
}

# A missing or unreadable reading allows the subagent: the gate never blocks on unknown usage.
dispatch_block_reason() {
    local harness="$1" reading
    reading="$(read_usage "$harness")" || return 0
    [ -n "$reading" ] || return 0
    printf '%s' "$reading" | jq -r --argjson max_age "$MAX_READING_AGE_SECONDS" \
        --argjson max_skew "$MAX_CLOCK_SKEW_SECONDS" --arg usage "$(usage_line "$harness")" "$DISPATCH_BLOCK_PROGRAM"
}

# Prints the project's own instruction file for the harness; fails for harnesses without one.
# The harness runs the hook from the project, so the repository root comes from the working
# directory, or the directory itself outside a repository.
project_rules_file() {
    local harness="$1" root name names
    case "$harness" in
        claude) names="CLAUDE.md .claude/CLAUDE.md" ;;
        codex|opencode|amp) names="AGENTS.md" ;;
        gemini) names="GEMINI.md" ;;
        *) return 1 ;;
    esac
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="$(pwd -P)"
    for name in $names; do
        if [ -f "$root/$name" ]; then
            echo "$root/$name"
            return 0
        fi
    done
    return 1
}

# The project's rules lose weight between compactions like the global ones, but repeating the
# whole file on every prompt would fill the context, so the reminder names it and its sections.
project_rules_line() {
    local file titles
    file="$(project_rules_file "$1")" || return 0
    # A file that cannot be read still gets its line, without sections: the reminder must not
    # break, and the path lets the agent open the file and see the error itself.
    titles="$(awk -v max="$MAX_SECTION_TITLES" "$SECTION_TITLES_PROGRAM" "$file" 2>/dev/null)" || titles=""
    if [ -n "$titles" ]; then
        echo "- Project rules: $file apply ($titles); re-read the relevant section before acting on it."
    else
        echo "- Project rules: $file apply; re-read the relevant section before acting on it."
    fi
}

build_context() {
    local harness="$1" event="$2"
    case "$event" in
        prompt)
            cat "$SCRIPT_DIR/reminder.md"
            project_rules_line "$harness"
            ;;
        compact)
            cat "$SCRIPT_DIR/AGENTS.md"
            echo
            cat "$SCRIPT_DIR/reminder.md"
            ;;
        subagent|dispatch)
            # Only these harnesses expose usage and have subagents with after- and before-tool hooks.
            case "$harness" in
                claude|codex) ;;
                *)
                    echo "inject.sh: the $event event is only for claude and codex" >&2
                    return 1
                    ;;
            esac
            if [ "$event" = "dispatch" ]; then
                dispatch_block_reason "$harness"
                return 0
            fi
            # The reminder already arrived with the prompt; only the usage may have changed.
            ;;
        *)
            echo "inject.sh: unknown event '$event' (expected prompt, compact, subagent, or dispatch)" >&2
            return 1
            ;;
    esac
    usage_line "$harness"
}

# Each harness expects its own output shape; see the adapter table in README.md.
emit() {
    local harness="$1" event="$2" context="$3"
    case "$harness" in
        claude|codex)
            case "$event" in
                subagent)
                    # After a tool call, both tools pass hook output to the model only as JSON.
                    jq -n --arg context "$context" \
                        '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $context}}'
                    ;;
                dispatch)
                    # No output lets the call through; a deny decision blocks it and tells the model why.
                    if [ -n "$context" ]; then
                        jq -n --arg reason "$context" '{hookSpecificOutput: {hookEventName: "PreToolUse",
                            permissionDecision: "deny", permissionDecisionReason: $reason}}'
                    fi
                    ;;
                *)
                    printf '%s\n' "$context"
                    ;;
            esac
            ;;
        # The OpenCode and Amp plugins read this plain text and hand it to the model themselves.
        kiro|opencode|amp)
            printf '%s\n' "$context"
            ;;
        gemini)
            jq -n --arg context "$context" \
                '{hookSpecificOutput: {hookEventName: "BeforeAgent", additionalContext: $context}}'
            ;;
        devin)
            jq -n --arg context "$context" \
                '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $context}}'
            ;;
        cline)
            jq -n --arg context "$context" '{cancel: false, contextModification: $context}'
            ;;
        *)
            echo "inject.sh: unknown harness '$harness'" >&2
            return 1
            ;;
    esac
}

main() {
    if [ "$#" -ne 2 ]; then
        echo "Usage: inject.sh <harness> <prompt|compact|subagent|dispatch>" >&2
        exit 2
    fi
    local context
    context="$(build_context "$1" "$2")" || exit 2
    emit "$1" "$2" "$context"
}

main "$@"
