-- Headless regression tests for shared/mus_engine.lua
-- Run from the repo root with plain lua (no Love2D):
--   lua tests/test_mus_engine.lua

package.path = package.path .. ";./?.lua"
local Engine = require("shared.mus_engine")
local I = Engine._internal

local failures = 0
local function check(cond, label)
    if cond then
        print("  OK   " .. label)
    else
        failures = failures + 1
        print("  FAIL " .. label)
    end
end

local CFG8 = { reyes8 = true }

local function C(rank, suit) return { rank = rank, suit = suit or "oros" } end

-- Suits only matter for deck identity, not comparisons; vary them so pairs
-- are legal card sets.
local function hand(r1, r2, r3, r4)
    return { C(r1, "oros"), C(r2, "copas"), C(r3, "espadas"), C(r4, "bastos") }
end

print("== strength / points (8 kings) ==")
check(I.strength(3, CFG8) == I.strength(12, CFG8), "3 counts as rey")
check(I.strength(2, CFG8) == I.strength(1, CFG8), "2 counts as as")
check(I.points(3, CFG8) == 10, "3 is worth 10 points")
check(I.points(2, CFG8) == 1, "2 is worth 1 point")
check(I.points(10, CFG8) == 10 and I.points(12, CFG8) == 10, "figures worth 10")
check(I.points(7, CFG8) == 7, "7 worth 7")

print("== grande / chica ==")
check(I.cmpGrande(hand(12, 12, 4, 5), hand(12, 11, 7, 7), CFG8) == 1, "two reyes beat rey-caballo")
check(I.cmpGrande(hand(3, 1, 4, 5), hand(12, 1, 4, 5), CFG8) == 0, "3 ties rey at grande (8 reyes)")
check(I.cmpChica(hand(1, 2, 4, 5), hand(1, 4, 4, 5), CFG8) == 1, "as-as beats as-4 at chica")
check(I.cmpChica(hand(12, 12, 12, 1), hand(12, 12, 12, 4), CFG8) == 1, "lowest card decides chica")

print("== pares ==")
check(I.paresOf(hand(1, 4, 5, 6), CFG8) == nil, "no pares")
check(I.paresOf(hand(12, 3, 4, 5), CFG8).class == 1, "rey+3 form a pair (8 reyes)")
check(I.paresOf(hand(7, 7, 7, 1), CFG8).class == 2, "three 7s are medias")
check(I.paresOf(hand(12, 12, 4, 4), CFG8).class == 3, "two pairs are duples")
check(I.paresOf(hand(6, 6, 6, 6), CFG8).class == 3, "four of a kind counts as duples")
check(I.cmpPares(hand(12, 12, 4, 4), hand(11, 11, 7, 7), CFG8) == 1, "duples reyes beat duples caballos")
check(I.cmpPares(hand(1, 1, 1, 5), hand(12, 12, 4, 5), CFG8) == 1, "medias beat par")
check(I.paresBonus(hand(12, 12, 4, 4), CFG8) == 3, "duples bonus 3")
check(I.paresBonus(hand(7, 7, 7, 1), CFG8) == 2, "medias bonus 2")
check(I.paresBonus(hand(12, 3, 4, 5), CFG8) == 1, "par bonus 1")

print("== juego / punto ==")
check(I.pointsOf(hand(12, 11, 10, 1), CFG8) == 31, "rey+caballo+sota+as = 31")
check(I.hasJuego(hand(12, 11, 10, 1), CFG8), "31 is juego")
check(not I.hasJuego(hand(12, 11, 7, 1), CFG8), "28 is not juego")
check(I.cmpJuego(hand(12, 11, 10, 1), hand(12, 12, 12, 12), CFG8) == 1, "31 beats 40")
check(I.cmpJuego(hand(12, 12, 11, 2), hand(12, 12, 12, 12), CFG8) == 1, "32 beats 40")
check(I.cmpJuego(hand(12, 12, 12, 12), hand(12, 12, 12, 7), CFG8) == 1, "40 beats 37")
check(I.cmpPunto(hand(12, 12, 7, 2), hand(12, 12, 6, 1), CFG8) == 1, "punto 29 beats 27")

-- ──────────────────────────────────────────────────────────────────────────────
-- Full-hand integration
-- ──────────────────────────────────────────────────────────────────────────────

local function findEvent(events, name)
    for _, e in ipairs(events) do
        if e.name == name then return e end
    end
end

local function rig(match, cards)
    -- Overwrite dealt hands with known cards (tests only).
    for seat = 1, 4 do match.hand.cards[seat] = cards[seat] end
end

print("== mus round: cut goes to grande ==")
do
    local m = Engine.newMatch({}, 7)
    Engine.startHand(m)
    local ok, ev = Engine.apply(m, 1, { type = "mus" })
    check(ok, "mano says mus")
    ok = Engine.apply(m, 2, { type = "no_mus" })
    check(ok and m.hand.stage == "grande", "no_mus cuts to grande")
    local wrong = select(1, Engine.apply(m, 4, { type = "paso" }))
    check(not wrong, "out-of-turn action rejected")
end

print("== mus round: all mus, discard, redraw ==")
do
    local m = Engine.newMatch({}, 11)
    Engine.startHand(m)
    for seat = 1, 4 do
        check(select(1, Engine.apply(m, ((m.manoSeat - 1 + seat - 1) % 4) + 1, { type = "mus" })), "mus " .. seat)
    end
    check(m.hand.stage == "discard", "into discard stage")
    for seat = 1, 4 do
        local ok = select(1, Engine.apply(m, seat, { type = "discard", indices = { 1, 2 } }))
        check(ok, "discard by seat " .. seat)
    end
    check(m.hand.stage == "mus", "back to mus after redraw")
    for seat = 1, 4 do
        check(#m.hand.cards[seat] == 4, "seat " .. seat .. " has 4 cards")
    end
end

print("== betting: envido rejected scores 1 immediately ==")
do
    local m = Engine.newMatch({}, 3)
    Engine.startHand(m)
    Engine.apply(m, m.manoSeat, { type = "no_mus" })            -- to grande
    local mano = m.manoSeat
    local ok = select(1, Engine.apply(m, mano, { type = "envido" }))
    check(ok, "mano bets 2 at grande")
    -- Both opposing players decline.
    local t = I.teamOf(mano)
    local ev
    ok, ev = Engine.apply(m, Engine.turnInfo(m).seats[1], { type = "no_quiero" })
    check(ok, "first responder declines")
    ok, ev = Engine.apply(m, Engine.turnInfo(m).seats[1], { type = "no_quiero" })
    check(ok, "second responder declines")
    check(m.scores[t] == 1, "bettor team scored 1 piedra (no querido)")
    check(m.hand.stage == "chica", "moved on to chica")
end

print("== betting: raise then quiero records accepted amount ==")
do
    local m = Engine.newMatch({}, 5)
    Engine.startHand(m)
    Engine.apply(m, m.manoSeat, { type = "no_mus" })
    local mano = m.manoSeat
    Engine.apply(m, mano, { type = "envido", amount = 2 })
    local responder = Engine.turnInfo(m).seats[1]
    Engine.apply(m, responder, { type = "envido", amount = 3 })  -- re-raise to 5
    local back = Engine.turnInfo(m).seats[1]
    check(I.teamOf(back) == I.teamOf(mano), "raise flips response to first team")
    Engine.apply(m, back, { type = "quiero" })
    check(m.hand.results.grande.kind == "accepted" and m.hand.results.grande.amount == 5,
        "grande accepted at 5")
    check(m.hand.stage == "chica", "moved on to chica")
end

print("== órdago accepted decides the game at showdown ==")
do
    local m = Engine.newMatch({}, 9)
    Engine.startHand(m)
    Engine.apply(m, m.manoSeat, { type = "no_mus" })
    -- Rig hands: seat 1 unbeatable at grande.
    rig(m, {
        [1] = hand(12, 12, 12, 12),
        [2] = hand(4, 5, 6, 7),
        [3] = hand(1, 4, 5, 6),
        [4] = hand(1, 2, 4, 5),
    })
    local mano = m.manoSeat
    Engine.apply(m, mano, { type = "ordago" })
    local responder = Engine.turnInfo(m).seats[1]
    local ok, ev = Engine.apply(m, responder, { type = "quiero" })
    check(ok, "órdago accepted")
    -- Play remaining phases with all paso until showdown resolves the órdago.
    while not m.winner and m.hand.betting do
        local seat = Engine.turnInfo(m).seats[1]
        Engine.apply(m, seat, { type = "paso" })
    end
    check(m.winner ~= nil, "game decided by órdago")
    check(m.winner == I.teamOf(1), "team of seat 1 wins (four reyes)")
end

print("== full hand en paso: scores flow and hand ends ==")
do
    local m = Engine.newMatch({}, 13)
    Engine.startHand(m)
    Engine.apply(m, m.manoSeat, { type = "no_mus" })
    local guard = 0
    while m.hand.stage ~= "showdown" and guard < 100 do
        local info = Engine.turnInfo(m)
        if not info then break end
        Engine.apply(m, info.seats[1], { type = "paso" })
        guard = guard + 1
    end
    check(m.hand.stage == "showdown", "hand reached showdown")
    local total = m.scores[1] + m.scores[2]
    check(total >= 2, "at least grande+chica piedras awarded (got " .. total .. ")")
end

print("== hidden information: viewFor never leaks other hands ==")
do
    local m = Engine.newMatch({}, 17)
    Engine.startHand(m)
    local v = Engine.viewFor(m, 2)
    check(v.my_cards == m.hand.cards[2], "own cards visible")
    check(v.all_cards == nil, "other hands hidden before showdown")
    Engine.apply(m, m.manoSeat, { type = "no_mus" })
    local guard = 0
    while m.hand.stage ~= "showdown" and guard < 100 do
        local info = Engine.turnInfo(m)
        if not info then break end
        Engine.apply(m, info.seats[1], { type = "paso" })
        guard = guard + 1
    end
    v = Engine.viewFor(m, 2)
    check(v.all_cards ~= nil, "all hands revealed at showdown")
end

print("== match to target: hands loop and mano rotates ==")
do
    local m = Engine.newMatch({ targetPiedras = 5 }, 21)
    local hands = 0
    while not m.winner and hands < 50 do
        Engine.startHand(m)
        hands = hands + 1
        local guard = 0
        while not m.winner and m.hand.stage ~= "showdown" and guard < 200 do
            local info = Engine.turnInfo(m)
            if not info then break end
            local seat = info.seats[1]
            if info.stage == "mus" then
                Engine.apply(m, seat, { type = "no_mus" })
            else
                Engine.apply(m, seat, { type = "paso" })
            end
            guard = guard + 1
        end
    end
    check(m.winner ~= nil, "match reached target in " .. hands .. " hands")
    check(m.handNo == hands, "hand counter consistent")
end

print("")
if failures > 0 then
    print(failures .. " TEST(S) FAILED")
    os.exit(1)
else
    print("ALL TESTS PASSED")
end
