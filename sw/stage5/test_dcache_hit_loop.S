# test_dcache_hit_loop.S — Stage 5f integration test for the D-cache.
#
# Programs mhpmcounter3 to count D$ misses (event 0x11), runs a tight
# load-store loop on a one-line array, verifies the miss count is
# bounded.

.section .text
.global main
main:
    li      t0, 0x11                # event ID = D$ miss
    csrw    0x323, t0               # mhpmevent3
    csrw    0xB03, zero             # mhpmcounter3 = 0
    csrw    0x320, zero             # mcountinhibit = 0

    li      t0, 1000
    la      t1, .Larr
1:  ld      t2, 0(t1)
    addi    t2, t2, 1
    sd      t2, 0(t1)
    addi    t0, t0, -1
    bnez    t0, 1b
    csrr    a0, 0xB03
    li      t1, 5                   # tolerance: ≤5 misses (cold-start)
    bgt     a0, t1, .Lfail
    li      a0, 0
    ret
.Lfail:
    li      a0, 1
    ret

.section .data
.balign 8
.Larr:  .dword 0
