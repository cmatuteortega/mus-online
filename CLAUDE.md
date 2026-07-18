# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Mus Online is a 4-player (2 teams of 2) online mus card game built in Love2D/Lua. It was
bootstrapped from AutoChest (a 1v1 autobattler) by keeping its networking/auth/UI
infrastructure and removing all autobattler gameplay. **Read `MUS_MIGRATION_PLAN.md`
first** — it is the roadmap for this project and defines the phases, architecture, and
reuse decisions. Keep both files up to date as the game is built.

---

## Project Status (Phase 0 complete)

Done:
- Repo bootstrapped from AutoChest; autobattler gameplay deleted (units, grid,
  pathfinding, battle sim, deck manager mechanics, tutorial, old game screen, spells).
- Renamed: window/save identity `mus-online`, server identity `mus-server`,
  port **12346**, env vars `MUS_PRODUCTION` / `MUS_SERVER_IP` / `MUS_SERVER_PORT`,
  systemd unit `deploy/mus-server.service` (`/opt/mus-online`).
- Boot path intact end-to-end: preload → loading (auto-auth) → name_entry → menu →
  lobby → placeholder game screen (1v1 matchmaking still — becomes 4-player in Phase 1).

Temporary scaffolding (delete when their callers are replaced):
- `src/unit_registry.lua`, `src/spell_registry.lua` — empty-registry shims so
  menu/lobby/preload boot with empty Collection/Deck panels (replaced in Phases 3/5).
- `src/deck_manager.lua` — legacy deck storage kept only because menu references it.
- `src/screens/game.lua` — placeholder screen; real mus table arrives in Phase 3.
- `title.png` / `title_shadow.png` — old AutoChest logo art, needs mus art.

Next: **Phase 1 — 4-player rooms** (see plan §6): 4-way matchmaking, `tables`
structure with seats/teams, `match_found` with 4 players, lobby showing 4 slots,
private rooms gathering 4, bot seat replacement on disconnect.

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

**Local Development (localhost server):**
```bash
love .                   # client (connects to localhost:12346)
love server/             # local dev server
```

**Production (cloud server at 75.119.142.247:12346):**
```bash
./play-online.sh         # client (sets MUS_PRODUCTION=true)
```

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
        ├── menu.lua         # 5-panel swipe UI (Collection/Decks panels are empty
        │                    #   shells — replaced with mus content in Phase 5)
        ├── lobby.lua        # Matchmaking lobby (still 1v1 — Phase 1 makes it 4p)
        └── game.lua         # PLACEHOLDER — real mus table in Phase 3
```

---

## What Carried Over From AutoChest (works today, don't rebuild)

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
Game-flow messages will be replaced by the mus protocol (plan §5).

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
