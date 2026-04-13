// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "Vkronos_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>

// 256 KB memory (byte-addressable, word-aligned access)
static uint32_t mem[65536];  // 256 KB / 4

static void load_hex(const char* path) {
    std::ifstream f(path);
    if (!f.is_open()) {
        fprintf(stderr, "[sim] ERROR: cannot open %s\n", path);
        return;
    }
    uint32_t addr = 0;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        if (line[0] == '@') {
            addr = std::stoul(line.substr(1), nullptr, 16);
        } else {
            for (size_t i = 0; i + 1 < line.size(); i += 2) {
                uint8_t byte = (uint8_t)std::stoul(line.substr(i, 2), nullptr, 16);
                uint32_t word_idx = addr / 4;
                uint32_t byte_off = addr % 4;
                mem[word_idx] = (mem[word_idx] & ~(0xFFu << (byte_off * 8)))
                              | ((uint32_t)byte << (byte_off * 8));
                addr++;
            }
        }
    }
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

    // Initialise all OBI inputs
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

    const int MAX_CYCLES = 100000;
    int halted = 0;

    for (int cycle = 0; cycle < MAX_CYCLES && !halted; cycle++) {
        // Rising edge
        top->clk_i = 1;
        top->eval();

        // Instruction OBI port (read-only, zero-latency)
        if (top->instr_req_o) {
            uint32_t word_addr      = (top->instr_addr_o >> 2) & 0xFFFF;
            top->instr_rdata_i      = mem[word_addr];
            top->instr_gnt_i        = 1;
            top->instr_rvalid_i     = 1;
            top->instr_err_i        = 0;
        } else {
            top->instr_gnt_i        = 0;
            top->instr_rvalid_i     = 0;
        }

        // Data OBI port (read/write, zero-latency)
        if (top->data_req_o) {
            uint32_t word_addr = (top->data_addr_o >> 2) & 0xFFFF;
            if (top->data_we_o) {
                // Store: apply byte enables
                uint32_t be   = top->data_be_o;
                uint32_t wdat = top->data_wdata_o;
                uint32_t cur  = mem[word_addr];
                if (be & 1) cur = (cur & ~0x000000FFu) | (wdat & 0x000000FFu);
                if (be & 2) cur = (cur & ~0x0000FF00u) | (wdat & 0x0000FF00u);
                if (be & 4) cur = (cur & ~0x00FF0000u) | (wdat & 0x00FF0000u);
                if (be & 8) cur = (cur & ~0xFF000000u) | (wdat & 0xFF000000u);
                mem[word_addr] = cur;

                // Halt sentinel: write to 0x40000000
                if ((top->data_addr_o & 0xC0000000u) == 0x40000000u) {
                    printf("[sim] halt at cycle %d, x10 = %u\n",
                           cycle, top->data_wdata_o);
                    halted = 1;
                }
            } else {
                top->data_rdata_i = mem[word_addr];
            }
            top->data_gnt_i    = 1;
            top->data_rvalid_i = 1;
            top->data_err_i    = 0;
        } else {
            top->data_gnt_i    = 0;
            top->data_rvalid_i = 0;
        }

        // Falling edge
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
