// fp_stack_spill.c — force FP regfile spills to stack, then reload.
// MUTATE: depth = randint(2, 8)
#include <stdint.h>
#define MMIO 0x10000000UL
#define PUT(c) (*((volatile uint32_t*)MMIO) = (uint8_t)(c))

static double mix(double a, double b, double c, double d, double e,
                  double f, double g, double h) {
  double s = a + b - c * d + e / (f + 1.0) - g + h;
  return s;
}

int cosim_main(void) {
  double r = mix(1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5);
  uint64_t bits;
  __builtin_memcpy(&bits, &r, sizeof(bits));
  PUT((uint8_t)(bits & 0xFF));
  PUT((uint8_t)((bits >> 8) & 0xFF));
  return 0;
}
