-- Legacy shim — spells were removed in the mus migration (see
-- MUS_MIGRATION_PLAN.md, Phase 0). Delete once no caller remains.

local SpellRegistry = {}

SpellRegistry.displayNames = {}
SpellRegistry.descriptions = {}

function SpellRegistry.isSpell() return false end
function SpellRegistry.getAllSpellTypes() return {} end
function SpellRegistry.loadSprites() end

return SpellRegistry
