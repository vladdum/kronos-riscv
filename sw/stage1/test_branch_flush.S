# test_branch_flush.S — control hazard: taken branches and jumps must squash
# the two instructions fetched after them without side-effects.
# If the squash works, the "poison" instructions (which increment a0) never execute.
.section .text
.global main
main:
  li   a0, 0            # failure counter

  # --- BEQ taken: two instructions after BEQ must be squashed ---
  li   t0, 5
  beq  t0, t0, .Lbeq_target    # taken
  addi a0, a0, 1        # MUST NOT execute (squashed)
  addi a0, a0, 1        # MUST NOT execute (squashed)
.Lbeq_target:

  # --- BNE taken ---
  li   t0, 1
  li   t1, 2
  bne  t0, t1, .Lbne_target
  addi a0, a0, 1
  addi a0, a0, 1
.Lbne_target:

  # --- BLT taken ---
  li   t0, -1
  li   t1, 0
  blt  t0, t1, .Lblt_target
  addi a0, a0, 1
  addi a0, a0, 1
.Lblt_target:

  # --- JAL taken ---
  jal  x0, .Ljal_target
  addi a0, a0, 1
  addi a0, a0, 1
.Ljal_target:

  # --- JALR taken: link address test ---
  # Save ra so ret works correctly after JALR clobbers it.
  mv   s0, ra
  la   t0, .Ljalr_target
  jalr ra, t0, 0        # jump to .Ljalr_target; ra = address of next instruction
.Ljalr_next:            # ra must equal this address
  addi a0, a0, 1        # MUST NOT execute (squashed)
  addi a0, a0, 1        # MUST NOT execute (squashed)
.Ljalr_target:
  # verify ra == .Ljalr_next
  la   t1, .Ljalr_next
  bne  ra, t1, 1f
  j    2f
1:addi a0, a0, 1
2:
  mv   ra, s0           # restore return address

  # --- Not-taken branch: next instructions MUST execute ---
  li   t0, 1
  li   t1, 2
  beq  t0, t1, .Lnot_taken_skip  # not taken
  addi t2, x0, 99       # must execute
  j    .Lnot_taken_done
.Lnot_taken_skip:
  addi a0, a0, 1        # should not reach here
.Lnot_taken_done:
  li   t3, 99
  bne  t2, t3, 3f
  j    4f
3:addi a0, a0, 1
4:

  ret
