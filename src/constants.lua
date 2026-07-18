local Constants = {}

-- Base reference resolution (used for proportional scaling)
Constants.BASE_WIDTH = 540
Constants.BASE_HEIGHT = 960

-- Current game resolution (will be set dynamically)
Constants.GAME_WIDTH = 540
Constants.GAME_HEIGHT = 960

-- Scale factor for UI elements (calculated based on actual screen size)
Constants.SCALE = 1

-- Grid configuration
Constants.GRID_COLS = 5
Constants.GRID_ROWS = 8

-- Base cell size (at reference resolution)
Constants.BASE_CELL_SIZE = 64

-- Current cell size (will be calculated dynamically)
Constants.CELL_SIZE = 64

-- Grid dimensions in pixels (will be calculated dynamically)
Constants.GRID_WIDTH = Constants.GRID_COLS * Constants.CELL_SIZE
Constants.GRID_HEIGHT = Constants.GRID_ROWS * Constants.CELL_SIZE

-- Player sides (rows are split between two players)
Constants.PLAYER1_ROWS = 4  -- Bottom half (rows 5-8)
Constants.PLAYER2_ROWS = 4  -- Top half (rows 1-4)

-- Local player's perspective (1 = P1 at bottom, 2 = P2 at bottom).
-- Set this before drawing to flip the board display for the guest player.
Constants.PERSPECTIVE = 1

-- Convert a canonical row to its visual (screen) row.
-- When PERSPECTIVE == 2 the board is mirrored: canonical row 1 appears at the bottom.
function Constants.toVisualRow(row)
    if Constants.PERSPECTIVE == 2 then
        return Constants.GRID_ROWS + 1 - row
    end
    return row
end

-- Colors
Constants.COLORS = {
    BACKGROUND = {0.1, 0.1, 0.15, 1},
    GRID_LINE = {0.3, 0.3, 0.35, 1},
    GRID_BG = {0.15, 0.15, 0.2, 1},
    -- Chess pattern colors
    CHESS_LIGHT = {0x26/255, 0x38/255, 0x4D/255, 1},  -- #26384D
    CHESS_DARK = {0x16/255, 0x2A/255, 0x3D/255, 1},   -- #162A3D
    CELL_HIGHLIGHT = {1, 1, 1, 0.2},
}

-- UI spacing (dynamic values, will be calculated)
Constants.GRID_OFFSET_X = 110
Constants.GRID_OFFSET_Y = 180

-- Base font sizes (at reference resolution)
Constants.BASE_FONT_SIZES = {
    LARGE = 48,
    MEDIUM = 32,
    SMALL = 24,
    TINY = 16
}

-- Current font sizes (will be scaled)
Constants.FONT_SIZES = {
    LARGE = 48,
    MEDIUM = 32,
    SMALL = 24,
    TINY = 16
}

-- Margin percentages (relative to screen dimensions)
Constants.MARGINS = {
    TOP = 0.05,        -- 5% top margin
    BOTTOM = 0.15,     -- 15% bottom margin for card row
    SIDE = 0.05,       -- 5% side margins for grid
    CARD_ROW = 0.135,  -- Card row distance from bottom (13.5% of height)
}

-- Safe area insets in virtual coordinates (set at startup for mobile notch/nav bar avoidance)
Constants.SAFE_INSET_TOP = 0
Constants.SAFE_INSET_BOTTOM = 0
Constants.SAFE_INSET_LEFT = 0
Constants.SAFE_INSET_RIGHT = 0

-- Calculate dynamic resolution and scaling based on window size
function Constants.updateResolution(windowWidth, windowHeight)
    -- Calculate the best virtual resolution that maintains aspect ratio and fills the screen
    -- We'll use a virtual resolution that matches the window aspect ratio
    local windowAspect = windowWidth / windowHeight
    local baseAspect = Constants.BASE_WIDTH / Constants.BASE_HEIGHT

    -- Set virtual resolution to match window aspect ratio
    -- Scale to match the window while maintaining reasonable resolution
    if windowAspect > baseAspect then
        -- Wider than base (landscape-ish)
        Constants.GAME_HEIGHT = Constants.BASE_HEIGHT
        Constants.GAME_WIDTH = math.floor(Constants.BASE_HEIGHT * windowAspect)
    else
        -- Taller than base (portrait-ish) or same
        Constants.GAME_WIDTH = Constants.BASE_WIDTH
        Constants.GAME_HEIGHT = math.floor(Constants.BASE_WIDTH / windowAspect)
    end

    -- Calculate scale factor for UI elements
    local scaleX = Constants.GAME_WIDTH / Constants.BASE_WIDTH
    local scaleY = Constants.GAME_HEIGHT / Constants.BASE_HEIGHT
    Constants.SCALE = math.min(scaleX, scaleY)

    -- Calculate grid cell size with 1.5 cell margin on all sides
    -- Grid margin: 1.5 cells on left/right, 1.5 cells on top, 1.5 cells + card row on bottom
    local gridMarginCells = 1.5

    -- Available space accounting for margins (in cell units)
    local totalColsWithMargins = Constants.GRID_COLS + (gridMarginCells * 2)
    local topMarginCells = gridMarginCells
    local bottomMarginCells = gridMarginCells + (Constants.MARGINS.CARD_ROW * Constants.BASE_HEIGHT / Constants.BASE_CELL_SIZE)
    local totalRowsWithMargins = Constants.GRID_ROWS + topMarginCells + bottomMarginCells

    -- Calculate cell size based on available space
    local cellByWidth = Constants.GAME_WIDTH / totalColsWithMargins
    local cellByHeight = Constants.GAME_HEIGHT / totalRowsWithMargins

    -- Use the smaller value to ensure grid fits with margins
    -- Round down to nearest multiple of 16 for crisp pixel art scaling (sprites are 16px wide)
    local minCellSize = math.floor(math.min(cellByWidth, cellByHeight))
    Constants.CELL_SIZE = math.floor(minCellSize / 16) * 16

    -- Update grid dimensions
    Constants.GRID_WIDTH = Constants.GRID_COLS * Constants.CELL_SIZE
    Constants.GRID_HEIGHT = Constants.GRID_ROWS * Constants.CELL_SIZE

    -- Center grid horizontally with less top margin
    Constants.GRID_OFFSET_X = (Constants.GAME_WIDTH - Constants.GRID_WIDTH) / 2
    -- Position grid with small top margin (10% of height from top)
    local topMarginPercent = 0.15
    Constants.GRID_OFFSET_Y = Constants.GAME_HEIGHT * topMarginPercent

    -- Scale font sizes and snap to multiples of 8 (Pixellari's pixel grid)
    -- This prevents sub-pixel rendering that blurs pixel-art fonts
    local PIXEL_GRID = 8
    local function snapFont(base, minSize)
        local scaled = math.floor(base * Constants.SCALE / PIXEL_GRID) * PIXEL_GRID
        return math.max(minSize, scaled)
    end

    Constants.FONT_SIZES.LARGE  = snapFont(Constants.BASE_FONT_SIZES.LARGE,  24)
    Constants.FONT_SIZES.MEDIUM = snapFont(Constants.BASE_FONT_SIZES.MEDIUM, 16)
    Constants.FONT_SIZES.SMALL  = snapFont(Constants.BASE_FONT_SIZES.SMALL,  8)
    Constants.FONT_SIZES.TINY   = snapFont(Constants.BASE_FONT_SIZES.TINY,   8)
end

-- Convert physical-pixel safe area into virtual-coordinate insets.
-- Call AFTER updateResolution() so GAME_WIDTH/GAME_HEIGHT are current.
-- Extra Y offset for all menu content below the header (virtual coordinates).
-- Non-zero only when safe area inset pushes the header lower than its default 8px position.
Constants.MENU_CONTENT_PUSH = 0

function Constants.updateSafeInsets(safeX, safeY, safeW, safeH, windowW, windowH)
    local scaleX = windowW / Constants.GAME_WIDTH
    local scaleY = windowH / Constants.GAME_HEIGHT
    Constants.SAFE_INSET_LEFT   = safeX / scaleX
    Constants.SAFE_INSET_TOP    = safeY / scaleY
    Constants.SAFE_INSET_RIGHT  = (windowW - safeX - safeW) / scaleX
    Constants.SAFE_INSET_BOTTOM = (windowH - safeY - safeH) / scaleY
    -- Header's default top is 8*SCALE; safe header adds 2*SCALE buffer above the inset.
    -- MENU_CONTENT_PUSH is how much further down the header sits vs. default.
    local sc = Constants.SCALE
    Constants.MENU_CONTENT_PUSH = math.max(0, math.floor(Constants.SAFE_INSET_TOP + 2 * sc) - math.floor(8 * sc))
end

return Constants
