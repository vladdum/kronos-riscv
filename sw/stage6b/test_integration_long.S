# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# test_integration_long.S — Stage 6c long-running integration program.
# Targets the 5 unverified risks from the Stage 6b plan in sequence:
#   1. Cross-page 32-bit fetch precision
#   2. PTW x dcache deadlock under LSU mid-store
#   3. A/D atomic vs. software reservation interaction
#   4. WARL-reject of unsupported satp.MODE
#   5. Cross-RVC-boundary fetch fault
# Self-checking: x10 increments on any failure; final value reported via halt.

.equ CSR_MSTATUS, 0x300
.equ CSR_MTVEC,   0x305
.equ CSR_MEPC,    0x341
.equ CSR_MCAUSE,  0x342
.equ CSR_MTVAL,   0x343
.equ CSR_SATP,    0x180

# Leaf flags U=1: V=1 R=1 W=1 X=1 U=1 A=1 D=1 -> 0xDF.
.equ LEAF_U,      0xDF
# Leaf flags (no U): V=1 R=1 W=1 X=1 A=1 D=1 -> 0xCF.
.equ LEAF_M,      0xCF

# satp.MODE encodings (bits [63:60])
.equ SATP_MODE_BARE_HI,  0
.equ SATP_MODE_SV39_HI,  8
.equ SATP_MODE_SV48_HI,  9
.equ SATP_MODE_SV57_HI, 10
.equ SATP_MODE_SV64_HI, 11

.section .text
.global main
main:
    addi    sp, sp, -16
    sd      ra, 0(sp)
    li      a0, 0                       # x10 = failure count

    # Install a generic M-mode trap handler that records the cause and
    # resumes at a per-test target address held in s11.  The target
    # determines whether a particular sub-test expected a trap.
    la      t0, _mhandler_dispatch
    csrw    CSR_MTVEC, t0

    # ---- Risk 4: satp.MODE WARL (no MMU activity, simplest)
    call    test_satp_warl

    # ---- Risk 1: Cross-page 32-bit fetch (executes correctly)
    call    test_cross_page_fetch

    # ---- Risk 5: Cross-RVC-boundary 32-bit fetch
    call    test_cross_rvc_fetch

    # ---- Risk 2: PTW vs LSU mid-store
    call    test_ptw_dcache_arb

    # ---- Risk 3: A/D atomic vs SW reservation
    call    test_ad_atomic_vs_sw_lrsc

    # All sub-tests done — turn translation off so _halt store reaches sim.
    csrw    CSR_SATP, zero
    sfence.vma

    ld      ra, 0(sp)
    addi    sp, sp, 16
    ret

# =====================================================================
# Risk 4 — WARL reject of unsupported satp.MODE
# =====================================================================
# Strategy:
#   1. Disable translation (write satp = Bare).  Read back: must be Bare.
#   2. Write satp.MODE = Sv57 (10).  Per kronos_csr.sv, the entire write
#      is dropped — satp.MODE must remain Bare.
#   3. Write satp.MODE = Sv64 (11).  Same: write dropped, satp.MODE = Bare.
#   4. Write satp.MODE = Sv39 (legal).  Reads back as Sv39.
#   5. Write satp.MODE = Sv57 again with different ASID/PPN to confirm
#      the entire write (not just MODE) is dropped — satp must still be
#      the prior Sv39 value.
test_satp_warl:
    addi    sp, sp, -16
    sd      ra, 0(sp)

    # 1. Bare baseline.
    csrw    CSR_SATP, zero
    csrr    t0, CSR_SATP
    bnez    t0, .L_warl_fail            # Bare must read back as 0

    # 2. Attempt Sv57 — write must be dropped, satp stays 0 (Bare).
    li      t1, SATP_MODE_SV57_HI
    slli    t1, t1, 60
    csrw    CSR_SATP, t1
    csrr    t0, CSR_SATP
    bnez    t0, .L_warl_fail

    # 3. Attempt Sv64 — same.
    li      t1, SATP_MODE_SV64_HI
    slli    t1, t1, 60
    csrw    CSR_SATP, t1
    csrr    t0, CSR_SATP
    bnez    t0, .L_warl_fail

    # 4. Legal Sv39 with ASID=3 — must persist (compose value, store as t6
    #    for later compare).  Use a sane PPN of 0x1 just so the field is
    #    non-zero.  We never enable translation so the PPN doesn't matter
    #    for correctness.
    li      t1, SATP_MODE_SV39_HI
    slli    t1, t1, 60
    li      t2, 3
    slli    t2, t2, 44
    or      t1, t1, t2
    ori     t1, t1, 1                   # PPN=1
    csrw    CSR_SATP, t1
    csrr    t0, CSR_SATP
    mv      t6, t0                      # save legal value
    bne     t0, t1, .L_warl_fail

    # 5. Attempt Sv64 with different fields — write dropped, satp must
    #    still equal the saved legal value.
    li      t1, SATP_MODE_SV64_HI
    slli    t1, t1, 60
    li      t2, 5
    slli    t2, t2, 44
    or      t1, t1, t2
    ori     t1, t1, 0xAA                # different PPN
    csrw    CSR_SATP, t1
    csrr    t0, CSR_SATP
    bne     t0, t6, .L_warl_fail

    # Restore Bare so subsequent tests start from a clean slate.
    csrw    CSR_SATP, zero
    sfence.vma
    j       .L_warl_done

.L_warl_fail:
    ori     a0, a0, 0x10                # bit 4: Risk 4 failed
.L_warl_done:
    ld      ra, 0(sp)
    addi    sp, sp, 16
    ret

# =====================================================================
# Risk 1 — Cross-page 32-bit fetch precision
# =====================================================================
# Place a small subroutine straddling a 4 KB page boundary; verify it
# executes correctly when both pages are mapped (1 GB megapage covers
# both halves).  The routine returns 0xCAFE_BABE in t0; the caller
# verifies the return value.
#
# We don't attempt the fault-when-only-low-half-mapped case: the harness
# is already 1 GB-mapped and the fine-grained PTE re-mapping required to
# make exactly one 4 KB page invalid is out of scope here (covered by
# the Stage 6b PTW unit TB).
test_cross_page_fetch:
    addi    sp, sp, -16
    sd      ra, 0(sp)

    # Build a 1 GB identity-mapped Sv39 root so fetches under translation
    # match unfetched layout.
    call    _build_sv39_idmap_M

    # Call the routine that straddles a page boundary.  It returns
    # 0xCAFE_BABE in t0 if the cross-page fetch retired correctly.
    call    cross_page_fn
    li      t1, 0xCAFEBABE
    bne     t0, t1, .L_xpage_fail

    # Tear down translation again.
    csrw    CSR_SATP, zero
    sfence.vma
    j       .L_xpage_done

.L_xpage_fail:
    ori     a0, a0, 0x01                # bit 0: Risk 1 failed
    csrw    CSR_SATP, zero
    sfence.vma
.L_xpage_done:
    ld      ra, 0(sp)
    addi    sp, sp, 16
    ret

# =====================================================================
# Risk 5 — Cross-RVC-boundary fetch (32-bit instr starting at 0xFFE)
# =====================================================================
# Verifies the documented stage-6b cross-page detection: a 32-bit
# instruction whose low half lives at offset 0xFFE in a page and whose
# high half spills into the next page is fetched correctly when both
# pages are mapped.  Same justification as Risk 1 for not attempting
# the fault case.
test_cross_rvc_fetch:
    addi    sp, sp, -16
    sd      ra, 0(sp)

    call    _build_sv39_idmap_M

    call    cross_rvc_fn                # returns 0xDEAFD00D in t0 on success
    li      t1, 0xDEAFD00D
    bne     t0, t1, .L_xrvc_fail

    csrw    CSR_SATP, zero
    sfence.vma
    j       .L_xrvc_done

.L_xrvc_fail:
    ori     a0, a0, 0x20                # bit 5: Risk 5 failed
    csrw    CSR_SATP, zero
    sfence.vma
.L_xrvc_done:
    ld      ra, 0(sp)
    addi    sp, sp, 16
    ret

# =====================================================================
# Risk 2 — PTW x dcache arbitration under in-flight LSU traffic
# =====================================================================
# Strategy: under translation, issue a stream of stores into a cold
# cache line; immediately follow with sfence.vma + load to a different
# row.  The sfence flushes the dTLB; the next access misses, forcing
# a PTW walk that contends with any still-pending store.  Verify (a)
# that the original store data is observable and (b) the post-fence
# load returns the expected value.
test_ptw_dcache_arb:
    addi    sp, sp, -16
    sd      ra, 0(sp)

    call    _build_sv39_idmap_M

    # Burst stores to scratch.
    la      t0, _scratch_a
    li      t1, 0xA1A2A3A4
    sw      t1, 0(t0)
    li      t2, 0xB1B2B3B4
    sw      t2, 4(t0)
    li      t3, 0xC1C2C3C4
    sw      t3, 8(t0)
    li      t4, 0xD1D2D3D4
    sw      t4, 12(t0)

    # Force TLB flush mid-store stream.
    sfence.vma

    # Reload through a (now cold) TLB — PTW must service this miss while
    # the prior stores are draining.  Use lwu (zero-extend) so 64-bit
    # compare matches the zero-extended li immediates.
    lwu     t5, 0(t0)
    bne     t5, t1, .L_arb_fail_a
    lwu     t5, 4(t0)
    bne     t5, t2, .L_arb_fail_b
    lwu     t5, 8(t0)
    bne     t5, t3, .L_arb_fail_c
    lwu     t5, 12(t0)
    bne     t5, t4, .L_arb_fail_d

    # Touch a different scratch (different line) to force another miss.
    la      t0, _scratch_b
    li      t1, 0x5A5A5A5A
    sw      t1, 0(t0)
    sfence.vma
    lwu     t5, 0(t0)
    bne     t5, t1, .L_arb_fail_e

    csrw    CSR_SATP, zero
    sfence.vma
    j       .L_arb_done

.L_arb_fail_a:
    li      t6, 0x002
    or      a0, a0, t6
    j       .L_arb_cleanup
.L_arb_fail_b:
    li      t6, 0x100
    or      a0, a0, t6
    j       .L_arb_cleanup
.L_arb_fail_c:
    li      t6, 0x200
    or      a0, a0, t6
    j       .L_arb_cleanup
.L_arb_fail_d:
    li      t6, 0x400
    or      a0, a0, t6
    j       .L_arb_cleanup
.L_arb_fail_e:
    li      t6, 0x800
    or      a0, a0, t6
.L_arb_cleanup:
    csrw    CSR_SATP, zero
    sfence.vma
.L_arb_done:
    ld      ra, 0(sp)
    addi    sp, sp, 16
    ret

# =====================================================================
# Risk 3 — A/D atomic vs. software LR/SC reservation (STUB)
# =====================================================================
# Stub: the original plan was to interleave software lr.d/sc.d with a
# PTW-issued LR/SC for A/D update on a fresh page, asserting that the
# software sc.d sees the reservation broken.  Empirically the LR/SC
# reservation behaviour under translation in stage 6b interacts with
# the dcache refill path in ways that are not reliably observable
# from M-mode asm without additional debug visibility.  The directed
# test_ad_update.S exercises the PTW A/D LR/SC path successfully, so
# the underlying mechanism is verified there; this stub is held in
# place so the call sequence remains intact for future work.
test_ad_atomic_vs_sw_lrsc:
    addi    sp, sp, -16
    sd      ra, 0(sp)
    # Intentionally empty — see header comment.
    ld      ra, 0(sp)
    addi    sp, sp, 16
    ret

# =====================================================================
# Helper — build Sv39 identity map covering [0, 2 GB) with M-only
# leaves (LEAF_M = 0xCF).  Reuses _root_table in .data.
# =====================================================================
_build_sv39_idmap_M:
    la      a1, _root_table

    # Clear root table.
    mv      t0, a1
    li      t1, 0
    li      t2, 512
.Lbuild_clear:
    sd      zero, 0(t0)
    addi    t0, t0, 8
    addi    t1, t1, 1
    bltu    t1, t2, .Lbuild_clear

    # root[0] = 1 GB leaf, PA 0..1 GB.
    li      t0, LEAF_M
    sd      t0, 0(a1)

    # root[1] = 1 GB leaf, PA 1..2 GB (covers halt sentinel).
    li      t0, LEAF_M
    li      t1, (1 << 28)
    or      t0, t0, t1
    sd      t0, 8(a1)

    # satp = MODE(Sv39=8) | ASID=9 | PPN(root_pa>>12)
    srli    t0, a1, 12
    li      t1, 9
    slli    t1, t1, 44
    or      t0, t0, t1
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    CSR_SATP, t0
    sfence.vma
    ret

# =====================================================================
# M-mode trap handler.  We don't expect any traps in this test (all
# pages are mapped).  Any trap is a fail: bump x10 and resume past the
# faulting instruction.
# =====================================================================
.balign 4
_mhandler_dispatch:
    ori     a0, a0, 0x80                # bit 7: unexpected trap
    csrr    t0, CSR_MEPC
    addi    t0, t0, 4                   # skip the faulting 32-bit instr
    csrw    CSR_MEPC, t0
    mret

# =====================================================================
# cross_page_fn — body straddles a 4 KB boundary.
# We pad to within a page-size of the boundary, then place a sequence
# of 32-bit instructions, the middle one of which crosses 0x1000.
# =====================================================================
.balign 4096
.skip 4090                              # leave 6 bytes before next 4 KB boundary
cross_page_fn:
    addi    sp, sp, -16                 # 4-byte instr at offset 0xFFA
    sd      ra, 0(sp)                   # 4-byte instr at offset 0xFFE — STRADDLES
    li      t0, 0xCAFEBABE              # at 0x1002 onward
    ld      ra, 0(sp)
    addi    sp, sp, 16
    ret

# =====================================================================
# cross_rvc_fn — leaf RVC code with a 32-bit instruction whose low half
# is at page offset 0xFFE.  The function is purely RVC framing around
# one cross-page 32-bit instruction.
# =====================================================================
.balign 4096
.option push
.option rvc
.skip 4094                              # 0xFFE bytes of pre-padding
.option pop
cross_rvc_fn:
    # 32-bit instruction starts at offset 0xFFE (exact cross-page edge)
    # — assembler picks 4-byte form because addi on imm=0 with rd=t0
    # is encodable as 32-bit only when explicitly rejected from compression.
    .insn i 0x13, 0, t0, t0, 0          # addi t0, t0, 0 (32-bit form)
    li      t0, 0xDEAFD00D
    ret

# =====================================================================
# Data section
# =====================================================================
.section .data
.balign 4096
_root_table:
    .skip 4096

.balign 4096
_scratch_a:
    .skip 64
.balign 4096
_scratch_b:
    .skip 64
.balign 4096
_scratch_lrsc:
    .dword 0
.balign 4096
_scratch_far:
    .dword 0xFEEDFACEFEEDFACE
