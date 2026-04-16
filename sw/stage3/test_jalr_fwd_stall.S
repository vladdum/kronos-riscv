# test_jalr_fwd_stall.S — verify JALR-forward stall correctness.
# Tests that JALR executes correctly when rs1 is forwarded from MEM/WB
# (the stall converts MEM/WB forward to EX/MEM forward or regfile read).
.section .text
.globl main
main:
    mv   s2, ra
    li   a0, 0          # failure count

    # ---------------------------------------------------------------
    # Test 1: ALU -> gap -> JALR (triggers JALR-fwd stall)
    # Producer (la x5) is 2 instructions ahead of JALR consumer.
    # Without the stall, rs1 would be MEM/WB-forwarded to JALR adder.
    # ---------------------------------------------------------------
    la   x5, t1_target   # producer: writes x5
    addi x6, x0, 42      # spacer (1 instruction gap)
    jalr x1, x5, 0       # consumer: JALR using x5
    j    fail             # should not reach here
    .balign 4
t1_target:
    li   x7, 42
    bne  x6, x7, fail    # verify spacer executed correctly

    # ---------------------------------------------------------------
    # Test 2: ALU -> ALU -> JALR (no stall — EX/MEM forward, not MEM/WB)
    # Producer is immediately before JALR — forwarded via EX/MEM path.
    # ---------------------------------------------------------------
    la   x5, t2_target
    jalr x1, x5, 0
    j    fail
    .balign 4
t2_target:
    nop

    # ---------------------------------------------------------------
    # Test 3: ALU -> gap -> gap -> JALR (no stall — producer already in WB/retired)
    # Producer is 3 instructions ahead: no forwarding needed (regfile read).
    # ---------------------------------------------------------------
    la   x5, t3_target
    addi x6, x0, 1       # gap 1
    addi x7, x0, 2       # gap 2
    jalr x1, x5, 0
    j    fail
    .balign 4
t3_target:
    nop

    # ---------------------------------------------------------------
    # Test 4: JALR with immediate offset (stall case)
    # Same MEM/WB forward pattern but JALR uses a non-zero immediate.
    # ---------------------------------------------------------------
    la   x5, t4_base
    addi x6, x0, 99      # spacer (triggers stall)
    jalr x1, x5, 8       # target = x5 + 8
    j    fail
    .balign 4
t4_base:
    .word 0               # t4_base + 0
    .word 0               # t4_base + 4
    j    t4_ok            # t4_base + 8 — this is the JALR target
    j    fail
t4_ok:
    nop

    # ---------------------------------------------------------------
    # Test 5: LW -> gap -> JALR (load-use fires first, not JALR stall)
    # The load-use stall happens for LW->next_instr; after the bubble,
    # the JALR sees rs1 via EX/MEM forward. Verify correct execution.
    # ---------------------------------------------------------------
    la   x8, addr_holder
    la   x9, t5_target
    sw   x9, 0(x8)       # store target address to memory
    lw   x5, 0(x8)       # load: triggers load-use stall
    addi x6, x0, 0       # spacer (after load-use bubble, x5 available via EX/MEM)
    jalr x1, x5, 0
    j    fail
    .balign 4
t5_target:
    nop

    # All tests passed
    mv   ra, s2
    ret

fail:
    addi a0, a0, 1
    mv   ra, s2
    ret

.section .data
.balign 4
addr_holder: .word 0
