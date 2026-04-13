// riscv_test.h — kronos target environment for riscv-tests rv32ui
// test_macros.h defines TEST_PASSFAIL in terms of RVTEST_PASS and RVTEST_FAIL;
// TEST_DATA and TEST_PASSFAIL themselves must NOT be defined here.
// Halt convention: sw TESTNUM, 0(t0) where t0=0x40000000.
//   x10=0 → PASS,  x10=N → test case N failed.

#ifndef RISCV_TEST_H
#define RISCV_TEST_H

#define RVTEST_RV32U
#define RVTEST_RV64U RVTEST_RV32U

// Register used by TEST_CASE macros to hold the current test number.
#define TESTNUM x28

// Code section preamble.
#define RVTEST_CODE_BEGIN         \
  .section .text.start;           \
  .global _start;                 \
_start:                           \
  la   sp, _stack_top;

#define RVTEST_CODE_END

// RVTEST_PASS: all tests passed — write 0 to halt address and spin.
#define RVTEST_PASS               \
  li   t0, 0x40000000;            \
  sw   zero, 0(t0);               \
  j    .;

// RVTEST_FAIL: a test failed — TESTNUM holds the failing test number.
#define RVTEST_FAIL               \
  li   t0, 0x40000000;            \
  sw   TESTNUM, 0(t0);            \
  j    .;

// Data section markers.
#define RVTEST_DATA_BEGIN  .align 4; begin_signature:
#define RVTEST_DATA_END    end_signature:

#endif // RISCV_TEST_H
