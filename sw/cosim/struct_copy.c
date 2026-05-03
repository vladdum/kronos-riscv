// struct_copy.c — copy a packed struct field-by-field, emit a checksum.
// MUTATE: a_init = randint(0, 255)
#include <stdint.h>
#define MMIO 0x10000000UL
#define PUT(c) (*((volatile uint32_t*)MMIO) = (uint8_t)(c))

typedef struct { uint8_t a; uint16_t b; uint32_t c; uint64_t d; } pkt_t;

int cosim_main(void) {
  pkt_t s = { .a = 0x55, .b = 0xCAFE, .c = 0xDEADBEEF, .d = 0x1122334455667788ULL };
  pkt_t t;
  t.a = s.a; t.b = s.b; t.c = s.c; t.d = s.d;
  PUT(t.a);
  PUT((uint8_t)(t.b & 0xFF));
  PUT((uint8_t)((t.c >> 24) & 0xFF));
  PUT((uint8_t)(t.d & 0xFF));
  return 0;
}
