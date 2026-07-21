# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Mus Online is a 4-player (2 teams of 2) online mus card game built in Love2D/Lua. It was
bootstrapped from AutoChest (a 1v1 autobattler) by keeping its networking/auth/UI
infrastructure and removing all autobattler gameplay. **Read `MUS_MIGRATION_PLAN.md`
first** — it is the roadmap for this project and defines the phases, architecture, and
reuse decisions. Keep both files up to date as the game is built.

---

## Project Status (Phases 0-4 core complete — pending live playtesting)

Done:
- Phase 0: bootstrapped from AutoChest, autobattler gameplay deleted, renamed
  (identity `mus-online`, server `mus-server`, port **12346**, `MUS_*` env vars,
  `deploy/mus-server.service` at `/opt/mus-online`).
- Phase 2: `shared/mus_engine.lua` — authoritative pure-Lua rules engine
  (8-kings variant, mus/discard, Grande/Chica/Pares/Juego/Punto betting with
  envido/raises/órdago, showdown scoring, `viewFor` hidden-info filter).
  Tests: `lua tests/test_mus_engine.lua`.
- Phases 1+4 (server): 4-player matchmaking (trophy range expansion kept, teams
  balanced by trophies), `server/tables.lua` hosts one engine match per table
  (event dispatch with per-seat privacy, turn timeouts, ranked rewards,
  disconnect grace → snapshot reattach → bot takeover), `server/bot.lua`
  heuristic bots, private rooms gather 4 with host "start with bots".
  Tests: `lua tests/test_table_manager.lua` (full game with mock peers).
- Phase 3 (client): lobby handles 4-player `match_found` and private lobby fill;
  `src/screens/game.lua` is the mus table (hand rendering + discard selection,
  contextual betting buttons from server turn options, table-talk feed,
  showdown reveal, game-over overlay, snapshot reconnect);
  `src/card_renderer.lua` draws cards (sprite files or procedural fallback).
- **Sandbox mode**: the menu's SANDBOX button (inherited from AutoChest,
  battle panel) launches the game screen with `isSandbox = true` —
  `src/local_table.lua` runs the same shared engine + bot locally (you at
  seat 1 + 3 bots), no server needed. The bot lives in `shared/mus_bot.lua`
  so client and server share it.

**Card sprites**: not in any repo — copy the `sprites/` folder from your local
musatro project into `src/assets/cards/` (same naming: `1_oros.png` …
`13_bastos.png`, `back.png`). The game is fully playable without them via the
procedural renderer.

Still to do:
- Live playtest (client boot, 4 clients + bots end-to-end) — nothing here has
  run under real Love2D/ENet yet, only headless tests.
- Menu is now a single battle screen (no tabs): PLAY / SANDBOX / private-room
  toggle + a left-side ranking button that opens the leaderboard popup. The old
  Shop panel (daily chest, card trade) and swipe tabs were removed. The
  `deck_manager.lua` / `unit_registry.lua` / `spell_registry.lua` shims are no
  longer required by the menu and can be deleted once nothing else references them.
- Señas via the emote panel; deal/discard animations; card flip polish.
- Deploy to the VPS alongside AutoChest (new unit, port 12346).
- `title.png` / `title_shadow.png` — old AutoChest logo art, needs mus art.

---

## What This Game Will Be (see plan §4 for full rules model)

- Mus: Spanish 40-card deck, 4 players, partners sit across (seats 1,3 vs 2,4).
- Hand flow: deal 4 cards → mus/discard rounds → betting phases Grande → Chica →
  Pares → Juego (Punto) → showdown → scoring in piedras/amarracos (to 40).
- Betting: paso / envido / raise / órdago / quiero / no quiero.
- Variants configurable from day 1 (8 kings, 40 piedras…) in the engine config.
- **Server-authoritative**: the server shuffles, deals, and validates every intent;
  clients only ever see their own hand (`viewFor`). No shared-seed peer simulation —
  mus is a hidden-information game. Bots and mid-hand reconnection are server-side.

---

## How to Run

**Client (connects to the cloud server by default):**
```bash
love .                   # client → cloud server 75.119.142.247:12346 (DEFAULT)
./play-online.sh         # same, plus optional MUS_SERVER_IP/PORT overrides
```

**Local Development (localhost server):**
```bash
MUS_DEV=true love .      # client → localhost:12346 (opt-in dev mode)
love server/             # local dev server
```

Production is the default in `src/config.lua` — a plain `love .` hits the VPS.
Set `MUS_DEV=true` to point at a local `love server/`, or `MUS_SERVER_IP` /
`MUS_SERVER_PORT` to target a different box.

**Cloud Server:**
```bash
sudo systemctl status mus-server
sudo journalctl -u mus-server -f
```

Note: the same VPS also runs the original AutoChest server on port 12345 — the two
games coexist; never reuse its port, systemd unit, or `/opt/autochest` directory.

**Engine tests** (Phase 2+, plain lua, no Love2D):
```bash
lua tests/test_mus_engine.lua
```

---

## Project Structure

```
mus-online/
├── conf.lua             # Love2D config (540×960 window, identity "mus-online")
├── main.lua             # Entry point, font loading, screen manager setup
├── play-online.sh       # Launcher for production server
├── MUS_MIGRATION_PLAN.md# THE roadmap — phases, architecture, protocol
├── deploy/              # VPS deployment (mus-server.service, setup, backup)
├── server/              # Auth + matchmaking + (Phase 2+) authoritative mus engine
│   ├── main.lua         # ENet server: auth, matchmaking, private rooms — port 12346
│   ├── database.lua     # SQLite (bcrypt, session tokens, email backup, trophies)
│   └── conf.lua
├── lib/                 # classic, sock (ENet), json, screen_manager, suit, push, tween
└── src/
    ├── config.lua           # Server address config (dev/production)
    ├── constants.lua        # 540×960 canvas, scaling helpers
    ├── audio_manager.lua    # Music/SFX singleton with persistent settings
    ├── locale.lua           # i18n: English/Spanish string tables, persisted to
    │                        #   locale.json; `Locale.t(key, ...)`, live-switchable
    ├── socket_manager.lua   # Socket health check + async token reconnection
    ├── transition_manager.lua # Screen transitions (cloud curtain)
    ├── palette_shader.lua   # 8-color palette-snap shader (menu/lobby sprites)
    ├── unit_registry.lua    # LEGACY SHIM — empty, delete when menu is re-done
    ├── spell_registry.lua   # LEGACY SHIM — empty, delete when menu is re-done
    ├── deck_manager.lua     # LEGACY — delete when menu deck panels are replaced
    ├── assets/              # ui/, Chest/, emotes/, clouds/, particles/, backgrounds
    ├── audio/               # ost + sfx
    └── screens/
        ├── preload.lua      # Splash + asset preload (load steps empty for now)
        ├── loading.lua      # Auto-auth (session.dat token, 5s timeout)
        ├── name_entry.lua   # Account creation / device login / email backup
        ├── menu.lua         # Single battle screen: PLAY / SANDBOX / private-room
        │                    #   toggle + ranking button → leaderboard popup
        ├── lobby.lua        # Matchmaking lobby (still 1v1 — Phase 1 makes it 4p)
        └── game.lua         # PLACEHOLDER — real mus table in Phase 3
```

---

## What Carried Over From AutoChest (works today, don't rebuild)

**Language (English / Spanish)**: `src/locale.lua` holds both string tables and a
persisted choice (`locale.json`, default English). Every screen looks strings up
via `Locale.t(key, ...)` at draw time, so the EN/ES toggle in the menu's SETTINGS
overlay switches the whole UI live. `GameSettings.summary()` and the game-table
labels/feed route through it too. Keep the `en` and `es` key sets identical (a
missing key silently falls back to English).

**Auth flow**: `preload` → `loading` reads `session.dat`; token → `auto_login` /
`login_with_device`; `name_entry` handles registration, device login, and
email backup (`link_email` / `login_with_email`). Client stores `_G.PlayerData`
and `_G.GameSocket` globally.

**Matchmaking (currently still 1v1 — Phase 1 rewrites to 4-player)**: `queue_join`
with trophy range ±100 expanding +50/5s to ±500; `match_found` → lobby →
game screen handoff (socket passed, `lobby:close()` skips disconnect when matched).
Private rooms via `private_queue_join` + room key.

**Server messages kept as-is**: `login`/`register`/`auto_login`/`login_with_device`/
`login_with_email`/`link_email`, `login_success`/`login_failed`, `queue_join`/
`queue_leave`, `private_queue_join`, `reconnect_with_token`, trophy updates.

**Game-mode settings (implemented)**: players tweak rules before queuing via the
menu's "Reglas" modal (tap the summary pill above PLAY). Three knobs live in
`src/game_settings.lua` (persisted to `game_settings.json`): `reyes8`
(4 vs 8 kings), `emotes` (on/off), `bestOf` (1/3/5 sets to 40). **Base queue =
4 kings, no emotes, best of 3.** Settings ride along on `queue_join` /
`private_queue_join`; the server sanitizes them, matches only same-settings
players (settings key + trophy range), and passes them to the table. Best-of-N
is a table-level loop (each set is one engine match to 40; server tracks
`setsWon`, emits `set_result`, starts a fresh match until a team reaches the
majority). Emotes are gated server-side by the table's setting.

**Mus protocol (implemented)**:
- Client → server: `mus_action {action={type=...}}` (types: `mus`, `no_mus`,
  `discard {indices}`, `paso`, `envido {amount}`, `ordago`, `quiero`,
  `no_quiero`), `table_emote {emote}`, `leave_table`, `private_start_bots`.
  `queue_join` / `private_queue_join` now also carry `settings {reyes8, emotes, bestOf}`.
- Server → client: `match_found {seat, team, ranked, players[4], settings}`, then
  `game_event {name, data}` wrapping engine events: `set_result`
  `{set_winner, sets_won, sets_needed, best_of, series_over}` (between/after sets),
  `hand_start`, `your_cards`
  (private), `turn`, `stage`, `mus_said`, `discard_chosen`, `redrew`,
  `declarations`, `bet_action`, `phase_result`, `score`, `showdown`,
  `hand_end`, `game_end`, `rewards`, `state_snapshot`, `seat_replaced`,
  `player_disconnected`, `player_reconnected`, `emote`, `timed_out`,
  `action_rejected`. Plus `private_lobby_update {players, count, is_host}`.

**Client plumbing**: `SocketManager.isHealthy()` / `.reconnect(onSuccess, onFailure)`;
menu pumps `_G.GameSocket:update()` every frame (ENet keepalive); `AudioManager`
singleton; SUIT buttons + custom button styles in menu; emote panel (will carry
señas); unified tap-vs-drag input pattern (press/move >10px/release).

**Coordinate/UI system**: 540×960 portrait canvas via `push`, `Constants.GAME_WIDTH/
HEIGHT`, fonts as `Fonts.large/medium/small/tiny` globals.

---

## Rules for New Code

- The mus rules engine goes in `shared/mus_engine.lua` as **pure Lua** (no Love2D, no
  sockets) with headless tests in `tests/` runnable by plain `lua`. Server requires it;
  clients never compute hidden state.
- Server is authoritative: clients send intents, server validates and broadcasts
  `viewFor(seat)` filtered state. Never send one player's cards to another before
  showdown.
- Keep variant knobs (8 kings, 40 piedras, señas policy, turn timer) in one config
  table in the engine.
- After changes to `server/` or the protocol: deploy per `deploy/YOUR_DEPLOYMENT_STEPS.md`
  (rsync to `/opt/mus-online`, `sudo systemctl restart mus-server`).
