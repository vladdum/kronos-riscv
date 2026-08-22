# bench_fdiv_s.S — cycles/instr for a dependent FDIV.S chain
# (kronos_fpu_fdiv_core via kronos_fpu_iter). architecture.md previously
# claimed <= 29 cycles for single precision -- doc-claimed, disproven: see
# task-4-report.md sec.6 and architecture.md Sec.8.3 for the corrected,
# RTL-sourced derivation (measured 62 cycles end-to-end here). fa1 = 1.0f
# (identity) keeps fa0 stable across the chain.

.section .data
.balign 4
_one: .word 0x3F800000             # 1.0f (single)

.section .text
.global main
main:
    la      t0, _one
    flw     fa0, 0(t0)
    flw     fa1, 0(t0)
    csrr    t0, mcycle
    li      t2, 100
1:  fdiv.s  fa0, fa0, fa1      # measured body — dependent chain
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
