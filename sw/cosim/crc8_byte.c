// crc8_byte.c — CRC-8 over a stack buffer.
// MUTATE: n_bytes = randint(2, 32)
#include <stdint.h>
#define MMIO 0x10000000UL
#define PUT(c) (*((volatile uint32_t*)MMIO) = (uint8_t)(c))

static uint8_t crc8(const uint8_t *p, int n) {
  uint8_t c = 0xFF;
  for (int i = 0; i < n; i++) {
    c ^= p[i];
    for (int b = 0; b < 8; b++) c = (c & 0x80) ? (uint8_t)((c << 1) ^ 0x07) : (uint8_t)(c << 1);
  }
  return c;
}

int cosim_main(void) {
  uint8_t buf[16] = {1,2,3,4,5,6,7,8,0,0,0,0,0,0,0,0};
  PUT(crc8(buf, 8));
  return 0;
}
