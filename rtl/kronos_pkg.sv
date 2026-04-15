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

  // -------------------------------------------------------------------------
  // Stage 5a: FPU operation select (declared here so decoded_instr_t can
  // embed fp_op_e; must appear before the struct definition).
  // -------------------------------------------------------------------------

  // FPU unit operation select. One enum covers every arithmetic/movement op
  // routed to the FPU; decode sets this. The destination format (S vs D) is
  // carried alongside on `fmt_d` (1 = double, 0 = single).
  typedef enum logic [4:0] {
    // FMISC
    FP_FSGNJ, FP_FSGNJN, FP_FSGNJX,
    FP_FMIN,  FP_FMAX,
    FP_FCLASS,
    FP_FEQ,   FP_FLT,   FP_FLE,
    FP_FMV_X_W, FP_FMV_W_X, FP_FMV_X_D, FP_FMV_D_X,
    // FCVT
    FP_FCVT_W_F, FP_FCVT_WU_F, FP_FCVT_L_F, FP_FCVT_LU_F,
    FP_FCVT_F_W, FP_FCVT_F_WU, FP_FCVT_F_L, FP_FCVT_F_LU,
    FP_FCVT_S_D, FP_FCVT_D_S,
    // Arith
    FP_FADD, FP_FSUB, FP_FMUL,
    // FMA
    FP_FMADD, FP_FMSUB, FP_FNMADD, FP_FNMSUB
  } fp_op_e;

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
    // RV64I
    logic        is_word_op;  // W-suffix instruction (ADDW, SUBW, etc.)
    // A extension
    logic        is_lr;       // LR.W or LR.D
    logic        is_sc;       // SC.W or SC.D
    logic        is_amo;      // AMO instruction
    logic [4:0]  amo_funct5;  // AMO function code
    // Writeback
    wb_sel_e     wb_sel;
    // Illegal
    logic        illegal;
    // Stage 5a: FP decode
    logic       is_fp;       // FPU unit consumes this instruction
    logic       fmt_d;       // 1 = double, 0 = single
    logic       rs1_fp;      // rs1 comes from the FP regfile
    logic       rs2_fp;      // rs2 comes from the FP regfile
    logic       rs3_fp;      // rs3 (FMA) comes from the FP regfile
    logic       rd_fp;       // rd writes the FP regfile
    logic [4:0] rs3;         // FMA third source (instr[31:27])
    logic [2:0] rm_resolved; // already-resolved rounding mode
    fp_op_e     fp_op;       // unit operation (from fp_op_e enum)
    logic       fp_load;     // FLW/FLD
    logic       fp_store;    // FSW/FSD
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
    logic [63:0]    rs1_data;
    logic [63:0]    rs2_data;
    logic [63:0]    rs3_data;       // Stage 5a: FMA third source (from FP regfile)
    fwd_sel_e       fwd_rs1_sel;    // pre-computed EX bypass select for rs1
    fwd_sel_e       fwd_rs2_sel;    // pre-computed EX bypass select for rs2
    logic           valid;
    // Stage 3+
    logic        is_16b;
    logic        pred_taken;
    logic [31:0] pred_target;
  } id_ex_reg_t;

  typedef struct packed {
    logic [31:0]    pc;
    decoded_instr_t dec;
    logic [63:0]    alu_result;
    logic [63:0]    rs2_data;
    logic [31:0]    pc_next;
    logic [63:0]    csr_rdata;
    logic           redirect;
    logic           valid;
    // Stage 3+
    logic           is_16b;   // needed so WB computes correct pc4 link address
  } ex_mem_reg_t;

  typedef struct packed {
    decoded_instr_t dec;
    logic [63:0]    alu_result;
    logic [63:0]    lsu_rdata;
    logic [63:0]    csr_rdata;
    logic [31:0]    pc4;
    logic           valid;
  } mem_wb_reg_t;

  // -------------------------------------------------------------------------
  // Stage 5a: Floating-point types and constants
  // -------------------------------------------------------------------------

  // Writeback-tag width. 5 bits in Stage 5a (one per architectural FP reg).
  // Widened in Stage 6 when physical registers appear.
  localparam int unsigned WB_TAG_W = 5;

  // IEEE 754 canonical quiet NaN (qNaN) payloads.
  localparam logic [31:0] FP_CANON_QNAN_S = 32'h7FC0_0000;
  localparam logic [63:0] FP_CANON_QNAN_D = 64'h7FF8_0000_0000_0000;

  // NaN-box upper-half (for FLW / single-precision operand check).
  localparam logic [31:0] FP_NANBOX_UPPER = 32'hFFFF_FFFF;

  // Rounding modes (IEEE 754 / RISC-V FRM encoding).
  typedef enum logic [2:0] {
    FP_RM_RNE = 3'b000, // round to nearest, ties to even
    FP_RM_RTZ = 3'b001, // round toward zero
    FP_RM_RDN = 3'b010, // round down (toward -inf)
    FP_RM_RUP = 3'b011, // round up (toward +inf)
    FP_RM_RMM = 3'b100, // round to nearest, ties to max-magnitude
    FP_RM_DYN = 3'b111  // dynamic (from FRM); illegal as a unit input
  } fp_round_e;

  // Exception flag bit positions within FFLAGS (fcsr[4:0]).
  localparam int unsigned FP_FFLAG_NX = 0; // inexact
  localparam int unsigned FP_FFLAG_UF = 1; // underflow
  localparam int unsigned FP_FFLAG_OF = 2; // overflow
  localparam int unsigned FP_FFLAG_DZ = 3; // divide by zero
  localparam int unsigned FP_FFLAG_NV = 4; // invalid

  // Writeback tag carried through each FPU pipeline.
  typedef struct packed {
    logic [WB_TAG_W-1:0] rd;       // destination register index
    logic                fp_dest;  // 1 = FP regfile, 0 = integer regfile
  } fpu_tag_t;

endpackage
