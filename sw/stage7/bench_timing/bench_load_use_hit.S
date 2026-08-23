# bench_load_use_hit.S — cycles/instr for a D$-hit load immediately
# consumed by a dependent ALU op (the load-use hazard, §7). The load can
# occupy any of six producer slots ahead of the consumer; FWD_MEMWB is the
# only load-forwarding path, so this stalls in ID until the load reaches
# mem_wb_q.

.section .data
.balign 8
_ld_addr: .dword 0x1234

.section .text
.global main
main:
    la      s3, _ld_addr
    ld      t5, 0(s3)          # warm the D$ line before timing
    csrr    t0, mcycle
    li      t2, 100
1:  ld      t3, 0(s3)          # measured body — load ...
    addi    t3, t3, 1          # ... immediately consumed (load-use stall)
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
