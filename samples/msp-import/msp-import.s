.include "ngin/ngin.inc"

; From asset importer:
.include "sprites.inc"

.segment "CODE"

ngin_entryPoint start
.proc start
    ngin_Debug_uploadDebugPalette
    jsr renderSprites

    ngin_Ppu_pollVBlank
    ngin_ShadowOam_upload
    ngin_mov8 ppu::mask, #( ppu::mask::kShowSprites | \
                            ppu::mask::kShowSpritesLeft )

    jmp *
.endproc

.proc renderSprites
    ngin_ShadowOam_startFrame

    ngin_SpriteRenderer_render #sprite_0, \
        #ngin_immVector2_16 ngin_SpriteRenderer_kTopLeftX+256/2-64, \
                            ngin_SpriteRenderer_kTopLeftY+240/2-32

    ngin_SpriteRenderer_render #sprite_1, \
        #ngin_immVector2_16 ngin_SpriteRenderer_kTopLeftX+256/2-0, \
                            ngin_SpriteRenderer_kTopLeftY+240/2-32

    ngin_SpriteRenderer_render #sprite_3, \
        #ngin_immVector2_16 ngin_SpriteRenderer_kTopLeftX+256/2+64, \
                            ngin_SpriteRenderer_kTopLeftY+240/2-32

    ngin_ShadowOam_endFrame

    rts
.endproc

.segment "GRAPHICS"
    .incbin "data/sprites.chr"
