# bench_taken_branch.S — cycles/instr for a predictable (always-taken)
# branch, resolved from a memory-held condition byte. The byte for
# iteration N is loaded during iteration N-1 (software-pipelined) so the
# branch never has a load-use dependency on the same iteration's load —
# it isolates branch-resolution cost, not load latency. Instruction shape
# is identical to bench_mispredict.S (lb / addi / bnez / mv) so the two
# benches' totals are directly comparable; the only difference is whether
# the branch predictor can learn the outcome.
#
# _bits_taken is a compile-time-constant all-ones array: every branch is
# taken, and the bimodal predictor (indexed by this branch's own PC) learns
# that immediately, so after a short warm-up every iteration is a correctly
# predicted taken branch.

.section .data
.balign 8
_bits_taken:
    .rept 100
    .byte 1
    .endr

.section .text
.global main
main:
    # Prewarm the D$ line(s) backing the array before timing.
    la      s2, _bits_taken
    lb      t5, 0(s2)
    lb      t5, 99(s2)

    la      s2, _bits_taken
    lb      t5, 0(s2)          # prefetch bit[0] (untimed — before the loop)
    addi    s2, s2, 1
    csrr    t0, mcycle
    li      t2, 100
1:  lb      t6, 0(s2)          # prefetch NEXT iteration's bit (independent)
    addi    s2, s2, 1
    bnez    t5, 2f             # measured body — THIS iteration's bit,
                                # loaded last iteration (no load-use stall)
    nop
2:  mv      t5, t6              # carry the prefetched bit forward
    addi    t2, t2, -1
    .balign 4
    bnez    t2, 1b
    csrr    t3, mcycle
    # Work around a latent RTL forwarding bug: FWD_EX1_NOW sources
    # ex_result (ALU/muldiv only, see architecture.md Sec.5), but
    # kronos_forward does not exclude is_csr producers from matching
    # it, so a CSR read's destination consumed by the very next
    # instruction reads stale/zero data instead of csr_rdata. Three
    # NOPs let the CSR read retire to the regfile before use --
    # harmless here since they run after the timed region closes.
    nop
    nop
    nop
    sub     a0, t3, t0
    ret
