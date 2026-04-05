# Advisory Runtime Contract

This document defines the terms used by the advisory bridge, sidecar, accounts UI, and recovery flows.

## Runtime truth

Runtime truth answers one question: can the advisory sidecar answer requests and execute recipes right now?

- Source of truth: live bridge health and sidecar supervisor state.
- Typical statuses: `ready`, `busy`, `starting`, `hung_start`, `socket_missing`, `transport_failure`, `timeout`, `unavailable`.
- A healthy runtime can still coexist with weak provider coverage for one or more accounts.

## Inventory truth

Inventory truth answers a different question: what isolated provider accounts and session folders exist on disk?

- Source of truth: `~/.cli-profiles` and its metadata files.
- Inventory does not guarantee runtime reachability.
- Runtime failure must not hide saved accounts from the UI.

## Provider verification

Provider verification means the sidecar checked a provider route recently enough to say whether it is usable.

- Provider-level verification may refer to the selected or currently routed account for that provider.
- Provider verification is a runtime statement, not just a filesystem statement.

## Account verification

Account verification is an exact `provider + account` check.

- It must validate the requested account, not "any healthy account for this provider".
- It is the required check after re-login, account switch, and imported-session reconciliation.

## Preferred account routing

Preferred accounts are stored in `.memograph-account-preferences.json` inside the profiles root.

- The preferences file is the live source of truth for preferred-account routing.
- Bootstrap env vars such as `MEMOGRAPH_ADVISOR_PROFILE_CLAUDE` are only a startup fallback.
- Execution-time account choice must still consider live account state before using the preferred account.

## Execution-time balancing

Account selection happens at execution time, inside the provider route.

- Non-runnable accounts are excluded first: missing binary, missing session marker, cooldown active, or non-retryable failure.
- Runnable accounts are ranked by lower `requests_made`, lower `failure_count`, then older `last_used_at`.
- Preferred account is only a tie-break bias, not a hard override.
- Successful execution records usage and clears stale account/provider failure state.

## Failure classes

### Transport failure

The client could not complete the socket round trip.

- Examples: connect failure, broken pipe, unreadable socket.
- This is different from a provider auth failure.

### Timeout

The runtime answered too slowly or a provider CLI call exceeded its deadline.

- Timeout means the path may still exist, but it did not complete in budget.

### Hung start

The sidecar process exists but never produces a usable socket within the startup grace period.

- Hung start is restart-worthy.
- Cleanup must target the owning pid before deleting socket or pidfile artifacts.

### Recoverable busy

The sidecar is alive and currently occupied with work such as auth verification or recipe execution.

- Busy should not be normalized into transport failure.
- Busy does not require restart by itself.

## Restart-worthy failures

These statuses justify restart or hard cleanup when recovery cannot stay targeted:

- `hung_start`
- `socket_missing`
- `transport_failure`
- `unavailable`

`busy` and ordinary account auth failures do not justify a blind restart.

## UI contract

The UI should always keep runtime and inventory separate.

- Runtime status explains whether advisory can answer and execute now.
- Inventory status explains what accounts exist on disk.
- A red runtime with green inventory is allowed and should be described explicitly, not hidden.
