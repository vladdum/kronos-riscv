# bench_overhead.S — pure loop-tail cost (decrement + taken branch), N=100.
#
# Every other bench in this directory wraps its measured body in the same
# 2-instruction loop tail (addi/bnez). This bench measures that tail alone,
# so its total is the baseline subtracted from every other bench's total:
#   cycles/op = (class_total - overhead_total) / 100
#
# a0 (x10) = total cycles for the 100-iteration loop (reported via the
# common.S halt idiom: written to 0x40000000, printed by sim_main.cpp as
# "x10 = <value>").

.section .text
.global main
main:
    csrr    t0, mcycle
    li      t2, 100
1:  addi    t2, t2, -1
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
