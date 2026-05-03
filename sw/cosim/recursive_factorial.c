// recursive_factorial.c — recursion-heavy callee-save reload pattern.
// MUTATE: n = randint(2, 12)
#include <stdint.h>
#define MMIO 0x10000000UL
#define PUT(c) (*((volatile uint32_t*)MMIO) = (uint8_t)(c))

static uint64_t fact(int n) { return (n <= 1) ? 1 : (uint64_t)n * fact(n - 1); }

int cosim_main(void) {
  enum { N = 8 };
  uint64_t v = fact(N);
  PUT((uint8_t)(v       & 0xFF));
  PUT((uint8_t)((v >> 8) & 0xFF));
  return 0;
}
