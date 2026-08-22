# bench_mul.S — cycles/instr for a dependent MUL chain (kronos_muldiv, EX1
# dispatch, doc-claimed 2 cycles).

.section .text
.global main
main:
    csrr    t0, mcycle
    li      t1, 3
    li      t4, 7
    li      t2, 100
1:  mul     t1, t1, t4         # measured body — dependent chain
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
