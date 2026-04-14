// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "axi/typedef.svh"

package kronos_pkg;

  // -------------------------------------------------------------------------
  // Stage 3+: AXI4 master port types
  // -------------------------------------------------------------------------
  typedef logic [31:0] kronos_axi_addr_t;
  typedef logic [ 0:0] kronos_axi_id_t;
  typedef logic [31:0] kronos_axi_data_t;
  typedef logic [ 3:0] kronos_axi_strb_t;
  typedef logic [ 0:0] kronos_axi_user_t;

  // Generates: kronos_axi_aw_chan_t, kronos_axi_w_chan_t, kronos_axi_b_chan_t,
  //            kronos_axi_ar_chan_t, kronos_axi_r_chan_t,
  //            kronos_axi_req_t, kronos_axi_resp_t
  `AXI_TYPEDEF_ALL(kronos_axi,
    kronos_axi_addr_t, kronos_axi_id_t, kronos_axi_data_t,
    kronos_axi_strb_t, kronos_axi_user_t)

  // ALU operation select
  typedef enum logic [3:0] {
    ALU_ADD   = 4'd0,
    ALU_SUB   = 4'd1,
    ALU_SLL   = 4'd2,
    ALU_SLT   = 4'd3,
    ALU_SLTU  = 4'd4,
    ALU_XOR   = 4'd5,
    ALU_SRL   = 4'd6,
    ALU_SRA   = 4'd7,
    ALU_OR    = 4'd8,
    ALU_AND   = 4'd9,
    ALU_PASSB = 4'd10  // pass B operand unchanged (used by LUI)
  } alu_op_e;

  // Writeback source
  typedef enum logic [1:0] {
    WB_ALU = 2'd0,  // ALU result
    WB_MEM = 2'd1,  // load data
    WB_PC4 = 2'd2,  // PC+4 (JAL/JALR link)
    WB_CSR = 2'd3   // CSR read value
  } wb_sel_e;

  // -------------------------------------------------------------------------
  // Stage 2: M-extension muldiv types
  // -------------------------------------------------------------------------

  typedef enum logic [2:0] {
    MULDIV_MUL    = 3'd0,
    MULDIV_MULH   = 3'd1,
    MULDIV_MULHSU = 3'd2,
    MULDIV_MULHU  = 3'd3,
    MULDIV_DIV    = 3'd4,
    MULDIV_DIVU   = 3'd5,
    MULDIV_REM    = 3'd6,
    MULDIV_REMU   = 3'd7
  } muldiv_op_e;

  // Decoded instruction — output of kronos_decode
  typedef struct packed {
    // Register operands
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic [4:0]  rd;
    logic        rs1_used;    // rs1 is a valid source
    logic        rs2_used;    // rs2 is a valid source
    logic        rd_wen;      // write result to rd
    // ALU
    alu_op_e     alu_op;
    logic [31:0] imm;         // sign-extended immediate
    logic        use_imm;     // use imm as ALU B-operand instead of rs2
    logic        use_pc;      // use PC as ALU A-operand (AUIPC)
    // Memory
    logic        is_load;
    logic        is_store;
    logic [2:0]  mem_funct3;  // load/store width + sign (funct3)
    // Control flow
    logic        is_branch;
    logic [2:0]  branch_funct3;
    logic        is_jal;
    logic        is_jalr;
    // CSR
    logic        is_csr;
    logic [11:0] csr_addr;
    logic [2:0]  csr_funct3;
    logic        csr_use_imm; // zimm for CSRRWI/CSRRSI/CSRRCI
    // Traps
    logic        is_ecall;
    logic        is_ebreak;
    logic        is_mret;
    // M extension
    logic        is_muldiv;
    muldiv_op_e  muldiv_op;
    // Writeback
    wb_sel_e     wb_sel;
    // Illegal
    logic        illegal;
  } decoded_instr_t;

  // -------------------------------------------------------------------------
  // Stage 1: forwarding and pipeline register types
  // -------------------------------------------------------------------------

  typedef enum logic [1:0] {
    FWD_NONE  = 2'd0,   // use register-file value
    FWD_EXMEM = 2'd1,   // forward from EX/MEM alu_result
    FWD_MEMWB = 2'd2    // forward from WB mux output
  } fwd_sel_e;

  // -------------------------------------------------------------------------
  // Stage 3: compressed instruction and branch predictor types
  // -------------------------------------------------------------------------

  // BTB entry (16-entry direct-mapped, indexed by pc[5:2])
  typedef struct packed {
    logic        valid;
    logic [25:0] tag;    // pc[31:6] — distinguishes aliased entries
    logic [31:0] target; // predicted branch/jump target
  } btb_entry_t;

  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic        valid;
    // Stage 3+
    logic        is_16b;      // instruction was 16-bit (C extension); PC+2, not PC+4
    logic        pred_taken;  // branch predictor predicted taken
    logic [31:0] pred_target; // predicted target (valid when pred_taken=1)
  } if_id_reg_t;

  typedef struct packed {
    logic [31:0]    pc;
    decoded_instr_t dec;
    logic [31:0]    rs1_data;
    logic [31:0]    rs2_data;
    logic           valid;
    // Stage 3+
    logic        is_16b;
    logic        pred_taken;
    logic [31:0] pred_target;
  } id_ex_reg_t;

  typedef struct packed {
    logic [31:0]    pc;
    decoded_instr_t dec;
    logic [31:0]    alu_result;
    logic [31:0]    rs2_data;
    logic [31:0]    pc_next;
    logic [31:0]    csr_rdata;
    logic           redirect;
    logic           valid;
    // Stage 3+
    logic           is_16b;   // needed so WB computes correct pc4 link address
  } ex_mem_reg_t;

  typedef struct packed {
    decoded_instr_t dec;
    logic [31:0]    alu_result;
    logic [31:0]    lsu_rdata;
    logic [31:0]    csr_rdata;
    logic [31:0]    pc4;
    logic           valid;
  } mem_wb_reg_t;

endpackage
