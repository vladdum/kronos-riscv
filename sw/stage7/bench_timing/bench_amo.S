# bench_amo.S — cycles/instr for AMOADD.D, repeated to the same D$-resident
# address (AMO reads-modifies-writes at MEM2, §9.5, and writes rd from
# lsu_rdata like an ordinary load).

.section .data
.balign 8
_amo_addr: .dword 0

.section .text
.global main
main:
    la      s3, _amo_addr
    li      t1, 1
    sd      t1, 0(s3)          # warm the D$ line before timing
    csrr    t0, mcycle
    li      t2, 100
1:  amoadd.d t3, t1, 0(s3)     # measured body — repeated hit, same address
    addi    t2, t2, -1
    .balign 4
    bnez    t2, 1b
    csrr    t4, mcycle
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
    sub     a0, t4, t0
    ret
