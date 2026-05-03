// byte_buffer_emit.c — fill a stack buffer byte-by-byte, then emit it
// in reverse — the exact pattern from issue #82.
// MUTATE: n = randint(2, 16)
#include <stdint.h>
#define MMIO 0x10000000UL
#define PUT(c) (*((volatile uint32_t*)MMIO) = (uint8_t)(c))

int cosim_main(void) {
  enum { N = 8 };
  char buf[16];
  for (int i = 0; i < N; i++) buf[i] = '0' + i;
  for (int i = N - 1; i >= 0; i--) PUT(buf[i]);
  return 0;
}
