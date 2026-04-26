# test_perf_counters.S — Stage 5c performance counters end-to-end test
#
# Validates Zicntr (mcycle/minstret writability) and partial Zihpm
# (mhpmcounter3..10 + mhpmevent3..10 + mcountinhibit).
#
# Layout:
#   1. mcycle SW-write
#   2. minstret SW-write
#   3. mhpmcounter3 counts branches
#   4. mhpmcounter4 counts loads
#   5. mcountinhibit freezes everything
#   6. Out-of-range event ID is inert
#
# x10 (a0) = failure count (0 = pass).

.equ CSR_MCOUNTINHIBIT, 0x320
.equ CSR_MHPMEVENT3,    0x323
.equ CSR_MHPMEVENT4,    0x324
.equ CSR_MHPMEVENT5,    0x325
.equ CSR_MCYCLE,        0xB00
.equ CSR_MINSTRET,      0xB02
.equ CSR_MHPMCOUNTER3,  0xB03
.equ CSR_MHPMCOUNTER4,  0xB04
.equ CSR_MHPMCOUNTER5,  0xB05

.equ EVT_BRANCH_RETIRE, 0x01
.equ EVT_LOAD_RETIRE,   0x03
.equ EVT_RESERVED_HI,   0x1F        # reserved (no event wired)

.section .text
.global main
main:
    li      a0, 0                   # fail counter

    # Make sure no counter is inhibited.
    csrw    CSR_MCOUNTINHIBIT, zero

    # ---- 1. mcycle SW-write takes effect ----
    csrw    CSR_MCYCLE, zero
    csrr    t0, CSR_MCYCLE
    li      t1, 1000                # mcycle should be much smaller than 1000
    bltu    t0, t1, 1f
    addi    a0, a0, 1
1:

    # ---- 2. minstret SW-write takes effect ----
    csrw    CSR_MINSTRET, zero
    csrr    t0, CSR_MINSTRET
    li      t1, 100
    bltu    t0, t1, 2f
    addi    a0, a0, 1
2:

    # ---- 3. mhpmcounter3 counts conditional branches ----
    li      t0, EVT_BRANCH_RETIRE
    csrw    CSR_MHPMEVENT3, t0
    csrw    CSR_MHPMCOUNTER3, zero
    li      t2, 8                   # loop iterations
    li      t3, 0                   # i = 0
.Lbloop:
    addi    t3, t3, 1
    blt     t3, t2, .Lbloop         # 1 conditional branch per iteration
    nop                             # drain: let last branch retire before csrr
    nop
    csrr    t4, CSR_MHPMCOUNTER3
    li      t5, 8
    bgeu    t4, t5, 3f              # >= 8 branches
    addi    a0, a0, 1
3:

    # ---- 4. mhpmcounter4 counts loads ----
    li      t0, EVT_LOAD_RETIRE
    csrw    CSR_MHPMEVENT4, t0
    csrw    CSR_MHPMCOUNTER4, zero
    la      t2, .Ldata
    ld      t3, 0(t2)
    ld      t3, 8(t2)
    ld      t3, 16(t2)
    ld      t3, 24(t2)
    nop                             # drain: let last load retire before csrr
    nop
    csrr    t4, CSR_MHPMCOUNTER4
    li      t5, 4
    bgeu    t4, t5, 4f              # >= 4 loads
    addi    a0, a0, 1
4:

    # ---- 5. mcountinhibit freezes counters ----
    li      t0, 0x7FF               # inhibit ALL 11 counters
    csrw    CSR_MCOUNTINHIBIT, t0
    csrr    t1, CSR_MHPMCOUNTER3    # snapshot
    csrr    t2, CSR_MCYCLE
    nop
    nop
    nop
    nop
    csrr    t3, CSR_MHPMCOUNTER3
    csrr    t4, CSR_MCYCLE
    bne     t1, t3, .Linh_fail
    bne     t2, t4, .Linh_fail
    j       .Linh_ok
.Linh_fail:
    addi    a0, a0, 1
.Linh_ok:
    csrw    CSR_MCOUNTINHIBIT, zero # release

    # ---- 6. Unwired event ID is inert ----
    li      t0, EVT_RESERVED_HI
    csrw    CSR_MHPMEVENT5, t0
    csrw    CSR_MHPMCOUNTER5, zero
    li      t6, 16
    li      t5, 0
.Lrloop:
    addi    t5, t5, 1
    blt     t5, t6, .Lrloop
    csrr    t4, CSR_MHPMCOUNTER5
    beqz    t4, 6f
    addi    a0, a0, 1
6:

    ret

.section .rodata
.balign 8
.Ldata:
    .dword 0xAAAAAAAA00000001
    .dword 0xAAAAAAAA00000002
    .dword 0xAAAAAAAA00000003
    .dword 0xAAAAAAAA00000004
