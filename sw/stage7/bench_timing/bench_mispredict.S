# bench_mispredict.S — cycles/instr for a branch whose outcome strictly
# alternates (T,N,T,N,...), which forces a misprediction on *every*
# iteration against the kronos_bpred bimodal 2-bit saturating counter
# (indexed by this branch's own PC, §4.4 — a single per-PC counter carries
# at most one bit of outcome history). Working the state machine by hand
# confirms this: starting at 2'b01 (weakly not-taken), outcome T increments
# to 10 (now predicts taken) but the *next* outcome is N (misprediction 2:
# predicted taken, actual not-taken) which decrements back to 01 — the
# counter oscillates 01<->10 forever and mispredicts every single step. An
# 8-bit maximal-length LFSR sequence was tried first and rejected: it did
# not reliably defeat the 2-bit counter (a real, mixed-outcome sequence
# lets the counter guess right often enough that the total came out lower
# than the predictable-branch bench, an observed failure of the method —
# see task-4-report.md), where strict alternation gives a provable 100%
# mispredict rate instead of a probabilistic one.
#
# The timed loop is software-pipelined exactly like bench_taken_branch.S —
# the byte for iteration N is loaded during iteration N-1, so the branch
# never has a load-use dependency on the same iteration's load, and the
# two benches' totals are directly comparable (identical instruction
# shape; only the array content differs).
#
# Caveat: the `nop` at label-local 2f retires on the ~50% of iterations
# that resolve not-taken (unlike bench_taken_branch.S, where it never
# retires) -- a real, small (~0.5 cycle/op average) instruction-count
# asymmetry between the two benches, on top of (not instead of) the
# misprediction cost itself; it does not change the delta's sign or its
# use as the honest comparison point (§11's caption).

.section .data
.balign 8
_bits_mispredict:
    .rept 50
    .byte 1, 0
    .endr

.section .text
.global main
main:
    # Prewarm the D$ line(s) backing the array before timing. Endpoint-only
    # (byte 0 and byte 99): this is sufficient here because the 100-byte
    # array fits in exactly the two 64B lines those two addresses fall in,
    # not because touching the ends of an arbitrary range warms everything
    # between them in general.
    la      s2, _bits_mispredict
    lb      t5, 0(s2)
    lb      t5, 99(s2)

    la      s2, _bits_mispredict
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
