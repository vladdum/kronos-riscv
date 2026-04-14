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
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>

// 256 KB memory (byte-addressable, word-aligned access)
static uint32_t mem[65536];

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
                uint32_t wi = (full_addr/4) & 0xFFFF, bo = full_addr%4;
                mem[wi] = (mem[wi] & ~(0xFFu << (bo*8))) | ((uint32_t)byte << (bo*8));
                full_addr++;
            }
        }
    }
    fclose(f);
}

// -------------------------------------------------------------------------
// AXI4 single-outstanding read channel state
// -------------------------------------------------------------------------
struct AxiRead {
    bool     pending  = false;
    uint32_t data     = 0;    // pre-fetched at AR time
    int      fire_at  = -1;   // cycle when r_valid should be driven
};

// -------------------------------------------------------------------------
// AXI4 single-outstanding write channel state
// -------------------------------------------------------------------------
struct AxiWrite {
    bool     aw_done   = false;
    bool     w_done    = false;
    uint32_t addr      = 0;
    uint32_t wdata     = 0;
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

    // Initialise all inputs
    top->clk_i           = 0;
    top->rst_ni          = 0;
    top->boot_addr_i     = 0x00000000;
    top->irq_timer_i     = 0;
    top->irq_fast_i      = 0;
    top->instr_ar_ready_i = 0;
    top->instr_r_valid_i  = 0;
    top->instr_r_data_i   = 0;
    top->data_ar_ready_i  = 0;
    top->data_r_valid_i   = 0;
    top->data_r_data_i    = 0;
    top->data_aw_ready_i  = 0;
    top->data_w_ready_i   = 0;
    top->data_b_valid_i   = 0;

    // Hold reset for 4 cycles
    for (int i = 0; i < 8; i++) { top->clk_i = !top->clk_i; top->eval(); }
    top->rst_ni = 1;
    top->eval();

    AxiRead  instr_r, data_r;
    AxiWrite data_w;

    const int MAX_CYCLES = 500000;
    int halted = 0;
    // irq_countdown: cycles remaining for irq_timer_i to stay asserted.
    // Held for INSTR_LAT*4 + DATA_LAT + 4 cycles so the pipeline can take the
    // interrupt even if instr_fetch_stall is blocking when irq_timer_i first fires.
    int irq_countdown = 0;
    const int IRQ_HOLD = INSTR_LAT * 4 + DATA_LAT + 4;

    for (int cycle = 0; cycle < MAX_CYCLES && !halted; cycle++) {

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

        // R response — instr
        if (instr_r.pending && cycle >= instr_r.fire_at) {
            top->instr_r_valid_i = 1;
            top->instr_r_data_i  = instr_r.data;
        } else {
            top->instr_r_valid_i = 0;
            top->instr_r_data_i  = 0;
        }

        // R response — data
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
        // Handshakes are sampled from the pre-clock combinatorial state. After the
        // rising edge, FSM state updates (e.g. FETCH_IDLE→FETCH_WAIT_R) deassert
        // ar_valid, making post-clock detection miss accepted transactions.
        top->eval();

        // ---- Detect handshakes from pre-clock combinatorial state ----

        // Instr AR handshake
        if (top->instr_ar_valid_o && top->instr_ar_ready_i) {
            if (instr_r.pending) {
                fprintf(stderr, "[AXI] FATAL: duplicate instr AR at cycle %d (addr=0x%08x)\n",
                        cycle, (unsigned)top->instr_ar_addr_o);
                return 1;
            }
            uint32_t wa = (top->instr_ar_addr_o >> 2) & 0xFFFF;
            instr_r.pending = true;
            instr_r.data    = mem[wa];
            instr_r.fire_at = cycle + INSTR_LAT;
        }

        // Instr R handshake complete
        if (top->instr_r_valid_i && top->instr_r_ready_o) {
            instr_r.pending = false;
        }

        // Data AR handshake
        if (top->data_ar_valid_o && top->data_ar_ready_i) {
            if (data_r.pending) {
                fprintf(stderr, "[AXI] FATAL: duplicate data AR at cycle %d\n", cycle);
                return 1;
            }
            uint32_t wa = (top->data_ar_addr_o >> 2) & 0xFFFF;
            data_r.pending = true;
            data_r.data    = mem[wa];
            data_r.fire_at = cycle + DATA_LAT;
        }

        // Data R handshake complete
        if (top->data_r_valid_i && top->data_r_ready_o) {
            data_r.pending = false;
        }

        // Data AW handshake
        if (top->data_aw_valid_o && top->data_aw_ready_i) {
            data_w.addr    = top->data_aw_addr_o;
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
            uint32_t wdat  = data_w.wdata;
            uint8_t  be    = data_w.wstrb;

            if (waddr == 0x80000000u) {
                // Timer IRQ trigger — fire one cycle after B handshake completes
                // so the pipeline is not mem-stalled when irq_timer_i asserts.
                data_w.irq_write = true;
            } else if ((waddr & 0xC0000000u) == 0x40000000u) {
                // Halt
                printf("[sim] halt at cycle %d, x10 = %u\n", cycle, wdat);
                halted = 1;
            } else {
                uint32_t wi  = (waddr >> 2) & 0xFFFF;
                uint32_t cur = mem[wi];
                if (be & 1) cur = (cur & ~0x000000FFu) | (wdat & 0x000000FFu);
                if (be & 2) cur = (cur & ~0x0000FF00u) | (wdat & 0x0000FF00u);
                if (be & 4) cur = (cur & ~0x00FF0000u) | (wdat & 0x00FF0000u);
                if (be & 8) cur = (cur & ~0xFF000000u) | (wdat & 0xFF000000u);
                mem[wi] = cur;
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

        if (halted) break;

        // ---- Rising edge ----
        top->clk_i = 1;
        top->eval();

        // ---- Falling edge ----
        top->clk_i = 0;
        top->eval();
    }

    if (!halted) {
        fprintf(stderr, "[sim] TIMEOUT after %d cycles\n", MAX_CYCLES);
    }

    top->final();
    delete top;
    return halted ? 0 : 1;
}
