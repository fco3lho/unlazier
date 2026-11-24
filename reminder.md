Unlazier rules are active for this session.
- Assumptions are stated explicitly; unclear requests get one question at a time, with a recommended answer.
- Changes use the minimum code that solves the request, with no speculative abstractions.
- Edits touch only lines that trace to the request and match the existing style.
- Work has success criteria and is verified before it is reported as done.
- Commits follow Conventional Commits; communication is concise.
- Parallelism follows the usage ladder: 5h window below 70% maximum parallelism, 70-85% at most 2 concurrent, 85-95% sequential with no subagents, 95% or more also in small steps that leave the work consistent, then in Claude Code and Codex keep working until the limit, where Claude Code waits or continues as the user chose (autoContinueAtUsageLimit, /rate-limit-options) and Codex stops for the user, in other tools finish the step, report, and wait; weekly window 99% or more pause and report; unknown usage at most 2-3 concurrent.
