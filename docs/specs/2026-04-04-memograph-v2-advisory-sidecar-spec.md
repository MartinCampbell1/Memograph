# Memograph V2 Advisory Sidecar Engineering Spec

Date: 2026-04-04
Status: Draft for implementation
Owner: Memograph core + advisory sidecar

## 1. Purpose

Memograph V2 should evolve from a passive memory engine into a memory-native advisory system.

It must not become:
- a bossy coach
- a productivity-shame machine
- a generic chat shell
- a rewrite of Memograph core
- a clone of FounderOS

It should become:
- a continuity advisor
- a second layer of thinking over lived digital activity
- a system that turns memory into:
  - continuity
  - insight
  - expression
  - gentle direction

Core product framing:

> Memograph V2 is a memory-native advisory system that turns lived digital activity into the next useful thread, the next text, or the next layer of clarity.

## 2. Product Principles

### 2.1 Tone

User-facing outputs must be:
- non-directive
- evidence-based
- high-agency
- concise
- useful
- optional

Do not use tones like:
- "тебе нужно"
- "тебе стоит обязательно"
- "сегодня ты был непродуктивен"
- "ты опять отвлекся"

Preferred style:
- "Я заметил..."
- "Похоже, тут повторяющаяся нить..."
- "Из этого может получиться сильный твит..."
- "Если хочешь продолжить, вот 3 хороших входа..."

### 2.2 Language

Default user-facing advisory artifacts should be in Russian.

Keep product names, tools, services, and model names in their natural canonical form:
- "Notion"
- "Claude"
- "Gemini"
- "Codex"
- "ScreenCaptureKit"

Do not translate brand or product identifiers into awkward Russian equivalents.

### 2.3 Proactivity mode

Default mode for Martin: `ambient`.

`ambient` means the system may proactively surface advice only when:
- signal is strong
- confidence is high
- evidence is present
- user attention budget is not exhausted

The system must not be silent by default in all cases, but it must not spam.

### 2.4 Insight competition

Advice candidates should compete for user attention in an internal ranking layer.

Working term:
- `Advisory Exchange`
- or `Insight Market`

The goal is not "first candidate wins" or "highest score wins".
The practical implementation should be a category-aware attention market, not a single global leaderboard.

## 3. Current Foundation in Memograph

Existing stable substrate already present in the repo:
- capture pipeline
- OCR pipeline
- accessibility context
- SQLite source of truth
- timeline and search
- daily/hourly summaries
- Obsidian export
- knowledge graph
- maintenance / review / apply workflows
- provider routing
- settings and privacy controls

Relevant current files:
- `docs/architecture.md`
- `Sources/MyMacAgent/App/AppDelegate.swift`
- `Sources/MyMacAgent/Database/DatabaseManager.swift`
- `Sources/MyMacAgent/Summary/DailySummarizer.swift`
- `Sources/MyMacAgent/Export/ObsidianExporter.swift`
- `Sources/MyMacAgent/Knowledge/KnowledgePipeline.swift`
- `Sources/MyMacAgent/Settings/AppSettings.swift`

FounderOS must be treated as a donor for runtime/orchestration ideas only.

Relevant donor files:
- `/Users/martin/FounderOS/quorum/provider_sessions.py`
- `/Users/martin/FounderOS/quorum/docs/specs/2026-03-26-orchestration-engine-design.md`

## 4. Architecture Decision

### 4.1 Final architecture

Memograph V2 should be built as:

`Memograph Core + Advisory Sidecar + Controlled Deep Context Access`

### 4.2 Boundary

#### Memograph Core owns:
- canonical memory
- capture data
- OCR and summaries
- knowledge graph
- deterministic signals
- packet building
- ranking state
- advisory artifacts
- user feedback
- UI surfaces
- policy and access decisions

#### Advisory Sidecar owns:
- model execution
- multi-step reasoning
- orchestration recipes
- provider selection
- CLI session usage
- MCP tool usage
- critique / tone checks
- ephemeral scratchpads

### 4.3 Anti-corruption rule

The sidecar must not write directly into Memograph SQLite.

All interaction must go through typed contracts:
- packet request
- evidence expansion request
- artifact proposal submission
- feedback submission

The sidecar may propose:
- thread upserts
- continuity item upserts
- content candidates
- advisory artifacts

Memograph core must validate and persist canonical state.

## 5. Context Access Model

The previous "thin packet only" model is too restrictive for this product.

The final model should be:

`packet-first + evidence-on-demand`

### 5.1 Access levels

#### L1 Summary Context
- hourly and daily summaries
- active entities
- thread refs
- open loops
- decisions
- basic session summaries

#### L2 Structured Context
- OCR excerpts
- fused context excerpts
- timeline search hits
- knowledge note excerpts
- richer session evidence
- note fragments

#### L3 Rich Evidence
- selected screenshots
- screenshot bundles
- raw OCR blocks
- graph neighborhoods
- high-fidelity context windows

### 5.2 Policy

Recipes start at `L1`.

They may request:
- `L2` if grounding or synthesis needs richer text evidence
- `L3` only when visual or high-fidelity context actually matters

There must be no always-on unrestricted raw access.

### 5.3 Advisory access profiles

Add a new advisory setting family:
- `conservative`
- `balanced`
- `deep_context`
- `full_research_mode`

Recommended default for Martin:
- `deep_context`

## 6. New Canonical Product Objects

These objects should live in Memograph core as canonical domain state.

### 6.1 Thread

A durable continuity line across days and apps.

Kinds:
- `project`
- `question`
- `interest`
- `person`
- `commitment`
- `theme`

Fields:
- `id`
- `title`
- `slug`
- `kind`
- `status` (`active`, `stalled`, `parked`, `resolved`)
- `confidence`
- `first_seen_at`
- `last_active_at`
- `source`
- `summary`

### 6.2 ThreadEvidence

Maps a thread to supporting evidence.

Fields:
- `id`
- `thread_id`
- `evidence_kind` (`session`, `summary`, `entity`, `capture`, `note`, `audio`)
- `evidence_ref`
- `weight`
- `created_at`

### 6.3 ContinuityItem

Canonical unresolved or stabilizing memory units.

Kinds:
- `open_loop`
- `decision`
- `question`
- `commitment`
- `blocked_item`

Fields:
- `id`
- `thread_id`
- `kind`
- `title`
- `body`
- `status`
- `confidence`
- `source_packet_id`
- `created_at`
- `updated_at`
- `resolved_at`

### 6.4 AdvisoryArtifact

User-facing or latent advisory units.

Kinds:
- `resume_card`
- `reflection_card`
- `tweet_seed`
- `thread_seed`
- `note_seed`
- `research_direction`
- `pattern_notice`
- `weekly_review`

Fields:
- `id`
- `kind`
- `title`
- `body`
- `thread_id`
- `source_packet_id`
- `source_recipe`
- `confidence`
- `why_now`
- `evidence_json`
- `language`
- `status`
- `created_at`
- `surfaced_at`
- `expires_at`

### 6.5 ArtifactFeedback

User feedback that shapes ranking and suppression.

Fields:
- `id`
- `artifact_id`
- `feedback_kind`
- `notes`
- `created_at`

Feedback kinds:
- `useful`
- `too_obvious`
- `too_bossy`
- `wrong`
- `not_now`
- `mute_kind`
- `more_like_this`

### 6.6 GuidanceProfile

Stored in settings, not necessarily in SQLite.

Fields:
- `language` default `ru`
- `tone_mode` default `non_directive`
- `assertiveness_level`
- `allow_proactive_advice`
- `proactivity_mode`
- `daily_attention_budget`
- `min_gap_minutes`
- `writing_style`
- `allow_screenshot_escalation`
- `allow_external_cli_providers`
- `allow_mcp_enrichment`

## 7. Proposed New SQLite Migrations

### 7.1 V006_AdvisoryThreads

Add tables:
- `advisory_threads`
- `advisory_thread_evidence`
- `continuity_items`

### 7.2 V007_AdvisoryArtifacts

Add tables:
- `advisory_packets`
- `advisory_artifacts`
- `advisory_artifact_feedback`

### 7.3 V008_AdvisoryRuns

Add tables:
- `advisory_runs`
- `advisory_evidence_requests`

These are for observability, dedupe, and debugging.

## 8. Packet Design

Packets are bounded, typed evidence bundles.

They are not raw database dumps.

### 8.1 ReflectionPacket

Used for fresh session reflection, resume hints, and lightweight output generation.

Suggested fields:
- `packet_id`
- `packet_version`
- `kind = reflection`
- `trigger_kind`
- `time_window`
- `active_entities`
- `candidate_thread_refs`
- `salient_sessions`
- `candidate_continuity_items`
- `attention_signals`
- `constraints`

### 8.2 ThreadPacket

Used for continuity and composition around a specific thread.

Suggested fields:
- `packet_id`
- `packet_version`
- `kind = thread`
- `thread`
- `recent_evidence`
- `linked_items`
- `continuity_state`
- `constraints`

### 8.3 WeeklyPacket

Used for pattern review and thread evolution.

Suggested fields:
- `packet_id`
- `packet_version`
- `kind = weekly`
- `window`
- `thread_rollup`
- `patterns`
- `continuity_items`
- `constraints`

### 8.4 Common packet requirements

Every packet must contain:
- `packet_version`
- `language`
- `evidence_refs`
- `confidence hints`
- `access_level_granted`
- `allowed_tools`
- `provider_constraints`

## 9. IPC Contract

The sidecar should run as a local process:
- suggested binary name: `memograph-advisor`

Suggested transport:
- local Unix domain socket
- JSON-RPC over UDS

### 9.1 Core -> Sidecar methods

- `advisor.runRecipe`
- `advisor.cancelRun`
- `advisor.health`

Example inputs:
- packet
- recipe name
- provider/runtime constraints
- access level
- timeout

### 9.2 Sidecar -> Core methods

- `core.requestEvidence`
- `core.submitArtifactProposals`
- `core.submitContinuityProposals`
- `core.recordRunOutcome`

### 9.3 Explicitly disallowed

The sidecar must not:
- open SQLite directly
- mutate knowledge tables directly
- mutate capture data directly

## 10. FounderOS Donor Integration

FounderOS is a donor runtime, not a product merge target.

### 10.1 Reuse ideas from FounderOS

Reuse/adapt:
- provider session import and login environment patterns from `provider_sessions.py`
- runtime abstraction
- recipe-based orchestration
- MCP gateway concepts
- provider rotation and retries

### 10.2 Do not import FounderOS ontology

Do not leak these into Memograph UI:
- "agents"
- "DAGs"
- "orchestrator sessions"
- "board mode"
- "tournament mode"

The product should feel like one advisory system, not a visible multi-agent playground.

### 10.3 Provider roles

Keep provider choice abstract.

Expected practical mapping:
- `Gemini CLI`: large-context pattern mining
- `Claude CLI`: deep reflective synthesis
- `Codex CLI`: structuring, formatting, implementation-quality outputs

But recipes should depend on capabilities, not provider names.

## 11. Advisory Exchange

This is the implementation of the user's "биржа идей / competition for attention" concept.

### 11.1 Goal

Advice candidates compete for user attention across multiple meaning poles, not inside one flat queue.

The system should distribute attention between domains such as:
- continuity
- writing / expression
- research
- focus
- social
- health
- decisions

Not every candidate gets surfaced.

The goal is not one universal winner, but a small balanced set of grounded candidates that fits the context of the day and the user's attention budget.

### 11.2 Candidate inputs

Candidates may come from:
- continuity resume
- open loop review
- writing seed / note seed
- research direction
- pattern finding / focus reflection
- social signal
- health pulse
- decision review
- weekly reflection

### 11.3 Score dimensions

Each candidate should carry an attention vector rather than one absolute score:
- `confidence`
- `evidence_strength`
- `novelty`
- `urgency`
- `timing_fit`
- `fatigue`
- `repetition`
- `category_balance`
- `feedback_history`

Memograph core may persist a diagnostic scalar such as `market_score` or `readiness_signal` for observability and tie-breaking, but this must not become the sole cross-domain decision rule.

### 11.4 Candidate states

- `candidate`
- `queued`
- `surfaced`
- `dismissed`
- `expired`
- `accepted`
- `muted`

### 11.5 Auction rules

Suggested behavior:
- candidates are evaluated at creation
- candidates first compete inside their own domain / category
- the exchange allocates attention across domains using day context, fatigue, balance pressure, and feedback history
- one domain should not monopolize attention just because its candidates have higher raw confidence
- lower-ranked candidates may remain latent for future resurfacing
- multiple domains may receive allocation on user-invoked runs
- repeated weak candidates decay
- strong candidates may persist if refreshed by new evidence

### 11.6 Default ambient budget

For `ambient` mode:
- soft target: `6` proactive surfaces per day
- hard cap: `10` per day
- min gap between proactive nudges: `45` minutes
- per-thread cooldown: `6` hours
- per-kind fatigue cooldown: `3` hours

These values should be configurable in `GuidanceProfile`.

## 12. Recipes for V1

V1 should already be architected as a broad advisory sidecar, even if individual recipes start with stubbed or lighter implementations.

Target domain coverage in V1:
- continuity
- writing / expression
- research
- focus
- social
- health
- decisions

### 12.1 continuity_resume

Purpose:
- help re-enter a thread or project

Output:
- `resume_card`

Must answer:
- where the user left off
- what seems unresolved
- what was already decided
- 2 to 3 possible next continuations

### 12.2 tweet_from_thread

Purpose:
- turn a thread into public signal

Output:
- `tweet_seed`
- optional `thread_seed`
- optional `note_seed`

Must include:
- angle
- why this is interesting
- evidence anchors

### 12.3 interest_miner

Purpose:
- detect recurring fascinations and research pull

Output:
- `research_direction`
- `pattern_notice`

### 12.4 open_loop_review

Purpose:
- identify unresolved, resurfacing, or repeatedly avoided threads

Output:
- `reflection_card`

### 12.5 weekly_reflection

Purpose:
- generate a weekly continuity and pattern digest

Output:
- `weekly_review`

### 12.6 pattern_finder

Purpose:
- inspect turbulence, re-entry cost, fragmentation, and focus episodes

Output:
- `pattern_notice`

### 12.7 health_pulse

Purpose:
- notice overload, rhythm breaks, and gentle recovery opportunities without moralizing

Output:
- `reflection_card`

### 12.8 decision_review

Purpose:
- capture fresh decisions and branch choices while they still have context

Output:
- `reflection_card`

## 13. Advisory Roles for V1

Use recipe-based minimal multi-agent orchestration, not a visible swarm.

V1 should preserve a single-advisor UX while still supporting multiple internal capabilities.

### Required capabilities

- `ContinuitySynthesizer`
- `PatternFinder`
- `Writer`
- `ResearchScout`
- `FocusReflector`
- `SocialSignalScout`
- `HealthObserver`
- `DecisionHistorian`
- `GroundingJudge`
- `ToneGuard`

### Explicitly not in V1

- planner agent
- executor agent
- autonomous life manager
- auto-poster
- social strategist swarm
- visible debate UI

## 14. UI Surfaces

Do not make chat the primary surface.

### 14.1 Resume Me

Primary value surface.

Shows:
- active thread
- where user stopped
- open loops
- prior decisions
- next continuation options

Likely implementation:
- menu bar panel section
- thread-specific card in timeline / knowledge surface

### 14.2 Turn This Into Signal

User-invoked transform:
- tweet ideas
- thread ideas
- note seed

Likely implementation:
- button on thread/resume card

### 14.3 What Am I Circling?

Interest mining and repeated pattern surface.

### 14.4 Help Me Get Unstuck

Manual invocation surface when user feels lost.

### 14.5 Weekly Review

Digest surface over threads, not just days.

### 14.6 Advisory Inbox

Optional passive list of surfaced advisory artifacts.

## 15. Proposed New Source Layout

Create new folders under `Sources/MyMacAgent/`:

- `Advisory/`
- `Advisory/Packets/`
- `Advisory/Bridge/`
- `Advisory/Exchange/`
- `Advisory/Signals/`
- `Advisory/Views/`
- `Advisory/Models/`

Suggested initial files:
- `Advisory/Signals/ThreadDetector.swift`
- `Advisory/Signals/ContinuitySignalBuilder.swift`
- `Advisory/Signals/AttentionPatternBuilder.swift`
- `Advisory/Packets/ReflectionPacketBuilder.swift`
- `Advisory/Packets/ThreadPacketBuilder.swift`
- `Advisory/Packets/WeeklyPacketBuilder.swift`
- `Advisory/Bridge/AdvisoryBridgeClient.swift`
- `Advisory/Bridge/AdvisoryBridgeServerProtocol.swift`
- `Advisory/Exchange/AdvisoryExchange.swift`
- `Advisory/Exchange/AttentionMarketEvaluator.swift`
- `Advisory/Views/ResumeCardView.swift`
- `Advisory/Views/AdvisoryInboxView.swift`

## 16. Settings Changes

Extend `AppSettings` with advisory-specific settings:
- `advisoryEnabled`
- `advisoryAccessProfile`
- `advisoryProactivityMode`
- `advisoryDailyAttentionBudget`
- `advisoryMinGapMinutes`
- `advisoryPerThreadCooldownHours`
- `advisoryAllowScreenshotEscalation`
- `advisoryAllowMCPEnrichment`
- `advisoryPreferredLanguage`
- `advisoryWritingStyle`

Recommended default values for Martin:
- enabled
- access profile: `deep_context`
- proactivity mode: `ambient`
- daily budget: `6`
- hard cap: `10`
- min gap: `45`
- language: `ru`

## 17. Trigger Model

Advisory triggers should be contextual, not cron-like spam.

### Trigger kinds

- `morning_resume`
- `reentry_after_idle`
- `thread_resurfaced`
- `research_burst_complete`
- `session_end`
- `end_of_day`
- `weekly_review`
- `user_invoked_lost`
- `user_invoked_write`

### Trigger gating

Before surfacing any proactive artifact, check:
- confidence threshold
- evidence threshold
- attention budget remaining
- cooldowns
- duplicate similarity
- thread fatigue

## 18. MCP and Enrichment Rollout

### Phase 1

No mandatory connectors.

Use only Memograph-derived context:
- sessions
- summaries
- knowledge graph
- notes

### Phase 2

Read-only enrichers:
- calendar
- reminders/tasks
- optional web research

### Phase 3

Expanded enrichers:
- WHOOP / sleep / HRV
- energy-aware advisory
- other MCP data sources

### Explicit note

iPhone coverage is not a blocker for advisory V1.

iPhone mirroring / video repeat false-positive capture behavior is a separate runtime issue and should be handled independently from the advisory architecture.

## 19. Rollout Plan

### Phase A: Advisory foundation

Implement:
- migrations
- thread detection
- continuity items
- packet builders
- artifact store
- feedback store

### Phase B: Sidecar bridge

Implement:
- local sidecar process
- UDS JSON-RPC
- FounderOS runtime adapter
- recipe runner
- evidence escalation contract

### Phase C: First surfaces

Implement:
- Resume Me
- Turn This Into Signal
- Weekly Review

### Phase D: Ambient delivery

Implement:
- Advisory Exchange
- budget and cooldown system
- bounded proactivity
- dismiss / snooze / mute controls

### Phase E: Enrichment

Implement:
- calendar
- reminders
- web research on request
- later WHOOP and recovery data

## 20. Non-goals

Do not build these in V1:
- full autonomous agent that runs life or business
- direct FounderOS ontology inside Memograph UI
- auto-posting to X
- hidden background swarm that constantly burns inference
- productivity score
- ADHD diagnosis layer
- direct unrestricted raw database access for sidecar
- rewrite of core capture/summaries/knowledge pipeline

## 21. Risks

### 21.1 Thread explosion

Too many low-value threads will destroy continuity value.

Mitigation:
- aggressive dedupe
- thread confidence thresholds
- merge/suppress review flow

### 21.2 Spam / attention fatigue

Too many surfaced artifacts make the system invisible.

Mitigation:
- Advisory Exchange
- daily budgets
- per-kind cooldowns
- user feedback shaping

### 21.3 Provider leakage

If product UI starts exposing orchestration internals, the product gets noisy and brittle.

Mitigation:
- keep FounderOS invisible behind recipe adapters

### 21.4 Grounding failure

Advice without inspectable evidence will feel fake.

Mitigation:
- evidence refs
- confidence
- grounding judge

### 21.5 Privacy overcorrection

Too little context reduces usefulness.

Mitigation:
- controlled access levels
- configurable advisory profiles
- evidence escalation

## 22. First Implementation Slice

If implementation starts immediately, the first slice should be:

1. `V006_AdvisoryThreads`
2. `ThreadDetector`
3. `ContinuitySignalBuilder`
4. `ReflectionPacketBuilder`
5. `AdvisoryArtifactStore`
6. `AdvisoryExchange`
7. `Resume Me` surface
8. local `memograph-advisor` bridge stub
9. a real `continuity_resume` flow
10. multi-domain recipe scaffolding for writing / expression, research, focus, social, health, and decisions
11. category-aware attention allocation instead of a single linear ranker

After that:
- richer recipes inside each domain
- `weekly_reflection`
- MCP enrichment
- richer multi-agent orchestration

## 23. Handoff Notes for the Next Agent

When continuing this work in a new chat or with a new agent:

- treat this document as the source engineering spec for Memograph V2 advisory work
- do not rewrite Memograph core
- do not modify FounderOS product logic directly
- use FounderOS only as a donor for runtime/orchestration patterns
- preserve Russian as the default user-facing advisory language
- preserve English/canonical naming for tools, services, models, and brands
- keep `ambient` as the default proactivity mode
- preserve the `Advisory Exchange` concept as the category-aware attention core
- optimize for quality of advice, not maximum privacy lockdown
- still keep access controlled and inspectable

## 24. Optional Prompt for a New Agent / New Chat

```text
Read this spec first:
/Users/martin/mymacagent/docs/specs/2026-04-04-memograph-v2-advisory-sidecar-spec.md

Context:
- Repo: /Users/martin/mymacagent
- FounderOS donor runtime: /Users/martin/FounderOS
- Do not modify FounderOS unless explicitly requested.
- Memograph must remain the memory engine.
- FounderOS concepts should be adapted only into a sidecar/runtime layer.
- Default product mode is ambient, not silent and not spammy.
- User-facing advisory language should default to Russian.
- Brand/product/tool names should remain in canonical English.

Your job:
- continue designing and implementing Memograph V2 advisory architecture from this spec
- prefer additive modules over rewrites
- preserve bounded proactivity and the Advisory Exchange attention-governor model
- optimize for continuity, insight, expression, and gentle direction
```
