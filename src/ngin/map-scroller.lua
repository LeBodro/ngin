-- This file contains a prototype Lua model of the ngin map scroller module.
-- The implementation details don't represent the final 6502 implementation,
-- but the functionality should be the same.

local MapScroller = {}

-- Width of the scrollable area view that should be valid at any given time.
-- Maximum possible value depends on the used mirroring mode:
--   * One screen mirroring: 256-8, 240-8; 256-16, 240-16
--     * Can also be used with other mirroring modes, but produces needless
--       artifacts.
--   * Horizontal mirroring: 256-8, 240; 256-16, 240
--   * Vertical mirroring: 256, 240-8; 256, 240-16
--   * Four-screen mirroring: 256, 240; 256, 240
-- Custom sizes (e.g. 64x64) could be used as well.
-- Note: The "maximum" is the maximum sensible value. E.g. with horizontal
--       mirroring the view height could be 384 pixels, but most of the updated
--       pixels would then go to waste. The tile and color attribute view
--       sizes can also differ.
-- Note: Using values other than "one screen mirroring" here requires manual
--       changes to attributeCache.
local kViewWidth, kViewHeight = 256-8, 240-8 -- One screen mirroring (generic)
local kAttrViewWidth, kAttrViewHeight = 256-16, 240-16 -- One screen mirroring (generic)

local kDirectionVertical, kDirectionHorizontal = 0, 1

local kTile8Width, kTile8Height = 8, 8
local kTile16Width, kTile16Height = 16, 16
local kTile32Width, kTile32Height = 32, 32
local kScreenWidth, kScreenHeight = 256, 256

local kNametableWidth = 256
local kNametableHeight = 240
local kNametableTotalWidth = 2*kNametableWidth
local kNametableTotalHeight = 2*kNametableHeight

-- These values are (in pixels) the maximum amount of pixels that need to be
-- updated when the screen scrolls. The reason for adding another 8 pixels is
-- that when the subtile offset is non-zero, one more tile of map is overlapped
-- by the view window. These values are the worst case scenario -- if subtile
-- offset is 0, only kViewWidth/kViewHeight pixels would need to be updated.
local kTileUpdateWidthPixels = kViewWidth + kTile8Width
local kTileUpdateHeightPixels = kViewHeight + kTile8Height
local kAttributeTileUpdateWidthPixels = kAttrViewWidth + kTile16Width
local kAttributeTileUpdateHeightPixels = kAttrViewHeight + kTile16Height

-------------------------------------------------------------------------------

-- Position of the edge of scroll (the first/last visible pixel row/column)
-- in both the map and the nametables, for all scroll directions.
-- \note In practice, map position and PPU position could share the same
--       subtile offset, and should be split into several parts for faster
--       access (e.g. screen part, tile part, subtile offset, ...)
--       There's also some redundancy in the tile/attribute counters.
-- \note Map position and PPU position have to be aligned to the color attribute
--       grid.
scrollDataTop = {
    mapPosition = 0,
    ppuPosition = 0,
    attrMapPosition = 0,
    attrPpuPosition = 0,
    updateDirection = kDirectionHorizontal
}

scrollDataBottom = {
    mapPosition = scrollDataTop.mapPosition + kViewHeight-1,
    ppuPosition = (scrollDataTop.ppuPosition + kViewHeight-1) % kNametableTotalHeight,
    attrMapPosition = scrollDataTop.mapPosition + kAttrViewHeight-1,
    attrPpuPosition = (scrollDataTop.ppuPosition + kAttrViewHeight-1) % kNametableTotalHeight,
    updateDirection = kDirectionHorizontal
}

scrollDataLeft = {
    mapPosition = 0,
    ppuPosition = 0,
    attrMapPosition = 0,
    attrPpuPosition = 0,
    updateDirection = kDirectionVertical
}

scrollDataRight = {
    mapPosition = scrollDataLeft.mapPosition + kViewWidth-1,
    ppuPosition = (scrollDataLeft.ppuPosition + kViewWidth-1) % kNametableTotalWidth,
    attrMapPosition = scrollDataLeft.mapPosition + kAttrViewWidth-1,
    attrPpuPosition = (scrollDataLeft.ppuPosition + kAttrViewWidth-1) % kNametableTotalWidth,
    updateDirection = kDirectionVertical
}

-------------------------------------------------------------------------------

-- Reads a 16-bit value from RAM.
local function read16( addr )
    return bit32.bor(
        bit32.lshift( RAM[ addr+1 ], 8 ),
        RAM[ addr+0 ]
    )
end

-- Members of ngin_MapData_Pointers struct
-- \todo If scopes were exposed from NDX, structs could be handled
--       automatically with a proxy object which would be constructed based
--       on a struct scope name.
local pointersStructMembers = {
    screenRowPointersLo=0,
    screenRowPointersHi=1,
    screenPointersLo=2,
    screenPointersHi=3,
    _16x16MetatileTopLeft=4,
    _16x16MetatileTopRight=5,
    _16x16MetatileBottomLeft=6,
    _16x16MetatileBottomRight=7,
    _16x16MetatileAttributes0=8,
    _32x32MetatileTopLeft=9,
    _32x32MetatileTopRight=10,
    _32x32MetatileBottomLeft=11,
    _32x32MetatileBottomRight=12
}

-- Retrieve values of some of the symbols defined by ngin.
local ngin_MapData_pointers = SYM.ngin_MapData_pointers[ 1 ]
local ngin_ppuBuffer        = SYM.ngin_ppuBuffer[ 1 ]

-- Attribute cache keeps a copy of the PPU color attributes in CPU memory.
-- The required size depends on the view size. 9x9 bytes should be enough for
-- all uses (although addressing the cache might be a bit tricky).
local attributeCache = {}
-- for i = 0, 255 do
for i = 0, 63 do
    attributeCache[ i ] = 0
end

-- Read a value of a map data pointer.
local function readPointer( structMember )
    return read16( ngin_MapData_pointers +
                   2 * pointersStructMembers[ structMember ] )
end

-- Convert an unsigned byte to a signed number.
local function signedByte( value )
    if value <= 127 then
        return value
    end
    return value - 256
end

-- Read a 16x16px metatile from the map. X and Y parameters are in pixels.
local function readMetatile16( x, y )
    -- Screen coordinates within the full map
    local screenX, screenY =
        math.floor( x / kScreenWidth ), math.floor( y / kScreenHeight )

    -- 32x32px metatile coordinates within the screen
    local tile32X, tile32Y =
        math.floor( x / kTile32Width ) % ( kScreenWidth / kTile32Width ),
        math.floor( y / kTile32Height ) % ( kScreenHeight / kTile32Height )

    -- 2x2 coordinates within the 32x32px metatile
    local tile32X_2, tile32Y_2 =
        math.floor( x / kTile16Width ) % ( kTile32Width / kTile16Width ),
        math.floor( y / kTile16Width ) % ( kTile32Height / kTile16Height )

    -- Get address of screen row pointers.
    local screenRowPointersLo = readPointer( "screenRowPointersLo" )
    local screenRowPointersHi = readPointer( "screenRowPointersHi" )

    -- Get address of screen pointers.
    local screenPointersLo = readPointer( "screenPointersLo" )
    local screenPointersHi = readPointer( "screenPointersHi" )

    -- Get address of 32x32px metatile pointers.
    local _32x32MetatileTopLeft     = readPointer( "_32x32MetatileTopLeft" )
    local _32x32MetatileTopRight    = readPointer( "_32x32MetatileTopRight" )
    local _32x32MetatileBottomLeft  = readPointer( "_32x32MetatileBottomLeft" )
    local _32x32MetatileBottomRight = readPointer( "_32x32MetatileBottomRight" )

    -- Index the screen row pointers list with the Y coordinate.
    local screenRowPointerLo = NDX.readMemory( screenRowPointersLo + screenY )
    local screenRowPointerHi = NDX.readMemory( screenRowPointersHi + screenY )
    local screenRowPointer = bit32.bor( bit32.lshift( screenRowPointerHi, 8 ),
                                        screenRowPointerLo )

    -- Index the screen row with the X coordinate to get the screen index.
    local screen = NDX.readMemory( screenRowPointer + screenX )

    -- Get the screen pointer lobyte and hibyte.
    local screenPointerLo = NDX.readMemory( screenPointersLo + screen )
    local screenPointerHi = NDX.readMemory( screenPointersHi + screen )
    local screenPointer = bit32.bor( bit32.lshift( screenPointerHi, 8 ),
                                     screenPointerLo )

    -- Read the 32x32px metatile.
    local index = tile32Y * 8 + tile32X
    local metatile32 = NDX.readMemory( screenPointer + index )

    -- Read the 16x16px metatile index from the 32x32px metatile.
    local addr = nil
    if tile32X_2 == 0 and tile32Y_2 == 0 then
        addr = _32x32MetatileTopLeft
    elseif tile32X_2 == 1 and tile32Y_2 == 0 then
        addr = _32x32MetatileTopRight
    elseif tile32X_2 == 0 and tile32Y_2 == 1 then
        addr = _32x32MetatileBottomLeft
    elseif tile32X_2 == 1 and tile32Y_2 == 1 then
        addr = _32x32MetatileBottomRight
    end
    local metatile16 = NDX.readMemory( addr + metatile32 )

    return metatile16
end

-- Read a tile from the map.
local function readTile( x, y )
    local metatile16 = readMetatile16( x, y )

    -- 2x2 coordinates within the 16x16px metatile
    local tile16X_2, tile16Y_2 =
        math.floor( x / kTile8Width ) % ( kTile16Width / kTile8Width ),
        math.floor( y / kTile8Width ) % ( kTile16Height / kTile8Width )

    -- Get address of 16x16px metatile pointers.
    local _16x16MetatileTopLeft     = readPointer( "_16x16MetatileTopLeft" )
    local _16x16MetatileTopRight    = readPointer( "_16x16MetatileTopRight" )
    local _16x16MetatileBottomLeft  = readPointer( "_16x16MetatileBottomLeft" )
    local _16x16MetatileBottomRight = readPointer( "_16x16MetatileBottomRight" )

    -- Read the 8x8px tile index from the 16x16px metatile.
    local addr = nil
    if tile16X_2 == 0 and tile16Y_2 == 0 then
        addr = _16x16MetatileTopLeft
    elseif tile16X_2 == 1 and tile16Y_2 == 0 then
        addr = _16x16MetatileTopRight
    elseif tile16X_2 == 0 and tile16Y_2 == 1 then
        addr = _16x16MetatileBottomLeft
    elseif tile16X_2 == 1 and tile16Y_2 == 1 then
        addr = _16x16MetatileBottomRight
    end
    local tile8 = NDX.readMemory( addr + metatile16 )

    return tile8
end

-- Read an attribute from the map.
local function readAttribute( x, y )
    local metatile16 = readMetatile16( x, y )

    local _16x16MetatileAttributes0 = readPointer( "_16x16MetatileAttributes0" )
    local attribute = NDX.readMemory( _16x16MetatileAttributes0 + metatile16 )

    return attribute
end

-- Add a byte to PPU buffer.
local function addPpuBufferByte( value )
    RAM[ ngin_ppuBuffer + RAM.ngin_ppuBufferPointer ] = value
    RAM.ngin_ppuBufferPointer = RAM.ngin_ppuBufferPointer + 1
end

-- Terminate the PPU buffer.
local function terminatePpuBuffer()
    RAM[ ngin_ppuBuffer + RAM.ngin_ppuBufferPointer ] = 0x80
end

-- Stores the position of the "size" byte within the buffer, so that we know
-- where to update it later.
local ppuBufferSizePointer = nil

-- Start counting the size of a PPU buffer update.
local function startPpuBufferSizeCounting()
    ppuBufferSizePointer = RAM.ngin_ppuBufferPointer
end

-- Stop counting the size of a PPU buffer update. Update the size byte in the
-- buffer with the correct size.
local function endPpuBufferSizeCounting()
    -- Don't do anything if buffer size counting wasn't started.
    if ppuBufferSizePointer == nil then
        return
    end

    -- Calculate the size based on current PPU pointer and where the size
    -- byte was.
    local size = RAM.ngin_ppuBufferPointer - ppuBufferSizePointer - 1

    -- Update the size in the buffer.
    RAM[ ngin_ppuBuffer + ppuBufferSizePointer ] = size

    ppuBufferSizePointer = nil
end

-- Generate a PPU nametable address from coordinates (0..511, 0..479)
local function ppuAddressFromCoord( x, y )
    local nametable = 2 * ( math.floor( y / kNametableHeight ) % 2 ) +
                      math.floor( x / kNametableWidth ) % 2

    local tileX = math.floor( x / kTile8Width ) %
                    ( kNametableWidth / kTile8Width )
    local tileY = math.floor( y / kTile8Height ) %
                    ( kNametableHeight / kTile8Height )

    return 0x2000 + 0x400 * nametable + 32*tileY + tileX
end

-- Generate a PPU attribute table address from coordinates (0..511, 0..479)
local function ppuAttributeAddressFromCoord( x, y )
    local nametable = 2 * ( math.floor( y / kNametableHeight ) % 2 ) +
                      math.floor( x / kNametableWidth ) % 2

    local attributeByteX = math.floor( x / kTile32Width ) %
                    ( kNametableWidth / kTile32Width )
    -- \note The nametable height (240px) is not an even multiple of attribute
    --       byte height (32px).
    local attributeByteY = math.floor( ( y % kNametableHeight ) / kTile32Height )

    return 0x2000 + 0x400 * nametable + 32*30 + 8*attributeByteY + attributeByteX
end

-- Updates attribute cache with attributeBits at (x, y), returns the updated
-- attribute byte corresponding to the coordinates.
local function updateAttributeCache( x, y, attributeBits )
    local attributeAddress = ppuAttributeAddressFromCoord( x, y )

    -- Strip out the nametable portion, leave only the attribute part.
    -- \todo Mask 0x3F works for a limited view size (one screen mirroring)
    --       For bigger views we would need a slightly bigger cache.
    attributeAddress = bit32.bor(
        bit32.band( attributeAddress, 0x3F ),
        -- Add the attribute bits to expand to 8-bit range.
        -- bit32.rshift( bit32.band( attributeAddress, 0xC00 ), 4 )
        0
    )

    -- Get the quadrant within the attribute byte.
    local attributeQuadrantX = math.floor( x / kTile16Width ) % 2
    -- \note A possibility of a subtle error here requires us to modulo the
    --       Y coordinate with nametable height before division. Otherwise
    --       e.g. Y = 240 would produce quadrantY = 1
    local attributeQuadrantY = math.floor( ( y % kNametableHeight ) / kTile16Height ) % 2

    -- Calculate the shift amount.
    -- (0,0) -> 0, (0,1) -> 2, (1,0) -> 4, (1,1) -> 6
    local shiftAmount = 2 * ( 2*attributeQuadrantY + attributeQuadrantX )

    -- Update the cache.
    local attributeByte = attributeCache[ attributeAddress ]
    attributeByte = bit32.bor(
        -- Clear out the existing data with AND.
        bit32.band( attributeByte, bit32.bnot( bit32.lshift( 0x3, shiftAmount ) ) ),
        bit32.lshift( attributeBits, shiftAmount )
    )
    attributeCache[ attributeAddress ] = attributeByte

    return attributeByte

end

-- Generates a PPU buffer update to add a new row/column of tiles.
-- "Perp" stands for perpendicular.
local function update( scrollData, perpScrollData )
    -- Determine the update length and the step amount based on the update
    -- direction.
    local kUpdateLengthPixels, kTileSize
    if scrollData.updateDirection == kDirectionVertical then
        kUpdateLengthPixels = kTileUpdateHeightPixels
        kTileSize = kTile8Height
    else
        kUpdateLengthPixels = kTileUpdateWidthPixels
        kTileSize = kTile8Width
    end

    local previousPpuAddress = nil

    -- Loop through the whole section that needs to be updated. Currently the
    -- scroll speed is limited to 8px/frame.
    -- Subtract one because the for loop is inclusive in the upper bound.
    -- \note The loop variables (X and Y) are named from the point of view
    --       of a vertical update.
    local mapX = scrollData.mapPosition
    for mapY = perpScrollData.mapPosition,
            perpScrollData.mapPosition+kUpdateLengthPixels-1, kTileSize do

        -- Calculate the nametable Y corresponding to mapY.
        ppuY = perpScrollData.ppuPosition + mapY - perpScrollData.mapPosition

        -- Again, need to swap X and Y depending on the update direction.
        local ppuAddress
        if scrollData.updateDirection == kDirectionVertical then
            ppuAddress = ppuAddressFromCoord( scrollData.ppuPosition, ppuY )
        else
            ppuAddress = ppuAddressFromCoord( ppuY, scrollData.ppuPosition )
        end

        -- Check if the nametable changed. In an actual implementation, we
        -- would not want to be doing this check on each iteration.
        if previousPpuAddress == nil or bit32.band( ppuAddress, 0xC00 ) ~=
                                        bit32.band( previousPpuAddress, 0xC00 ) then
            endPpuBufferSizeCounting()

            local inc32
            if scrollData.updateDirection == kDirectionVertical then
                inc32 = 0x40
            else
                inc32 = 0
            end

            -- Add a PPU buffer update header.

            -- PPU address hibyte (+flags)
            addPpuBufferByte( bit32.bor( bit32.rshift( ppuAddress, 8 ), inc32 ) )
            -- PPU address lobyte
            addPpuBufferByte( bit32.band( ppuAddress, 0xFF ) )
            -- Add a placeholder size byte and start counting the size.
            startPpuBufferSizeCounting()
            addPpuBufferByte( 0 )
        end
        previousPpuAddress = ppuAddress

        -- Read a tile from the map and add to buffer.
        local tile
        if scrollData.updateDirection == kDirectionVertical then
            tile = readTile( mapX, mapY )
        else
            tile = readTile( mapY, mapX )
        end
        addPpuBufferByte( tile )
    end

    endPpuBufferSizeCounting()
    terminatePpuBuffer()
end

-- Mostly copied from update(). Annoyingly different enough to make combining
-- the two functions quite difficult.
local function updateAttributes( scrollData, perpScrollData )
    local kUpdateLengthPixels, kAttributeTileSize
    if scrollData.updateDirection == kDirectionVertical then
        kUpdateLengthPixels = kAttributeTileUpdateHeightPixels
        kAttributeTileSize = kTile16Height
    else
        kUpdateLengthPixels = kAttributeTileUpdateWidthPixels
        kAttributeTileSize = kTile16Width
    end

    local previousPpuAddress = nil

    local mapX = scrollData.attrMapPosition
    for mapY = perpScrollData.attrMapPosition,
            perpScrollData.attrMapPosition+kUpdateLengthPixels-1,
            kAttributeTileSize do

        ppuY = perpScrollData.attrPpuPosition + mapY - perpScrollData.attrMapPosition

        local ppuAddress
        if scrollData.updateDirection == kDirectionVertical then
            ppuAddress = ppuAttributeAddressFromCoord( scrollData.attrPpuPosition,
                                                       ppuY )
        else
            ppuAddress = ppuAttributeAddressFromCoord( ppuY,
                                                       scrollData.attrPpuPosition )
        end

        -- If update is to the same address as before, replace the old update.
        -- This can happen because several attributes are packed into a single
        -- byte.
        if ppuAddress == previousPpuAddress then
            -- Replace the previous update by moving the pointer backwards.
            RAM.ngin_ppuBufferPointer = RAM.ngin_ppuBufferPointer - 1
        -- If nametable changed, OR doing a vertical update, start a new update
        -- batch (always needed for vertical, since there's no "inc8" mode)
        elseif previousPpuAddress == nil or bit32.band( ppuAddress, 0xC00 ) ~=
                bit32.band( previousPpuAddress, 0xC00 ) or
                scrollData.updateDirection == kDirectionVertical then
            endPpuBufferSizeCounting()

            -- \note Inc1 mode is always used for attributes.

            addPpuBufferByte( bit32.rshift( ppuAddress, 8 ) )
            addPpuBufferByte( bit32.band( ppuAddress, 0xFF ) )
            startPpuBufferSizeCounting()
            addPpuBufferByte( 0 )
        end
        previousPpuAddress = ppuAddress

        -- Read an attribute from the map, combine it with cached attributes,
        -- store back in cache, and add to the update buffer.
        local attribute
        if scrollData.updateDirection == kDirectionVertical then
            attribute = updateAttributeCache( scrollData.attrPpuPosition, ppuY,
                readAttribute( mapX, mapY ) )
        else
            attribute = updateAttributeCache( ppuY, scrollData.attrPpuPosition,
                readAttribute( mapY, mapX ) )
        end

        addPpuBufferByte( attribute )
    end

    endPpuBufferSizeCounting()
    terminatePpuBuffer()
end

local function scroll( amount, scrollData, oppositeScrollData, perpScrollData )
    local previousPosition = scrollData.mapPosition
    local previousAttrPosition = scrollData.attrMapPosition

    -- Update the position in the map, on the side we're scrolling to, and on
    -- the opposite side.
    -- \todo If we know the map size, could clamp the value, or roll it over
    --       for a repeating map.
    scrollData.mapPosition = scrollData.mapPosition + amount
    oppositeScrollData.mapPosition = oppositeScrollData.mapPosition + amount

    scrollData.attrMapPosition = scrollData.attrMapPosition + amount
    oppositeScrollData.attrMapPosition = oppositeScrollData.attrMapPosition + amount

    -- Determine the maximum nametable coordinate based on update direction.
    local kPpuPositionMax
    if scrollData.updateDirection == kDirectionVertical then
        kPpuPositionMax = kNametableTotalWidth
    else
        kPpuPositionMax = kNametableTotalHeight
    end

    scrollData.ppuPosition =
        (scrollData.ppuPosition + amount) % kPpuPositionMax
    oppositeScrollData.ppuPosition =
        (oppositeScrollData.ppuPosition + amount) % kPpuPositionMax

    scrollData.attrPpuPosition =
        (scrollData.attrPpuPosition + amount) % kPpuPositionMax
    oppositeScrollData.attrPpuPosition =
        (oppositeScrollData.attrPpuPosition + amount) % kPpuPositionMax

    -- If the scroll position update pushed us over to a new tile, we need to
    -- update a new tile row/column. In an actual implementation we could check
    -- if the subtile offset overflowed.
    if math.floor( previousPosition/8 ) ~=
            math.floor( scrollData.mapPosition/8 ) then
        -- A new tile row/column is visible, generate PPU update for it.
        update( scrollData, perpScrollData )
    end

    if math.floor( previousAttrPosition/16 ) ~=
            math.floor( scrollData.attrMapPosition/16 ) then
        updateAttributes( scrollData, perpScrollData )
    end
end

function MapScroller.scrollHorizontal()
    local amount = signedByte( RAM.__ngin_MapScroller_scrollHorizontal_amount )

    if amount < 0 then
        scroll( amount, scrollDataLeft, scrollDataRight, scrollDataTop )
    elseif amount > 0 then
        scroll( amount, scrollDataRight, scrollDataLeft, scrollDataTop )
    end
end

function MapScroller.scrollVertical()
    local amount = signedByte( RAM.__ngin_MapScroller_scrollVertical_amount )

    if amount < 0 then
        scroll( amount, scrollDataTop, scrollDataBottom, scrollDataLeft )
    elseif amount > 0 then
        scroll( amount, scrollDataBottom, scrollDataTop, scrollDataLeft )
    end
end

ngin.MapScroller = MapScroller