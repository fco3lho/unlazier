# Agent Parallelism

- **Parallelize by Priority** — when work can run concurrently, prefer, in this order:
    1. Subagents for subtasks of the same main task.
    2. Different tasks of a single request (for example, the tasks of one issue).
    3. Two or more different requests, each with one or more main tasks.
- **Read Usage First** — the injected Unlazier reminder carries a `Usage:` line with the 5-hour and weekly window percentages and their source. Check it before starting concurrent work and again after long-running steps. Report the reading and its source to the user when it changes your pace.
- **Follow the Usage Ladder** — scale concurrency to the 5-hour window:

    | 5-hour window | Behavior |
    |---------------|----------|
    | below 70% | Maximum parallelism |
    | 70% to 85% | At most 2 concurrent agents or tasks |
    | 85% to 95% | Sequential only, no subagents; start nothing new, and let agents already running finish their current step |
    | 95% or more | Stop starting new work and finish the current step; let the tool decide whether to wait and resume after the limit |

    When the weekly window reaches 99%, pause: finish the current step, report, and wait for the user.
- **At the Limit (Claude Code)** — from version 2.1.234, Claude Code can wait in the open session and resume after a claude.ai usage limit resets. The user controls this with `autoContinueAtUsageLimit` and `/rate-limit-options`. Follow that choice: do not start your own waiter, do not re-arm a wait they cancelled, and do not change the setting. Claude Code stops after three automatic continuations.
- **No Native Wait** — when the tool offers no wait (other tools, older Claude Code, `-p` runs, API-key sessions), finish the current step, report, and wait for the user.
- **Unknown Usage** — when the `Usage:` line is missing or reads `unknown`, run at most 2–3 tasks concurrently and ask the user before going beyond 5.
- **Rate-Limit Signals** — on any rate-limit error or quota warning, finish what is running, start nothing new, and report. Never retry in a tight loop.
- **No Credential Access** — never read credential files or call undocumented endpoints to obtain usage data.
- **No Subagents Available** — if the harness has no subagents, apply the same ladder to concurrent tool calls or background tasks.

---

## Examples

[BAD] Ignoring the usage reading
```
Usage: 5h 91% · weekly 40%
-> spawns 6 subagents to refactor 6 modules at once
```

[GOOD] Pace matches the ladder
```
Usage: 5h 91% · weekly 40%
-> 5-hour window is between 85% and 95%: refactor the 6 modules sequentially, no subagents
```

[GOOD] Let the tool handle the limit
```
Usage: 5h 95% · weekly 40%
-> starts no new agents, finishes the current step, and lets Claude Code's own wait follow the user's choice
```
