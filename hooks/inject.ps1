# Unlazier context hook for Windows.
#
# Usage: inject.ps1 <harness> <event>, or inject.ps1 claude wait <session id>
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
#   stop         (Claude Code) keeps the turn going in band 4 until the waiter runs, and once when the
#                agent ends the turn over usage in bands 2 and 3.
#   agent-start, agent-stop
#                (Claude Code) keep the count of running subagents that the gate reads in band 2.
#   wait         (Claude Code) started by the agent in the background in band 4: sleeps once until
#                the full window resets plus $WaitMarginSeconds and exits, which wakes the session.
#
# Rules loaded at session start lose weight as the context window fills, so the harness
# calls this hook to place a compact copy near the end of the context. Installed at
# <harness home>\unlazier\inject.ps1 next to reminder.md and AGENTS.md. The output is
# byte-for-byte the same as inject.sh. This file is kept ASCII-only because Windows
# PowerShell 5.1 reads scripts without a byte order mark in the legacy code page.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDirectory = $PSScriptRoot
$HarnessHome = Split-Path -Parent $ScriptDirectory
$MaxReadingAgeSeconds = 900
# A reading further ahead than this (milliseconds instead of seconds, or a wrong clock) would never
# go stale, so it counts as stale at once.
$MaxClockSkewSeconds = 300
$MaxSectionTitles = 12
$MaxTitleCharacters = 60
$MaxTitleListCharacters = 400
$MaxProjectRulesBytes = 65536
# Control characters and the bidirectional controls U+202A-U+202E and U+2066-U+2069, built from
# code points so that this file stays ASCII.
$HiddenTitleCharacters = '[\p{Cc}' + [char]0x202A + '-' + [char]0x202E + [char]0x2066 + '-' + [char]0x2069 + ']'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Usage bands, as in rules/parallelism.md: a rounded percentage up to the first limit is band 1, up
# to the second band 2, up to the third band 3, and above it band 4. The stricter window sets the band.
$FiveHourBandLimits = @(70, 85, 95)
$WeeklyBandLimits = @(90, 95, 98)
$UnknownUsageBand = 2
$Band2SubagentLimit = 2
$WaitMarginSeconds = 180
$StateDirectory = [System.IO.Path]::Combine($ScriptDirectory, 'state')
# A subagent killed or cut by an API error may never report its end, and an allowed launch may never
# start (the user can refuse its permission), so their places in the count expire.
$MaxSubagentSeconds = 18000
$MaxReservationSeconds = 120
$MaxSessionFileDays = 7
# As long as inject.sh tries for its lock before it gives up.
$LockTimeoutMilliseconds = 5000
# A stop message that gives usage as the reason, in English, Portuguese, and Spanish; the i with an
# acute accent is built from its code point so that this file stays ASCII.
$UsageStopPattern = '(5-hour|five-hour|weekly|usage) (window|limit)|rate limit|janela (de 5 horas|semanal|de uso)|' +
    'limite (de uso|semanal)|ventana (de 5 horas|semanal|de uso)|l[i' + [char]0x00ED + ']mite (de uso|semanal)'
$HookInput = $null

# Opens the file with FileShare.ReadWrite because Codex keeps its session log open for
# writing; the default sharing mode would fail with a sharing violation.
function Read-SharedText {
    param([string]$Path)
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $reader = New-Object System.IO.StreamReader($stream, $Utf8NoBom)
        try {
            return $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

# Reads at most the first $MaxBytes bytes, as head -c does in inject.sh. Like jq there, the decoder
# keeps a byte order mark as text and turns invalid or cut UTF-8 sequences into U+FFFD.
function Read-SharedTextPrefix {
    param([string]$Path, [int]$MaxBytes)
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $buffer = New-Object byte[] $MaxBytes
        $count = 0
        do {
            $read = $stream.Read($buffer, $count, $MaxBytes - $count)
            $count += $read
        } while ($read -gt 0 -and $count -lt $MaxBytes)
        return $Utf8NoBom.GetString($buffer, 0, $count)
    } finally {
        $stream.Dispose()
    }
}

# A Windows checkout may convert the payload to CRLF; LF keeps the output identical to inject.sh.
function Read-PayloadText {
    param([string]$Name)
    return (Read-SharedText ([System.IO.Path]::Combine($ScriptDirectory, $Name))) -replace "`r`n", "`n"
}

function Get-JsonProperty {
    param($Object, [string]$Name)
    if ($Object -is [System.Management.Automation.PSCustomObject] -and $null -ne $Object.PSObject.Properties[$Name]) {
        return , $Object.PSObject.Properties[$Name].Value
    }
    return $null
}

function Get-UnixTimeNow {
    return [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
}

# PowerShell 7 turns ISO dates into DateTime while 5.1 keeps strings; both are accepted.
# Fractions of a second are dropped, as jq's fromdateiso8601 does.
function ConvertTo-UnixSeconds {
    param($Value)
    if ($Value -is [System.DateTime]) {
        $utc = $Value
        if ($Value.Kind -eq [System.DateTimeKind]::Local) {
            $utc = $Value.ToUniversalTime()
        }
        return [double]([System.DateTimeOffset]::new([System.DateTime]::SpecifyKind($utc, 'Utc'))).ToUnixTimeSeconds()
    }
    if ($Value -is [string]) {
        $parsed = [System.DateTimeOffset]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal)
        return [double]$parsed.ToUnixTimeSeconds()
    }
    return $null
}

function Test-Number {
    param($Value)
    return ($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [double]) -or ($Value -is [decimal])
}

# A window as Percent and ResetsAt. A window whose reset time has passed has reset, so it counts as
# 0% until the next reading; a value that is not a number counts as missing, as in inject.sh.
function Get-UsageWindow {
    param($Percent, $ResetsAt, [double]$Now)
    if (-not (Test-Number $Percent)) {
        return @{ Percent = $null; ResetsAt = $null }
    }
    if (-not (Test-Number $ResetsAt)) {
        return @{ Percent = [double]$Percent; ResetsAt = $null }
    }
    if ([double]$ResetsAt -le $Now) {
        return @{ Percent = 0.0; ResetsAt = $null }
    }
    return @{ Percent = [double]$Percent; ResetsAt = [double]$ResetsAt }
}

function Read-ClaudeUsage {
    param([double]$Now)
    $stateFile = [System.IO.Path]::Combine($HarnessHome, 'state', 'rate_limits.json')
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        return $null
    }
    $text = Read-SharedText $stateFile
    # Only a single JSON object is a reading, as in inject.sh. PowerShell 7 unwraps a one-element
    # array into its element, so the text tells an object from an array.
    if ($text -notmatch '^[ \t\r\n]*\{') {
        return $null
    }
    $state = $text | ConvertFrom-Json
    $fiveHour = Get-JsonProperty $state 'five_hour'
    $sevenDay = Get-JsonProperty $state 'seven_day'
    $capturedAt = Get-JsonProperty $state 'captured_at'
    if (-not (Test-Number $capturedAt)) {
        $capturedAt = $null
    }
    return @{
        FiveHour = Get-UsageWindow (Get-JsonProperty $fiveHour 'used_percentage') (Get-JsonProperty $fiveHour 'resets_at') $Now
        Weekly = Get-UsageWindow (Get-JsonProperty $sevenDay 'used_percentage') (Get-JsonProperty $sevenDay 'resets_at') $Now
        CapturedAt = $capturedAt
    }
}

function Find-NewestRollout {
    $sessionsDirectory = [System.IO.Path]::Combine($HarnessHome, 'sessions')
    if (-not (Test-Path -LiteralPath $sessionsDirectory -PathType Container)) {
        return $null
    }
    [string[]]$rollouts = @(Get-ChildItem -LiteralPath $sessionsDirectory -Recurse -File -Force |
        Where-Object { $_.Name -like 'rollout-*.jsonl' } |
        ForEach-Object { $_.FullName })
    if ($rollouts.Count -eq 0) {
        return $null
    }
    # Rollout paths are sessions\YYYY\MM\DD\rollout-<timestamp>-<id>.jsonl, so the ordinal
    # maximum is the most recent session.
    [System.Array]::Sort($rollouts, [System.StringComparer]::Ordinal)
    return $rollouts[$rollouts.Count - 1]
}

function Find-LastRateLimitEvent {
    param([string]$Path)
    $lines = (Read-SharedText $Path) -split "`n"
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        # Parsing every line of a long session is slow; only token_count lines can match.
        if (-not $lines[$index].Contains('"token_count"')) {
            continue
        }
        try {
            $record = $lines[$index] | ConvertFrom-Json
        } catch {
            # The last line can be half-written while Codex appends to the log; the previous
            # complete event is the latest reading, as with jq in inject.sh.
            continue
        }
        $payload = Get-JsonProperty $record 'payload'
        if ((Get-JsonProperty $record 'type') -eq 'event_msg' -and (Get-JsonProperty $payload 'type') -eq 'token_count' `
                -and $null -ne (Get-JsonProperty $payload 'rate_limits')) {
            return $record
        }
    }
    return $null
}

function Read-CodexUsage {
    param([double]$Now)
    $rollout = Find-NewestRollout
    if ($null -eq $rollout) {
        return $null
    }
    $record = Find-LastRateLimitEvent $rollout
    if ($null -eq $record) {
        return $null
    }
    $capturedAt = ConvertTo-UnixSeconds (Get-JsonProperty $record 'timestamp')
    if ($null -eq $capturedAt) {
        return $null
    }
    $rateLimits = Get-JsonProperty (Get-JsonProperty $record 'payload') 'rate_limits'
    $windows = @(@((Get-JsonProperty $rateLimits 'primary'), (Get-JsonProperty $rateLimits 'secondary')) |
        Where-Object { $null -ne $_ })
    return @{
        FiveHour = Select-CodexWindow $windows 300 $capturedAt $Now
        Weekly = Select-CodexWindow $windows 10080 $capturedAt $Now
        CapturedAt = $capturedAt
    }
}

# Windows are matched by length (300 minutes = 5 hours, 10080 = one week), not by position; the
# first one of that length with a percentage counts.
function Select-CodexWindow {
    param([object[]]$Windows, [int]$Minutes, [double]$CapturedAt, [double]$Now)
    foreach ($window in $Windows) {
        $percent = Get-JsonProperty $window 'used_percent'
        if ((Get-JsonProperty $window 'window_minutes') -ne $Minutes -or -not (Test-Number $percent)) {
            continue
        }
        $resetsAt = Get-JsonProperty $window 'resets_at'
        $resetsInSeconds = Get-JsonProperty $window 'resets_in_seconds'
        if (-not (Test-Number $resetsAt) -and (Test-Number $resetsInSeconds)) {
            $resetsAt = $CapturedAt + $resetsInSeconds
        }
        return Get-UsageWindow $percent $resetsAt $Now
    }
    return Get-UsageWindow $null $null $Now
}

function Format-Percent {
    param($Value)
    if ($null -eq $Value) {
        return 'unknown'
    }
    return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture) + '%'
}

# The usage reading of the harness, or $null. A missing or corrupt usage file must not break the
# hook: the reading becomes unknown, as in inject.sh, and the cause goes to stderr where the
# harness logs it.
function Read-Usage {
    param([string]$Harness, [double]$Now)
    try {
        if ($Harness -eq 'claude') {
            return Read-ClaudeUsage $Now
        }
        return Read-CodexUsage $Now
    } catch {
        [Console]::Error.WriteLine("inject.ps1: usage reading failed: $($_.Exception.Message)")
        return $null
    }
}

function Test-StaleReading {
    param($CapturedAt, [double]$Now)
    return $null -eq $CapturedAt -or ($Now - $CapturedAt) -gt $MaxReadingAgeSeconds -or
        ($CapturedAt - $Now) -gt $MaxClockSkewSeconds
}

# A window with its percentage rounded as shown, so the band agrees with the number the model
# reads: one band above the first for each limit the percentage passes. A window without a
# reading counts as band 2.
function Get-BandedWindow {
    param($Window, [int[]]$Limits)
    if ($null -eq $Window.Percent) {
        return @{ Percent = $null; Band = $UnknownUsageBand; ResetsAt = $null }
    }
    $percent = [long][System.Math]::Floor($Window.Percent + 0.5)
    $band = 1 + @($Limits | Where-Object { $percent -gt $_ }).Count
    return @{ Percent = $percent; Band = $band; ResetsAt = $Window.ResetsAt }
}

# The latest known reset of the full windows, or 0 when no full window has one.
function Get-ResumeTime {
    param([object[]]$Windows)
    $resets = @($Windows | Where-Object { $_.Band -eq 4 -and $null -ne $_.ResetsAt } | ForEach-Object { $_.ResetsAt })
    if ($resets.Count -eq 0) {
        return [long]0
    }
    return [long][System.Math]::Floor(($resets | Measure-Object -Maximum).Maximum)
}

# The band, the time the full windows reset (0 when none is full or its reset is unknown), and the
# usage text of the harness. A stale reading counts as band 2.
function Get-UsageSummary {
    param([string]$Harness)
    $now = Get-UnixTimeNow
    switch ($Harness) {
        'claude' { $source = 'Claude Code status line' }
        'codex' { $source = 'Codex session log' }
        default { return @{ Band = $UnknownUsageBand; ResumeAt = [long]0; Text = 'Usage: unknown (this tool does not expose usage windows)' } }
    }
    $reading = Read-Usage $Harness $now
    if ($null -eq $reading) {
        return @{ Band = $UnknownUsageBand; ResumeAt = [long]0; Text = 'Usage: unknown (no usage reading available)' }
    }
    if (Test-StaleReading $reading.CapturedAt $now) {
        return @{ Band = $UnknownUsageBand; ResumeAt = [long]0; Text = 'Usage: unknown (no usage reading from the last 15 minutes)' }
    }
    $fiveHour = Get-BandedWindow $reading.FiveHour $FiveHourBandLimits
    $weekly = Get-BandedWindow $reading.Weekly $WeeklyBandLimits
    $ageMinutes = ([long][System.Math]::Floor(($now - $reading.CapturedAt) / 60)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    return @{
        Band = [System.Math]::Max($fiveHour.Band, $weekly.Band)
        ResumeAt = Get-ResumeTime @($fiveHour, $weekly)
        Text = "Usage: 5h $(Format-Percent $fiveHour.Percent) | weekly $(Format-Percent $weekly.Percent) (source: $source, $ageMinutes min old)"
    }
}

# What the band asks of the agent. Only Claude Code can wake a session from a background command,
# so only there does band 4 end in a wait instead of a report to the user.
function Get-BandRule {
    param([string]$Harness, [int]$Band)
    switch ($Band) {
        1 { return 'Band 1: maximum parallelism.' }
        2 { return "Band 2: start a subagent only while fewer than $Band2SubagentLimit are running." }
        3 { return 'Band 3: start no subagent; continue the work yourself in this session.' }
        4 {
            if ($Harness -eq 'claude') {
                return 'Band 4: start nothing new; running subagents wrap up, then start the waiter and end the turn.'
            }
            return 'Band 4: start nothing new; finish the current step, report, and wait for the user.'
        }
        default { throw "unknown band '$Band'" }
    }
}

# The usage summary with Line, the usage text followed by the rule of its band.
function Get-UsageStatus {
    param([string]$Harness)
    $status = Get-UsageSummary $Harness
    $status.Line = "$($status.Text). $(Get-BandRule $Harness $status.Band)"
    return $status
}

# Windows PowerShell by its full path, as the installer writes the hook commands, so the command
# can never pick up a powershell script that the repository ships.
function Get-WaiterInstruction {
    param([string]$Session)
    $powerShell = 'powershell'
    if (-not [string]::IsNullOrEmpty($env:SystemRoot)) {
        $powerShell = [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe') -replace '\\', '/'
    }
    $command = '{0} -NoProfile -ExecutionPolicy Bypass -File "{1}/inject.ps1" claude wait {2}' -f $powerShell, ($ScriptDirectory -replace '\\', '/'), $Session
    return "Start the waiter now with run_in_background: $command. Let the running subagents wrap up, then end the turn; the waiter wakes the session after the reset."
}

function Write-HookError {
    param([string]$Message)
    [Console]::Error.WriteLine("inject.ps1: $Message")
}

# Claude Code passes the hook input as JSON on standard input, in UTF-8 whatever the console code
# page, so the bytes are decoded directly. Input that is not a JSON object carries no field, as
# with jq in inject.sh; PowerShell 7 unwraps a one-element array, so the text tells them apart.
function Read-HookInput {
    if (-not [Console]::IsInputRedirected) {
        return $null
    }
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $Utf8NoBom)
    try {
        $text = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
    if ($text -notmatch '^[ \t\r\n]*\{') {
        return $null
    }
    try {
        return $text | ConvertFrom-Json
    } catch {
        Write-HookError "the hook input is not JSON: $($_.Exception.Message)"
        return $null
    }
}

# A hook input field as text, as jq's '.[$name] // "" | tostring' gives the strings, numbers, and
# booleans the hooks compare. Objects and arrays, never a plain id or "true", become ''.
function Get-HookField {
    param([string]$Name)
    $value = Get-JsonProperty $HookInput $Name
    if ($value -is [string]) {
        return $value
    }
    if ($value -is [bool]) {
        if ($value) {
            return 'true'
        }
        return ''
    }
    if (Test-Number $value) {
        return [System.Convert]::ToString($value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return ''
}

# Session and agent ids come from the hook input and name files or JSON keys, so anything but a
# plain id is refused.
function Test-PlainId {
    param([string]$Id)
    return $Id -cmatch '^[A-Za-z0-9_-]{1,128}\z'
}

function Get-SessionFile {
    param([string]$Session)
    return [System.IO.Path]::Combine($StateDirectory, "session-$Session.json")
}

# Hooks of parallel tool calls run at the same time, so every access to the session state, reads
# included, holds its lock. A named mutex is exclusive in Windows PowerShell 5.1 and PowerShell 7,
# costs next to nothing when free, and Windows releases it when its holder dies, so no stale lock
# outlives a killed hook. Its name cannot hold a backslash, hence the hash of the path, which
# Windows compares without case.
function Enter-StateLock {
    param([string]$Path)
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = [System.BitConverter]::ToString($hash.ComputeHash($Utf8NoBom.GetBytes($Path.ToUpperInvariant()))) -replace '-', ''
    } finally {
        $hash.Dispose()
    }
    $mutex = New-Object System.Threading.Mutex($false, "Local\unlazier-$digest")
    $isLocked = $false
    try {
        try {
            $isLocked = $mutex.WaitOne($LockTimeoutMilliseconds)
        } catch [System.Threading.AbandonedMutexException] {
            # The previous holder died while holding the lock and Windows handed it over; the state
            # it left is whole, because every write replaces the file in one step.
            $isLocked = $true
        }
    } finally {
        if (-not $isLocked) {
            $mutex.Dispose()
        }
    }
    if (-not $isLocked) {
        throw "could not lock $Path"
    }
    return $mutex
}

function Exit-StateLock {
    param([System.Threading.Mutex]$Mutex)
    try {
        $Mutex.ReleaseMutex()
    } finally {
        $Mutex.Dispose()
    }
}

# The properties of a JSON object, or none for anything else.
function Get-ObjectProperties {
    param($Object)
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        return @($Object.PSObject.Properties)
    }
    return @()
}

# The parsed session file, or $null when it is missing or holds no JSON object.
function Read-StateDocument {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $text = Read-SharedText $Path
    if ($text -notmatch '^[ \t\r\n]*\{') {
        return $null
    }
    try {
        return $text | ConvertFrom-Json
    } catch {
        Write-HookError "the session state in $Path is damaged and starts over: $($_.Exception.Message)"
        return $null
    }
}

# The session state with expired entries dropped: Agents (agent id -> start epoch), Reservations
# (epochs of allowed launches not started yet), Announced ("main" or agent id -> band last told),
# and Waiter ({pid, until} or $null). Anything damaged starts over empty. The caller holds the lock.
function Read-SessionState {
    param([string]$Path)
    $now = Get-UnixTimeNow
    $document = Read-StateDocument $Path
    $agents = [ordered]@{}
    Get-ObjectProperties (Get-JsonProperty $document 'agents') |
        Where-Object { (Test-Number $_.Value) -and $_.Value -gt $now - $MaxSubagentSeconds } |
        ForEach-Object { $agents[$_.Name] = $_.Value }
    $reservations = Get-JsonProperty $document 'reservations'
    if ($reservations -isnot [array]) {
        $reservations = @()
    }
    $announced = [ordered]@{}
    Get-ObjectProperties (Get-JsonProperty $document 'announced') | ForEach-Object { $announced[$_.Name] = $_.Value }
    return @{
        Agents = $agents
        Reservations = [object[]]@($reservations | Where-Object { (Test-Number $_) -and $_ -gt $now - $MaxReservationSeconds })
        Announced = $announced
        Waiter = Get-JsonProperty $document 'waiter'
    }
}

# Writes the state as inject.sh does, compact JSON on one line. The new file replaces the old one in
# a single step, so a hook killed while writing leaves the old state whole. The caller holds the lock.
function Write-SessionState {
    param([string]$Path, $State)
    $document = [ordered]@{ agents = $State.Agents; reservations = $State.Reservations; announced = $State.Announced }
    if ($null -ne $State.Waiter) {
        $document['waiter'] = $State.Waiter
    }
    [void][System.IO.Directory]::CreateDirectory($StateDirectory)
    $temporary = "$Path.$([System.IO.Path]::GetRandomFileName())"
    try {
        [System.IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $document -Depth 10 -Compress) + "`n", $Utf8NoBom)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # PowerShell passes $null to a string parameter as '', which Replace refuses as a backup path.
            [System.IO.File]::Replace($temporary, $Path, [NullString]::Value)
        } else {
            [System.IO.File]::Move($temporary, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

# Applies a change, a script block that receives the state and edits it, under the lock.
function Edit-SessionState {
    param([string]$Path, [scriptblock]$Change)
    $lock = Enter-StateLock $Path
    try {
        $state = Read-SessionState $Path
        & $Change $state
        Write-SessionState $Path $state
    } finally {
        Exit-StateLock $lock
    }
}

# The harness runs the hook from the project, so the repository root comes from the working
# directory, or the directory itself outside a repository or without git.
function Get-ProjectRoot {
    $location = (Get-Location).ProviderPath
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return $location
    }
    # Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop'.
    $ErrorActionPreference = 'Continue'
    $root = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $root) {
        return $location
    }
    return [System.IO.Path]::GetFullPath(@($root)[0])
}

# The project's own instruction file for the harness, or $null for harnesses without one.
function Find-ProjectRulesFile {
    param([string]$Harness)
    switch ($Harness) {
        'claude' { $names = @('CLAUDE.md', '.claude/CLAUDE.md') }
        { $_ -in @('codex', 'opencode', 'amp') } { $names = @('AGENTS.md') }
        'gemini' { $names = @('GEMINI.md') }
        default { return $null }
    }
    $root = Get-ProjectRoot
    foreach ($name in $names) {
        $path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $name))
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }
    return $null
}

# Removes control characters (category Cc) and bidirectional controls, trims spaces, and cuts the
# title to $MaxTitleCharacters code points, as inject.sh does.
function Format-SectionTitle {
    param([string]$Text)
    $title = ($Text -replace $HiddenTitleCharacters, '').Trim(' ')
    $codePoints = [System.Text.Encoding]::UTF32.GetBytes($title)
    if ($codePoints.Length -gt 4 * $MaxTitleCharacters) {
        return [System.Text.Encoding]::UTF32.GetString($codePoints, 0, 4 * $MaxTitleCharacters) + '...'
    }
    return $title
}

# Keeps at most $MaxSectionTitles titles and stops before the list would pass
# $MaxTitleListCharacters code points; ", ..." marks titles left out.
function Join-SectionTitles {
    param([System.Collections.Generic.List[string]]$Titles)
    $kept = New-Object System.Collections.Generic.List[string]
    $characters = 0
    foreach ($title in $Titles) {
        $length = $characters + [System.Text.Encoding]::UTF32.GetByteCount($title) / 4
        if ($kept.Count -gt 0) {
            $length += 2
        }
        if ($kept.Count -eq $MaxSectionTitles -or $length -gt $MaxTitleListCharacters) {
            return ($kept -join ', ') + ', ...'
        }
        $kept.Add($title)
        $characters = $length
    }
    return $kept -join ', '
}

# The "## " titles of a Markdown file, comma-separated. The file comes from the repository but
# reaches the model as Unlazier's own text, so headings hidden from readers (in fenced code or HTML
# comments) are skipped and titles are cleaned and capped, as in inject.sh.
function Get-SectionTitles {
    param([string]$Path)
    $titles = New-Object System.Collections.Generic.List[string]
    $isFenced = $false
    $isCommented = $false
    foreach ($line in ((Read-SharedTextPrefix $Path $MaxProjectRulesBytes) -split "`n")) {
        # One title past the cap is enough to know that the list leaves some out.
        if ($titles.Count -gt $MaxSectionTitles) {
            break
        }
        if ($isFenced) {
            $isFenced = $line -notmatch '^(```|~~~)'
            continue
        }
        if (-not $isCommented -and $line -match '^(```|~~~)') {
            $isFenced = $true
            continue
        }
        $isHeading = -not $isCommented -and $line.StartsWith('## ', [System.StringComparison]::Ordinal)
        $visible = $line
        if ($isCommented) {
            if (-not $line.Contains('-->')) {
                continue
            }
            $visible = $line -replace '^.*?-->', ''
            $isCommented = $false
        }
        $visible = $visible -replace '<!--.*?-->', ''
        if ($visible.Contains('<!--')) {
            $visible = $visible -replace '<!--.*$', ''
            $isCommented = $true
        }
        if ($isHeading) {
            $title = Format-SectionTitle $visible.Substring(3)
            if ($title -ne '') {
                $titles.Add($title)
            }
        }
    }
    return Join-SectionTitles $titles
}

# The project's rules lose weight between compactions like the global ones, but repeating the
# whole file on every prompt would fill the context, so the reminder names it and its sections.
function Get-ProjectRulesLine {
    param([string]$Harness)
    $path = Find-ProjectRulesFile $Harness
    if ($null -eq $path) {
        return ''
    }
    # A file that cannot be read still gets its line, without sections: the reminder must not
    # break, and the path lets the agent open the file and see the error itself.
    try {
        $titles = Get-SectionTitles $path
    } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
        $titles = ''
    }
    $displayPath = $path -replace '\p{Cc}', ''
    if ($titles) {
        return "- Project rules: $displayPath apply ($titles); re-read the relevant section before acting on it.`n"
    }
    return "- Project rules: $displayPath apply; re-read the relevant section before acting on it.`n"
}

function Remove-OldSessionFiles {
    if (-not (Test-Path -LiteralPath $StateDirectory -PathType Container)) {
        return
    }
    $cutoff = [System.DateTime]::UtcNow.AddDays(-$MaxSessionFileDays)
    Get-ChildItem -LiteralPath $StateDirectory -Filter 'session-*' -Force |
        Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
        Remove-Item -Recurse -Force
}

# The prompt carries the usage line, so the main agent has heard the current band. Session files
# older than a week belong to sessions long closed. Neither step may fail the prompt.
function Save-MainBand {
    param([string]$Session, [int]$Band)
    try {
        Edit-SessionState (Get-SessionFile $Session) { param($state) $state.Announced['main'] = $Band }
    } catch {
        Write-HookError "the band of the main agent was not recorded: $($_.Exception.Message)"
    }
    try {
        Remove-OldSessionFiles
    } catch {
        Write-HookError "old session files were not removed: $($_.Exception.Message)"
    }
}

# Takes a place among the running subagents when fewer than the band 2 limit are taken. A state
# that cannot be read or written allows the call, as a missing session id does: the gate never
# blocks over a failure of its own.
function Add-SubagentReservation {
    param([string]$Path)
    try {
        $lock = Enter-StateLock $Path
        try {
            $state = Read-SessionState $Path
            if ($state.Agents.Count + $state.Reservations.Count -ge $Band2SubagentLimit) {
                return $false
            }
            $state.Reservations += (Get-UnixTimeNow)
            Write-SessionState $Path $state
            return $true
        } finally {
            Exit-StateLock $lock
        }
    } catch {
        Write-HookError "the running subagents were not counted, so the call is allowed: $($_.Exception.Message)"
        return $true
    }
}

# Why the band forbids a new subagent, or '' when it allows one. Codex reports no subagent start or
# end, so only Claude Code counts the running subagents in band 2.
function Get-DispatchReason {
    param([string]$Harness)
    $usage = Get-UsageStatus $Harness
    $session = Get-HookField 'session_id'
    # Without a session id the running subagents cannot be counted, so the call is allowed.
    $isClaudeSession = $Harness -eq 'claude' -and (Test-PlainId $session)
    switch ($usage.Band) {
        1 { return '' }
        2 {
            if (-not $isClaudeSession -or (Add-SubagentReservation (Get-SessionFile $session))) {
                return ''
            }
            return "$($usage.Line) $Band2SubagentLimit subagents are running: wait for one to finish, or do this task yourself."
        }
        3 { return $usage.Line }
        4 {
            if ($isClaudeSession) {
                return "$($usage.Line) $(Get-WaiterInstruction $session)"
            }
            return $usage.Line
        }
        default { throw "unknown band '$($usage.Band)'" }
    }
}

# Records the band told to an agent; returns $false when that agent already heard it.
function Set-AnnouncedBand {
    param([string]$Path, [string]$Key, [int]$Band)
    $lock = Enter-StateLock $Path
    try {
        $state = Read-SessionState $Path
        if ("$($state.Announced[$Key])" -ceq "$Band") {
            return $false
        }
        $state.Announced[$Key] = $Band
        Write-SessionState $Path $state
        return $true
    } finally {
        Exit-StateLock $lock
    }
}

# The usage line, after any tool call, when the band changed since the agent last heard it. A
# subagent hears only band 4, its signal to wrap up; the gate enforces the other bands.
function Get-ToolContext {
    $session = Get-HookField 'session_id'
    $agent = Get-HookField 'agent_id'
    if (-not (Test-PlainId $session)) {
        return ''
    }
    $key = 'main'
    if ($agent -ne '') {
        if (-not (Test-PlainId $agent)) {
            return ''
        }
        $key = $agent
    }
    $usage = Get-UsageStatus 'claude'
    try {
        $isNewBand = Set-AnnouncedBand (Get-SessionFile $session) $key $usage.Band
    } catch {
        Write-HookError "the band was not recorded: $($_.Exception.Message)"
        return ''
    }
    if (-not $isNewBand) {
        return ''
    }
    if ($key -ceq 'main') {
        if ($usage.Band -eq 4) {
            return "$($usage.Line)`n$(Get-WaiterInstruction $session)"
        }
        return $usage.Line
    }
    if ($usage.Band -eq 4) {
        return "$($usage.Text). Band 4. Wrap up now: finish the current step at a consistent point (commit or checkpoint), report what is done and what is left, and end your run."
    }
    return ''
}

# The waiter runs while its record is current and its process lives.
function Test-WaiterRunning {
    param([string]$Path)
    $lock = Enter-StateLock $Path
    try {
        $waiter = (Read-SessionState $Path).Waiter
    } finally {
        Exit-StateLock $lock
    }
    $until = Get-JsonProperty $waiter 'until'
    $processId = 0
    $isProcessId = [int]::TryParse("$(Get-JsonProperty $waiter 'pid')", [System.Globalization.NumberStyles]::None,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$processId)
    if (-not $isProcessId -or -not (Test-Number $until) -or $until -le (Get-UnixTimeNow)) {
        return $false
    }
    return $null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)
}

# Devin also runs the hooks it finds in the Claude Code settings, so only a session whose transcript
# lives in this Claude Code folder may be held. Windows paths take either slash and ignore case.
function Test-ClaudeCodeSession {
    $transcript = (Get-HookField 'transcript_path') -replace '/', '\'
    $projects = ([System.IO.Path]::Combine($HarnessHome, 'projects') -replace '/', '\') + '\'
    return $transcript.StartsWith($projects, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-StopBlamesUsage {
    $options = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'
    return [regex]::IsMatch((Get-HookField 'last_assistant_message'), $UsageStopPattern, $options)
}

# Why the turn must go on, or '' to let it end. A stop the hook already continued always ends, so
# the hook never holds a turn twice for the same reason.
function Get-StopReason {
    if ((Get-HookField 'stop_hook_active') -ceq 'true') {
        return ''
    }
    $session = Get-HookField 'session_id'
    if (-not (Test-PlainId $session) -or -not (Test-ClaudeCodeSession)) {
        return ''
    }
    $usage = Get-UsageStatus 'claude'
    switch ($usage.Band) {
        4 {
            try {
                $isWaiting = Test-WaiterRunning (Get-SessionFile $session)
            } catch {
                # The hook never holds a turn over a failure of its own.
                Write-HookError "the waiter could not be checked: $($_.Exception.Message)"
                return ''
            }
            if ($isWaiting) {
                return ''
            }
            return "$($usage.Line) $(Get-WaiterInstruction $session)"
        }
        { $_ -in @(2, 3) } {
            if (Test-StopBlamesUsage) {
                return "$($usage.Line) Usage is not a reason to end the turn in band $($usage.Band): continue the remaining work. End the turn only when the task is done or needs a decision from the user."
            }
            return ''
        }
        # Band 1 never holds the turn.
        default { return '' }
    }
}

# Keeps the count of running subagents. These events must never fail: a failing SubagentStop hook
# would keep the subagent from stopping.
function Update-SubagentCount {
    param([string]$EventName)
    $session = Get-HookField 'session_id'
    $agent = Get-HookField 'agent_id'
    if (-not (Test-PlainId $session) -or -not (Test-PlainId $agent)) {
        return
    }
    $path = Get-SessionFile $session
    try {
        if ($EventName -eq 'agent-start') {
            # A started subagent takes the place its launch reserved.
            Edit-SessionState $path {
                param($state)
                $state.Agents[$agent] = Get-UnixTimeNow
                $state.Reservations = [object[]]@($state.Reservations | Select-Object -Skip 1)
            }
        } else {
            Edit-SessionState $path {
                param($state)
                $state.Agents.Remove($agent)
                $state.Announced.Remove($agent)
            }
        }
    } catch {
        Write-HookError "the running subagents were not updated: $($_.Exception.Message)"
    }
}

function Clear-Waiter {
    param([string]$Path)
    try {
        Edit-SessionState $Path { param($state) $state.Waiter = $null }
    } catch {
        Write-HookError "the waiter record was not removed: $($_.Exception.Message)"
    }
}

# Sleeps once until the full windows reset plus the margin, then exits: Claude Code wakes the
# session when a background command ends. One sleep instead of a polling loop, because the
# machine is expected to stay awake; a suspended machine wakes the session late. Returns the
# exit code.
function Wait-ForReset {
    param([string]$Session)
    if (-not (Test-PlainId $Session)) {
        Write-HookError 'wait needs the session id given in the hook message'
        return 2
    }
    $usage = Get-UsageStatus 'claude'
    if ($usage.Band -ne 4) {
        Write-StandardOutput "No wait needed: $($usage.Line)`n"
        return 0
    }
    if ($usage.ResumeAt -eq 0) {
        [Console]::Error.WriteLine('The reset time of the full usage window is unknown, so the waiter cannot wake the session: finish the current step, report, and wait for the user.')
        return 1
    }
    $wakeAt = $usage.ResumeAt + $WaitMarginSeconds
    $path = Get-SessionFile $Session
    try {
        Edit-SessionState $path { param($state) $state.Waiter = [pscustomobject]@{ pid = $PID; until = $wakeAt } }
    } catch {
        Write-HookError "the waiter was not recorded: $($_.Exception.Message)"
        return 1
    }
    try {
        Start-Sleep -Seconds ([System.Math]::Max([long]0, $wakeAt - [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
        $resetAt = [System.DateTimeOffset]::FromUnixTimeSeconds($usage.ResumeAt).UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        Write-StandardOutput "The usage window reset at $resetAt. Resume the plan where it stopped; read the usage line before starting subagents.`n"
    } finally {
        Clear-Waiter $path
    }
    return 0
}

function Test-HarnessAllowed {
    param([string]$EventName, [string]$Harness, [string[]]$Harnesses)
    if ($Harness -in $Harnesses) {
        return $true
    }
    Write-HookError "the $EventName event is only for $($Harnesses -join ' ')"
    return $false
}

# Mirrors the shell version: the pieces are printed in order and command substitution
# strips the trailing newlines before the final one is added. Returns $null when the event
# cannot run for the harness.
function Get-Context {
    param([string]$Harness, [string]$EventName)
    switch ($EventName) {
        'prompt' {
            $usage = Get-UsageStatus $Harness
            $text = (Read-PayloadText 'reminder.md') + (Get-ProjectRulesLine $Harness) + $usage.Line + "`n"
            $session = Get-HookField 'session_id'
            if ($Harness -eq 'claude' -and (Test-PlainId $session)) {
                # A band 4 prompt ends with the exact waiter command of its session.
                if ($usage.Band -eq 4) {
                    $text += (Get-WaiterInstruction $session) + "`n"
                }
                Save-MainBand $session $usage.Band
            }
        }
        'compact' {
            # Claude Code reloads the rule files and the project CLAUDE.md after a compaction, so a
            # copy of the principles would only repeat them; the reminder and the band still return.
            $principles = ''
            if ($Harness -ne 'claude') {
                $principles = (Read-PayloadText 'AGENTS.md') + "`n"
            }
            $text = $principles + (Read-PayloadText 'reminder.md') + (Get-UsageStatus $Harness).Line + "`n"
        }
        'subagent' {
            # Claude Code hears usage changes through the tool event instead.
            if (-not (Test-HarnessAllowed $EventName $Harness @('codex'))) {
                return $null
            }
            $text = (Get-UsageStatus $Harness).Line
        }
        'dispatch' {
            if (-not (Test-HarnessAllowed $EventName $Harness @('claude', 'codex'))) {
                return $null
            }
            $text = Get-DispatchReason $Harness
        }
        'tool' {
            if (-not (Test-HarnessAllowed $EventName $Harness @('claude'))) {
                return $null
            }
            $text = Get-ToolContext
        }
        'stop' {
            if (-not (Test-HarnessAllowed $EventName $Harness @('claude'))) {
                return $null
            }
            $text = Get-StopReason
        }
        { $_ -in @('agent-start', 'agent-stop') } {
            if (-not (Test-HarnessAllowed $EventName $Harness @('claude'))) {
                return $null
            }
            Update-SubagentCount $EventName
            $text = ''
        }
        default {
            Write-HookError "unknown event '$EventName'"
            return $null
        }
    }
    return $text.TrimEnd("`n")
}

# Escapes a string the way jq does: control characters as \u00xx, non-ASCII left as UTF-8.
function ConvertTo-JsonString {
    param([string]$Text)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($character in $Text.ToCharArray()) {
        $code = [int]$character
        switch ($code) {
            0x22 { [void]$builder.Append('\"') }
            0x5C { [void]$builder.Append('\\') }
            0x0A { [void]$builder.Append('\n') }
            0x0D { [void]$builder.Append('\r') }
            0x09 { [void]$builder.Append('\t') }
            0x08 { [void]$builder.Append('\b') }
            0x0C { [void]$builder.Append('\f') }
            default {
                if ($code -lt 0x20 -or $code -eq 0x7F) {
                    [void]$builder.Append('\u').Append($code.ToString('x4'))
                } else {
                    [void]$builder.Append($character)
                }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

# Each harness expects its own output shape; see the adapter table in README.md. The JSON is
# laid out exactly as jq prints it.
function Format-HookOutput {
    param([string]$Harness, [string]$EventName, [string]$Context)
    $value = ConvertTo-JsonString $Context
    switch ($Harness) {
        { $_ -in @('claude', 'codex') } {
            switch ($EventName) {
                { $_ -in @('subagent', 'tool') } {
                    # After a tool call, both tools pass hook output to the model only as JSON.
                    if ($Context -eq '') {
                        return ''
                    }
                    return "{`n  `"hookSpecificOutput`": {`n    `"hookEventName`": `"PostToolUse`",`n    `"additionalContext`": $value`n  }`n}`n"
                }
                'dispatch' {
                    # No output lets the call through; a deny decision blocks it and tells the model why.
                    if ($Context -eq '') {
                        return ''
                    }
                    return "{`n  `"hookSpecificOutput`": {`n    `"hookEventName`": `"PreToolUse`",`n    `"permissionDecision`": `"deny`",`n    `"permissionDecisionReason`": $value`n  }`n}`n"
                }
                'stop' {
                    # No output lets the turn end; a block decision continues it with the reason.
                    if ($Context -eq '') {
                        return ''
                    }
                    return "{`n  `"decision`": `"block`",`n  `"reason`": $value`n}`n"
                }
                { $_ -in @('agent-start', 'agent-stop') } {
                    return ''
                }
                default {
                    return $Context + "`n"
                }
            }
        }
        { $_ -in @('kiro', 'opencode', 'amp') } {
            return $Context + "`n"
        }
        'gemini' {
            return "{`n  `"hookSpecificOutput`": {`n    `"hookEventName`": `"BeforeAgent`",`n    `"additionalContext`": $value`n  }`n}`n"
        }
        'devin' {
            return "{`n  `"hookSpecificOutput`": {`n    `"hookEventName`": `"UserPromptSubmit`",`n    `"additionalContext`": $value`n  }`n}`n"
        }
        'cline' {
            return "{`n  `"cancel`": false,`n  `"contextModification`": $value`n}`n"
        }
        default {
            return $null
        }
    }
}

# Raw UTF-8 bytes on stdout: Console.OutputEncoding defaults to the legacy code page and
# setting it fails when the hook runs without a console.
function Write-StandardOutput {
    param([string]$Text)
    $bytes = $Utf8NoBom.GetBytes($Text)
    $standardOutput = [Console]::OpenStandardOutput()
    try {
        $standardOutput.Write($bytes, 0, $bytes.Length)
        $standardOutput.Flush()
    } finally {
        $standardOutput.Dispose()
    }
}

function Invoke-Main {
    param([string[]]$Arguments)
    if ($Arguments.Count -eq 3 -and $Arguments[1] -eq 'wait') {
        if (-not (Test-HarnessAllowed 'wait' $Arguments[0] @('claude'))) {
            exit 2
        }
        exit (Wait-ForReset $Arguments[2])
    }
    if ($Arguments.Count -ne 2 -or $Arguments[1] -eq 'wait') {
        [Console]::Error.WriteLine('Usage: inject.ps1 <harness> <prompt|compact|subagent|dispatch|tool|stop|agent-start|agent-stop>')
        [Console]::Error.WriteLine('       inject.ps1 claude wait <session id>')
        exit 2
    }
    $harness = $Arguments[0]
    $eventName = $Arguments[1]
    if ($harness -eq 'claude') {
        $script:HookInput = Read-HookInput
    }
    $context = Get-Context $harness $eventName
    if ($null -eq $context) {
        exit 2
    }
    $output = Format-HookOutput $harness $eventName $context
    if ($null -eq $output) {
        Write-HookError "unknown harness '$harness'"
        exit 1
    }
    Write-StandardOutput $output
}

Invoke-Main -Arguments $args
