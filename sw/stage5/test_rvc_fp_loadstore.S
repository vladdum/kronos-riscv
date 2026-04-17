// RVC FP load/store decode test (C.FLD, C.FSD, C.FLDSP, C.FSDSP).
// Verifies the compressed FP load/store opcodes route through OP-LOAD-FP /
// OP-STORE-FP and land in the FP regfile, not the integer regfile.
//
// Each opcode is exercised twice: once at offset 0, and once at the maximum
// legal non-zero offset, so any bit-shuffling error in the immediate decode
// (for example uimm[7:3] / uimm[8:3] field ordering) would mis-address the
// access and fail. Maximum offsets:
//   C.FLD / C.FSD     (CL/CS, 5-bit imm, *8) -> 248 (0xF8)
//   C.FLDSP / C.FSDSP (CI/CSS, 6-bit imm, *8) -> 504 (0x1F8)
//
// a0 accumulates failure count; a0=0 means pass. There are 8 sub-tests, so
// the worst-case failure count is 8.

.section .data
.balign 8
val_a:      .dword 0x4012345678ABCDEF   // sub-test 1 / 2 source pattern
            .zero  240                  // pad so val_a + 248 is in-bounds
val_a_far:  .dword 0xC0FFEE0BADBEEF42   // sub-test 1b source pattern (val_a+248)
slot_b:     .dword 0                    // sub-test 2 store target
            .zero  240                  // pad so slot_b + 248 is in-bounds
slot_b_far: .dword 0                    // sub-test 2b store target (slot_b+248)

.section .text
.globl main

main:
    li      a0, 0

    // ---- Test 1a: C.FLD (Q0 funct3=001), offset 0 ----
    la      a1, val_a
    c.fld   fs0, 0(a1)
    fmv.x.d t0, fs0
    li      t1, 0x4012345678ABCDEF
    beq     t0, t1, 1f
    addi    a0, a0, 1
1:

    // ---- Test 1b: C.FLD, offset 248 (max non-zero CL imm) ----
    la      a1, val_a
    c.fld   fs0, 248(a1)
    fmv.x.d t0, fs0
    li      t1, 0xC0FFEE0BADBEEF42
    beq     t0, t1, 1002f
    addi    a0, a0, 2
1002:

    // ---- Test 2a: C.FSD (Q0 funct3=101), offset 0 ----
    // Reload the original pattern into fs0 from val_a, then store it.
    la      a1, val_a
    c.fld   fs0, 0(a1)
    la      a1, slot_b
    c.fsd   fs0, 0(a1)
    ld      t0, 0(a1)
    li      t1, 0x4012345678ABCDEF
    beq     t0, t1, 2f
    addi    a0, a0, 4
2:

    // ---- Test 2b: C.FSD, offset 248 ----
    // fs0 still holds 0x4012345678ABCDEF from above.
    la      a1, slot_b
    c.fsd   fs0, 248(a1)
    ld      t0, 248(a1)
    li      t1, 0x4012345678ABCDEF
    beq     t0, t1, 2002f
    addi    a0, a0, 8
2002:

    // ---- Test 3a: C.FLDSP (Q2 funct3=001), offset 0 ----
    // Allocate enough stack space for the 504-byte sub-test 3b/4b too.
    addi    sp, sp, -512
    li      t0, 0x3FF0000000000000
    sd      t0, 0(sp)
    c.fldsp fs1, 0(sp)
    fmv.x.d t1, fs1
    li      t2, 0x3FF0000000000000
    beq     t1, t2, 3f
    addi    a0, a0, 16
3:

    // ---- Test 3b: C.FLDSP, offset 504 (max non-zero CI imm) ----
    li      t0, 0xDEADBEEFCAFEBABE
    sd      t0, 504(sp)
    c.fldsp fs1, 504(sp)
    fmv.x.d t1, fs1
    li      t2, 0xDEADBEEFCAFEBABE
    beq     t1, t2, 3002f
    addi    a0, a0, 32
3002:

    // ---- Test 4a: C.FSDSP (Q2 funct3=101), offset 8 ----
    // fs1 currently holds 0xDEADBEEFCAFEBABE; reload the 1.0 pattern first.
    li      t0, 0x3FF0000000000000
    sd      t0, 0(sp)
    c.fldsp fs1, 0(sp)
    c.fsdsp fs1, 8(sp)
    ld      t0, 8(sp)
    li      t1, 0x3FF0000000000000
    beq     t0, t1, 4f
    addi    a0, a0, 64
4:

    // ---- Test 4b: C.FSDSP, offset 504 ----
    // Load a distinct pattern into fs1, then store it via C.FSDSP at sp+504.
    li      t0, 0x0123456789ABCDEF
    sd      t0, 0(sp)
    c.fldsp fs1, 0(sp)
    // Pre-poison the destination so a no-op store would fail the check.
    sd      zero, 504(sp)
    c.fsdsp fs1, 504(sp)
    ld      t0, 504(sp)
    li      t1, 0x0123456789ABCDEF
    beq     t0, t1, 4002f
    addi    a0, a0, 128
4002:
    addi    sp, sp, 512

    ret
