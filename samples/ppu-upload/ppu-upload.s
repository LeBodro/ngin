.include "ngin/ngin.inc"

.segment "RODATA"

.proc backgroundPalette
    .byte $0F, $2B, $2B, $2B
    .byte $0F, $0F, $0F, $0F
    .byte $0F, $0F, $0F, $0F
    .byte $0F, $0F, $0F, $0F
.endproc

.segment "BSS"

; \todo Use DATA segment, implement initialization in reset routines.
counter1: .byte 0
counter2: .byte 0

; -----------------------------------------------------------------------------

.segment "CODE"

ngin_entryPoint start
.proc start
    ngin_mov8 counter1, #0
    ngin_mov8 counter2, #128

    jsr uploadPalette
    jsr initializeNametable

    loop:
        ngin_PpuBuffer_startFrame
        jsr constructPpuBuffer1
        jsr constructPpuBuffer2
        ngin_PpuBuffer_endFrame

        ngin_pollVBlank
        ngin_PpuBuffer_upload
        ngin_mov8 ppu::scroll, #0
        ngin_mov8 ppu::scroll, #0
        ngin_mov8 ppu::ctrl, #0
        ngin_mov8 ppu::mask, #ppu::mask::kShowBackground
    jmp loop
.endproc

.proc uploadPalette
    ngin_pollVBlank

    ; Set all palettes to black.
    ngin_setPpuAddress #ppu::backgroundPalette
    ngin_fillPort #ppu::data, #$F, #32

    ; Upload sprite palette.
    ngin_setPpuAddress #ppu::backgroundPalette
    ngin_copyMemoryToPort #ppu::data, #backgroundPalette, \
                          #.sizeof( backgroundPalette )

    rts
.endproc

.proc initializeNametable
    ngin_setPpuAddress #ppu::nametable0
    ngin_fillPort #ppu::data, #0, #1024

    rts
.endproc

.macro constructPpuBuffer_template counter, tile
    ldx ngin_ppuBufferPointer

    ; Set the PPU address and flags.
    ; \note PPU address is big endian.
    ngin_mov8 { ngin_ppuBuffer + ngin_PpuBufferElement::ppuAddress + 0, x }, \
              #.hibyte( ppu::nametable0 + 8*32 )
    ngin_mov8 { ngin_ppuBuffer + ngin_PpuBufferElement::ppuAddress + 1, x }, \
              {counter}

    ; Set the size.
    ngin_mov8 { ngin_ppuBuffer + ngin_PpuBufferElement::size, x }, #1

    ; Set the data (tile).
    ngin_mov8 { ngin_ppuBuffer + ngin_PpuBufferElement::data, x }, {tile}

    ; Update ngin_ppuBufferPointer. We added the header and one data byte.
    txa
    clc
    adc #.sizeof( ngin_PpuBufferElement ) + 1
    tax
    stx ngin_ppuBufferPointer

    ; Set the terminator.
    ngin_mov8 { ngin_ppuBuffer + ngin_PpuBufferElement::ppuAddress + 0, x }, \
              #ngin_kPpuBufferTerminatorMask

    inc counter

    rts
.endmacro

.proc constructPpuBuffer1
    constructPpuBuffer_template counter1, #1
.endproc

.proc constructPpuBuffer2
    constructPpuBuffer_template counter2, #0
.endproc

; -----------------------------------------------------------------------------

.segment "CHR_ROM"

.repeat 16
    .byte 0
.endrepeat

.repeat 16
    .byte $FF
.endrepeat