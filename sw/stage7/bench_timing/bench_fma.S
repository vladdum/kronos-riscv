# bench_fma.S — cycles/instr for a dependent FMADD.D chain (kronos_fpu_fma,
# 9-cycle unit latency + dispatch/WB overhead). fa1 = 1.0, fa2 = 0.0 makes
# each step an identity (fa0*1.0 + 0.0), keeping fa0 stable.

.section .data
.balign 8
_one:  .dword 0x3FF0000000000000  # 1.0 (double)
_zero: .dword 0x0000000000000000  # 0.0 (double)

.section .text
.global main
main:
    la      t0, _one
    fld     fa0, 0(t0)
    fld     fa1, 0(t0)
    la      t0, _zero
    fld     fa2, 0(t0)
    csrr    t0, mcycle
    li      t2, 100
1:  fmadd.d fa0, fa0, fa1, fa2 # measured body — dependent chain
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
