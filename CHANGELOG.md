# Changelog

All notable changes to Unlazier (called Unlazier AI before version 2.1) are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [2.4.2] - 2026-11-24

### Fixed

- Reinstalling now updates the Claude Code status line that Unlazier installed earlier: it gets the current script and gains `refreshInterval: 60` if it has none. Before, any existing status line was kept as yours, so upgrades never delivered status line fixes (such as the 2.4.0 temporary file fix). A status line of your own is still left alone.

## [2.4.1] - 2026-11-24

### Fixed

- A subagent that Claude Code sends to the background on its own (without `run_in_background`) no longer gets a usage line at launch, which repeated the reading the assistant already had. The hook now also reads the launch status from the tool result.

## [2.4.0] - 2026-11-24

### Added

- **Release assets:** each release publishes `install.sh`, `install.ps1`, `uninstall.sh`, and `uninstall.ps1` with every download pinned to the release tag, plus a `SHA256SUMS` file. The README now installs from `releases/latest/download` and shows how to check a script before running it, so a push to `main` can no longer change or mix what you install.
- **Secret Files rule:** never read or print `.env` files, private keys, or credential files; ask for the non-secret value, or let the user check it with the secret masked.

### Changed

- **Project rules line:** headings inside HTML comments are no longer listed, control and bidirectional characters are removed from titles and from the path, each title is cut to 60 characters, the list stops at 12 titles or 400 characters, and only the first 64 KiB of the file is read. A repository can no longer slip hidden instructions or thousands of characters into every prompt through its headings.
- No usage line is added after a background Claude Code subagent, which returns at once with the same reading.
- The Codex usage hook reads only the newest `token_count` events: with a 60 MB session log, a prompt went from 631 to 59 ms.
- Rules: what to do about test-first when a project has no tests, what "impossible scenarios" means next to "validate inputs", execution instructions only for new projects and modules, and only the `Usage:` line from Unlazier counts.
- On Windows, hook commands start PowerShell by its full path. Codex users approve the changed hooks once more with `/hooks`.
- Installing refuses a tool folder whose path holds characters a hook command cannot carry safely: `$`, backtick, `"`, and `\` (Windows: `"`, `$`, backtick, and `%`).
- The version 1 instructions file is recognized only while it is exactly the file version 1 wrote.
- CI runs with a read-only token and with `actions/checkout` v5.1.0 pinned to its commit.

### Fixed

- A malformed usage file blocked every Claude Code prompt, because the hook exited with code 2. The reading now counts as unknown.
- A usage reading dated in the future never went stale and kept driving the subagent gate; it now counts as stale.
- On Windows, a repository could ship a `powershell.bat` that ran on every prompt, because hook commands named PowerShell without a path.
- Installing changed the files it edits: a `settings.json` with mode 600 became 644, and a symlinked config became a plain file. Mode, owner, and symlinks are now kept.
- Uninstalling removed a user's own hooks or status line whose path merely contained "unlazier".
- A start marker without an end marker made installing wipe the rest of the file. The text is now kept, the block goes at the end, and you get a notice.
- Temporary files have unique names, so two status lines refreshing at once no longer collide.
- Windows PowerShell 5.1 flattened settings nested deeper than 20 levels.

## [2.3.0] - 2026-11-24

### Added

- **Subagent gate (Claude Code and Codex CLI):** a `PreToolUse` hook on the subagent tool (`Agent` in Claude Code, `spawn_agent` in Codex) blocks new helper agents while the 5-hour window is at 85% or more, or the weekly window at 99% or more, and tells the assistant to continue on its own (or to pause, for the weekly window). Below those levels it prints nothing, so it costs no tokens. With unknown usage it never blocks.
- **Usage after each subagent in Codex CLI:** the `PostToolUse` hook that adds the usage line after each subagent call now covers Codex too. Approve the new hooks once with `/hooks`.
- The installer tells you when `autoContinueAtUsageLimit` is off in Claude Code's user settings, because the session then waits for you after a usage limit. It never changes the setting.

### Changed

- **Codex CLI at 95% or more:** the assistant keeps working until the limit instead of finishing the step and stopping, because Codex lets the turn in progress go on past the limit and never resumes on its own afterwards. Codex then stops, and you continue after the reset.

## [2.2.0] - 2026-11-23

### Added

- **Project rules in the reminder:** with each message, the reminder names the project's own rules file (`CLAUDE.md` or `.claude/CLAUDE.md` for Claude Code, `AGENTS.md` for Codex CLI, OpenCode, and Amp, `GEMINI.md` for Gemini CLI) and up to 12 of its sections, so the project's rules keep their weight between compactions. The file itself is not repeated, because Claude Code already re-reads the project-root `CLAUDE.md` after each compaction.
- **Usage after each subagent (Claude Code):** a `PostToolUse` hook on the `Agent` tool adds the current usage line after each subagent call, so the assistant sees usage climb during a long turn instead of only with your next message.

### Changed

- **Usage ladder:** from 85%, agents already running finish their current step and nothing new starts. At 95% or more the assistant also works in small steps that each leave the work consistent. At the usage limit the tool decides: Claude Code v2.1.234 or later waits and continues the task, or leaves the next step to you, as you chose with `autoContinueAtUsageLimit` and `/rate-limit-options`, so in Claude Code the assistant keeps working until the limit instead of stopping early. Other tools keep finishing the step, reporting, and waiting for you. Unlazier never changes the setting and runs no waiter of its own; installs made from `main` before this release had background waiters (`wait-usage.sh`, `wait-usage.ps1`), and installing again deletes them.
- The Claude Code status line installed by Unlazier refreshes every minute (`refreshInterval: 60`), not only when a message is sent, so the usage saved for the reminder stays current while you are idle.

## [2.1.0] - 2026-11-14

### Added

- **Alerts layer:** three short beeps when the assistant asks for permission, asks a question, or finishes its turn, through each tool's own events. Kiro and Amp signal only the end of a turn, and Cline signals no permission prompts.

### Changed

- **Renamed from Unlazier AI to Unlazier.** Files, folders, and markers use `unlazier` instead of `unlazier-ai`, and the repository moves to `fco3lho/unlazier`. Installing again removes everything version 2.0 wrote under the old name.
- **Rules go into the tool's rules folder, one small file per rule**, for tools that always load such a folder: Claude Code (`~/.claude/rules/`), Devin, Kiro, and Cline. Anthropic recommends keeping each CLAUDE.md under 200 lines, and version 2.0 added about 480 lines to it. Your `CLAUDE.md` is no longer touched. Tools that read a single instructions file (Codex CLI, OpenCode, Copilot CLI, Gemini CLI, Amp) keep the marked block.
- **Upgrading from 2.0 is automatic:** installing again removes the block from `CLAUDE.md` and the old rule files in the Kiro, Cline, and Devin folders, then writes the new files.
- The Claude Code status line shows reset times longer than a day in days, for example `3d 11h 30m`.

### Fixed

- The Claude Code status line script is copied only when Unlazier actually installs the status line, instead of on every install.

## [2.0.0] - 2026-11-14

Version 2 changes how Unlazier AI is installed. If you have version 1, read [Upgrading from Version 1](README.md#upgrading-from-version-1) before installing, and **do not run the version 1 uninstaller**.

### Added

- **Seven more tools:** Codex CLI, GitHub Copilot CLI, Gemini CLI, Amp, Kiro, Cline, and Devin Desktop (formerly Windsurf), in addition to Claude Code and OpenCode.
- **Windows support:** native PowerShell installer and uninstaller (`install.ps1`, `uninstall.ps1`), with nothing extra to install.
- **Choose your tools:** the installer shows a menu, marks the tools it finds on your computer, and installs only where you choose. `--harness` (Windows: `-Harness`) picks tools without the menu.
- **Reminder layer:** a short summary of the rules (`reminder.md`) is sent again with each message, and the core principles again after the conversation is compacted, so the rules keep their weight in long sessions. It works through each tool's own hooks or plugins.
- **Usage layer:** the reminder includes how much of the 5-hour and weekly usage windows is used (Claude Code through its status line, Codex through its session log), so the assistant can pace itself.
- **New rule, Agent Parallelism (`rules/parallelism.md`):** how much work to run in parallel, based on the usage windows, and in which order to parallelize.
- **Claude Code status line** that shows both usage windows and saves them for the reminder; installed only when you have no status line of your own.
- **Version 1 cleanup:** the installer finds files left by version 1, lists them, and asks before removing them.
- **Tests and continuous integration** for the installers and the hook, on Ubuntu, macOS, and Windows.
- This changelog.

### Changed

- **The installer adds to your configuration instead of replacing it.** The rules go inside a marked block (`<!-- unlazier-ai:start -->` to `<!-- unlazier-ai:end -->`) in each tool's instructions file; your own content in that file is kept. Hooks are added next to yours in settings files.
- **No more backup folders.** Version 1 copied the whole configuration folder to `*.bak.<date>` on every install.
- The principles no longer list rule file paths, because the topic rules are now always installed together with them.
- The **README** was rewritten in plain language, with a table of every file the installer touches.

### Removed

- The `bugfix`, `code-review`, and `refactoring` skills.
- `opencode.global.json`: OpenCode now gets its rules from `~/.config/opencode/AGENTS.md`, so your `opencode.json` is no longer replaced.

### Fixed

- **The uninstaller no longer deletes your whole configuration.** Version 1 ran `rm -rf ~/.claude` and `rm -rf ~/.config/opencode`, which also deleted settings, history, and credentials. Version 2 removes only what it added.
- **The installer no longer overwrites** `~/.claude/CLAUDE.md` and `~/.config/opencode/opencode.json`.
- **Installing on macOS** no longer fails when rewriting rule paths (version 1 used a `sed -i` form that only works on Linux).

## [1.0.0]

First release: behavioral principles (`AGENTS.md`), nine topic rules, three skills, and a bash installer for Claude Code and OpenCode on Linux and macOS.
