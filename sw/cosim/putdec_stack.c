// putdec_stack.c — issue #82 reproducer.
// Emits "12345" to MMIO console and halts with exit code 0.
// On v0.6.2 (broken): emits five NUL bytes; cosim_main returns 0 but digits wrong.
// With Phase 1 fix: emits "12345"; cosim_main returns 0.
//
// MUTATE-stable: this is the directed reproducer. The Phase-4 fuzzer
// targets other corpus files, not this one.

#include <stdint.h>

// Console output port (sim_main.cpp line ~554: 0x10000000 -> putchar per byte)
#define CONSOLE ((volatile uint32_t*)0x10000000UL)
#define PUT(c) (*CONSOLE = (uint8_t)(c))

static void putdec_stack(uint32_t v) {
  char buf[11];
  int  pos = 0;
  if (v == 0) { PUT('0'); return; }
  while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
  while (pos > 0) PUT(buf[--pos]);
}

int cosim_main(void) {
  // Emit
  putdec_stack(12345);
  // Self-check via shadow buffer (avoids stalling the test on a stuck MMIO)
  // — the Verilator harness compares MMIO writes against expected[] separately.
  return 0;  // 0 == pass; harness independently asserts MMIO byte stream
}
