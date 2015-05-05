.include "ngin/ngin.inc"

.segment "RODATA"

spriteDefinition:
    ; \note Sprite coordinate origin is close to the center of the screen
    ;       because of the adjustments.

    .byte ngin_SpriteRenderer_kAttribute|%000_000_00 ; Attributes
    .byte ngin_SpriteRenderer_kAdjustX+0             ; X
    .byte ngin_SpriteRenderer_kAdjustY+0             ; Y
    .byte 1                                          ; Tile

    .byte ngin_SpriteRenderer_kAttribute|%000_000_01 ; Attributes
    .byte ngin_SpriteRenderer_kAdjustX+0             ; X
    .byte ngin_SpriteRenderer_kAdjustY+8             ; Y
    .byte 1                                          ; Tile

    .byte ngin_SpriteRenderer_kAttribute|%000_000_00 ; Attributes
    .byte ngin_SpriteRenderer_kAdjustX+8             ; X
    .byte ngin_SpriteRenderer_kAdjustY+8             ; Y
    .byte 1                                          ; Tile

    .byte ngin_SpriteRenderer_kAttribute|%000_000_01 ; Attributes
    .byte ngin_SpriteRenderer_kAdjustX+8             ; X
    .byte ngin_SpriteRenderer_kAdjustY+0             ; Y
    .byte 1                                          ; Tile

    .byte ngin_SpriteRenderer_kDefinitionTerminator

.proc spritePalette
    ; \todo Symbolic constants for color hues? (separate hue and brightness)
    ;       E.g. ngin_Color::black
    kBackgroundColor = $F
    .byte kBackgroundColor, $2B, $2B, $2B
    .byte kBackgroundColor, $38, $38, $38
    .byte kBackgroundColor, $0F, $0F, $0F
    .byte kBackgroundColor, $0F, $0F, $0F
.endproc

; -----------------------------------------------------------------------------

.segment "CODE"

ngin_entryPoint start
.proc start
    jsr uploadPalette
    jsr renderSprites

    ngin_pollVBlank
    ngin_mov8 ppu::oam::dma, #.hibyte( ngin_ShadowOam_buffer )
    ngin_mov8 ppu::mask, #( ppu::mask::kShowSprites | \
                            ppu::mask::kShowSpritesLeft )

    jmp *
.endproc

.proc uploadPalette
    ngin_pollVBlank

    ; Set all palettes to black.
    ngin_setPpuAddress #ppu::backgroundPalette
    ngin_fillPort #ppu::data, #$F, #32

    ; Upload sprite palette.
    ngin_setPpuAddress #ppu::spritePalette
    ; \note .sizeof cannot be used with imported symbols
    ngin_copyMemoryToPort #ppu::data, #spritePalette, #.sizeof( spritePalette )

    rts
.endproc

.proc renderSprites
    ngin_ShadowOam_startFrame

    ngin_SpriteRenderer_render #spriteDefinition, \
        #ngin_immediateVector2_16 ngin_SpriteRenderer_kOriginX, \
                                  ngin_SpriteRenderer_kOriginY

    ngin_SpriteRenderer_render #spriteDefinition, \
        #ngin_immediateVector2_16 ngin_SpriteRenderer_kOriginX-65, \
                                  ngin_SpriteRenderer_kOriginY+50

    ngin_ShadowOam_endFrame

    rts
.endproc

; -----------------------------------------------------------------------------

.segment "CHR_ROM"

.repeat 16
    .byte 0
.endrepeat

.repeat 16
    .byte $FF
.endrepeat
