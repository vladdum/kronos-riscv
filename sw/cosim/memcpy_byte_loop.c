// memcpy_byte_loop.c — byte-loop memcpy, then emit a CRC of the destination.
// MUTATE: src_pad   = randint(0, 16)
// MUTATE: copy_len  = randint(8, 128)
#include <stdint.h>
#define MMIO 0x10000000UL
#define PUT(c) (*((volatile uint32_t*)MMIO) = (uint8_t)(c))

static const char src[136] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!?<>$%&";

int cosim_main(void) {
  enum { SRC_PAD = 0, COPY_LEN = 64 };
  char dst[160];
  for (int i = 0; i < COPY_LEN; i++) dst[i + SRC_PAD] = src[i];
  uint8_t crc = 0;
  for (int i = 0; i < COPY_LEN; i++) crc ^= dst[i + SRC_PAD];
  PUT(crc);
  return 0;
}
