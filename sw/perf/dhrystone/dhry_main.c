// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Dhrystone 2.1 driver for kronos perf-baseline gate.
// Reads mcycle before/after dhry_run, computes delta, compares to
// BASELINE_CYCLES +/- 2%, returns 0 (PASS) or 1 (FAIL) in a0/x10.
//
// In capture mode (BASELINE_CYCLES == 0) the raw delta is returned as-is
// so T7 can read it from x10 to bake the baseline into this file.
//
// Also provides freestanding stubs for malloc/strcpy/strcmp/memcpy used
// by dhry_1.c / dhry_2.c (the build is -nostdlib -ffreestanding).

#include <stdint.h>

extern int dhry_run(int Number_Of_Runs);

#define NUMBER_OF_RUNS   1000U
// captured 2026-05-06 on stage7b branch @ commit c7f59f8 against the CI
// toolchain (Ubuntu 24.04 apt gcc-riscv64-unknown-elf v13/14, the
// reference for sim-perf-baseline-s6).  Local builds with a different
// riscv64-unknown-elf-gcc version (e.g. v15.x) emit different dhry_run
// code and may report a ~4 % higher cycle count — this is expected and
// only the CI value is authoritative.  Re-bake on any RTL change that
// affects integer IPC by setting BASELINE_CYCLES=0 (capture mode) and
// reading x10 from the CI halt line.
#define BASELINE_CYCLES  904764U  /* s7b @ c7f59f8 (was 992151 = s6i baseline) */
#define TOLERANCE_PCT    2U

// ---------------------------------------------------------------------------
// Freestanding stubs for the libc symbols Dhrystone uses.
// ---------------------------------------------------------------------------

// Bump allocator: Dhrystone calls malloc() exactly twice (Ptr_Glob and
// Next_Ptr_Glob, each sizeof(Rec_Type)). Rec_Type is ~40 bytes; 4 KiB is
// generous and lives in .bss so it costs nothing on disk.
#define HEAP_BYTES 4096U
static unsigned char heap_pool[HEAP_BYTES];
static unsigned long heap_off;

void *malloc(unsigned long size) {
  // 8-byte align
  unsigned long off = (heap_off + 7U) & ~7UL;
  if (off + size > HEAP_BYTES) {
    return (void *)0;
  }
  heap_off = off + size;
  return (void *)&heap_pool[off];
}

char *strcpy(char *dest, const char *src) {
  char *d = dest;
  while ((*d++ = *src++) != '\0') { }
  return dest;
}

int strcmp(const char *s1, const char *s2) {
  while (*s1 && (*s1 == *s2)) {
    s1++;
    s2++;
  }
  return (int)(unsigned char)*s1 - (int)(unsigned char)*s2;
}

// gcc may emit memcpy calls for struct assignments at -O2 even with
// -ffreestanding, so provide a defensive implementation.
void *memcpy(void *dest, const void *src, unsigned long n) {
  unsigned char *d = (unsigned char *)dest;
  const unsigned char *s = (const unsigned char *)src;
  while (n--) {
    *d++ = *s++;
  }
  return dest;
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

static inline uint64_t rdcycle(void) {
  uint64_t v;
  asm volatile ("csrr %0, mcycle" : "=r"(v));
  return v;
}

int main(void) {
  uint64_t start, end, delta, lo, hi;

  start = rdcycle();
  (void)dhry_run(NUMBER_OF_RUNS);
  end   = rdcycle();

  delta = end - start;

  // +/- TOLERANCE_PCT of BASELINE_CYCLES
  lo = BASELINE_CYCLES - (BASELINE_CYCLES * TOLERANCE_PCT) / 100U;
  hi = BASELINE_CYCLES + (BASELINE_CYCLES * TOLERANCE_PCT) / 100U;

  if (BASELINE_CYCLES == 0U) {
    // Capture mode: T7 reads delta from x10 to set the baseline.
    return (int)delta;
  }

  return (delta >= lo && delta <= hi) ? 0 : 1;
}
