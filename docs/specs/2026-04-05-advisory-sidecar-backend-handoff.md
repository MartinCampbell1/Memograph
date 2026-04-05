# Advisory Sidecar Backend Handoff

Date: 2026-04-05
Status: Critical bugs — needs deep backend investigation
Owner: Next agent taking over backend work

## Context

Memograph V2 advisory sidecar was implemented per spec at:
`/Users/martin/mymacagent/docs/specs/2026-04-04-memograph-v2-advisory-sidecar-spec.md`

The frontend/UI foundation is mostly working (tabs, views, accounts page).
The backend sidecar system has fundamental issues that need deep investigation.

## Current State

- Build: passes (`swift build -c release`)
- Tests: 407 pass
- App runs from `/Applications/Memograph.app`
- Advisory tab in Settings shows accounts
- Python sidecar (`memograph_advisor.py`) can start and respond to health checks
- But the system is unstable — sidecar keeps failing and recovering in a loop

## Critical Issues (all from user's direct feedback)

### 1. Sidecar keeps cycling between "ready" and "starting/degraded"

**Symptom:** Advisory sidecar status oscillates: "Advisory sidecar ready" → works for a moment → "Advisory sidecar starting" → "sidecar failures: N" → eventually comes back → fails again.

**Where to look:**
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/AdvisoryBridgeClient.swift` — `AdvisorySidecarSupervisor.ensureStarted()`, health check flow, socket management
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/AdvisoryHealthMonitor.swift` — `refresh()` creates a new `AdvisoryBridgeClient` on every health poll, which may create competing supervisors
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/memograph_advisor.py` — Python sidecar, single-threaded, can block on long health probes

**Known contributing factors:**
- Socket path gets deleted when stale detection triggers (60-second threshold in `UDSJSONRPCTransport.send()`)
- Multiple sidecar processes have been observed competing for same socket
- Health check with `forceRefresh: true` takes 10-15 seconds (Gemini MCP discovery is slow), during which new health checks time out
- Python sidecar is single-threaded: if one request is being processed, next connection blocks

**What needs to happen:**
- Investigate why the socket keeps being detected as "stale (not modified in 60s)"
- The 60-second stale threshold may be too aggressive — a healthy sidecar doesn't modify its socket file after creation
- Consider removing the stale socket deletion entirely and relying only on connect failure
- Ensure only ONE sidecar process ever exists per socket path
- Consider making the Python sidecar multi-threaded or using async I/O so health checks don't block recipe execution

### 2. "Session detected, but account identity is not exposed by the CLI"

**Symptom:** Claude and Codex accounts show "Session detected, but account identity is not exposed by the CLI" — no email/name shown. Gemini shows email correctly.

**Where to look:**
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/memograph_advisor.py` — `_compute_health()` and provider probe logic
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/provider_sessions.py` — session detection and identity extraction
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/AdvisoryCLIProfilesStore.swift` — `identityHint()` method

**What needs to happen:**
- For Claude CLI: find where Claude stores account identity (email) and extract it. Check `~/.claude/` or `~/.cli-profiles/claude/acc1/home/.claude/` for credential/identity files.
- For Codex CLI: find where Codex stores account identity. Check `~/.codex/auth.json` or similar.
- Each provider's identity extraction is different — need to inspect actual files on disk.
- The `identityHint()` in `AdvisoryCLIProfilesStore.swift` reads `.credentials.json` and `google_accounts.json` — these may not exist for Claude/Codex profiles.

### 3. Only one provider used at a time — should rotate/use all

**Symptom:** When sidecar is ready, it shows "active provider: claude" — only Claude is used. User wants ALL providers (Claude, Gemini, Codex) to be used for different tasks, with rotation.

**Where to look:**
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/memograph_advisor.py` — provider selection logic, `_compute_health()`, recipe execution
- Provider order is configured in `AppSettings.advisorySidecarProviderOrder` (default: `["claude", "gemini", "codex"]`)

**What needs to happen:**
- The sidecar currently picks the first healthy provider and sticks with it
- Need to implement provider routing per recipe/task type (as described in the spec):
  - Gemini: large-context pattern mining, weekly analysis
  - Claude: deep reflective synthesis, continuity
  - Codex: structuring, formatting, crisp outputs
- At minimum: rotate providers when one fails, don't just use the first one forever
- Account rotation within a provider (e.g., if acc1 rate-limited, try acc2) — this is critical because user has 20+ Codex accounts

### 4. Socket "stale" detection is broken

**Symptom:** Error message: "Advisory sidecar socket at .../memograph-advisor.sock is stale (not modified in 60s), removed."

**Root cause:** The `UDSJSONRPCTransport.send()` method checks if the socket file was modified within the last 60 seconds. Unix domain sockets don't update their mtime when data flows through them — mtime is set at creation time and never changes. So after 60 seconds, EVERY healthy socket looks "stale".

**Where to look:**
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/AdvisoryBridgeClient.swift` — `UDSJSONRPCTransport.send()`, around the `fileModificationDate` check

**Fix:** Remove the stale socket detection based on mtime entirely. Instead, detect staleness by attempting to connect — if connect fails, the socket is stale.

### 5. Sidecar keeps respawning (failures accumulate even with high max)

**Symptom:** Even with `maxConsecutiveFailures` set to 50, failures keep accumulating (3, 4, 5...) and the system oscillates.

**Where to look:**
- The health monitor timer fires every 10-60 seconds
- Each timer tick creates a new `AdvisoryBridgeClient` which resolves the shared supervisor
- The supervisor's `prepareForHealthCheck()` calls `ensureStarted()`
- If the socket was deleted by the stale detection, `ensureStarted()` tries to launch a new process
- But the old process may still be running (socket deleted doesn't kill the process)
- Now there are orphaned Python processes with no socket

**Fix:** The cascade is: stale detection → socket deleted → ensureStarted → new process → old process orphaned → more failures. Fix stale detection (issue #4) and this should stabilize.

### 6. Gemini CLI is very slow to probe (8-15 seconds)

**Symptom:** Gemini shows "session expired" or "CLI probe timed out" even though the session is valid.

**Root cause:** Gemini CLI v0.36.0 does MCP server discovery on every invocation, which takes 8-15 seconds. The default probe timeout was 6 seconds (now increased to 20 in settings, but the Python sidecar also has its own timeout).

**Where to look:**
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/memograph_advisor.py` — `probe_timeout_seconds` parameter, `_run_provider_probe()`
- The `--probe-timeout-seconds` CLI argument is passed when launching the sidecar

**What needs to happen:**
- Ensure the probe timeout passed to the Python sidecar is actually 20 seconds (check the launch arguments)
- Consider caching Gemini probe results so we don't re-probe on every health check
- Consider adding `--no-sandbox` or `--skip-mcp` flag to Gemini CLI invocation for faster probes

### 7. Re-login flow is unreliable

**Symptom:** User clicks Re-login → Terminal opens → auth completes → "Process completed" → but sidecar doesn't pick up the new session. Status stays "starting" or "degraded".

**Where to look:**
- `/Users/martin/mymacagent/Sources/MyMacAgent/Settings/SettingsView.swift` — `handleReauthorizeProviderAccount()`
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/AdvisoryProviderSessionControl.swift` — Terminal launch and session import
- After Terminal completes, user clicks "Refresh" but the sidecar is already in a bad state

**What needs to happen:**
- After re-login, automatically restart the sidecar (not just refresh health)
- Clear consecutive failures counter on explicit user action (re-login, restart)
- Show clear feedback: "Session imported. Restarting sidecar..."

## File Map for Backend Investigation

### Python sidecar (the core backend)
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/memograph_advisor.py` — main sidecar, JSON-RPC server, health checks, recipe execution, provider probing
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/provider_sessions.py` — CLI session detection, import, login flows

### Swift bridge (connects app to sidecar)
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/AdvisoryBridgeClient.swift` — supervisor, socket transport, process management, health checks
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/AdvisoryHealthMonitor.swift` — periodic health polling, singleton
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/AdvisorySidecarRuntime.swift` — Python/script path resolution
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/AdvisoryCLIProfilesStore.swift` — filesystem profile discovery
- `/Users/martin/mymacagent/Sources/MyMacAgent/Advisory/Bridge/AdvisoryProviderSessionControl.swift` — login/import/switch actions

### Settings
- `/Users/martin/mymacagent/Sources/MyMacAgent/Settings/AppSettings.swift` — advisory settings (timeouts, max failures, provider order)
- `/Users/martin/mymacagent/Sources/MyMacAgent/Settings/SettingsView.swift` — accounts tab UI

### CLI profiles on disk
- `~/.cli-profiles/claude/acc1/` — Claude account
- `~/.cli-profiles/gemini/acc1/`, `acc2/` — Gemini accounts  
- `~/.cli-profiles/codex/acc1/`, `acc2/`, `acc3/`, `acc4/` — Codex accounts

### FounderOS donor (read-only reference)
- `/Users/martin/FounderOS/quorum/provider_sessions.py` — original provider session management code
- `/Users/martin/FounderOS/quorum/gateway.py` — provider gateway with rotation and cooldown

## User's Explicit Requirements

1. **Accounts must ALWAYS be visible** — regardless of sidecar state (fixed in UI, but backend should also return account data even when degraded)
2. **Sidecar must not oscillate** — either it works or it gracefully reports why, no cycling
3. **All providers should be usable** — not just the first healthy one. Route by capability.
4. **Account rotation within providers** — if acc1 is rate-limited, try acc2, acc3, etc.
5. **Identity must be shown** — find email/name for Claude and Codex accounts
6. **Failures should not disable the system** — max failures should be very high, and explicit user actions (restart, re-login) should reset failure counters
7. **Re-login must work end-to-end** — Terminal auth → session import → sidecar restart → working state
8. **No stale socket false positives** — don't delete working sockets based on mtime

## Priority Order for Fixes

1. Fix socket stale detection (remove mtime check, use connect-based detection)
2. Fix sidecar oscillation (single process guarantee, proper lifecycle)
3. Fix provider identity extraction (Claude email, Codex email)
4. Implement provider rotation (not just first-healthy)
5. Fix re-login end-to-end flow
6. Reset failure counters on explicit user actions
7. Implement account rotation within providers

## Testing Approach

After each fix:
1. `swift build -c release`
2. `swift test` — all 407 must pass
3. Deploy to `/Applications/Memograph.app`
4. Open Settings → Accounts
5. Click "Run full auth check"
6. Verify: sidecar stays "ready", accounts show with identity, no oscillation
7. Wait 2 minutes — verify sidecar doesn't cycle back to "starting"
8. Kill sidecar process (`pkill -f memograph_advisor`) — verify app doesn't crash, accounts still visible, sidecar restarts cleanly

## Important Constraints

- Do NOT modify FounderOS
- Do NOT rewrite Memograph core (capture, OCR, summaries, knowledge)  
- Advisory layer builds ON TOP of existing core
- Python sidecar and Swift bridge must both be fixed
- All commits must be pushed to `origin master`
- App must be redeployed after changes: build → copy binary + bundle → restart
