# test_icache_hit_loop.S — Stage 5e integration test for the I-cache.
#
# Programs mhpmcounter3 to count I$ misses (event 0x10), runs a 1000-iteration
# tight loop that fits in a single 64-byte cache line, and verifies the miss
# count is bounded.

.section .text
.global main
main:
    li      t0, 0x10                    # event ID = I$ miss
    csrw    0x323, t0                   # mhpmevent3
    csrw    0xB03, zero                 # mhpmcounter3 = 0
    csrw    0x320, zero                 # mcountinhibit = 0

    li      t0, 1000                    # iteration count
1:  addi    t0, t0, -1                  # 4 bytes
    bnez    t0, 1b                      # 4 bytes — full loop = 8 bytes
    csrr    a0, 0xB03                   # read miss count
    li      t1, 5                       # tolerance: <= 5 misses (cold start + setup)
    bgt     a0, t1, .Lfail
    li      a0, 0
    ret
.Lfail:
    li      a0, 1
    ret
