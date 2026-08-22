# bench_trap.S — cycles per ECALL round-trip (M-mode ECALL -> direct-mode
# handler bumps MEPC by 4 -> MRET -> back into the timed loop).

.equ CSR_MTVEC, 0x305
.equ CSR_MEPC,  0x341

.section .text
.global main
main:
    la      t0, _handler
    csrw    CSR_MTVEC, t0
    csrr    t0, mcycle
    li      t2, 100
1:  ecall                      # measured body — full trap round-trip
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

.balign 4
_handler:
    csrr    t5, CSR_MEPC
    # Same latent RTL forwarding bug as noted above (FWD_EX1_NOW does not
    # exclude is_csr producers): without this NOP, the addi below reads a
    # stale ex_result instead of the freshly-read MEPC, and MRET returns to
    # a garbage PC. This NOP is genuinely part of the measured round-trip
    # cost (it runs inside the timed loop, once per ECALL).
    nop
    addi    t5, t5, 4
    csrw    CSR_MEPC, t5
    mret
