# test_load_muldiv_edge.S
# Checks that LOAD followed immediately by MULDIV (no gap) produces correct results.
# a0 (x10) = failure count; common.S halts and reports.
.section .text
.global main
main:
    li   a0, 0

    # Store a known value to the scratch area in RAM.
    # Use s0-s2 (caller-saved is fine; we don't call sub-functions).
    la   s0, scratch
    li   s1, 42
    sw   s1, 0(s0)       # scratch = 42

    # LOAD immediately followed by MUL (no gap instruction)
    lw   s1, 0(s0)       # s1 = 42
    mul  s2, s1, s1      # s2 = 42 * 42 = 1764

    li   a1, 1764
    bne  s2, a1, fail

    # LOAD followed by DIV (worst case: multi-cycle)
    lw   s1, 0(s0)       # s1 = 42
    div  s2, s1, s1      # s2 = 1
    li   a1, 1
    bne  s2, a1, fail

    li   a0, 0
    ret
fail:
    li   a0, 1
    ret

.section .data
scratch: .word 0
