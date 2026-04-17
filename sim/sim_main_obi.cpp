// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// sim_main_obi.cpp — OBI memory model for kronos stage0–2 simulation.
// Targets Vkronos_top (direct OBI ports on kronos_top).
// Restored from git history: this driver was replaced by sim_main.cpp (AXI4)
// when stage3 switched to native AXI4; kept here to allow stage0–2 regression.
//
// Usage: Vkronos_top <hex_file>

#include "Vkronos_top.h"
#include "Vkronos_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>

// 256 KB memory (byte-addressable, word-aligned access)
static uint32_t mem[65536];  // 256 KB / 4

// Parse Intel HEX format (produced by objcopy -O ihex).
// Supports record types:
//   00  Data
//   01  End of File
//   02  Extended Segment Address  (base = ext << 4)
//   04  Extended Linear Address   (base = ext << 16)
static void load_hex(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "[sim] ERROR: cannot open %s\n", path);
        return;
    }
    char line[1024];
    uint32_t base_addr = 0;
    while (fgets(line, sizeof(line), f)) {
        if (line[0] != ':') continue;
        unsigned byte_count = 0, addr16 = 0, rec_type = 0;
        sscanf(line + 1, "%02x%04x%02x", &byte_count, &addr16, &rec_type);
        if (rec_type == 0x01) break; // EOF record
        if (rec_type == 0x04) {      // Extended linear address
            unsigned ext = 0;
            sscanf(line + 9, "%04x", &ext);
            base_addr = (uint32_t)ext << 16;
        } else if (rec_type == 0x02) { // Extended segment address
            unsigned ext = 0;
            sscanf(line + 9, "%04x", &ext);
            base_addr = (uint32_t)ext << 4;
        } else if (rec_type == 0x00) { // Data record
            uint32_t full_addr = base_addr + addr16;
            for (unsigned i = 0; i < byte_count; i++) {
                unsigned byte = 0;
                sscanf(line + 9 + i * 2, "%02x", &byte);
                uint32_t word_idx = (full_addr / 4) & 0xFFFF;
                uint32_t byte_off = full_addr % 4;
                mem[word_idx] = (mem[word_idx] & ~(0xFFu << (byte_off * 8)))
                              | ((uint32_t)byte << (byte_off * 8));
                full_addr++;
            }
        }
    }
    fclose(f);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) {
        fprintf(stderr, "Usage: sim <hex_file>\n");
        return 1;
    }

    memset(mem, 0, sizeof(mem));
    load_hex(argv[1]);

    Vkronos_top* top = new Vkronos_top;
    top->clk_i        = 0;
    top->rst_ni       = 0;
    top->boot_addr_i  = 0x00000000;
    top->irq_timer_i  = 0;
    top->irq_fast_i   = 0;
    top->instr_gnt_i    = 0;
    top->instr_rvalid_i = 0;
    top->instr_rdata_i  = 0;
    top->instr_err_i    = 0;
    top->data_gnt_i     = 0;
    top->data_rvalid_i  = 0;
    top->data_rdata_i   = 0;
    top->data_err_i     = 0;

    // Hold reset for 4 cycles
    for (int i = 0; i < 8; i++) {
        top->clk_i = !top->clk_i;
        top->eval();
    }
    top->rst_ni = 1;
    top->eval();

    auto fetch_instr = [&]() {
        if (top->instr_req_o) {
            uint32_t wa       = (top->instr_addr_o >> 2) & 0xFFFF;
            top->instr_rdata_i  = mem[wa];
            top->instr_gnt_i    = 1;
            top->instr_rvalid_i = 1;
            top->instr_err_i    = 0;
        } else {
            top->instr_gnt_i    = 0;
            top->instr_rvalid_i = 0;
        }
    };

    auto prefetch_data = [&]() {
        top->eval();
        if (top->data_req_o) {
            if (!top->data_we_o) {
                uint32_t wa       = (top->data_addr_o >> 2) & 0xFFFF;
                top->data_rdata_i = mem[wa];
            }
            top->data_gnt_i    = 1;
            top->data_rvalid_i = 1;
            top->data_err_i    = 0;
        } else {
            top->data_gnt_i    = 0;
            top->data_rvalid_i = 0;
            top->data_rdata_i  = 0;
        }
    };

    fetch_instr();
    prefetch_data();

    int MAX_CYCLES = 20000000;
    const char* max_env = getenv("SIM_MAX_CYCLES");
    if (max_env) MAX_CYCLES = atoi(max_env);
    int halted = 0;
    uint32_t halt_x10 = 0;
    bool fire_irq = false;
    bool debug = (getenv("SIM_DEBUG") != nullptr);

    for (int cycle = 0; cycle < MAX_CYCLES && !halted; cycle++) {
        top->irq_timer_i = fire_irq ? 1 : 0;
        if (fire_irq) fire_irq = false;

        top->clk_i = 1;
        top->eval();

        if (debug) {
            uint32_t pc = top->rootp->kronos_top__DOT__pc_q;
            printf("C%06d: pc=%08x instr_addr=%08x\n",
                   cycle, pc, (unsigned)top->instr_addr_o);
        }

        if (top->data_req_o && top->data_we_o) {
            uint32_t be   = top->data_be_o;
            uint32_t wdat = top->data_wdata_o;

            if (top->data_addr_o == 0x80000000u) {
                fire_irq = true;
            } else if (top->data_addr_o == 0x10000000u) {
                for (int i = 0; i < 4; i++)
                    if (be & (1u << i))
                        putchar((wdat >> (i * 8)) & 0xFF);
                fflush(stdout);
            } else if ((top->data_addr_o & 0xC0000000u) == 0x40000000u) {
                halt_x10 = wdat;
                printf("[sim] halt at cycle %d, x10 = %u\n", cycle, wdat);
                halted = 1;
                break;
            } else {
                uint32_t word_addr = (top->data_addr_o >> 2) & 0xFFFF;
                uint32_t cur  = mem[word_addr];
                if (be & 1) cur = (cur & ~0x000000FFu) | (wdat & 0x000000FFu);
                if (be & 2) cur = (cur & ~0x0000FF00u) | (wdat & 0x0000FF00u);
                if (be & 4) cur = (cur & ~0x00FF0000u) | (wdat & 0x00FF0000u);
                if (be & 8) cur = (cur & ~0xFF000000u) | (wdat & 0xFF000000u);
                mem[word_addr] = cur;
            }
        }

        fetch_instr();
        prefetch_data();

        top->clk_i = 0;
        top->eval();
    }

    if (!halted) {
        fprintf(stderr, "[sim] TIMEOUT after %d cycles\n", MAX_CYCLES);
    }

    top->final();
    delete top;
    return (halted && halt_x10 == 0) ? 0 : 1;
}
