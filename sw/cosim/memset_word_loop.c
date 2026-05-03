// memset_word_loop.c — set N words to a pattern, emit XOR.
// MUTATE: n_words = randint(4, 64)
#include <stdint.h>
#define MMIO 0x10000000UL
#define PUT(c) (*((volatile uint32_t*)MMIO) = (uint8_t)(c))

int cosim_main(void) {
  enum { N_WORDS = 16 };
  uint32_t buf[64];
  uint32_t pat = 0xDEADBEEFu;
  for (int i = 0; i < N_WORDS; i++) buf[i] = pat;
  uint32_t x = 0;
  for (int i = 0; i < N_WORDS; i++) x ^= buf[i];
  PUT((uint8_t)(x       & 0xFF));
  PUT((uint8_t)((x >> 8) & 0xFF));
  return 0;
}
