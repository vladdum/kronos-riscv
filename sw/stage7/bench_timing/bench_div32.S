# bench_div32.S — cycles/instr for a dependent 32-bit DIVW chain
# (kronos_muldiv, doc-claimed 34 cycles, normal case — not div-by-zero or
# INT_MIN/-1). t1 shrinks toward 0 over the 100 iterations but never hits
# the divisor==0 or INT_MIN/-1 early-exit conditions, so every iteration
# takes the same normal-case latency.

.section .text
.global main
main:
    csrr    t0, mcycle
    li      t1, 123456789
    li      t4, 7
    li      t2, 100
1:  divw    t1, t1, t4         # measured body — dependent chain
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
