# NotchAgent — build & architecture notes for Claude

A native macOS notch/menu-bar control surface for AI coding agents running under
[herdr](https://herdr.dev), viewed and driven from Ghostty. herdr is the state
authority; this app is a **socket client + notch UI** that keeps transport and
state reconciliation in `HerdrClient`, while the app
remains a thin, user-driven control surface. herdr continues to own PTYs and
agent lifecycle state; NotchAgent reads snapshots/events and sends explicit actions.

## Build & test

```bash
swift build                      # build all targets
swift build --target HerdrClient # build just the core library (fast lane)
swift test                       # run the full swift-testing suite (needs ALL targets to compile)
swift run notchctl list          # dogfood the core against live herdr
swift run notchctl sessions      # list herdr sessions + their real socket paths
swift run notchctl sessions --remote workbox   # same, over ssh
swift run NotchApp               # launch the notch UI (accessory app; no dock icon)
```

- **Toolchain:** Swift 6.2, macOS 14+. No third-party dependencies (Foundation/AppKit/SwiftUI + POSIX sockets only).
- `swift test` compiles *every* target first — a broken UI target blocks core tests. Use `swift build --target HerdrClient`/`--target HerdrClientTests` to verify the core in isolation.
- Tests use the **swift-testing** framework (`import Testing`, `@Test`/`@Suite`/`#expect`), NOT XCTest. `xcrun xctest` will report "0 tests" — always use `swift test`.

## Targets

| Target | Kind | Contents |
| --- | --- | --- |
| `HerdrClient` | library | Socket client, Codable models, state store, prompt classifier, action layer, session discovery + SSH tunnelling. The whole M1 core. |
| `notchctl` | executable | Headless CLI harness that dogfoods the core (`list`/`sessions`/`watch`/`read`/`resolve`/`reply`/`jump`). |
| `NotchApp` | executable | The notch `NSPanel` UI (accessory app). Owns the `SessionRegistry`/`SessionRuntime`s that bind to `HerdrClient`. |

## Architecture (data flow)

```
herdr server(s)  — local default, local named sessions, remote hosts over SSH
    │ newline-delimited JSON over a Unix socket
    │ local:  ~/.config/herdr/herdr.sock  (named: ~/.config/herdr/sessions/<n>/herdr.sock)
    │ remote: SSHTunnel forwards the REMOTE socket to a per-user temp socket,
    │         so everything below is identical for local and remote
    │
HerdrClient.request()  → connect-per-call (herdr closes socket after one req/resp)
HerdrClient.events()   → ONE long-lived connection, reconnects with backoff
    │
    ▼
SessionRegistry (@MainActor) → one SessionRuntime per herdr server, keyed by session id
    │                           + one SSHTunnel per remote session
    ▼
SessionRuntime  (transport + store + coordinator for ONE server; reports
    │            transitions upward, never touches presentation)
    ▼
StateStore (@MainActor @Observable)  → hydrate(snapshot) then apply(event)
    │
    ├─→ InteractionCoordinator (pane-keyed cache, drafts, refresh + response phases)
    │     ├─ ScreenInteractionProvider → ScreenAdapterRegistry
    │     │     ├─ ClaudeScreenAdapter
    │     │     ├─ CodexScreenAdapter
    │     │     └─ GenericScreenAdapter (safe raw fallback)
    │     └─ InteractionResponder (fresh-read safety boundary + pane-scoped settle)
    ├─→ InteractionDisplayModel + InteractionResponsePlanner (pure; no transport)
    ├─→ PromptClassifier  (temporary ClassifiedPrompt compatibility facade)
    └─→ Actions           (approve/deny/answer/reply/jump → send_keys/send_text/focus + Ghostty raise)
    │
NotchApp UI (NSPanel + SwiftUI)  /  notchctl CLI
```

## Protocol facts that shaped the code (verified live against herdr 0.7.4 / protocol 16)

- **One request per connection.** The server closes the socket after a single
  request/response. `HerdrClient.request` connects per call. Only `events()`
  keeps a connection open. Do NOT build a persistent multiplexed request channel.
- **`pane.agent_status_changed` is per-pane** — its subscription requires a
  `pane_id`. There is no global status firehose. `StateStore.currentSubscriptions()`
  emits one entry per pane + the global `pane.agent_detected`/`created`/`exited`,
  and is re-derived on every (re)connect. Do *not* add `pane.output_matched` to
  that set — herdr requires it per-pane WITH a `source` field, and one bad entry
  makes herdr reject the *entire* subscribe batch (`invalid_request`) so no events flow.
- **Status is driven by POLLING, not events — because herdr's events are
  themselves polls.** Read the herdr source before "optimising" this away:
  `src/api/server.rs` runs each subscribe connection as
  `loop { poll every subscription; sleep(100ms) }` (`CONNECTION_POLL_INTERVAL`), and
  `ActiveAgentStatusChangedSubscription::poll_result` in `src/api/subscriptions.rs`
  reads the event hub and then **falls back to `pane_get(pane_id)`**, diffing the
  status itself. So a per-pane status subscription is not push — it is herdr
  re-reading that one pane ten times a second on our behalf. One `session.snapshot`
  covers every pane in a session in a single round-trip, which is strictly cheaper
  on both sides. `SessionRuntime` therefore polls the snapshot and calls
  `StateStore.reconcileTransitions(_:)` (the primary status path); the event stream is
  only an accelerator + new-pane detector.
  (Historical note: this used to be justified by `pane_agent_status_changed` being
  "sparse/absent". That is no longer true as of 0.7.5 — the server-side `pane_get`
  backstop is exactly what makes the events reliable. The cost argument is the real
  reason, and it still holds.)
  Consequently `StateStore.currentSubscriptions(includePerPaneStatus:)` drops the
  per-pane entries unless a session owns focused detail: the global
  `pane.created`/`exited`/`agent_detected` subscriptions resolve to
  `ActiveSubscription::Event`, a pure event-hub read that costs herdr nothing extra.
  Expanded overview still gives every visible session the fast snapshot cadence;
  visibility and selected-detail subscription cost are deliberately separate.
  `SessionRuntime` restarts only its event stream when selected detail changes;
  polling, interaction state, and drafts stay intact.
  If you ever see the UI "frozen," verify with `notchctl list` (pure snapshot path).
- **A pane id is only unique within one server.** Every herdr names its first pane
  `w1:p1`, so once more than one session is tracked, anything that identifies a pane
  across sessions must use `AgentRef {sessionID, paneID}` — selections, SwiftUI row
  identity (`InteractionAttentionDisplayModel.id`), and action routing all do.
  `StateStore` and `InteractionCoordinator` stay deliberately pane-keyed and
  single-server; aggregation happens above them in `NotchViewModel`.
- **Sessions are enumerated by the CLI, not the socket API.** There is no
  `session.list` method — `herdr session list --json` is the only authority, and it
  is the only way to learn a session's real socket path. Note the default session's
  socket is `~/.config/herdr/herdr.sock`, **not** under `sessions/`; deriving a path
  from the session name alone is wrong for it (`SocketPath.forSession` is a fallback
  for when the CLI is missing). For a remote host the same command over ssh is what
  yields the absolute remote socket path, which `ssh -L` needs because it does not
  tilde-expand the remote side.
- **Remote support is an SSH socket forward, nothing more.** herdr exposes no remote
  API; `herdr --remote` is a terminal UI attach whose server stays on the far host.
  `SSHTunnel` runs `ssh -N -L <local>:<remote> <target>` and everything downstream
  connects to an ordinary local socket. `BatchMode=yes` is deliberate — a GUI app
  must fail fast with an explainable error rather than block on a passphrase prompt
  it cannot answer. A local listener existing does not prove the lazy remote
  stream-local channel can open; `SSHTunnel` requires a bounded herdr `ping` through
  the forward before publishing `.up`. Report a dead tunnel as a tunnel problem,
  never as "herdr isn't running": that sends the user looking on the wrong machine.
  A tunnel explicitly disables multiplexing and persistence: it must remain the
  dedicated foreground process `SSHTunnel` supervises, rather than exit as a mux
  client or detach as a persistent master. Discovery is short-lived and uses
  `ControlMaster=no` with a per-user control path, so it may reuse some separately
  managed master but never leaves one behind. Local sessions are rediscovered every
  10s, while remote listings run every 60s and on configuration changes.
- **Interactions are pane-scoped.** `InteractionCoordinator` keeps blocked
  interactions, drafts, errors, read revisions, and response/settle phases keyed
  by pane ID. A busy pane never suppresses another pane's refresh. Selected panes
  refresh promptly; non-selected panes use revision changes plus a fourth-poll
  fallback when revision evidence is missing or explicitly untrusted.
- **herdr replays `pane_created` for long-closed panes on every subscribe.** An
  unfamiliar `pane_id` in an event does not mean a new pane exists — confirm against
  a fresh snapshot before resubscribing, or it thrashes.
- **`pane_created`/`pane_focused` nest the id at `data.pane.pane_id`**;
  `pane_agent_status_changed` uses `data.pane_id`. `EventEnvelope.paneID` checks both.
- **Envelopes are nested by result type:** `session.snapshot`→`result.snapshot...`,
  `pane.read`→`result.read.text`, `pane.focus`/`pane.get`→`result.pane`. Events
  arrive as `{event:"<snake_name>", data:{…}}`. Models decode the nested shapes.
- **Snapshot may repeat panes** — `Snapshot.uniquePanes` dedups by `pane_id`.
- **`done` is rollup-only.** `PaneAgentState` (per-pane authored) has no `done`;
  the store *derives* done (a working-idle pane the user hasn't viewed). See
  `StateStore.derivedStatus`.
- **Raw keys only.** `send_keys`/`send_input` reject `prefix+` chords and invalid
  keys before writing; `Actions` surfaces that as `ActionError.keysRejected` and
  never retries blindly. **Never auto-answer** — every action is user-initiated.

## Conventions

- **Fixtures are the test corpus.** Real captures live canonically in
  `Tests/HerdrClientTests/Fixtures/` and are bundled via `.copy` (which preserves
  the directory, so resolve with `Bundle.module.resourceURL`, not `forResource:`).
  Never hand-write a "live" prompt fixture; capture from a real agent with
  `notchctl capture` and keep its provenance metadata beside the fixture.
- **Decode-tolerant models.** Unknown JSON fields are ignored; unknown enum values
  map to `.unknown` rather than throwing. A decode failure on unknown input is a bug.
- Swift 6 strict concurrency: UI, `StateStore`, and `InteractionCoordinator` are
  `@MainActor`. A CLI/loop that touches them should live inside one `@MainActor`
  container (see `notchctl`).
