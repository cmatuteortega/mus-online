# Mus Online

An online **mus** card game — 4 players, 2 teams of 2 — built with Love2D/Lua.

Grande, chica, pares, juego. Órdago.

## Status

Phase 0 of the migration is complete: the project was bootstrapped from
[AutoChest](https://github.com/cmatuteortega/auto-chest) (a 1v1 autobattler),
keeping its ENet networking, account system (device login + email backup),
matchmaking server, private rooms, and mobile-portrait UI shell — with all
autobattler gameplay removed. See `MUS_MIGRATION_PLAN.md` for the full roadmap
and `CLAUDE.md` for current project state.

## Run

```bash
love .            # client (localhost)
love server/      # local dev server (port 12346)
./play-online.sh  # client against the production server
```
