// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// sim_main.cpp — AXI4 memory model for kronos stage3+ simulation.
// Targets Vsim_top (flat AXI4 ports unpacked by sim_top.sv).
//
// Usage: sim <hex_file> [instr_latency] [data_latency]
//   instr_latency: cycles from AR accepted to R valid (default 1)
//   data_latency:  cycles from AW+W accepted to B valid / AR to R valid (default 1)

#include "Vsim_top.h"
#include "Vsim_top___024root.h"
#include "verilated.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif
#include <cstdio>
#include <cstring>
#include <cstdlib>

// 2 MB memory (byte-addressable, word-aligned access). ACT4 FMA tests carry
// multi-hundred-KB .data tables (FP edge-case vectors), so 256 KB wraps and
// corrupts the reset vector. 2 MB comfortably holds every current test.
static uint32_t mem[524288]; // 524288 words = 2 MB

// Parse Intel HEX format (unchanged from stage2)
static void load_hex(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) { fprintf(stderr, "[sim] ERROR: cannot open %s\n", path); return; }
    char line[1024];
    uint32_t base_addr = 0;
    while (fgets(line, sizeof(line), f)) {
        if (line[0] != ':') continue;
        unsigned byte_count = 0, addr16 = 0, rec_type = 0;
        sscanf(line + 1, "%02x%04x%02x", &byte_count, &addr16, &rec_type);
        if (rec_type == 0x01) break;
        if (rec_type == 0x04) { unsigned ext = 0; sscanf(line+9,"%04x",&ext); base_addr=(uint32_t)ext<<16; }
        else if (rec_type == 0x02) { unsigned ext=0; sscanf(line+9,"%04x",&ext); base_addr=(uint32_t)ext<<4; }
        else if (rec_type == 0x00) {
            uint32_t full_addr = base_addr + addr16;
            for (unsigned i = 0; i < byte_count; i++) {
                unsigned byte = 0; sscanf(line + 9 + i*2, "%02x", &byte);
                uint32_t wi = (full_addr/4) & 0x7FFFF, bo = full_addr%4;
                mem[wi] = (mem[wi] & ~(0xFFu << (bo*8))) | ((uint32_t)byte << (bo*8));
                full_addr++;
            }
        }
    }
    fclose(f);
}

// -------------------------------------------------------------------------
// AXI4 read channel state — supports single-beat and multi-beat bursts.
// beat counts from 0 to len (inclusive), giving len+1 beats total.
// -------------------------------------------------------------------------
struct AxiRead {
    bool     pending   = false;
    uint64_t base_addr = 0;   // AR address (first beat)
    uint8_t  burst     = 0;   // 2'b01=INCR, 2'b10=WRAP
    uint8_t  len       = 0;   // ar_len: number of beats minus one
    uint8_t  beat      = 0;   // current beat index (0..len)
    int      fire_at   = -1;  // cycle when r_valid should first be driven
    // Legacy single-beat field kept for data port (no burst needed there yet).
    uint64_t data      = 0;
};

// -------------------------------------------------------------------------
// AXI4 single-outstanding write channel state
// -------------------------------------------------------------------------
struct AxiWrite {
    bool     aw_done   = false;
    bool     w_done    = false;
    uint32_t addr      = 0;
    uint64_t wdata     = 0;
    uint8_t  wstrb     = 0;
    int      fire_at   = -1;   // cycle when b_valid should be driven
    bool     b_pending = false;
    bool     irq_write = false; // fire irq_timer_i one cycle after B handshake
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "Usage: sim <hex_file> [instr_lat] [data_lat]\n"); return 1; }

    int INSTR_LAT = (argc >= 3) ? atoi(argv[2]) : 1;
    int DATA_LAT  = (argc >= 4) ? atoi(argv[3]) : 1;

    memset(mem, 0, sizeof(mem));
    load_hex(argv[1]);

    Vsim_top* top = new Vsim_top;

#if VM_TRACE
    VerilatedVcdC* vcd = nullptr;
    uint32_t vcd_lo = 0, vcd_hi = 0xFFFFFFFFu;
    const char* vcd_path = getenv("SIM_VCD");
    const char* vcd_range = getenv("SIM_VCD_CYCLES");
    if (vcd_path) {
        if (vcd_range) {
            unsigned lo = 0, hi = 0;
            if (sscanf(vcd_range, "%u-%u", &lo, &hi) == 2) {
                vcd_lo = lo; vcd_hi = hi;
            }
        }
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC;
        top->trace(vcd, 99);
        vcd->open(vcd_path);
    }
#endif

    // -------------------------------------------------------------------
    // Retire trace (Sail diff harness). Gated by SIM_TRACE=<path>.
    // One line per retired instruction in the normalized format:
    //   <pc>:<instr> [x<n>=<hex>] [f<n>=<hex>] [mem[<addr>]=<hex>]
    //     [mem_rd[<addr>]=<hex>] [csr[<addr>]=<hex>]
    // -------------------------------------------------------------------
    FILE* trace_fp = nullptr;
    const char* trace_path = getenv("SIM_TRACE");
    if (trace_path) {
        trace_fp = fopen(trace_path, "w");
        if (!trace_fp) {
            fprintf(stderr, "[sim] ERROR: cannot open SIM_TRACE=%s\n", trace_path);
            return 1;
        }
    }

    // Initialise all inputs
    top->clk_i           = 0;
    top->rst_ni          = 0;
    top->boot_addr_i     = 0x00000000;
    top->irq_timer_i     = 0;
    top->irq_fast_i      = 0;
    top->instr_ar_ready_i = 0;
    top->instr_r_valid_i  = 0;
    top->instr_r_data_i   = 0;
    top->instr_r_last_i   = 0;
    top->data_ar_ready_i  = 0;
    top->data_r_valid_i   = 0;
    top->data_r_data_i    = 0;
    top->data_aw_ready_i  = 0;
    top->data_w_ready_i   = 0;
    top->data_b_valid_i   = 0;
    // Note: data widths are now 64-bit; C++ types are updated accordingly.

    // Hold reset for 4 cycles
    for (int i = 0; i < 8; i++) { top->clk_i = !top->clk_i; top->eval(); }
    top->rst_ni = 1;
    top->eval();

    AxiRead  instr_r, data_r;
    AxiWrite data_w;

    int MAX_CYCLES = 20000000;
    const char* max_env = getenv("SIM_MAX_CYCLES");
    if (max_env) MAX_CYCLES = atoi(max_env);
    int halted = 0;
    int halt_drain = 0;  // cycles left to drain after halt (lets mem_stall clear)
    uint32_t halt_x10 = 0;
    // irq_countdown: cycles remaining for irq_timer_i to stay asserted.
    // Held for INSTR_LAT*4 + DATA_LAT + 4 cycles so the pipeline can take the
    // interrupt even if instr_fetch_stall is blocking when irq_timer_i first fires.
    int irq_countdown = 0;
    const int IRQ_HOLD = INSTR_LAT * 4 + DATA_LAT + 4;

    bool debug = (getenv("SIM_DEBUG") != nullptr);
    uint32_t dbg_pc_lo = 0, dbg_pc_hi = 0xFFFFFFFFu;
    const char* pc_range_env = getenv("SIM_PC_RANGE");
    if (pc_range_env) {
        unsigned lo = 0, hi = 0;
        if (sscanf(pc_range_env, "%x-%x", &lo, &hi) == 2) {
            dbg_pc_lo = lo; dbg_pc_hi = hi;
        }
    }

    for (int cycle = 0; cycle < MAX_CYCLES; cycle++) {

        // ---- Drive IRQ ----
        top->irq_timer_i = (irq_countdown > 0) ? 1 : 0;
        if (irq_countdown > 0) irq_countdown--;

        // ---- Set slave inputs for this cycle (before rising edge) ----

        // AR channels: always ready to accept (assert fatal if already in flight)
        top->instr_ar_ready_i = 1;
        top->data_ar_ready_i  = 1;

        // AW/W channels: always ready
        top->data_aw_ready_i = 1;
        top->data_w_ready_i  = 1;

        // R response — instr (multi-beat burst support: INCR and WRAP)
        if (instr_r.pending && cycle >= instr_r.fire_at) {
            uint64_t addr = instr_r.base_addr;
            if (instr_r.burst == 0x1) {
                // INCR: linear advance by 8 bytes per beat.
                addr += (uint64_t)instr_r.beat * 8;
            } else if (instr_r.burst == 0x2) {
                // WRAP: wrap within a power-of-two aligned line.
                // line_size = (len+1) * 8 bytes.
                uint64_t line_size = ((uint64_t)instr_r.len + 1) * 8;
                uint64_t line_mask = line_size - 1;
                uint64_t line_base = addr & ~line_mask;
                uint64_t off       = ((addr & line_mask) + (uint64_t)instr_r.beat * 8) & line_mask;
                addr = line_base | off;
            }
            // Fetch the 64-bit beat (two consecutive 32-bit words, little-endian).
            uint32_t wa    = ((uint32_t)(addr >> 2)) & 0x7FFFF;
            uint32_t wa_hi = (wa + 1) & 0x7FFFF;
            uint64_t beat_data = (uint64_t)mem[wa] | ((uint64_t)mem[wa_hi] << 32);
            top->instr_r_valid_i = 1;
            top->instr_r_data_i  = beat_data;
            top->instr_r_last_i  = (instr_r.beat == instr_r.len) ? 1 : 0;
        } else {
            top->instr_r_valid_i = 0;
            top->instr_r_data_i  = 0;
            top->instr_r_last_i  = 0;
        }

        // R response — data (64-bit beat)
        if (data_r.pending && cycle >= data_r.fire_at) {
            top->data_r_valid_i = 1;
            top->data_r_data_i  = data_r.data;
        } else {
            top->data_r_valid_i = 0;
            top->data_r_data_i  = 0;
        }

        // B response
        if (data_w.b_pending && cycle >= data_w.fire_at) {
            top->data_b_valid_i = 1;
        } else {
            top->data_b_valid_i = 0;
        }

        // ---- Evaluate combinatorial outputs BEFORE rising edge ----
        top->eval();

        if (debug) {
            uint32_t pc   = top->rootp->sim_top__DOT__u_top__DOT__pc_q;
            if (pc >= dbg_pc_lo && pc <= dbg_pc_hi) {
            uint8_t  al_v = top->rootp->sim_top__DOT__u_top__DOT__align_instr_valid;
            uint32_t ins  = top->rootp->sim_top__DOT__u_top__DOT__align_instr;
            uint8_t  redir = top->rootp->sim_top__DOT__u_top__DOT__ex_redirect;
            uint32_t epc  = top->rootp->sim_top__DOT__u_top__DOT__ex_pc_next;
#ifdef KRONOS_HAS_FPU
            uint8_t  fov  = top->rootp->sim_top__DOT__u_top__DOT__fpu_out_valid;
            uint8_t  fi   = top->rootp->sim_top__DOT__u_top__DOT__fp_inflight_q;
            uint64_t fres = top->rootp->sim_top__DOT__u_top__DOT__fpu_result;
            uint8_t  fwe  = top->rootp->sim_top__DOT__u_top__DOT__fp_we;
            uint64_t fwd  = top->rootp->sim_top__DOT__u_top__DOT__fp_wd;
            uint8_t  fwa  = top->rootp->sim_top__DOT__u_top__DOT__fp_wa;
            printf("C%05d: pc=%08x al_v=%d ins=%08x redir=%d epc=%08x"
                   " fov=%d fi=%d fres=%016llx fwe=%d fwa=%d fwd=%016llx\n",
                   cycle, pc, al_v, ins, redir, epc,
                   fov, fi, (unsigned long long)fres,
                   fwe, fwa, (unsigned long long)fwd);
#else
            printf("C%05d: pc=%08x al_v=%d ins=%08x redir=%d epc=%08x\n",
                   cycle, pc, al_v, ins, redir, epc);
#endif
            } // end pc range check
        }

        // ---- Detect handshakes from pre-clock combinatorial state ----

        // Instr AR handshake
        if (top->instr_ar_valid_o && top->instr_ar_ready_i) {
            if (instr_r.pending) {
                fprintf(stderr, "[AXI] FATAL: duplicate instr AR at cycle %d (addr=0x%016llx)\n",
                        cycle, (unsigned long long)top->instr_ar_addr_o);
                return 1;
            }
            instr_r.pending   = true;
            instr_r.base_addr = (uint64_t)top->instr_ar_addr_o;
            instr_r.burst     = (uint8_t)top->instr_ar_burst_o;
            instr_r.len       = (uint8_t)top->instr_ar_len_o;
            instr_r.beat      = 0;
            instr_r.fire_at   = cycle + INSTR_LAT;
        }

        // Instr R handshake: advance beat or complete burst
        if (top->instr_r_valid_i && top->instr_r_ready_o) {
            if (instr_r.beat == instr_r.len) {
                instr_r.pending = false;
                instr_r.beat    = 0;
            } else {
                instr_r.beat++;
            }
        }

        // Data AR handshake
        if (top->data_ar_valid_o && top->data_ar_ready_i) {
            if (data_r.pending) {
                fprintf(stderr, "[AXI] FATAL: duplicate data AR at cycle %d\n", cycle);
                return 1;
            }
            // 64-bit beat: two consecutive 32-bit words, little-endian.
            uint32_t wa_lo = (top->data_ar_addr_o >> 2) & 0x7FFFF;
            uint32_t wa_hi = (wa_lo + 1) & 0x7FFFF;
            data_r.pending = true;
            data_r.data    = (uint64_t)mem[wa_lo] | ((uint64_t)mem[wa_hi] << 32);
            data_r.fire_at = cycle + DATA_LAT;
            if (debug) {
                uint64_t addr = top->data_ar_addr_o;
                uint32_t pc = top->rootp->sim_top__DOT__u_top__DOT__pc_q;
                fprintf(stderr, "[MEM] C%05d pc=%08x R  addr=%016llx data=%016llx\n",
                        cycle, pc, (unsigned long long)addr,
                        (unsigned long long)data_r.data);
            }
        }

        // Data R handshake complete
        if (top->data_r_valid_i && top->data_r_ready_o) {
            data_r.pending = false;
        }

        // Data AW handshake
        if (top->data_aw_valid_o && top->data_aw_ready_i) {
            data_w.addr    = (uint32_t)top->data_aw_addr_o;
            data_w.aw_done = true;
        }

        // Data W handshake
        if (top->data_w_valid_o && top->data_w_ready_i) {
            data_w.wdata  = top->data_w_data_o;
            data_w.wstrb  = (uint8_t)top->data_w_strb_o;
            data_w.w_done = true;
        }

        // Both AW and W accepted: commit write and schedule B
        if (data_w.aw_done && data_w.w_done && !data_w.b_pending) {
            uint32_t waddr = data_w.addr;
            uint64_t wdat  = data_w.wdata;
            uint8_t  be    = data_w.wstrb;

            if (waddr == 0x80000000u) {
                // Timer IRQ trigger — fire one cycle after B handshake completes
                // so the pipeline is not mem-stalled when irq_timer_i asserts.
                data_w.irq_write = true;
            } else if (waddr == 0x10000000u) {
                // Console output: use lower 32-bit lane (byte strobes 0-3)
                for (int i = 0; i < 4; i++)
                    if (be & (1u << i))
                        putchar((wdat >> (i * 8)) & 0xFF);
                fflush(stdout);
            } else if ((waddr & 0xC0000000u) == 0x40000000u) {
                // Halt — drain DATA_LAT+1 more cycles so mem_stall can clear and
                // any instruction stalled in mem_wb_q behind the store can retire.
                // x10 is in the lower 32 bits of the 64-bit beat.
                halt_x10 = (uint32_t)(wdat & 0xFFFFFFFFu);
                printf("[sim] halt at cycle %d, x10 = %u\n", cycle, halt_x10);
                halted = 1;
                halt_drain = DATA_LAT + 1;
            } else {
                // Write lower 32-bit word (bytes 0-3)
                uint32_t wi_lo = (waddr >> 2) & 0x7FFFF;
                uint32_t cur_lo = mem[wi_lo];
                if (be & 0x01) cur_lo = (cur_lo & ~0x000000FFu) | (uint32_t)((wdat >>  0) & 0xFFu);
                if (be & 0x02) cur_lo = (cur_lo & ~0x0000FF00u) | (uint32_t)((wdat >>  8) & 0xFFu) <<  8;
                if (be & 0x04) cur_lo = (cur_lo & ~0x00FF0000u) | (uint32_t)((wdat >> 16) & 0xFFu) << 16;
                if (be & 0x08) cur_lo = (cur_lo & ~0xFF000000u) | (uint32_t)((wdat >> 24) & 0xFFu) << 24;
                mem[wi_lo] = cur_lo;
                // Write upper 32-bit word (bytes 4-7)
                uint32_t wi_hi = (wi_lo + 1) & 0x7FFFF;
                uint32_t cur_hi = mem[wi_hi];
                if (be & 0x10) cur_hi = (cur_hi & ~0x000000FFu) | (uint32_t)((wdat >> 32) & 0xFFu);
                if (be & 0x20) cur_hi = (cur_hi & ~0x0000FF00u) | (uint32_t)((wdat >> 40) & 0xFFu) <<  8;
                if (be & 0x40) cur_hi = (cur_hi & ~0x00FF0000u) | (uint32_t)((wdat >> 48) & 0xFFu) << 16;
                if (be & 0x80) cur_hi = (cur_hi & ~0xFF000000u) | (uint32_t)((wdat >> 56) & 0xFFu) << 24;
                mem[wi_hi] = cur_hi;
            }

            data_w.aw_done   = false;
            data_w.w_done    = false;
            data_w.b_pending = true;
            data_w.fire_at   = cycle + DATA_LAT;
        }

        // B handshake complete
        if (top->data_b_valid_i && top->data_b_ready_o) {
            if (data_w.irq_write) {
                irq_countdown = IRQ_HOLD; // assert irq_timer_i from next cycle
                data_w.irq_write = false;
            }
            data_w.b_pending = false;
        }

        // ---- Retire trace (sampled before rising edge) -------------------------
        // retire_valid_o = mem_wb_q.valid & ~combined_stall is combinatorial.
        // Sampling here (after the pre-edge eval, before the rising edge) gives
        // the correct value: combined_stall reflects whether this cycle's WB
        // instruction retires.  Sampling after the rising edge is too late —
        // mem_wb_q has already advanced and combined_stall may have toggled.
        //
        // When halted, we drain halt_drain more cycles so the B response can
        // arrive and state_q can transition to STORE_DONE on the rising edge,
        // clearing mem_stall so the instruction stalled in mem_wb_q can retire.
        if (trace_fp && top->retire_valid_o) {
            // PC + instruction
            fprintf(trace_fp, "%016llx:%08x",
                    (unsigned long long)top->retire_pc_o,
                    (unsigned)top->retire_instr_o);
            if (top->retire_rd_wen_o && top->retire_rd_o != 0) {
                fprintf(trace_fp, " x%u=%016llx",
                        (unsigned)top->retire_rd_o,
                        (unsigned long long)top->retire_rd_wdata_o);
            }
            if (top->retire_fp_wen_o) {
                fprintf(trace_fp, " f%u=%016llx",
                        (unsigned)top->retire_fp_rd_o,
                        (unsigned long long)top->retire_fp_wdata_o);
            }
            if (top->retire_mem_wen_o) {
                fprintf(trace_fp, " mem[%016llx]=%016llx",
                        (unsigned long long)top->retire_mem_addr_o,
                        (unsigned long long)top->retire_mem_wdata_o);
            }
            if (top->retire_csr_wen_o) {
                fprintf(trace_fp, " csr[%03x]=%016llx",
                        (unsigned)top->retire_csr_addr_o,
                        (unsigned long long)top->retire_csr_wdata_o);
            }
            fputc('\n', trace_fp);
        }

        if (halted) {
            if (halt_drain <= 0) break;
            --halt_drain;
        }

        // ---- Rising edge ----
        top->clk_i = 1;
        top->eval();
#if VM_TRACE
        if (vcd && (unsigned)cycle >= vcd_lo && (unsigned)cycle <= vcd_hi) {
            vcd->dump((vluint64_t)cycle * 10);
        }
#endif

        // ---- Falling edge ----
        top->clk_i = 0;
        top->eval();
#if VM_TRACE
        if (vcd && (unsigned)cycle >= vcd_lo && (unsigned)cycle <= vcd_hi) {
            vcd->dump((vluint64_t)cycle * 10 + 5);
        }
#endif
    }

    if (!halted) {
        fprintf(stderr, "[sim] TIMEOUT after %d cycles\n", MAX_CYCLES);
    }

#if VM_TRACE
    if (vcd) { vcd->close(); delete vcd; }
#endif
    if (trace_fp) fclose(trace_fp);
    top->final();
    delete top;
    return (halted && halt_x10 == 0) ? 0 : 1;
}
