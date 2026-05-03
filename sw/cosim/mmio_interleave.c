// mmio_interleave.c — interleave MMIO writes with cacheable RAM ops.
// MUTATE: n = randint(1, 8)
#include <stdint.h>
#define MMIO 0x10000000UL
#define PUT(c) (*((volatile uint32_t*)MMIO) = (uint8_t)(c))

int cosim_main(void) {
  enum { N = 4 };
  char tmp[16];
  for (int i = 0; i < N; i++) {
    tmp[i] = (char)('A' + i);
    PUT(tmp[i]);
  }
  return 0;
}
