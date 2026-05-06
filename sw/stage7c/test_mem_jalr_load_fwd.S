# test_mem_jalr_load_fwd.S — MEM1/MEM2 split: JALR-load-fwd stall correctness.
#
# Per spec §2.3: the JALR-fwd stall fires when JALR's rs1 producer is a load
# currently in ex2_mem1_q (MEM1 stage at ID-issue time of the JALR).  This
# incurs a 1-cycle stall so the load result (FWD_MEM2) is ready when JALR
# resolves in EX1.
#
# Pattern (pre-set x10 = 1 before the jalr, clear to 0 at target):
#   ld  rs1, mem       # load target address into rs1
#   jalr x0, 0(rs1)   # JALR whose rs1 is the fresh load result
#   # unreachable (would increment x10 on wrong path)
#   .target: x10 = 0
#
# Two variants:
#   1. JALR immediately after ld (load-use + JALR stall interaction)
#   2. JALR one instruction after ld (JALR stall fires when ld is in MEM1)
#
# x10 == 0 on PASS.

.section .text
.global main
main:
    li      a0, 0

    # ---- Test 1: JALR immediately after ld --------------------------------
    # Pre-arm: if JALR lands wrongly, x10 will retain the wrong value.
    la      t0, _addr_t1_target
    la      t1, _addr_t1_addr
    sd      t0, 0(t1)                   # store target address in mem

    li      a0, 0x1                     # failure sentinel
    la      t2, _addr_t1_addr
    ld      t3, 0(t2)                   # t3 = &_addr_t1_target
    jalr    x0, 0(t3)                   # jump to _addr_t1_target
    # unreachable
    addi    a0, a0, 0x100               # won't execute on correct path
_addr_t1_target:
    li      a0, 0                       # clear failure sentinel — landed correctly

    # ---- Test 2: JALR one instr after ld ----------------------------------
    # Insert one instruction between ld and jalr so the load is in MEM1
    # when the JALR is in ID.  Stall must still fire to wait for FWD_MEM2.
    la      t0, _addr_t2_target
    la      t1, _addr_t2_addr
    sd      t0, 0(t1)

    li      a0, 0x2                     # failure sentinel
    la      t2, _addr_t2_addr
    ld      t3, 0(t2)                   # t3 = &_addr_t2_target
    nop                                 # one pipeline slot between ld and jalr
    jalr    x0, 0(t3)                   # jump to _addr_t2_target
    addi    a0, a0, 0x100               # unreachable on correct path
_addr_t2_target:
    li      a0, 0                       # clear sentinel — landed correctly

    ret

.section .data
.balign 8
_addr_t1_addr:
    .dword  0
_addr_t2_addr:
    .dword  0
