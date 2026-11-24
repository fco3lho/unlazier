# Agent Parallelism

- **Parallelize by Priority** — when work can run concurrently, prefer, in this order:
    1. Subagents for subtasks of the same main task.
    2. Different tasks of a single request (for example, the tasks of one issue).
    3. Two or more different requests, each with one or more main tasks.
- **Read Usage First** — the injected Unlazier reminder carries a `Usage:` line with the 5-hour and weekly window percentages and their source. It arrives with each prompt; in Claude Code, also with each turn Claude Code starts on its own and after each subagent call. Check it before starting concurrent work and again after long-running steps. Report the reading and its source to the user when it changes your pace.
- **Follow the Usage Ladder** — scale concurrency to the 5-hour window:

    | 5-hour window | Behavior |
    |---------------|----------|
    | below 70% | Maximum parallelism |
    | 70% to 85% | At most 2 concurrent agents or tasks |
    | 85% to 95% | Sequential only, no subagents; start nothing new, and let agents already running finish their current step |
    | 95% or more | As from 85% to 95%, in small steps that each leave the work consistent, so the limit can stop it at any point; then follow **At the Limit** |

    When the weekly window reaches 99%, pause: finish the current step, report, and wait for the user.
- **At the Limit** — the tool, not this ladder, decides what happens at the usage limit:
    - Claude Code: keep working and do not end the turn early to wait or report. When the limit stops the session, Claude Code applies the user's choice in `autoContinueAtUsageLimit` and `/rate-limit-options`: it waits and continues the task on its own, or leaves the next step to the user. Never start a waiter of your own, re-arm a wait the user cancelled, or change the setting. When Claude Code continues after the reset, resume the interrupted task without repeating completed work.
    - Other tools: finish the current step, report, and wait for the user.
- **Unknown Usage** — when the `Usage:` line is missing or reads `unknown`, run at most 2–3 tasks concurrently and ask the user before going beyond 5.
- **Rate-Limit Signals** — on any rate-limit error or quota warning, never retry in a tight loop. In Claude Code, its own usage-limit messages take precedence and **At the Limit** applies. In other tools, finish what is running, start nothing new, and report.
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

[GOOD] Let Claude Code handle the limit
```
Usage: 5h 95% · weekly 40%
-> keeps working without subagents, in small steps that each leave the work consistent, and does not end the turn early; at the limit, Claude Code waits and continues, or leaves the next step to the user, as chosen in /rate-limit-options
```
