-- DeckManager – Persistent deck storage and runtime draw-pile management

local json          = require('lib.json')
local UnitRegistry  = require('src.unit_registry')
local SpellRegistry = require('src.spell_registry')

local DeckManager = {}

-- Returns array of every card type that can appear in a deck (units + spells).
local function getAllCardTypes()
    local out = {}
    for _, u in ipairs(UnitRegistry.getAllUnitTypes()) do table.insert(out, u) end
    for _, s in ipairs(SpellRegistry.getAllSpellTypes()) do table.insert(out, s) end
    return out
end

local SAVE_FILE = "decks.json"
local MAX_CARDS = 20
local NUM_SLOTS = 5

-- Persistent data (survives screen switches within one session)
DeckManager._data = nil

-- Transient per-game draw pile (reset each match via initDrawPile)
DeckManager._drawPile = {}

-- ── Helpers ────────────────────────────────────────────────────────────────

local function emptyDeck(i)
    local counts = {}
    for _, u in ipairs(getAllCardTypes()) do counts[u] = 0 end
    counts["boney"] = 1
    return { name = "Deck " .. i, counts = counts }
end

-- ── Persistence ───────────────────────────────────────────────────────────

function DeckManager.reset()
    DeckManager._data = { activeDeckIndex = nil, decks = {} }
    for i = 1, NUM_SLOTS do
        DeckManager._data.decks[i] = emptyDeck(i)
    end
end

function DeckManager.save()
    -- If logged in, sync to server
    if _G.PlayerData and _G.GameSocket then
        _G.GameSocket:send("sync_decks", {
            active_deck_index = DeckManager._data.activeDeckIndex,
            decks = DeckManager._data.decks
        })
        -- Keep PlayerData in sync so DeckManager.load() gets correct values on re-init
        _G.PlayerData.activeDeckIndex = DeckManager._data.activeDeckIndex
        _G.PlayerData.decks = DeckManager._data.decks
    end

    -- Always save locally as backup
    local ok, encoded = pcall(json.encode, DeckManager._data)
    if ok then
        love.filesystem.write(SAVE_FILE, encoded)
    end
end

function DeckManager.load()
    -- If logged in, load from server data
    if _G.PlayerData and _G.PlayerData.decks then
        DeckManager._data = {
            activeDeckIndex = _G.PlayerData.activeDeckIndex,
            decks = _G.PlayerData.decks
        }

        -- Ensure all unit type keys exist in each deck (forward-compat)
        for i = 1, NUM_SLOTS do
            if not DeckManager._data.decks[i] then
                DeckManager._data.decks[i] = emptyDeck(i)
            end
            for _, u in ipairs(getAllCardTypes()) do
                if not DeckManager._data.decks[i].counts[u] then
                    DeckManager._data.decks[i].counts[u] = 0
                end
            end
        end
        return
    end

    -- Otherwise, load from local file
    local content = love.filesystem.read(SAVE_FILE)
    if content then
        local ok, data = pcall(json.decode, content)
        if ok and data and data.decks and #data.decks == NUM_SLOTS then
            -- Ensure all unit type keys exist in each deck (forward-compat)
            for i = 1, NUM_SLOTS do
                for _, u in ipairs(getAllCardTypes()) do
                    if not data.decks[i].counts[u] then
                        data.decks[i].counts[u] = 0
                    end
                end
            end
            DeckManager._data = data
            return
        end
    end
    DeckManager.reset()
    DeckManager.save()
end

-- ── Deck queries ──────────────────────────────────────────────────────────

function DeckManager.getDeck(index)
    return DeckManager._data.decks[index]
end

function DeckManager.getActiveDeck()
    local idx = DeckManager._data.activeDeckIndex
    if not idx then return nil end
    return DeckManager._data.decks[idx]
end

function DeckManager.getTotalCount(deckIndex)
    local deck = DeckManager._data.decks[deckIndex]
    local total = 0
    for _, count in pairs(deck.counts) do
        total = total + count
    end
    return total
end

-- ── Deck editing ──────────────────────────────────────────────────────────

-- delta: +1 or -1. Returns true if count changed.
function DeckManager.adjustCount(deckIndex, unitType, delta)
    local deck    = DeckManager._data.decks[deckIndex]
    local current = deck.counts[unitType] or 0
    if delta > 0 and DeckManager.getTotalCount(deckIndex) >= MAX_CARDS then
        return false
    end
    local newCount = math.max(0, current + delta)
    -- Enforce unlock limits (skip in God Mode or offline/no unlock data)
    if delta > 0 and not _G.GodMode then
        local unlocks = _G.PlayerData and _G.PlayerData.unlocks
        if unlocks and unlocks.cards then
            local owned = unlocks.cards[unitType] or 0
            if owned <= 0 then return false end
            if newCount > owned then return false end
        end
    end
    -- Prevent lowering to 0 if it would leave the deck empty
    if newCount == 0 and DeckManager.getTotalCount(deckIndex) <= 1 then
        return false
    end
    if newCount == current then return false end
    deck.counts[unitType] = newCount
    DeckManager.save()
    return true
end

-- Zero out all unit counts in a deck slot and save.
function DeckManager.clearDeck(deckIndex)
    local deck = DeckManager._data.decks[deckIndex]
    for utype, _ in pairs(deck.counts) do
        deck.counts[utype] = 0
    end
    DeckManager.save()
end

-- Set deck at deckIndex as the active battle deck.
function DeckManager.setActive(deckIndex)
    DeckManager._data.activeDeckIndex = deckIndex
    DeckManager.save()
end

-- ── Draw pile (per-game, transient) ───────────────────────────────────────

-- Build and shuffle the draw pile from the active deck.
-- Returns true if a valid deck was loaded, false for fallback-to-random.
function DeckManager.initDrawPile()
    DeckManager._drawPile = {}
    if not DeckManager._data then DeckManager.reset() end
    local idx = DeckManager._data.activeDeckIndex
    if not idx then return false end
    local deck  = DeckManager._data.decks[idx]
    local total = DeckManager.getTotalCount(idx)
    if total == 0 then return false end

    -- Expand counts into flat array
    for unitType, count in pairs(deck.counts) do
        for _ = 1, count do
            table.insert(DeckManager._drawPile, unitType)
        end
    end

    -- Fisher-Yates shuffle
    local pile = DeckManager._drawPile
    for i = #pile, 2, -1 do
        local j = math.random(i)
        pile[i], pile[j] = pile[j], pile[i]
    end
    return true
end

-- Draw up to n cards from the top of the pile.
-- Returns array of unitType strings (length 0..n).
function DeckManager.drawCards(n)
    local drawn = {}
    for _ = 1, n do
        if #DeckManager._drawPile == 0 then break end
        table.insert(drawn, table.remove(DeckManager._drawPile))
    end
    return drawn
end

-- Return an array of unitType strings back to the pile (no reshuffle).
function DeckManager.returnCards(unitTypes)
    for _, u in ipairs(unitTypes) do
        table.insert(DeckManager._drawPile, u)
    end
end

-- Return currentHand to pile, reshuffle entire pile, draw n new cards.
-- Returns new drawn array.
function DeckManager.reshuffleAndDraw(currentHand, n)
    -- Shuffle only the pile (excludes current hand), then draw
    local pile = DeckManager._drawPile
    for i = #pile, 2, -1 do
        local j = math.random(i)
        pile[i], pile[j] = pile[j], pile[i]
    end
    local drawn = DeckManager.drawCards(n)
    -- Return old hand to pile for future draws
    DeckManager.returnCards(currentHand)
    return drawn
end

function DeckManager.pileSize()
    return #DeckManager._drawPile
end

return DeckManager
