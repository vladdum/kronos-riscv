// bcd_to_binary.c — parse a BCD digit stream from stack and emit binary.
// MUTATE: digits = randint(1, 6)
#include <stdint.h>
#define MMIO 0x10000000UL
#define PUT(c) (*((volatile uint32_t*)MMIO) = (uint8_t)(c))

int cosim_main(void) {
  uint8_t bcd[] = {1, 2, 3, 4, 5};
  uint32_t v = 0;
  for (unsigned i = 0; i < sizeof(bcd); i++) v = v * 10 + bcd[i];
  PUT((uint8_t)(v & 0xFF));
  PUT((uint8_t)((v >> 8) & 0xFF));
  return 0;
}
