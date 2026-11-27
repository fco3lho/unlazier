#!/bin/bash
# Unlazier context hook for Linux and macOS.
#
# Usage: inject.sh <harness> <event>, or inject.sh claude wait <session id>
#   prompt       prints the short reminder and the usage line; runs on every user prompt.
#   compact      prints the core principles (except in Claude Code, which reloads them itself), the
#                reminder, and the usage line; runs after context compaction, when the original
#                instructions may have been summarized away.
#   subagent     (Codex) prints only the usage line as PostToolUse context after each subagent call.
#   dispatch     (Claude Code, Codex) denies a subagent call that the usage band does not allow and
#                prints nothing otherwise.
#   tool         (Claude Code) runs after every tool call, in the main agent and in subagents; prints
#                the usage line when the band changed since that agent last heard it, and tells
#                subagents to wrap up in band 4.
#   stop         (Claude Code) keeps the turn going in band 4 until the waiter runs, once when the
#                agent ends the turn over usage in bands 2 and 3, and once per running subagent when
#                it ends the turn in bands 1 to 3 while subagents run.
#   agent-start, agent-stop
#                (Claude Code) keep the count of running subagents that the gate reads in band 2.
#   wait         (Claude Code) started by the agent in the background in band 4: sleeps once until
#                the full window resets plus WAIT_MARGIN_SECONDS and exits, which wakes the session.
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
MAX_TITLE_CHARACTERS=60
MAX_TITLE_LIST_CHARACTERS=400
MAX_PROJECT_RULES_BYTES=65536

# Usage bands, as in rules/parallelism.md: a rounded percentage up to the first limit is band 1, up
# to the second band 2, up to the third band 3, and above it band 4. The stricter window sets the band.
FIVE_HOUR_BAND_LIMITS='[70, 85, 95]'
WEEKLY_BAND_LIMITS='[90, 95, 98]'
UNKNOWN_USAGE_BAND=2
BAND_2_SUBAGENT_LIMIT=2
WAIT_MARGIN_SECONDS=180
STATE_DIR="$SCRIPT_DIR/state"
# A subagent killed or cut by an API error may never report its end, and an allowed launch may never
# start (the user can refuse its permission), so their places in the count expire.
MAX_SUBAGENT_SECONDS=18000
MAX_RESERVATION_SECONDS=120
# A stop message that gives usage as the reason, in English, Portuguese, and Spanish.
USAGE_STOP_PATTERN='(5-hour|five-hour|weekly|usage) (window|limit)|rate limit|janela (de 5 horas|semanal|de uso)|limite (de uso|semanal)|ventana (de 5 horas|semanal|de uso)|l[ií]mite (de uso|semanal)'
HOOK_INPUT=""


# The project rules line, from the "## " titles of a Markdown file read on standard input. The file
# comes from the repository but reaches the model as Unlazier's own text, so headings hidden from
# readers (in fenced code or HTML comments) are skipped, control and bidirectional characters are
# removed, and titles and their list are capped. Lengths count code points, as in inject.ps1.
# shellcheck disable=SC2016  # jq program, not a shell expansion
PROJECT_RULES_PROGRAM='
def fence: startswith("```") or startswith("~~~");
# The part of a line outside HTML comments, and whether a comment is still open at its end.
def outside_comments($commented):
    if $commented then
        if index("-->") != null then sub("^.*?-->"; "") | outside_comments(false) else {text: "", commented: true} end
    elif index("<!--") != null then
        gsub("<!--.*?-->"; "")
        | if index("<!--") != null then {text: sub("<!--.*$"; ""), commented: true} else {text: ., commented: false} end
    else {text: ., commented: false} end;
# Code points of category Cc, and the bidirectional controls U+202A-U+202E and U+2066-U+2069.
def control: . < 32 or (. >= 127 and . < 160);
def bidirectional: (. >= 8234 and . <= 8238) or (. >= 8294 and . <= 8297);
def title: .[3:] | explode | map(select(control or bidirectional | not))
    | until(length == 0 or .[0] != 32; .[1:]) | until(length == 0 or .[-1] != 32; .[:-1])
    | if length > $max_title then (.[:$max_title] | implode) + "..." else implode end;
# One title past the cap is enough to know that the list leaves some out.
(reduce inputs as $line ({fenced: false, commented: false, titles: []};
    if (.titles | length) > $max_titles then .
    elif .fenced then .fenced = ($line | fence | not)
    elif (.commented | not) and ($line | fence) then .fenced = true
    else .commented as $commented
        | ($line | outside_comments($commented)) as $visible
        | .commented = $visible.commented
        | if ($commented | not) and ($line | startswith("## ")) then
            .titles += [$visible.text | title | select(. != "")]
          else . end
    end).titles
    | reduce .[] as $title ({titles: [], characters: 0, omitted: false};
        (.characters + (if .titles == [] then 0 else 2 end) + ($title | length)) as $characters
        | if .omitted then .
          elif (.titles | length) == $max_titles or $characters > $max_characters then .omitted = true
          else .titles += [$title] | .characters = $characters end)
    | (.titles | join(", ")) + (if .omitted then ", ..." else "" end)) as $titles
| ($path | explode | map(select(control | not)) | implode) as $file
| if $titles == "" then "- Project rules: \($file) apply; re-read the relevant section before acting on it."
    else "- Project rules: \($file) apply (\($titles)); re-read the relevant section before acting on it." end
'

# Normalized usage reading: {five_hour, weekly: <percent|null>, five_hour_resets_at,
# weekly_resets_at: <epoch|null>, captured_at: <epoch|null>}. A window whose reset time has passed
# has reset, so it counts as 0% until the next reading. A field that is not a number counts as
# missing, so a damaged reading becomes unknown usage instead of a jq error. The Claude file is
# slurped so that anything but a single JSON object is rejected.
# shellcheck disable=SC2016  # jq programs, not shell expansions
CLAUDE_USAGE_PROGRAM='
def number: if type == "number" then . else null end;
def window: if type != "object" or (.used_percentage | number) == null then {percent: null, resets_at: null}
    elif (.resets_at | number) != null and .resets_at <= now then {percent: 0, resets_at: null}
    else {percent: .used_percentage, resets_at: (.resets_at | number)} end;
if length == 1 and (.[0] | type) == "object" then
    .[0] | (.five_hour | window) as $five | (.seven_day | window) as $weekly
    | {five_hour: $five.percent, weekly: $weekly.percent, five_hour_resets_at: $five.resets_at,
       weekly_resets_at: $weekly.resets_at, captured_at: (.captured_at | number)}
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
| def pick($minutes): (map(select(.window_minutes == $minutes and (.used_percent | number) != null)) | first)
    | if . == null then {percent: null, resets_at: null}
      elif .resets_epoch != null and .resets_epoch <= now then {percent: 0, resets_at: null}
      else {percent: .used_percent, resets_at: .resets_epoch} end;
pick(300) as $five | pick(10080) as $weekly
| {five_hour: $five.percent, weekly: $weekly.percent, five_hour_resets_at: $five.resets_at,
   weekly_resets_at: $weekly.resets_at, captured_at: $captured_at}
'

# The band, the time the full windows reset (0 when none is full or its reset is unknown), and the
# usage line of a normalized reading (null when there is none), separated by tabs. Percentages are
# rounded as shown, so the band agrees with the numbers the model reads. A window without a
# reading counts as band 2, and so does a stale reading.
# shellcheck disable=SC2016
USAGE_STATUS_PROGRAM='
def rounded: if . == null then null else (. + 0.5 | floor) end;
def percent: if . == null then "unknown" else "\(.)%" end;
def band($limits): if . == null then $unknown_band elif . <= $limits[0] then 1 elif . <= $limits[1] then 2
    elif . <= $limits[2] then 3 else 4 end;
if . == null then [$unknown_band, 0, "Usage: unknown (\($missing))"]
elif .captured_at == null or (now - .captured_at) > $max_age or (.captured_at - now) > $max_skew then
    [$unknown_band, 0, "Usage: unknown (no usage reading from the last 15 minutes)"]
else
    (.five_hour | rounded) as $five | (.weekly | rounded) as $weekly
    | ($five | band($five_limits)) as $five_band | ($weekly | band($weekly_limits)) as $weekly_band
    | [([$five_band, $weekly_band] | max),
       ([(if $five_band == 4 then .five_hour_resets_at else empty end),
         (if $weekly_band == 4 then .weekly_resets_at else empty end)] | map(numbers) | max | . // 0 | floor),
       "Usage: 5h \($five | percent) | weekly \($weekly | percent) (source: \($source), \((now - .captured_at) / 60 | floor) min old)"]
end
| map(tostring) | join("\t")
'

# The session state with expired entries dropped: {agents: {<agent id>: <start epoch>},
# reservations: [<epoch of an allowed launch not started yet>], announced: {<"main" or agent id>:
# <band last told>}, held: {<agent id>: true once a stop was held while it ran}, waiter: {pid,
# until}}. Anything damaged starts over empty.
# shellcheck disable=SC2016
STATE_PROGRAM='
def current: (if type == "object" then . else {} end)
    | .agents = ((.agents // {}) | if type == "object"
        then with_entries(select((.value | type) == "number" and .value > now - $max_agent_age)) else {} end)
    | .reservations = ((.reservations // []) | if type == "array"
        then map(select(type == "number" and . > now - $max_reservation_age)) else [] end)
    | .announced = ((.announced // {}) | if type == "object" then . else {} end)
    | .held = ((.held // {}) | if type == "object" then . else {} end);
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

# Prints the band, the reset time of the full windows, and the usage line of the harness, separated
# by tabs. Usage data never fails the hook: a failing usage line would make Claude Code block the prompt.
usage_status() {
    local harness="$1" reading="null" source="" missing="no usage reading available"
    case "$harness" in
        claude) source="Claude Code status line" ;;
        codex) source="Codex session log" ;;
        *) missing="this tool does not expose usage windows" ;;
    esac
    if [ -n "$source" ]; then
        reading="$(read_usage "$harness")" || reading=""
        [ -n "$reading" ] || reading="null"
    fi
    printf '%s' "$reading" | jq -r --arg source "$source" --arg missing "$missing" \
        --argjson max_age "$MAX_READING_AGE_SECONDS" --argjson max_skew "$MAX_CLOCK_SKEW_SECONDS" \
        --argjson five_limits "$FIVE_HOUR_BAND_LIMITS" --argjson weekly_limits "$WEEKLY_BAND_LIMITS" \
        --argjson unknown_band "$UNKNOWN_USAGE_BAND" "$USAGE_STATUS_PROGRAM" 2>/dev/null \
        || printf '%s\t0\t%s\n' "$UNKNOWN_USAGE_BAND" "Usage: unknown (no usage reading available)"
}

# What the band asks of the agent. Only Claude Code can wake a session from a background command,
# so only there does band 4 end in a wait instead of a report to the user.
band_rule() {
    local harness="$1" band="$2"
    case "$band" in
        1) echo "Band 1: maximum parallelism." ;;
        2) echo "Band 2: start a subagent only while fewer than $BAND_2_SUBAGENT_LIMIT are running." ;;
        3) echo "Band 3: start no subagent; continue the work yourself in this session." ;;
        4)
            if [ "$harness" = claude ]; then
                echo "Band 4: start nothing new; running subagents wrap up, then start the waiter and end the turn."
            else
                echo "Band 4: start nothing new; finish the current step, report, and wait for the user."
            fi
            ;;
        *)
            echo "inject.sh: unknown band '$band'" >&2
            return 1
            ;;
    esac
}

# Sets BAND, RESUME_AT, USAGE_TEXT (the reading alone), and USAGE_LINE (the reading and its band).
load_usage() {
    local harness="$1"
    IFS=$'\t' read -r BAND RESUME_AT USAGE_TEXT <<< "$(usage_status "$harness")"
    USAGE_LINE="$USAGE_TEXT. $(band_rule "$harness" "$BAND")"
}

waiter_instruction() {
    printf 'Start the waiter now with run_in_background: bash "%s/inject.sh" claude wait %s. Let the running subagents wrap up, then end the turn; the waiter wakes the session after the reset.' \
        "$SCRIPT_DIR" "$1"
}

# Claude Code passes the hook input as JSON on standard input.
read_hook_input() {
    [ -t 0 ] && return 0
    HOOK_INPUT="$(cat 2>/dev/null)"
}

hook_field() {
    printf '%s' "$HOOK_INPUT" | jq -r --arg name "$1" '.[$name] // "" | tostring' 2>/dev/null
}

# Session and agent ids come from the hook input and name files or JSON keys, so anything but a
# plain id is refused.
is_plain_id() {
    case "$1" in
        ""|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    [ "${#1}" -le 128 ]
}

session_file() { printf '%s/session-%s.json' "$STATE_DIR" "$1"; }

# The file is slurped so that an empty file, left by a full disk for example, reads as empty state.
# jq still prints the empty state for a missing file before failing, so that case is handled first.
read_state() {
    if [ -f "$1" ] && jq -cs --argjson max_agent_age "$MAX_SUBAGENT_SECONDS" \
        --argjson max_reservation_age "$MAX_RESERVATION_SECONDS" "$STATE_PROGRAM .[0] | current" "$1" 2>/dev/null; then
        return 0
    fi
    echo '{"agents":{},"reservations":[],"announced":{}}'
}

# Applies a jq program to the session state; the caller holds the lock. The new state replaces the
# old one in a single rename, so a hook that only reads never sees half a file.
write_state() {
    local file="$1" program="$2" temporary
    shift 2
    temporary="$(mktemp "$file.XXXXXX")" || return 1
    if read_state "$file" | jq -c --argjson max_agent_age "$MAX_SUBAGENT_SECONDS" \
        --argjson max_reservation_age "$MAX_RESERVATION_SECONDS" "$@" "$STATE_PROGRAM current | $program" > "$temporary"; then
        mv "$temporary" "$file"
    else
        rm -f "$temporary"
        return 1
    fi
}

# Runs a command while holding the lock of the session file. Hooks of parallel tool calls run at the
# same time, so every change to the state is made under it. The lock is a file bash creates under
# noclobber, an exclusive open made by bash itself: mkdir is not atomic in every coreutils (uutils
# mkdir 0.10, the default in recent Ubuntu, lets two callers create the same directory), and flock
# is missing on macOS. A lock older than a minute was left by a hook that died and is taken over.
# Returns the command's status, or 75 when the lock cannot be taken.
with_lock() {
    local file="$1" lock="$1.lock" status
    shift
    if ! mkdir -p "$STATE_DIR" || [ ! -w "$STATE_DIR" ]; then
        echo "inject.sh: cannot write $STATE_DIR" >&2
        return 75
    fi
    for _ in $(seq 1 100); do
        if (set -C; : > "$lock") 2>/dev/null; then
            "$@"
            status=$?
            rm -f "$lock"
            return "$status"
        fi
        if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            rm -f "$lock"
        fi
        sleep 0.05
    done
    echo "inject.sh: could not lock $file" >&2
    return 75
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
    local file
    file="$(project_rules_file "$1")" || return 0
    # A file that cannot be read still gets its line, without sections: the reminder must not
    # break, and the path lets the agent open the file and see the error itself.
    head -c "$MAX_PROJECT_RULES_BYTES" "$file" 2>/dev/null | jq -nrR --arg path "$file" \
        --argjson max_titles "$MAX_SECTION_TITLES" --argjson max_title "$MAX_TITLE_CHARACTERS" \
        --argjson max_characters "$MAX_TITLE_LIST_CHARACTERS" "$PROJECT_RULES_PROGRAM"
}

# The prompt carries the usage line, so the main agent has heard the current band; in band 4 it
# also needs the waiter command, which names the session. Session files older than a week belong
# to sessions long closed.
remember_main_band() {
    local session file
    session="$(hook_field session_id)"
    is_plain_id "$session" || return 0
    if [ "$BAND" = 4 ]; then
        waiter_instruction "$session"
        echo
    fi
    file="$(session_file "$session")"
    # shellcheck disable=SC2016  # jq program, not a shell expansion
    with_lock "$file" write_state "$file" '.announced.main = $band' --argjson band "$BAND" || true
    find "$STATE_DIR" -maxdepth 1 -name 'session-*' -mtime +7 -exec rm -rf {} + 2>/dev/null
    return 0
}

# Takes a place among the running subagents when fewer than the band 2 limit are taken; the caller
# holds the lock. Returns 1 when the places are taken, and 2 when the state cannot be used.
reserve_subagent() {
    local file="$1" taken
    taken="$(read_state "$file" | jq '(.agents | length) + (.reservations | length)')" || return 2
    [ "$taken" -lt "$BAND_2_SUBAGENT_LIMIT" ] || return 1
    write_state "$file" '.reservations += [now]' || return 2
}

# Why the band forbids a new subagent, or nothing when it allows one. Codex reports no subagent
# start or end, so only Claude Code counts the running subagents in band 2.
dispatch_reason() {
    local harness="$1" session file status
    load_usage "$harness"
    session="$(hook_field session_id)"
    case "$BAND" in
        1) ;;
        2)
            # Without a session id or a usable state the running subagents cannot be counted, so the
            # call is allowed.
            if [ "$harness" = claude ] && is_plain_id "$session"; then
                file="$(session_file "$session")"
                with_lock "$file" reserve_subagent "$file"
                status=$?
                if [ "$status" = 1 ]; then
                    echo "$USAGE_LINE $BAND_2_SUBAGENT_LIMIT subagents are running: wait for one to finish, or do this task yourself."
                fi
            fi
            ;;
        3) echo "$USAGE_LINE" ;;
        4)
            if [ "$harness" = claude ] && is_plain_id "$session"; then
                echo "$USAGE_LINE $(waiter_instruction "$session")"
            else
                echo "$USAGE_LINE"
            fi
            ;;
        *)
            echo "inject.sh: unknown band '$BAND'" >&2
            return 1
            ;;
    esac
}

# Records the band told to an agent; fails when that agent already heard it. The caller holds the lock.
record_band() {
    local file="$1" key="$2" band="$3"
    [ "$(read_state "$file" | jq -r --arg key "$key" '.announced[$key] // "none" | tostring')" != "$band" ] || return 1
    # shellcheck disable=SC2016  # jq program, not a shell expansion
    write_state "$file" '.announced[$key] = $band' --arg key "$key" --argjson band "$band"
}

# The usage line, after any tool call, when the band changed since the agent last heard it. A
# subagent hears only band 4, its signal to wrap up; the gate enforces the other bands.
tool_context() {
    local session agent key file
    session="$(hook_field session_id)"
    agent="$(hook_field agent_id)"
    is_plain_id "$session" || return 0
    key="main"
    if [ -n "$agent" ]; then
        is_plain_id "$agent" || return 0
        key="$agent"
    fi
    file="$(session_file "$session")"
    load_usage claude
    # An unchanged band, the common case, needs no lock.
    if [ "$(read_state "$file" | jq -r --arg key "$key" '.announced[$key] // "none" | tostring')" = "$BAND" ]; then
        return 0
    fi
    with_lock "$file" record_band "$file" "$key" "$BAND" || return 0
    if [ "$key" = main ]; then
        echo "$USAGE_LINE"
        if [ "$BAND" = 4 ]; then
            waiter_instruction "$session"
        fi
    elif [ "$BAND" = 4 ]; then
        echo "$USAGE_TEXT. Band 4. Wrap up now: finish the current step at a consistent point (commit or checkpoint), report what is done and what is left, and end your run."
    fi
    return 0
}

waiter_is_running() {
    local pid
    pid="$(read_state "$1" | jq -r 'if (.waiter.until | type) == "number" and .waiter.until > now
        then .waiter.pid // "" | tostring else "" end')"
    case "$pid" in
        ""|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null
}

# Devin also runs the hooks it finds in the Claude Code settings, so only a session whose transcript
# lives in this Claude Code folder may be held.
is_claude_code_session() {
    case "$(hook_field transcript_path)" in
        "$HARNESS_HOME"/projects/*) return 0 ;;
        *) return 1 ;;
    esac
}

stop_blames_usage() {
    printf '%s' "$HOOK_INPUT" | jq -e --arg pattern "$USAGE_STOP_PATTERN" \
        '(.last_assistant_message // "") | tostring | test($pattern; "i")' >/dev/null 2>&1
}

# Prints how many subagents are running and marks them as held; fails when none of them is new since
# the last hold, so a session with nothing else to do is not held again. The caller holds the lock.
mark_waiting_stop() {
    local file="$1" count
    count="$(read_state "$file" | jq '.held as $held
        | if any(.agents | keys[]; $held[.] != true) then .agents | length else 0 end')" || return 1
    [ "$count" -gt 0 ] || return 1
    write_state "$file" '.held = (.agents | map_values(true))' || return 1
    echo "$count"
}

# Why a turn that ends while subagents run must go on once, or nothing.
waiting_stop_reason() {
    local file count action
    file="$(session_file "$1")"
    count="$(with_lock "$file" mark_waiting_stop "$file")" || return 0
    if [ "$BAND" = 1 ] || { [ "$BAND" = 2 ] && [ "$count" -lt "$BAND_2_SUBAGENT_LIMIT" ]; }; then
        action="start or continue work that is independent of them"
    else
        action="continue, without starting a subagent, work in this session that is independent of them"
    fi
    echo "$USAGE_LINE $count subagent(s) still running. Before ending the turn, $action: other tasks of the request, preparation of the next step, checks of what already finished. End the turn only if nothing independent is left or a decision belongs to the user, and say which."
}

# Why the turn must go on, or nothing to let it end. A stop the hook already continued always ends,
# so the hook never holds a turn twice for the same reason.
stop_reason() {
    local session
    [ "$(hook_field stop_hook_active)" = true ] && return 0
    session="$(hook_field session_id)"
    if ! is_plain_id "$session" || ! is_claude_code_session; then
        return 0
    fi
    load_usage claude
    case "$BAND" in
        4)
            if ! waiter_is_running "$(session_file "$session")"; then
                echo "$USAGE_LINE $(waiter_instruction "$session")"
            fi
            ;;
        1|2|3)
            if [ "$BAND" != 1 ] && stop_blames_usage; then
                echo "$USAGE_LINE Usage is not a reason to end the turn in band $BAND: continue the remaining work. End the turn only when the task is done or needs a decision from the user."
            else
                waiting_stop_reason "$session"
            fi
            ;;
        *)
            echo "inject.sh: unknown band '$BAND'" >&2
            return 1
            ;;
    esac
    return 0
}

# Keeps the count of running subagents. These hooks must never fail: a failing SubagentStop hook
# would keep the subagent from stopping.
count_subagent() {
    local event="$1" session agent file
    session="$(hook_field session_id)"
    agent="$(hook_field agent_id)"
    if ! is_plain_id "$session" || ! is_plain_id "$agent"; then
        return 0
    fi
    file="$(session_file "$session")"
    # shellcheck disable=SC2016  # jq programs, not shell expansions
    if [ "$event" = agent-start ]; then
        with_lock "$file" write_state "$file" '.agents[$agent] = now | .reservations |= .[1:]' --arg agent "$agent"
    else
        with_lock "$file" write_state "$file" 'del(.agents[$agent], .announced[$agent])' --arg agent "$agent"
    fi
    return 0
}

clear_waiter() { with_lock "$WAITER_FILE" write_state "$WAITER_FILE" 'del(.waiter)'; }

# Sleeps once until the full windows reset plus the margin, then exits: Claude Code wakes the
# session when a background command ends. One sleep instead of a polling loop, because the
# machine is expected to stay awake; a suspended machine wakes the session late.
wait_for_reset() {
    local session="$1" wake_at
    if ! is_plain_id "$session"; then
        echo "inject.sh: wait needs the session id given in the hook message" >&2
        return 2
    fi
    load_usage claude
    if [ "$BAND" != 4 ]; then
        echo "No wait needed: $USAGE_LINE"
        return 0
    fi
    if [ "$RESUME_AT" = 0 ]; then
        echo "The reset time of the full usage window is unknown, so the waiter cannot wake the session: finish the current step, report, and wait for the user." >&2
        return 1
    fi
    wake_at=$((RESUME_AT + WAIT_MARGIN_SECONDS))
    WAITER_FILE="$(session_file "$session")"
    # shellcheck disable=SC2016  # jq program, not a shell expansion
    with_lock "$WAITER_FILE" write_state "$WAITER_FILE" '.waiter = {pid: $pid, until: $wake_at}' \
        --argjson pid "$$" --argjson wake_at "$wake_at" || return 1
    trap clear_waiter EXIT
    sleep "$(( wake_at > $(date +%s) ? wake_at - $(date +%s) : 0 ))"
    echo "The usage window reset at $(jq -rn --argjson epoch "$RESUME_AT" '$epoch | todate'). Resume the plan where it stopped; read the usage line before starting subagents."
}

require_harness() {
    local event="$1" harness="$2"
    shift 2
    case " $* " in
        *" $harness "*) return 0 ;;
    esac
    echo "inject.sh: the $event event is only for $*" >&2
    return 1
}

build_context() {
    local harness="$1" event="$2"
    case "$event" in
        prompt)
            cat "$SCRIPT_DIR/reminder.md"
            project_rules_line "$harness"
            load_usage "$harness"
            echo "$USAGE_LINE"
            if [ "$harness" = claude ]; then
                remember_main_band
            fi
            ;;
        compact)
            # Claude Code reloads the rule files and the project CLAUDE.md after a compaction, so a
            # copy of the principles would only repeat them; the reminder and the band still return.
            if [ "$harness" != claude ]; then
                cat "$SCRIPT_DIR/AGENTS.md"
                echo
            fi
            cat "$SCRIPT_DIR/reminder.md"
            load_usage "$harness"
            echo "$USAGE_LINE"
            ;;
        subagent)
            # Claude Code hears usage changes through the tool event instead.
            require_harness "$event" "$harness" codex || return 1
            load_usage "$harness"
            echo "$USAGE_LINE"
            ;;
        dispatch)
            require_harness "$event" "$harness" claude codex || return 1
            dispatch_reason "$harness"
            ;;
        tool)
            require_harness "$event" "$harness" claude || return 1
            tool_context
            ;;
        stop)
            require_harness "$event" "$harness" claude || return 1
            stop_reason
            ;;
        agent-start|agent-stop)
            require_harness "$event" "$harness" claude || return 1
            count_subagent "$event"
            ;;
        *)
            echo "inject.sh: unknown event '$event'" >&2
            return 1
            ;;
    esac
}

# Each harness expects its own output shape; see the adapter table in README.md.
emit() {
    local harness="$1" event="$2" context="$3"
    case "$harness" in
        claude|codex)
            case "$event" in
                subagent|tool)
                    # After a tool call, both tools pass hook output to the model only as JSON.
                    if [ -n "$context" ]; then
                        jq -n --arg context "$context" \
                            '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $context}}'
                    fi
                    ;;
                dispatch)
                    # No output lets the call through; a deny decision blocks it and tells the model why.
                    if [ -n "$context" ]; then
                        jq -n --arg reason "$context" '{hookSpecificOutput: {hookEventName: "PreToolUse",
                            permissionDecision: "deny", permissionDecisionReason: $reason}}'
                    fi
                    ;;
                stop)
                    # No output lets the turn end; a block decision continues it with the reason.
                    if [ -n "$context" ]; then
                        jq -n --arg reason "$context" '{decision: "block", reason: $reason}'
                    fi
                    ;;
                agent-start|agent-stop) ;;
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
    local context
    # With standard input closed, the pipe of a command substitution could take its place and a
    # command reading the hook input would read its own output.
    { : <&0; } 2>/dev/null || exec </dev/null
    if [ "$#" = 3 ] && [ "$2" = wait ]; then
        require_harness wait "$1" claude || exit 2
        wait_for_reset "$3"
        exit $?
    fi
    if [ "$#" -ne 2 ] || [ "$2" = wait ]; then
        echo "Usage: inject.sh <harness> <prompt|compact|subagent|dispatch|tool|stop|agent-start|agent-stop>" >&2
        echo "       inject.sh claude wait <session id>" >&2
        exit 2
    fi
    if [ "$1" = claude ]; then
        read_hook_input
    fi
    context="$(build_context "$1" "$2")" || exit 2
    emit "$1" "$2" "$context"
}

main "$@"
