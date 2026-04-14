# test_bpred_loop.S — exercises the branch predictor with loops.
.section .text
.globl main
main:
    mv   s2, ra
    li   a0, 0

    # Test 1: countdown loop (predictor learns "taken")
    li   x1, 100
loop1:
    addi x1, x1, -1
    bnez x1, loop1
    bnez x1, fail

    # Test 2: same branch PC alternates taken/not-taken (exercises 2-bit hysteresis)
    # beqz x8, alt_not_taken is taken on even phase (x8==0), not-taken on odd phase (x8==1)
    li   x2, 0          # hit counter
    li   x3, 16         # 16 iterations
    li   x8, 0          # phase (flipped each iteration)
alt_loop:
    xori x8, x8, 1              # flip phase: 0->1->0->1...
    beqz x8, alt_not_taken      # taken when x8==0 (even), not-taken when x8==1 (odd)
    addi x2, x2, 1              # count not-taken outcomes (x8 was 1)
alt_not_taken:
    addi x3, x3, -1
    bnez x3, alt_loop
    li   x4, 8                  # 16 iters, x8==1 (not-taken path) on 8 of them
    bne  x2, x4, fail

    # Test 3: nested loops
    li   x4, 5
outer:
    li   x5, 4
inner:
    addi x5, x5, -1
    bnez x5, inner
    addi x4, x4, -1
    bnez x4, outer
    bnez x4, fail
    bnez x5, fail

    # Test 4: JAL/RET sequence (stresses BTB — JAL target training)
    mv   s1, s2          # save original return address (x1/ra already clobbered by Test 1)
    li   x6, 0
    li   x7, 8
call_loop:
    jal  x1, inc_x6
    addi x7, x7, -1
    bnez x7, call_loop
    mv   ra, s1          # restore return address unconditionally before any branch to fail
    li   x8, 8
    bne  x6, x8, fail
    ret

inc_x6:
    addi x6, x6, 1
    jr   x1              # return via x1 (explicit link register)

fail:
    li   a0, 1
    ret
