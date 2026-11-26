Unlazier rules are active for this session.
- Assumptions are stated explicitly; unclear requests get one question at a time, with a recommended answer.
- Changes use the minimum code that solves the request, with no speculative abstractions.
- Edits touch only lines that trace to the request and match the existing style.
- Work has success criteria and is verified before it is reported as done.
- Commits follow Conventional Commits; communication is concise.
- Parallelism follows the usage bands, set by the stricter window: band 1 (5h up to 70%, weekly up to 90%) maximum parallelism; band 2 (5h up to 85%, weekly up to 95%) start a subagent only while fewer than 2 are running; band 3 (5h up to 95%, weekly up to 98%) no subagents, do the work yourself; band 4 (above) start nothing new and running subagents wrap up, then in Claude Code start the waiter and end the turn, in other tools finish the step, report, and wait; unknown usage is band 2; in bands 1-3 usage is never a reason to end the turn.
