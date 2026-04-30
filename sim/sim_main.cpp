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
#include <unordered_map>
#include <vector>
#include <algorithm>

// 2 MB memory (byte-addressable, word-aligned access). ACT4 FMA tests carry
// multi-hundred-KB .data tables (FP edge-case vectors), so 256 KB wraps and
// corrupts the reset vector. 2 MB comfortably holds every current test.
static uint32_t mem[524288]; // 524288 words = 2 MB

// MMIO scratch buffer: 16 KB at 0x4001_0000 - 0x4001_3FFF.
// Supports byte-strobed reads/writes for NC PMA bypass tests.
// Index = (addr - 0x40010000) >> 2, masked to 0xFFF (4096 words).
static uint32_t mmio_mem[4096]; // 4096 words = 16 KB
static inline bool is_mmio_scratch(uint32_t addr) {
    return (addr >= 0x40010000u && addr <= 0x40013FFFu);
}

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
};

// -------------------------------------------------------------------------
// AXI4 write channel state — supports multi-beat bursts (INCR).
// Accepts AW and W beats independently; commits writes per W beat.
// B response fires after the last W beat (w_last) is accepted.
// -------------------------------------------------------------------------
struct AxiWrite {
    bool     aw_done   = false;  // AW handshake received
    bool     b_armed   = false;  // W handshake completed this cycle; arm B for next
    bool     b_pending = false;  // B response valid (drives data_b_valid_i)
    bool     irq_write = false;  // fire irq_timer_i one cycle after B handshake
    uint64_t base_addr = 0;      // AW address (first beat)
    uint8_t  beat      = 0;      // current W beat index
};

// Stage 5h B1: minimal disassembler — resolves the common-case opcodes.
// Unknown opcodes return "<unk>:<hex>".  Format-based decode (RISC-V V20191213).
static const char* resolve_mnemonic(uint32_t instr, char* buf, size_t buflen) {
    uint32_t opcode = instr & 0x7F;
    uint32_t funct3 = (instr >> 12) & 0x7;
    uint32_t funct7 = (instr >> 25) & 0x7F;
    switch (opcode) {
        case 0x37: return "lui";
        case 0x17: return "auipc";
        case 0x6F: return "jal";
        case 0x67: return "jalr";
        case 0x63: switch (funct3) {
            case 0: return "beq"; case 1: return "bne";
            case 4: return "blt"; case 5: return "bge";
            case 6: return "bltu"; case 7: return "bgeu"; }
            break;
        case 0x03: switch (funct3) {
            case 0: return "lb"; case 1: return "lh"; case 2: return "lw"; case 3: return "ld";
            case 4: return "lbu"; case 5: return "lhu"; case 6: return "lwu"; }
            break;
        case 0x23: switch (funct3) {
            case 0: return "sb"; case 1: return "sh"; case 2: return "sw"; case 3: return "sd"; }
            break;
        case 0x13: switch (funct3) {
            case 0: return "addi"; case 1: return "slli"; case 2: return "slti"; case 3: return "sltiu";
            case 4: return "xori"; case 5: return (funct7 & 0x40) ? "srai" : "srli";
            case 6: return "ori";  case 7: return "andi"; }
            break;
        case 0x33:
            if (funct7 == 0x01) {
                switch (funct3) {
                    case 0: return "mul"; case 1: return "mulh"; case 2: return "mulhsu"; case 3: return "mulhu";
                    case 4: return "div"; case 5: return "divu"; case 6: return "rem"; case 7: return "remu"; }
            }
            switch (funct3) {
                case 0: return (funct7 & 0x40) ? "sub" : "add";
                case 1: return "sll";
                case 2: return "slt"; case 3: return "sltu";
                case 4: return "xor";
                case 5: return (funct7 & 0x40) ? "sra" : "srl";
                case 6: return "or";  case 7: return "and"; }
            break;
        case 0x1B:  // OP-IMM-32
            switch (funct3) {
                case 0: return "addiw";
                case 1: return "slliw";
                case 5: return (funct7 & 0x40) ? "sraiw" : "srliw"; }
            break;
        case 0x3B:  // OP-32
            if (funct7 == 0x01) {
                switch (funct3) {
                    case 0: return "mulw"; case 4: return "divw"; case 5: return "divuw";
                    case 6: return "remw"; case 7: return "remuw"; }
            }
            switch (funct3) {
                case 0: return (funct7 & 0x40) ? "subw" : "addw";
                case 1: return "sllw";
                case 5: return (funct7 & 0x40) ? "sraw" : "srlw"; }
            break;
        case 0x0F: return (funct3 == 1) ? "fence.i" : "fence";
        case 0x73:
            if (instr == 0x00000073) return "ecall";
            if (instr == 0x00100073) return "ebreak";
            if (instr == 0x30200073) return "mret";
            switch (funct3) {
                case 1: return "csrrw"; case 2: return "csrrs"; case 3: return "csrrc";
                case 5: return "csrrwi"; case 6: return "csrrsi"; case 7: return "csrrci"; }
            break;
        case 0x07: return (funct3 == 2) ? "flw" : "fld";
        case 0x27: return (funct3 == 2) ? "fsw" : "fsd";
        case 0x53: return "fp.op";  // catch-all for FPU
        case 0x2F: return "amo";    // catch-all for AMO
        default: break;
    }
    snprintf(buf, buflen, "<unk>:%08x", instr);
    return buf;
}

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

    // Stage 5h B1: structured retire CSV ("+trace=<path>" Verilator plusarg).
    FILE* csv_fp = nullptr;
    uint64_t csv_pc_lo = 0, csv_pc_hi = ~uint64_t(0);
    uint64_t csv_cyc_lo = 0, csv_cyc_hi = ~uint64_t(0);
    {
        const char* p = Verilated::commandArgsPlusMatch("trace=");
        // commandArgsPlusMatch returns "+trace=<path>" or "" if no match.
        if (p && p[0] == '+') {
            const char* eq = strchr(p, '=');
            if (eq && *(eq+1)) {
                csv_fp = fopen(eq + 1, "w");
                if (!csv_fp) {
                    fprintf(stderr, "[sim] ERROR: cannot open +trace=%s\n", eq+1);
                    return 1;
                }
                fprintf(csv_fp,
                    "cycle,pc,instr,mnemonic,"
                    "rd_wen,rd,rd_wdata,"
                    "fp_wen,fp_rd,fp_wdata,"
                    "csr_wen,csr_addr,csr_wdata,"
                    "mem_wen,mem_addr,mem_wdata,mem_funct3,"
                    "trap_taken,trap_cause\n");
            }
        }
        const char* pcr = Verilated::commandArgsPlusMatch("trace_pc=");
        if (pcr && pcr[0] == '+') {
            const char* eq = strchr(pcr, '=');
            unsigned long long lo, hi;
            if (eq && sscanf(eq+1, "%llx,%llx", &lo, &hi) == 2) {
                csv_pc_lo = lo; csv_pc_hi = hi;
            }
        }
        const char* cyr = Verilated::commandArgsPlusMatch("trace_cycle=");
        if (cyr && cyr[0] == '+') {
            const char* eq = strchr(cyr, '=');
            unsigned long long lo, hi;
            if (eq && sscanf(eq+1, "%llu,%llu", &lo, &hi) == 2) {
                csv_cyc_lo = lo; csv_cyc_hi = hi;
            }
        }
    }

    // Stage 5h B2: hot-PC profiler ("+profile=<path>" Verilator plusarg).
    FILE* prof_fp = nullptr;
    {
        const char* p = Verilated::commandArgsPlusMatch("profile=");
        if (p && p[0] == '+') {
            const char* eq = strchr(p, '=');
            if (eq && *(eq+1)) {
                prof_fp = fopen(eq + 1, "w");
                if (!prof_fp) {
                    fprintf(stderr, "[sim] ERROR: cannot open +profile=%s\n", eq+1);
                    return 1;
                }
            }
        }
    }
    std::unordered_map<uint64_t, uint64_t> pc_count;
    std::unordered_map<uint64_t, uint32_t> pc_instr;  // last-seen instr at each PC

    // Stage 5h B3: stall-reason histogram ("+stalls=<path>" Verilator plusarg).
    FILE* stalls_fp = nullptr;
    {
        const char* p = Verilated::commandArgsPlusMatch("stalls=");
        if (p && p[0] == '+') {
            const char* eq = strchr(p, '=');
            if (eq && *(eq+1)) {
                stalls_fp = fopen(eq + 1, "w");
                if (!stalls_fp) {
                    fprintf(stderr, "[sim] ERROR: cannot open +stalls=%s\n", eq+1);
                    return 1;
                }
            }
        }
    }
    // Per-event-id cycle counter (only IDs 0x14..0x1F tracked).
    uint64_t stall_count[32] = {0};
    uint64_t total_cycles = 0;

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
    top->data_r_last_i    = 0;
    top->data_aw_ready_i  = 0;
    top->data_w_ready_i   = 0;
    top->data_b_valid_i   = 0;
    top->data_b_resp_i    = 0;
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

        // AW channel: always ready
        top->data_aw_ready_i = 1;
        // W channel: gated — driven below after AW handshake detection
        top->data_w_ready_i  = 0;

        // Promote any B armed during last cycle's W handshake to b_pending
        // for this cycle. This adds the one-cycle write→B delay that the
        // dcache's NC store path (DC_NC_W → DC_NC_B → DC_IDLE) requires:
        // without it, b_valid would fire in the same cycle as W and the
        // dcache would miss it because state has not yet advanced to DC_NC_B.
        if (data_w.b_armed) {
            data_w.b_pending = true;
            data_w.b_armed   = false;
        }

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

        // R response — data (multi-beat burst: INCR and WRAP)
        if (data_r.pending && cycle >= data_r.fire_at) {
            uint64_t addr = data_r.base_addr;
            if (data_r.burst == 0x1) {
                // INCR: linear advance by 8 bytes per beat.
                addr += (uint64_t)data_r.beat * 8;
            } else if (data_r.burst == 0x2) {
                // WRAP: wrap within a power-of-two aligned line.
                // line_size = (len+1) * 8 bytes.
                uint64_t line_size = ((uint64_t)data_r.len + 1) * 8;
                uint64_t line_mask = line_size - 1;
                uint64_t line_base = addr & ~line_mask;
                uint64_t off       = ((addr & line_mask) + (uint64_t)data_r.beat * 8) & line_mask;
                addr = line_base | off;
            }
            // Fetch the 64-bit beat (two consecutive 32-bit words, little-endian).
            uint64_t beat_data;
            if (is_mmio_scratch((uint32_t)addr)) {
                uint32_t mi    = ((uint32_t)addr - 0x40010000u) >> 2;
                uint32_t mi_hi = (mi + 1) & 0xFFF;
                beat_data = (uint64_t)mmio_mem[mi & 0xFFF] | ((uint64_t)mmio_mem[mi_hi] << 32);
            } else {
                uint32_t wa    = ((uint32_t)(addr >> 2)) & 0x7FFFF;
                uint32_t wa_hi = (wa + 1) & 0x7FFFF;
                beat_data = (uint64_t)mem[wa] | ((uint64_t)mem[wa_hi] << 32);
            }
            top->data_r_valid_i = 1;
            top->data_r_data_i  = beat_data;
            top->data_r_last_i  = (data_r.beat == data_r.len) ? 1 : 0;
        } else {
            top->data_r_valid_i = 0;
            top->data_r_data_i  = 0;
            top->data_r_last_i  = 0;
        }

        // ---- Evaluate combinatorial outputs BEFORE rising edge ----
        top->eval();

        if (debug) {
            uint32_t pc   = top->rootp->sim_top__DOT__u_top__DOT__pc_q;
            if (pc >= dbg_pc_lo && pc <= dbg_pc_hi) {
            uint8_t  al_v = top->rootp->sim_top__DOT__u_top__DOT__align_instr_valid;
            uint32_t ins  = top->rootp->sim_top__DOT__u_top__DOT__align_instr;
            uint8_t  redir = top->rootp->sim_top__DOT__u_top__DOT__ex_redirect;
            uint32_t epc  = top->rootp->sim_top__DOT__u_top__DOT__ex_pc_d;
#ifdef KRONOS_HAS_S6_PRIV
            uint8_t  priv = top->rootp->sim_top__DOT__u_top__DOT__priv_q;
            uint8_t  cstl = top->rootp->sim_top__DOT__u_top__DOT__combined_stall;
            uint8_t  trap = top->rootp->sim_top__DOT__u_top__DOT__trap_taken_pulse;
            uint32_t tcse = top->rootp->sim_top__DOT__u_top__DOT__trap_cause;
#endif
#ifdef KRONOS_HAS_FPU
            uint8_t  fov  = top->rootp->sim_top__DOT__u_top__DOT__fpu_out_valid;
            uint8_t  fi   = top->rootp->sim_top__DOT__u_top__DOT__fp_inflight_q;
            uint64_t fres = top->rootp->sim_top__DOT__u_top__DOT__fpu_result;
            uint8_t  fwe  = top->rootp->sim_top__DOT__u_top__DOT__fp_we;
            uint64_t fwd  = top->rootp->sim_top__DOT__u_top__DOT__fp_wd;
            uint8_t  fwa  = top->rootp->sim_top__DOT__u_top__DOT__fp_wa;
            printf("C%05d: pc=%08x al_v=%d ins=%08x redir=%d epc=%08x"
#ifdef KRONOS_HAS_S6_PRIV
                   " priv=%d cstl=%d trap=%d tcause=%x"
#endif
                   " fov=%d fi=%d fres=%016llx fwe=%d fwa=%d fwd=%016llx\n",
                   cycle, pc, al_v, ins, redir, epc,
#ifdef KRONOS_HAS_S6_PRIV
                   priv, cstl, trap, tcse,
#endif
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
                fprintf(stderr, "[AXI] FATAL: duplicate data AR at cycle %d (addr=0x%016llx)\n",
                        cycle, (unsigned long long)top->data_ar_addr_o);
                return 1;
            }
            data_r.pending   = true;
            data_r.base_addr = (uint64_t)top->data_ar_addr_o;
            data_r.burst     = (uint8_t)top->data_ar_burst_o;
            data_r.len       = (uint8_t)top->data_ar_len_o;
            data_r.beat      = 0;
            data_r.fire_at   = cycle + DATA_LAT;
            if (debug) {
                uint32_t pc = top->rootp->sim_top__DOT__u_top__DOT__pc_q;
                fprintf(stderr, "[MEM] C%05d pc=%08x AR addr=%016llx len=%u burst=%u\n",
                        cycle, pc, (unsigned long long)data_r.base_addr,
                        (unsigned)data_r.len, (unsigned)data_r.burst);
            }
        }

        // Data R handshake: advance beat or complete burst
        if (top->data_r_valid_i && top->data_r_ready_o) {
            if (data_r.beat == data_r.len) {
                data_r.pending = false;
                data_r.beat    = 0;
            } else {
                data_r.beat++;
            }
        }

        // Data AW handshake
        if (top->data_aw_valid_o && top->data_aw_ready_i) {
            data_w.base_addr = (uint64_t)top->data_aw_addr_o;
            data_w.beat      = 0;
            data_w.aw_done   = true;
        }

        // Data W handshake: accept beats when AW has been received.
        // Commits each W beat immediately (INCR burst: +8 bytes per beat).
        // B response fires after the last W beat (w_last) is accepted.
        top->data_w_ready_i = data_w.aw_done ? 1 : 0;
        if (data_w.aw_done && top->data_w_valid_o && top->data_w_ready_i) {
            uint64_t waddr = data_w.base_addr + (uint64_t)data_w.beat * 8;
            uint64_t wdat  = (uint64_t)top->data_w_data_o;
            uint8_t  be    = (uint8_t)top->data_w_strb_o;

            if ((uint32_t)waddr == 0x80000000u) {
                // Timer IRQ trigger — fire one cycle after B handshake completes
                // so the pipeline is not mem-stalled when irq_timer_i asserts.
                data_w.irq_write = true;
            } else if ((uint32_t)waddr == 0x10000000u) {
                // Console output: use lower 32-bit lane (byte strobes 0-3)
                for (int i = 0; i < 4; i++)
                    if (be & (1u << i))
                        putchar((wdat >> (i * 8)) & 0xFF);
                fflush(stdout);
            } else if (is_mmio_scratch((uint32_t)waddr)) {
                // MMIO scratch buffer: byte-strobed write to 0x4001_0000-0x4001_3FFF.
                // Used by NC PMA bypass asm tests; does NOT trigger halt.
                uint32_t mi_lo = ((uint32_t)waddr - 0x40010000u) >> 2;
                uint32_t cur_lo = mmio_mem[mi_lo & 0xFFF];
                if (be & 0x01) cur_lo = (cur_lo & ~0x000000FFu) | (uint32_t)((wdat >>  0) & 0xFFu);
                if (be & 0x02) cur_lo = (cur_lo & ~0x0000FF00u) | (uint32_t)((wdat >>  8) & 0xFFu) <<  8;
                if (be & 0x04) cur_lo = (cur_lo & ~0x00FF0000u) | (uint32_t)((wdat >> 16) & 0xFFu) << 16;
                if (be & 0x08) cur_lo = (cur_lo & ~0xFF000000u) | (uint32_t)((wdat >> 24) & 0xFFu) << 24;
                mmio_mem[mi_lo & 0xFFF] = cur_lo;
                uint32_t mi_hi = (mi_lo + 1) & 0xFFF;
                uint32_t cur_hi = mmio_mem[mi_hi];
                if (be & 0x10) cur_hi = (cur_hi & ~0x000000FFu) | (uint32_t)((wdat >> 32) & 0xFFu);
                if (be & 0x20) cur_hi = (cur_hi & ~0x0000FF00u) | (uint32_t)((wdat >> 40) & 0xFFu) <<  8;
                if (be & 0x40) cur_hi = (cur_hi & ~0x00FF0000u) | (uint32_t)((wdat >> 48) & 0xFFu) << 16;
                if (be & 0x80) cur_hi = (cur_hi & ~0xFF000000u) | (uint32_t)((wdat >> 56) & 0xFFu) << 24;
                mmio_mem[mi_hi] = cur_hi;
            } else if (((uint32_t)waddr & 0xFFFF0000u) == 0x40000000u) {
                // Halt via AXI writeback (dcache eviction path).
                // Sentinel: 0x4000_0000 - 0x4000_FFFF (common.S uses 0x4000_0000).
                // Only trigger if not already halted via the retire-trace path.
                if (!halted) {
                    halt_x10 = (uint32_t)(wdat & 0xFFFFFFFFu);
                    printf("[sim] halt at cycle %d, x10 = %u\n", cycle, halt_x10);
                    halted = 1;
                    halt_drain = DATA_LAT + 1;
                }
            } else {
                // Write lower 32-bit word (bytes 0-3)
                uint32_t wi_lo = ((uint32_t)waddr >> 2) & 0x7FFFF;
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
                if (debug) {
                    uint32_t pc = top->rootp->sim_top__DOT__u_top__DOT__pc_q;
                    fprintf(stderr, "[MEM] C%05d pc=%08x AW addr=%016llx beat=%u data=%016llx strb=%02x\n",
                            cycle, pc, (unsigned long long)waddr,
                            (unsigned)data_w.beat, (unsigned long long)wdat, (unsigned)be);
                }
            }

            data_w.beat++;
            if (top->data_w_last_o) {
                data_w.aw_done = false;
                // Arm B for next cycle (one-cycle write→B delay; see start of loop).
                data_w.b_armed = true;
            }
        }

        // B response — drive immediately once b_pending; no latency needed here
        // (the write latency was already absorbed by w_ready gating on aw_done).
        top->data_b_valid_i = data_w.b_pending ? 1 : 0;
        top->data_b_resp_i  = 0;

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

        if (csv_fp && top->retire_valid_o) {
            uint64_t pc = (uint64_t)top->retire_pc_o;
            if (pc >= csv_pc_lo && pc <= csv_pc_hi &&
                (uint64_t)cycle >= csv_cyc_lo && (uint64_t)cycle <= csv_cyc_hi) {
                char mbuf[32];
                const char* mn = resolve_mnemonic(top->retire_instr_o, mbuf, sizeof(mbuf));
                fprintf(csv_fp,
                    "%d,%016llx,%08x,%s,"
                    "%u,%u,%016llx,"
                    "%u,%u,%016llx,"
                    "%u,%03x,%016llx,"
                    "%u,%016llx,%016llx,%u,"
                    "%u,%u\n",
                    cycle,
                    (unsigned long long)pc,
                    (unsigned)top->retire_instr_o,
                    mn,
                    (unsigned)top->retire_rd_wen_o, (unsigned)top->retire_rd_o,
                    (unsigned long long)top->retire_rd_wdata_o,
                    (unsigned)top->retire_fp_wen_o, (unsigned)top->retire_fp_rd_o,
                    (unsigned long long)top->retire_fp_wdata_o,
                    (unsigned)top->retire_csr_wen_o, (unsigned)top->retire_csr_addr_o,
                    (unsigned long long)top->retire_csr_wdata_o,
                    (unsigned)top->retire_mem_wen_o,
                    (unsigned long long)top->retire_mem_addr_o,
                    (unsigned long long)top->retire_mem_wdata_o,
                    (unsigned)top->retire_mem_funct3_o,
                    (unsigned)top->retire_trap_taken_o,
                    (unsigned)top->retire_trap_cause_o);
            }
        }

        if (prof_fp && top->retire_valid_o) {
            uint64_t pc = (uint64_t)top->retire_pc_o;
            pc_count[pc]++;
            pc_instr[pc] = (uint32_t)top->retire_instr_o;
        }

#ifdef KRONOS_HAS_FPU
        if (stalls_fp) {
            // Read the event_bus directly from the public-flat-rw root path.
            // Only available in stage-5 builds (event_bus was added in 5c).
            uint32_t evb = top->rootp->sim_top__DOT__u_top__DOT__event_bus;
            for (int id = 0x14; id <= 0x1F; id++) {
                if (evb & (1u << id)) stall_count[id]++;
            }
            total_cycles++;
        }
#endif

        // Retire-trace halt detection: a store that retires to the 0x4000_0000
        // sentinel region signals termination.  This works with the write-back
        // dcache where the AXI writeback may be deferred indefinitely (the dirty
        // line stays in cache until eviction).
        // Sentinel range: 0x4000_0000 - 0x4000_FFFF (common.S uses 0x4000_0000).
        // 0x4001_0000 - 0x4001_3FFF is the MMIO scratch buffer (not a halt).
        if (!halted && top->retire_mem_wen_o &&
            ((uint32_t)top->retire_mem_addr_o & 0xFFFF0000u) == 0x40000000u) {
            halt_x10 = (uint32_t)(top->retire_mem_wdata_o & 0xFFFFFFFFu);
            printf("[sim] halt at cycle %d, x10 = %u\n", cycle, halt_x10);
            halted = 1;
            halt_drain = 2;
        }

        // Retire-trace console output: a store that retires to 0x10000000
        // (the ACT4 RVMODEL_IO_WRITE_STR address).  Same rationale as halt:
        // write-back dcache means the AXI writeback may never fire in a
        // self-checking test, so we surface the store from the retire stream
        // immediately.  funct3 selects the access size (000=B, 001=H, 010=W,
        // 011=D); console writes are typically byte stores.
        if (top->retire_mem_wen_o &&
            ((uint32_t)top->retire_mem_addr_o == 0x10000000u)) {
            uint8_t funct3 = (uint8_t)top->retire_mem_funct3_o & 0x07u;
            uint64_t wdat  = (uint64_t)top->retire_mem_wdata_o;
            int nbytes = (funct3 == 0) ? 1 : (funct3 == 1) ? 2 : (funct3 == 2) ? 4 : 8;
            for (int i = 0; i < nbytes; i++) putchar((wdat >> (i * 8)) & 0xFF);
            fflush(stdout);
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
    if (csv_fp) fclose(csv_fp);

    if (prof_fp) {
        // Sort by count desc.
        std::vector<std::pair<uint64_t, uint64_t>> rows(pc_count.begin(), pc_count.end());
        std::sort(rows.begin(), rows.end(),
                  [](const auto& a, const auto& b){ return a.second > b.second; });
        uint64_t total = 0;
        for (const auto& kv : rows) total += kv.second;
        fprintf(prof_fp, "pc,mnemonic,count,fraction\n");
        for (const auto& kv : rows) {
            char mbuf[32];
            const char* mn = resolve_mnemonic(pc_instr[kv.first], mbuf, sizeof(mbuf));
            double frac = total ? (double)kv.second / (double)total : 0.0;
            fprintf(prof_fp, "%016llx,%s,%llu,%.6f\n",
                    (unsigned long long)kv.first, mn,
                    (unsigned long long)kv.second, frac);
        }
        fclose(prof_fp);
    }
    if (stalls_fp) {
        static const char* names[32] = {0};
        names[0x14] = "load_use_stall";
        names[0x15] = "jalr_fwd_stall";
        names[0x16] = "fp_raw_stall";
        names[0x17] = "frm_hazard_stall";
        names[0x18] = "fp_inflight_stall";
        names[0x19] = "fence_i_drain_stall";
        names[0x1A] = "mem_busy_stall";
        names[0x1B] = "muldiv_stall";
        names[0x1C] = "fpu_stall";
        names[0x1D] = "instr_fetch_stall";
        names[0x1E] = "branch_mispredict";
        names[0x1F] = "ex_redirect";
        fprintf(stalls_fp, "event_id,event_name,cycle_count,fraction\n");
        for (int id = 0x14; id <= 0x1F; id++) {
            double frac = total_cycles ? (double)stall_count[id] / (double)total_cycles : 0.0;
            fprintf(stalls_fp, "0x%02x,%s,%llu,%.6f\n",
                    id, names[id],
                    (unsigned long long)stall_count[id], frac);
        }
        fclose(stalls_fp);
    }

    top->final();
    delete top;
    return (halted && halt_x10 == 0) ? 0 : 1;
}
