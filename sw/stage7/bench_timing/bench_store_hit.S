# bench_store_hit.S — cycles/instr for a D$-hit integer store (SD),
# repeated to the same address (line stays resident for the whole loop).

.section .data
.balign 8
_st_addr: .dword 0

.section .text
.global main
main:
    la      s3, _st_addr
    li      t1, 0x1234
    sd      t1, 0(s3)          # warm the D$ line before timing
    csrr    t0, mcycle
    li      t2, 100
1:  sd      t1, 0(s3)          # measured body — repeated hit, same address
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
