# assist_mem_alignment.S — directed assist for cg_mem alignment bins
# Targets: byte_aligned, byte_off4, byte_off2, byte_odd,
#          half_aligned, half_off4, half_off2,
#          word_off4
# Why: The existing memory scenarios only did word/double aligned accesses.
#      Byte accesses never misalign; halfword at even addresses is fine;
#      word at addr%8==4 (off4) is 4-byte aligned and legal.
#      All ops here are non-trapping (aligned or byte-granularity).

.section .text
.global main
main:
    li      a0, 0           # failure counter

    # Allocate a 16-byte buffer on the stack (aligned to 8)
    addi    sp, sp, -16

    # Write known bytes at each offset 0..7 (use simple values to avoid sign issues)
    li      t0, 0x12345678
    sw      t0, 0(sp)       # offsets 0-3
    li      t0, 0x9ABCDEF0
    sw      t0, 4(sp)       # offsets 4-7

    # ---- cg_mem.byte_aligned: LB at offset 0 (addr[2:0] = 000) ----
    lb      t1, 0(sp)

    # ---- cg_mem.byte_off4: LB at offset 4 (addr[2:0] = 100) ----
    lb      t1, 4(sp)

    # ---- cg_mem.byte_off2: LB at offset 2 (addr[2:0] = 010) ----
    lb      t1, 2(sp)

    # ---- cg_mem.byte_odd: LB at offset 1 (addr[2:0] = 001) ----
    lb      t1, 1(sp)

    # ---- cg_mem.byte_odd again at offset 3 ----
    lb      t1, 3(sp)

    # ---- cg_mem.half_aligned: LH at offset 0 (addr[2:0] = 000, addr[0]=0) ----
    lh      t1, 0(sp)

    # ---- cg_mem.half_off4: LH at offset 4 (addr[2:0] = 100, addr[0]=0) ----
    lh      t1, 4(sp)

    # ---- cg_mem.half_off2: LH at offset 2 (addr[2:0] = 010, addr[0]=0) ----
    lh      t1, 2(sp)

    # ---- cg_mem.word_off4: LW at offset 4 (addr[2:0] = 100, addr[1:0]=00) ----
    lw      t1, 4(sp)

    # Verify word loads return the expected values
    lw      t2, 0(sp)
    li      t3, 0x12345678  # small positive value, no sign-extension issue
    bne     t2, t3, 1f
    j       2f
1:  addi    a0, a0, 1
2:

    lw      t2, 4(sp)
    # 0x9ABCDEF0 has bit31=1, lw sign-extends to 0xFFFFFFFF9ABCDEF0
    li      t3, -1698898192 # 0xFFFFFFFF9ABCDEF0 as signed 64-bit
    bne     t2, t3, 3f
    j       4f
3:  addi    a0, a0, 1
4:

    # Store via byte stores at odd offsets (covers byte_odd for stores)
    li      t0, 0x55
    sb      t0, 1(sp)       # byte store at odd address
    lb      t1, 1(sp)
    li      t2, 0x55
    bne     t1, t2, 5f
    j       6f
5:  addi    a0, a0, 1
6:

    # Store via halfword at off2 offset
    li      t0, 0x1234
    sh      t0, 2(sp)       # halfword store at offset 2
    lh      t1, 2(sp)
    bne     t1, t0, 7f
    j       8f
7:  addi    a0, a0, 1
8:

    addi    sp, sp, 16
    ret
