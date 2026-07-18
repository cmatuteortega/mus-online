-- Legacy shim — the autobattler unit system was removed in the mus migration
-- (see MUS_MIGRATION_PLAN.md, Phase 0). Menu/lobby/preload still call into this
-- API; every accessor returns empty data so those panels render empty until they
-- are replaced with mus content (plan Phases 3 and 5). Delete this file once no
-- caller remains.

local UnitRegistry = {}

UnitRegistry.factions            = {}
UnitRegistry.factionIcons        = {}
UnitRegistry.unitCosts           = {}
UnitRegistry.groups              = {}
UnitRegistry.rarity              = {}
UnitRegistry.rarityTiers         = {}
UnitRegistry.passiveDescriptions = {}

function UnitRegistry.getAllUnitTypes() return {} end
function UnitRegistry.getLoadSteps() return {} end
function UnitRegistry.getUnitDisplayInfo() return nil end
function UnitRegistry.loadDirectionalSprites() return nil end
function UnitRegistry.finalizeSprites() end

return UnitRegistry
