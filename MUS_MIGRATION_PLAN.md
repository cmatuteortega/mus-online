# Mus Migration Plan — from AutoChest (1v1 autobattler) to a 4-player 2v2 Mus card game

This document is the plan for building an online **Mus** game (4 players, 2 teams of 2,
betting rounds: Grande / Chica / Pares / Juego) reusing the infrastructure already built
for AutoChest: ENet networking, auth server (device login + email backup), matchmaking,
private games, bots, card UI/animations, screen system, audio, and button styles.

---

## 1. Decision: copy this repo, or start from scratch?

**Recommendation: copy the repo and strip it ("copy-and-demolish"), do NOT start from scratch.**

Reasoning, based on what's actually in the codebase:

| Layer | Lines (approx) | Verdict |
|---|---|---|
| `server/main.lua` (auth, sessions, device login, email link, matchmaking, private queue, relay) | ~920 | **~80% reusable** — only matchmaking pairing and relay change |
| `server/database.lua` (SQLite, bcrypt, tokens, email backup) | ~950 | **~95% reusable** — swap decks table for mus stats |
| `lib/` (sock/ENet, classic, json, screen_manager, SUIT) | ~2500 | **100% reusable** |
| `src/screens/loading,login,name_entry,preload` | ~1100 | **~95% reusable** — the whole auth funnel just works |
| `src/screens/menu.lua` (5-panel swipe UI, button styles, settings) | ~3900 | **~70% reusable** — replace Collection/Decks panels with mus content |
| `src/screens/lobby.lua` (queue, spinner, match_found handling) | ~700 | **~60% reusable** — adapt to 4-player rooms |
| `src/socket_manager.lua`, `audio_manager.lua`, `transition_manager.lua`, `config.lua`, `constants.lua` | ~600 | **100% reusable** |
| `src/card.lua` (draggable card, draw animation) | ~270 | **~80% reusable** — reskin for Spanish deck |
| `src/screens/game.lua`, `grid.lua`, `pathfinding.lua`, `base_unit*.lua`, `src/units/`, `src/spells/`, `tutorial_manager.lua`, determinism tests | ~8000+ | **Delete** — this is the autobattler |
| `deploy/` (systemd service, VPS setup, backup scripts) | — | **~90% reusable** — rename service |

Roughly **half the project by line count — and nearly all of the annoying-to-rebuild half
(auth, reconnection, email backup, deployment, screen/UI plumbing)** — carries over.
Starting from scratch means re-writing and re-debugging exactly the parts that took the
longest and have the least to do with gameplay. The gameplay you *are* replacing
(units, grid, battle sim) deletes cleanly because it's well isolated in `src/units/`,
`grid.lua`, `pathfinding.lua`, and the `battle` states of `game.lua`.

**How to copy:** create a fresh repo (e.g. `mus-online`) from a copy of this one, delete
history-irrelevant assets, and do the strip in the first commit so the new repo never
carries autobattler baggage. Do not develop the mus game inside the AutoChest repo —
AutoChest stays live on the VPS and the two servers will run side by side (different
port, different systemd unit, different DB file).

---

## 2. The one real architectural change: server-authoritative game logic

This is the most important section of the plan.

AutoChest uses **deterministic peer simulation + dumb relay**: the server forwards
messages and both clients simulate the battle identically from a shared seed. That model
is *wrong* for mus and must not be ported:

- Mus is a **hidden-information** game. If a peer deals the cards (or a seed is shared),
  every client can compute everyone's hand → trivial cheating.
- Mus is **turn-based** with a strict betting order. The server must validate whose turn
  it is and whether a bet (envido, órdago, paso, quiero) is legal.

So the new server is **authoritative**:

- Server shuffles and deals. Each client receives **only its own 4 cards**.
- Clients send *intents* (`mus`, `no_mus`, `discard {indices}`, `bet {phase, amount}`,
  `paso`, `quiero`, `no_quiero`, `ordago`); the server validates, applies, and broadcasts
  the resulting public state.
- Opponents' cards are revealed only at showdown, by the server.
- This also makes **bots trivial**: a bot is just a server-side seat that produces
  intents. No client needed, works in matchmaking fill and private games alike.
- And it makes **mid-hand reconnection** possible: the server owns full state, so a
  reconnecting client (existing `SocketManager.reconnect` + token flow) just receives a
  `state_snapshot`.

The good news: all the *transport* (ENet channels, connKey/session mapping, token
reconnect, keepalive) is already built and keeps working unchanged. Only the
`"relay"` handler grows into a real game-state machine.

---

## 3. Reuse map (keep / adapt / delete)

### Keep as-is
- `lib/` — everything (sock.lua, classic, json, screen, screen_manager, suit)
- `src/config.lua`, `src/constants.lua` (resolution/scaling; drop grid constants)
- `src/audio_manager.lua`, `src/socket_manager.lua`, `src/transition_manager.lua`
- `src/screens/loading.lua`, `login.lua`, `name_entry.lua`, `preload.lua` — full auth
  funnel: device login, session token in `session.dat`, email link/backup, 5s timeout
- `server/database.lua` — auth, bcrypt, sessions, email backup, trophies
- `deploy/` — server-setup, systemd unit (renamed), backup-db.sh
- Screen-bound detection, button styles, emote panel, fonts — all in menu/game UI code

### Adapt
- **`server/main.lua`**
  - `queue`/`findMatch`/`processMatchmaking`: match **4** players instead of 2 (same
    trophy-range-expansion logic). Assign seats 1–4; teams = seats {1,3} vs {2,4}
    (partners sit across, mus-style). `match_found` gains `seat`, `team`, and all 4
    player infos.
  - `rooms`: replace pairwise `partnerKey` with a **table object**:
    `tables[tableId] = {seats = {ck1..ck4}, state = <mus state machine>, ...}` and
    `connKey → tableId` index. Disconnect handling notifies 3 peers, seats a bot,
    or pauses for reconnect.
  - `privateQueue` (room-key private games): same key mechanism, wait for 4 (or fewer +
    "fill with bots" / "start with bots" option for the host).
  - `relay` handler → **mus rules engine** (see Phase 2). Keep a thin relay only for
    chat/emotes/señas.
  - `match_result`/trophies: team-based — both winners +20, both losers −15 (already a
    server-side DB update; just apply to 2 IDs each).
- **`src/screens/lobby.lua`** — show 4 slots filling up instead of 1 opponent; add
  "play with bots" button; keep spinner, cancel, socket-handoff logic.
- **`src/screens/menu.lua`** — keep panel-swipe shell, settings, shop/ranking scaffolding;
  replace Collection/Decks panels (no deck building in mus) with e.g. Stats / Rules /
  Card-skin cosmetics.
- **`src/card.lua`** — keep draw/hover/animation code; new sprites (Spanish 40-card
  deck), remove unit-cost logic; add flip animation (back → face) for dealing.
- **`server/database.lua` schema** — drop `decks` sync; add per-player mus stats
  (hands played, órdagos won, etc.). Keep trophies column for ranked.

### Delete
- `src/units/`, `src/spells/`, `spell_registry.lua`, `unit_registry.lua`
- `src/grid.lua`, `src/pathfinding.lua`, `base_unit.lua`, `base_unit_ranged.lua`
- `src/tooltip.lua` (unit tooltip), `src/explosion_anim.lua`
- `src/deck_manager.lua` (deck building doesn't exist in mus)
- `src/tutorial_manager.lua` (rewrite later for mus; the polling-overlay *pattern* is
  worth re-reading when you do)
- `src/screens/game.lua` (rewrite; steal input handling + emote panel + state-text UI)
- `tests/test_battle_determinism.lua`, `tests/balance_sim.lua`
- Unit sprite folders in `src/assets/`

---

## 4. Mus game model (what we're building)

Rules baseline (make variants configurable from day 1):

- **Deck**: Spanish 40 cards (no 8/9). Default variant: **8 kings** (3s count as kings,
  2s as aces) — config flag `reyes8 = true`.
- **Flow per hand**: deal 4 cards each → **mus rounds** (all 4 agree "mus" → each
  discards 1–4 and redraws, repeat until someone cuts with "no hay mus") → betting
  phases in order: **Grande → Chica → Pares → Juego** (Punto if nobody has Juego) →
  showdown → scoring.
- **Betting** per phase: paso / envido (2) / raise (+N) / órdago (all-in) / quiero /
  no quiero. Deferred phases (nobody quiso) resolve at showdown.
- **Pares/Juego declarations**: each player declares "sí/no" in turn before betting
  those phases; phase is skipped if one team has nothing.
- **Scoring**: piedras up to 40 (config: 30), amarracos as UI grouping of 5. Match =
  best of N vacas (config).
- **Señas**: partner signaling via the existing **emote panel** — preset señas
  (ceja, morros, lengua…) sent as emotes. Config flag to allow/forbid; when allowed
  they're visible to everyone who's "looking" (simplest online adaptation: visible to
  all — classic online-mus compromise; revisit later).
- **Turn order**: mano rotates each hand; speaking order from mano.

### The rules engine is a pure module

`shared/mus_engine.lua` — plain Lua, no Love2D, no sockets:

```lua
local state = MusEngine.newHand(seed, config, manoSeat)
local ok, err, events = MusEngine.apply(state, seat, action)  -- validate + mutate
local view = MusEngine.viewFor(state, seat)                    -- hidden-info filter
```

- Runs **on the server** (authoritative) and is unit-testable headless with plain
  `lua` (same pattern as the old determinism test):
  `tests/test_mus_engine.lua` covers hand rankings (Grande/Chica orderings, pares
  types: pares/medias/duples, juego values 31/32/40…), betting legality, mus-discard
  redraw, órdago resolution, and full scripted hands.
- `viewFor(seat)` is the *only* thing serialized to clients — it structurally cannot
  leak other hands.

### Client is a renderer + intent sender

`src/screens/game.lua` (new): renders table state, animates deals/discards/bets, shows
whose turn, sends intents. No game logic beyond input legality hints (grey out illegal
buttons using the same `viewFor` data).

Table layout on the 540×960 portrait canvas:
- Your hand bottom (fanned, tap-to-select for discards — reuse card drag/tap detection
  from AutoChest's unified `handlePress/Move/Release`).
- Partner top, opponents left/right (card backs + name + declared sí/no chips).
- Center: pot/bet indicator, phase banner (reuse the state-text top-center pattern),
  amarracos/piedras score for both teams.
- Betting buttons: SUIT buttons with existing styles (Paso / Envido / Más / Órdago /
  Quiero / No quiero — context-sensitive set).

---

## 5. Network protocol (new messages)

Client → server (intents):
```
mus | no_mus | discard {indices} | declare {phase, has}
bet {phase, kind = paso|envido|raise|ordago, amount} | respond {quiero|no_quiero|raise, amount}
sena {id}   -- emote/seña, thin-relayed
```

Server → clients:
```
match_found {table_id, seat, team, players[4]}
hand_start {mano_seat, your_cards[4], hand_no}
mus_result {cut_by | all_mus, redraw_counts[4]}   -- + private: your new cards
phase_start {phase, speaking_order}
action_applied {seat, action, ...}                 -- public echo of every accepted intent
declarations {phase, per_seat_bool}
showdown {phase_results, revealed_hands, piedras_delta}
score_update {team_scores, amarracos}
hand_end / game_end {winner_team, trophy_delta}
state_snapshot {viewFor(seat)}                     -- reconnect
seat_replaced {seat, by_bot} / player_reconnected {seat}
error {reason}
```

Keep the existing envelope (`encode(event, data)` over sock.lua) and the existing
auth/queue/private/email messages untouched.

---

## 6. Phased plan

### Phase 0 — Fork & strip (½ day)
1. Copy repo → new repo `mus-online`; keep git init fresh.
2. Delete everything in the **Delete** list; rename service/config (`mus-server`,
   new port e.g. 12346, new `players.db` path).
3. Smoke test: client boots → auth funnel → menu → lobby joins queue (server pairs
   nobody yet). **The app should run end-to-end minus gameplay before any mus code.**

### Phase 1 — 4-player rooms (1–2 days)
4. Server: 4-way matchmaking, `tables` structure, seat/team assignment, `match_found`
   with 4 players; lobby screen shows 4 slots.
5. Private games: room key gathers 4; host "start with bots" button.
6. Disconnect → notify table, mark seat pending, allow token reconnect (snapshot comes
   in Phase 3); after timeout, bot takes the seat.

### Phase 2 — Rules engine, headless (2–4 days)
7. `shared/mus_engine.lua` + `tests/test_mus_engine.lua` (plain lua, CI-friendly).
   Complete hand lifecycle, all four phases, scoring, órdago, variants config.
   **Do this before any UI** — it's the highest-risk correctness code and it's fully
   testable without networking.
8. Wire engine into server: intents in, `viewFor` out, per-table state machine with
   turn timeouts (auto-paso on timeout, like the setup-timer pattern).

### Phase 3 — Game screen (3–5 days)
9. New `game.lua`: table layout, hand rendering, deal/flip/discard animations (reuse
   `card.lua` + transition manager), betting buttons, declarations, phase banners,
   score/amarracos UI, showdown reveal, hand-end / game-end flow.
10. Reconnect: apply `state_snapshot`; spectate-until-next-action.
11. Señas via emote panel; chat presets.

### Phase 4 — Bots (1–2 days)
12. Server-side bot: rule-based (hand-strength heuristics per phase, mus-discard
    logic, occasional órdago). Used for: queue fill after N seconds (optional),
    private-game fill, disconnect replacement, and a practice mode vs 3 bots
    (replaces the tutorial for launch).

### Phase 5 — Meta & ship (2–3 days)
13. Menu panels: stats, rules/help, cosmetics stub; ranked trophies (team ±20/−15),
    ranking panel reuse.
14. Deploy on the VPS next to AutoChest: new systemd unit, new port, `deploy/` scripts
    updated; both games share the machine.
15. Playtest with 4 real clients + bots; then iterate on señas policy and variants.

---

## 7. Risks / open decisions

- **Señas policy online** (visible-to-all vs disabled vs "glance" mechanic) — ship
  simplest (config-off or visible-to-all), decide with playtesting.
- **Ranked 2v2 rating**: random-partner trophy math is fine at ±20/−15 to start;
  premade-team queue can come later.
- **Turn timers**: mus needs snappy auto-paso timeouts (~15s) or online games drag.
- **Regional variants** (30 vs 40 piedras, 4 vs 8 kings): keep in one `config` table in
  the engine from the first commit — retrofitting variants is painful.
- **Server stays Love2D?** The current server runs under `love server/`. It works, keep
  it — the engine module being pure Lua means you could later move it to plain
  luajit + lua-enet without touching game logic.

---

## 8. Appendix — prompt for a fresh Claude Code session

If you prefer to kick off the new repo in a separate session, copy the AutoChest repo
first (Phase 0 steps 1–2 can be done by the agent), then paste:

```
This repo is a copy of AutoChest, a Love2D 1v1 online autobattler. I'm turning it into
"Mus Online": the Spanish card game mus — 4 players, 2 teams of 2 (partners across),
betting phases Grande/Chica/Pares/Juego, mus/discard rounds, órdago, señas, scoring in
piedras/amarracos to 40. Read CLAUDE.md and MUS_MIGRATION_PLAN.md first and follow the
plan's phases in order.

Key constraints:
- KEEP: auth server (device login, email backup, session tokens, SQLite), ENet/sock
  networking, SocketManager reconnection, screen manager, auth screens, menu shell,
  audio manager, card UI + animations, SUIT button styles, deploy scripts.
- DELETE: all autobattler gameplay (units, grid, pathfinding, battle sim, deck manager,
  tutorial, old game screen).
- REWRITE the server from dumb relay to AUTHORITATIVE: the server shuffles/deals and
  sends each client only its own cards; clients send validated intents. No shared-seed
  peer simulation — mus is a hidden-information game.
- Matchmaking becomes 4-player tables (trophy range expansion logic stays); private
  games via room key gather 4; server-side bots fill seats and replace disconnects.
- Rules engine is a pure Lua module (shared/mus_engine.lua) with headless tests
  (plain lua, like the old determinism test), variants configurable (8 kings,
  40 piedras).
- Client game screen is a renderer + intent sender on the 540×960 portrait canvas:
  own hand bottom, partner top, opponents sides, betting buttons via SUIT.

Start with Phase 0 (strip + rename + boot smoke test), then Phase 1 (4-player rooms),
then Phase 2 (engine + tests) before any game UI. Update CLAUDE.md as you go so it
describes the mus game, not the autobattler.
```

---

## 9. Bottom line

**Copy and strip.** The expensive, boring, already-debugged 50% (auth + email backup,
networking + reconnection, matchmaking scaffold, private rooms, screens, card
animations, audio, deployment) transfers nearly untouched; the autobattler-specific
50% deletes cleanly along module boundaries. The single deliberate rewrite is
promoting the server from relay to authoritative dealer/referee — which mus's hidden
information makes mandatory anyway, and which buys you bots and mid-hand reconnection
for free.
