// bsearch_static.c — binary search in a static const sorted array.
// MUTATE: target = randint(0, 47)
#include <stdint.h>
#define MMIO 0x10000000UL
#define PUT(c) (*((volatile uint32_t*)MMIO) = (uint8_t)(c))

static const uint8_t arr[16] = {1,3,5,7,9,11,13,17,19,23,29,31,37,41,43,47};

int cosim_main(void) {
  enum { TARGET = 31 };
  int lo = 0, hi = 16;
  int idx = -1;
  while (lo < hi) {
    int mid = (lo + hi) >> 1;
    if (arr[mid] == TARGET) { idx = mid; break; }
    if (arr[mid] < TARGET) lo = mid + 1; else hi = mid;
  }
  PUT((uint8_t)(idx & 0xFF));
  return 0;
}
