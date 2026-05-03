// linked_list_traverse.c — build a small linked list on stack, traverse.
// MUTATE: n_nodes = randint(2, 6)
#include <stdint.h>
#define MMIO 0x10000000UL
#define PUT(c) (*((volatile uint32_t*)MMIO) = (uint8_t)(c))

typedef struct node { struct node *next; uint8_t val; } node_t;

int cosim_main(void) {
  node_t a = { 0, 'A' };
  node_t b = { 0, 'B' };
  node_t c = { 0, 'C' };
  node_t d = { 0, 'D' };
  a.next = &b; b.next = &c; c.next = &d;
  for (node_t *p = &a; p; p = p->next) PUT(p->val);
  return 0;
}
