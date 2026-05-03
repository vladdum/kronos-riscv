// string_reverse.c — in-place string reverse on stack, emit result.
// MUTATE: pad = randint(0, 8)
#include <stdint.h>
#define MMIO 0x10000000UL
#define PUT(c) (*((volatile uint32_t*)MMIO) = (uint8_t)(c))

int cosim_main(void) {
  char s[16] = "abcdefg";
  int n = 7;
  for (int i = 0, j = n - 1; i < j; i++, j--) {
    char t = s[i]; s[i] = s[j]; s[j] = t;
  }
  for (int i = 0; i < n; i++) PUT(s[i]);
  return 0;
}
