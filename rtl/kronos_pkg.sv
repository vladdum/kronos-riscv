// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "axi/typedef.svh"

package kronos_pkg;

  // -------------------------------------------------------------------------
  // Stage 3+: AXI4 master port types
  // -------------------------------------------------------------------------
  typedef logic [63:0] kronos_axi_addr_t;
  typedef logic [ 0:0] kronos_axi_id_t;
  typedef logic [63:0] kronos_axi_data_t;
  typedef logic [ 7:0] kronos_axi_strb_t;
  typedef logic [ 0:0] kronos_axi_user_t;

  // Generates: kronos_axi_aw_chan_t, kronos_axi_w_chan_t, kronos_axi_b_chan_t,
  //            kronos_axi_ar_chan_t, kronos_axi_r_chan_t,
  //            kronos_axi_req_t, kronos_axi_resp_t
  `AXI_TYPEDEF_ALL(kronos_axi,
    kronos_axi_addr_t, kronos_axi_id_t, kronos_axi_data_t,
    kronos_axi_strb_t, kronos_axi_user_t)

  // -------------------------------------------------------------------------
  // Core data widths
  // -------------------------------------------------------------------------
  localparam int unsigned XLEN       = 64;                  // integer register / data bus width
  localparam int unsigned XLEN_BYTES = XLEN/8;              // = 8
  localparam int unsigned INST_W     = 32;                  // RISC-V base instruction width

  // -------------------------------------------------------------------------
  // RV64IMAFDC opcode constants — referenced by kronos_decode (the wrapper)
  // and every sub-decoder (kronos_decode_int / _ctrl / _mem / _sys / _fp).
  // Used inside `unique case` selectors; treat like enum members at use sites
  // (bare reference, no `kronos_pkg::` prefix needed) for ergonomics.
  // -------------------------------------------------------------------------
  localparam logic [6:0] OP         = 7'b011_0011;  // R-type integer ALU
  localparam logic [6:0] OP_IMM     = 7'b001_0011;  // I-type integer ALU
  localparam logic [6:0] OP_IMM_32  = 7'b001_1011;  // RV64 I-type ALU-W
  localparam logic [6:0] OP_32      = 7'b011_1011;  // RV64 R-type ALU-W
  localparam logic [6:0] LOAD       = 7'b000_0011;
  localparam logic [6:0] STORE      = 7'b010_0011;
  localparam logic [6:0] LOAD_FP    = 7'b000_0111;
  localparam logic [6:0] STORE_FP   = 7'b010_0111;
  localparam logic [6:0] OP_FP      = 7'b101_0011;
  localparam logic [6:0] FMADD_OP   = 7'b100_0011;
  localparam logic [6:0] FMSUB_OP   = 7'b100_0111;
  localparam logic [6:0] FNMSUB_OP  = 7'b100_1011;
  localparam logic [6:0] FNMADD_OP  = 7'b100_1111;
  localparam logic [6:0] BRANCH     = 7'b110_0011;
  localparam logic [6:0] LUI        = 7'b011_0111;
  localparam logic [6:0] AUIPC      = 7'b001_0111;
  localparam logic [6:0] JAL        = 7'b110_1111;
  localparam logic [6:0] JALR       = 7'b110_0111;
  localparam logic [6:0] SYSTEM     = 7'b111_0011;
  localparam logic [6:0] AMO        = 7'b010_1111;

  // -------------------------------------------------------------------------
  // Floating-point widths and biases (IEEE-754 binary32 / binary64)
  // -------------------------------------------------------------------------
  localparam int unsigned FLEN          = 64;
  localparam int unsigned FP_S_EXP_W    = 8;
  localparam int unsigned FP_S_MANT_W   = 23;
  localparam int unsigned FP_S_TOTAL_W  = 32;               // 1 + FP_S_EXP_W + FP_S_MANT_W
  localparam int unsigned FP_D_EXP_W    = 11;
  localparam int unsigned FP_D_MANT_W   = 52;
  localparam int unsigned FP_D_TOTAL_W  = 64;               // 1 + FP_D_EXP_W + FP_D_MANT_W
  localparam int          FP_S_BIAS     = 127;
  localparam int          FP_D_BIAS     = 1023;
  localparam logic [FP_S_EXP_W-1:0] FP_S_EXP_MAX = 8'hFF;
  localparam logic [FP_D_EXP_W-1:0] FP_D_EXP_MAX = 11'h7FF;
  // Penultimate biased exponents (max finite encoded value)
  localparam logic [FP_S_EXP_W-1:0] FP_S_EXP_PENULT = 8'hFE;
  localparam logic [FP_D_EXP_W-1:0] FP_D_EXP_PENULT = 11'h7FE;
  // Minimum normal unbiased exponents (1 - bias)
  localparam int FP_S_EMIN_NORM = -126;
  // Extended signed exponent width used by internal FPU datapath
  // (wide enough to hold +/-2*BIAS plus shift margin)
  localparam int unsigned FP_EXP_EXT_W = 13;

  // FCLASS one-hot bit positions (RISC-V FCLASS instruction)
  localparam logic [9:0] FCLASS_NEG_INF       = 10'b00_0000_0001; // bit 0
  localparam logic [9:0] FCLASS_NEG_NORMAL    = 10'b00_0000_0010; // bit 1
  localparam logic [9:0] FCLASS_NEG_SUBNORMAL = 10'b00_0000_0100; // bit 2
  localparam logic [9:0] FCLASS_NEG_ZERO      = 10'b00_0000_1000; // bit 3
  localparam logic [9:0] FCLASS_POS_ZERO      = 10'b00_0001_0000; // bit 4
  localparam logic [9:0] FCLASS_POS_SUBNORMAL = 10'b00_0010_0000; // bit 5
  localparam logic [9:0] FCLASS_POS_NORMAL    = 10'b00_0100_0000; // bit 6
  localparam logic [9:0] FCLASS_POS_INF       = 10'b00_1000_0000; // bit 7
  localparam logic [9:0] FCLASS_SNAN          = 10'b01_0000_0000; // bit 8
  localparam logic [9:0] FCLASS_QNAN          = 10'b10_0000_0000; // bit 9

  // -------------------------------------------------------------------------
  // Memory map / addressing
  // -------------------------------------------------------------------------
  // Base of the default non-cacheable / MMIO window. Matches the dcache PMA
  // default region (issue #67: 0x4000_0000-0x4FFF_FFFF) so RTL can reference
  // a single named constant instead of the bare literal.
  localparam logic [XLEN-1:0] MMIO_BASE = 64'h0000_0000_4000_0000;

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
  // Privilege modes (RISC-V Privileged Spec Table 1.1)
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    PRIV_U = 2'b00,
    PRIV_S = 2'b01,
    PRIV_M = 2'b11
  } priv_e;

  // -------------------------------------------------------------------------
  // which TLB requested a PTW walk
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    TLB_NONE  = 2'b00,
    TLB_FETCH = 2'b01,
    TLB_LOAD  = 2'b10,
    TLB_STORE = 2'b11
  } tlb_op_e;

  // -------------------------------------------------------------------------
  // FPU operation select (declared here so decoded_instr_t can
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
    FP_FADD, FP_FSUB, FP_FMUL, FP_FDIV, FP_FSQRT,
    // FMA
    FP_FMADD, FP_FMSUB, FP_FNMADD, FP_FNMSUB
  } fp_op_e;

  // FP rm-field helpers — used by kronos_decode_fp.
  // resolve_rm: substitute FRM (FCSR.frm) when the instruction-encoded rm
  // field is DYN (3'b111). rm_is_illegal: true for the two reserved encodings.
  function automatic logic [2:0] resolve_rm(input logic [2:0] rm_in,
                                            input logic [2:0] frm);
    return (rm_in == 3'b111) ? frm : rm_in;
  endfunction

  function automatic logic rm_is_illegal(input logic [2:0] rm);
    return (rm == 3'b101) || (rm == 3'b110);
  endfunction

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
    logic        is_sret;          // Stage 6a
    logic        is_sfence_vma;    // Stage 6b
    logic        is_wfi;           // Stage 6b
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
    // FP decode
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
  // Stage 7a — fault propagation contract.
  //
  // Each fault source produces exactly one bit; the bit is registered into the
  // next pipeline register before any consumer reads it.  No combinational
  // path crosses two modules.  Redirect formation is a single OR per redirect
  // class: ex_redirect_d at EX2 (direction mispredict only), mem_redirect_d
  // at MEM (everything else).  See
  // docs/superpowers/specs/2026-05-05-stage7a-fault-bits-ex-split-design.md
  // section 3 for the producer-stage write contract.
  // -------------------------------------------------------------------------
  typedef struct packed {
    // ID-stage producers
    logic ecall;
    logic ebreak;
    logic illegal;
    logic is_mret;
    logic is_sret;
    // EX1-stage producers
    logic csr_illegal;
    logic mret_priv_fail;
    logic sret_priv_fail;
    logic satp_tvm_fail;
    logic wfi_priv_fail;
    logic irq_pending;
    logic bpred_dir_mispredict;
    // EX2-stage producers
    logic pmp_fetch_fault;
    logic pmp_data_fault;
    logic ex_amo_nc_fault;
    logic trig_hit;
    // MEM-stage producers
    logic instr_page_fault;
    logic load_page_fault;
    logic store_page_fault;
    logic bpred_target_mispredict;
    logic dcache_bus_err_fault;
  } fault_t;

  localparam fault_t FAULT_ZERO = '{default: '0};

  // -------------------------------------------------------------------------
  // Stage 1 / Stage 7a: forwarding and pipeline register types
  // -------------------------------------------------------------------------

  // fwd_sel_e — forwarding source select for rs1/rs2 bypass mux at RR stage.
  // Six producer slots, freshest first:
  //   FWD_EX1_NOW  - same cycle (combinational alu_result_d at EX1)
  //   FWD_EX1      - 1-cycle-old (ex1_ex2_q.alu_result)
  //   FWD_EXMEM    - 2-cycle-old (ex2_mem1_q.alu_result; legacy name from 7b/7c)
  //   FWD_MEM1B    - 3-cycle-old (mem1_mem1b_q.alu_result; new in 7d)
  //   FWD_MEM2     - 4-cycle-old (mem1_mem2_q.alu_result; suppressed for loads)
  //   FWD_MEMWB    - 5-cycle-old (mem_wb_q via writeback mux)
  typedef enum logic [2:0] {
    FWD_NONE     = 3'd0,   // use regfile rdata
    FWD_EX1_NOW  = 3'd1,   // 7b — same-cycle EX1 alu_result_d (combinational)
    FWD_EX1      = 3'd2,   // 1-cycle-old: ex1_ex2_q.alu_result
    FWD_EXMEM    = 3'd3,   // 2-cycle-old: ex2_mem1_q.alu_result
    FWD_MEM1B    = 3'd4,   // 3-cycle-old: mem1_mem1b_q.alu_result   (new in 7d)
    FWD_MEM2     = 3'd5,   // 4-cycle-old: mem1_mem2_q.alu_result (loads suppressed)
    FWD_MEMWB    = 3'd6    // 5-cycle-old: mem_wb_q via writeback mux
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
    // Retire-trace: original 32-bit instruction word (already expanded from
    // the C-extension alignment unit, so this is the fully-expanded form).
    logic [31:0] instr;
    // Stage 7a — registered fault bits.  ID-stage producers populate ecall /
    // ebreak / illegal / is_mret / is_sret; the rest stay '0 until later
    // stages OR-fold their bits in at the next pipeline boundary.
    fault_t      fault;
  } id_ex_reg_t;

  // Stage 7a — pipeline register between EX1 and EX2.  Carries the registered
  // ALU result + AGU output + branch-direction so EX2 can aggregate faults
  // and form the direction-mispredict redirect from registered bits only.
  typedef struct packed {
    logic [31:0]    pc;
    decoded_instr_t dec;
    logic [63:0]    rs2_data;       // forwarded for stores / CSR
    logic [63:0]    alu_result;     // EX1 output (ALU/AGU)
    logic [31:0]    eff_va;         // EX1 effective VA for loads/stores/AMO
    logic [31:0]    ex_pc_d;        // EX1 next-PC (redirect target on mispredict / trap)
    logic           branch_taken;   // EX1 branch direction
    logic [63:0]    csr_rdata;      // EX1 CSR read snapshot
    logic [63:0]    csr_wdata;      // EX1 CSR write source (rs1)
    logic           valid;
    logic           is_16b;
    logic           pred_taken;
    logic [31:0]    pred_target;
    logic [31:0]    instr;
    fault_t         fault;
  } ex1_ex2_reg_t;

  typedef struct packed {
    logic [31:0]    pc;
    decoded_instr_t dec;
    logic [63:0]    alu_result;
    logic [63:0]    rs2_data;
    logic [31:0]    pc_d;
    logic [63:0]    csr_rdata;
    logic           redirect;    // kept for backward compat; unused in Stage 7+.
    logic           valid;
    // Stage 3+
    logic           is_16b;      // needed so WB computes correct pc4 link address
    logic           pred_taken;  // propagated for MEM-stage bpred target check
    logic [31:0]    pred_target; // propagated for MEM-stage bpred target check
    // Retire-trace: original 32-bit instruction word and the rs1 value fed
    // into kronos_csr (snapshot of the CSR write source operand).
    logic [31:0]    instr;
    logic [63:0]    csr_wdata;
    // Registered fault bits.  Forms mem_redirect_d together with MEM-cycle
    // producers.
    fault_t         fault;
  } ex_mem_reg_t;

  // Pipeline register between MEM1 and MEM1B.  Carries instruction context
  // through the MEM1->MEM1B->MEM2 stack.  The kronos_tlb module is internally
  // split into S0 (CAM) / S1 (encode) sub-stages — dTLB outputs (PA,
  // perm_fail, miss/a_zero/d_zero/hit) are flop outputs of the dTLB-S1
  // stage at the MEM1B edge, so they live in mem1_mem2_reg_t (registered
  // MEM1B->MEM2) rather than mem1_mem1b_reg_t.
  typedef struct packed {
    logic [31:0]    pc;
    decoded_instr_t dec;
    logic [63:0]    alu_result;
    logic [63:0]    rs2_data;
    logic [31:0]    pc_d;
    logic [63:0]    csr_rdata;
    logic           redirect;       // legacy — kept for backward compat; unused
    logic           valid;
    logic           is_16b;
    logic           pred_taken;
    logic [31:0]    pred_target;
    logic [31:0]    instr;
    logic [63:0]    csr_wdata;
    fault_t         fault;          // PMP/PMA/page-fault bits all '0 at this edge
    logic           dcache_pre_launched; // metadata for retire trace
  } mem1_mem1b_reg_t;

  typedef struct packed {
    // mirror of mem1_mem1b_reg_t (passed through MEM1B->MEM2 with PMP/PMA bits filled in)
    logic [31:0]    pc;
    decoded_instr_t dec;
    logic [63:0]    alu_result;
    logic [63:0]    rs2_data;
    logic [31:0]    pc_d;
    logic [63:0]    csr_rdata;
    logic           redirect;       // legacy — kept for backward compat; unused
    logic           valid;
    logic           is_16b;
    logic           pred_taken;
    logic [31:0]    pred_target;
    logic [31:0]    instr;
    logic [63:0]    csr_wdata;
    // Fault aggregate.  Includes MEM2-produced bits: pmp_data_fault,
    // ex_amo_nc_fault, load_page_fault, store_page_fault.
    fault_t         fault;
    logic [31:0]    dtlb_pa;        // translated PA from dTLB-S1 (registered MEM1B->MEM2)
    logic           dtlb_perm_fail; // raw dTLB perm-fail (registered MEM1B->MEM2)
    logic           dtlb_miss;      // dTLB-driven miss (~hit & ~perm_fail | a_zero | d_zero)
    logic           dtlb_a_zero;    // hit with A=0 -> PTW re-walk to set A
    logic           dtlb_d_zero;    // hit with D=0 on a store -> PTW re-walk to set D
    logic           dtlb_hit;       // dTLB lookup hit indicator
    logic           dtlb_was_hit;   // 1=lookup hit (or translation off); 0=dtlb_miss path
    logic           dcache_pre_launched; // metadata for retire trace
  } mem1_mem2_reg_t;

  typedef struct packed {
    decoded_instr_t dec;
    logic [63:0]    alu_result;
    logic [63:0]    lsu_rdata;
    logic [63:0]    csr_rdata;
    logic [31:0]    pc4;
    logic           valid;
    logic           is_amo_write;  // AMO/SC op that wrote memory (Stage 5f)
    // Retire-trace fields (populated for differential tracing against a
    // reference model).  Not consumed by the pipeline itself; kept in the
    // same flop so the values line up with the cycle mem_wb_q advances.
    logic [31:0]    pc;
    logic [31:0]    instr;
    logic [63:0]    mem_addr;    // ex_mem_q.alu_result at MEM (store addr)
    logic [63:0]    mem_wdata;   // ex_mem_q.rs2_data at MEM (store data)
    logic [63:0]    csr_wdata;   // rs1 data presented to kronos_csr at EX
    // Stage 7a — full registered fault aggregate at retire.
    fault_t         fault;
  } mem_wb_reg_t;

  // -------------------------------------------------------------------------
  // Typed zero constants for structs that contain enum fields.
  // Strict lint mode rejects '{default: '0} for enum members; these
  // constants name each enum field with its zero value and let the remaining
  // logic fields default to 0.
  // -------------------------------------------------------------------------
  localparam decoded_instr_t DECODED_INSTR_ZERO = '{
    alu_op:    ALU_ADD,
    muldiv_op: MULDIV_MUL,
    wb_sel:    WB_ALU,
    fp_op:     FP_FSGNJ,
    default:   '0
  };

  localparam ex_mem_reg_t EX_MEM_REG_ZERO = '{
    dec:     DECODED_INSTR_ZERO,
    fault:   FAULT_ZERO,
    default: '0
  };

  localparam mem1_mem1b_reg_t MEM1_MEM1B_REG_ZERO = '{
    dec:     DECODED_INSTR_ZERO,
    fault:   FAULT_ZERO,
    default: '0
  };

  localparam mem1_mem2_reg_t MEM1_MEM2_REG_ZERO = '{
    dec:     DECODED_INSTR_ZERO,
    fault:   FAULT_ZERO,
    default: '0
  };

  localparam id_ex_reg_t ID_EX_REG_ZERO = '{
    dec:         DECODED_INSTR_ZERO,
    fwd_rs1_sel: FWD_NONE,
    fwd_rs2_sel: FWD_NONE,
    default:     '0
  };

  // -------------------------------------------------------------------------
  // ID/RR and RR/EX1 pipeline register types (RR = register-read)
  // -------------------------------------------------------------------------
  // The RR stage sits between ID and EX1.  id_rr_reg_t carries the decode
  // output + ID-owned fault bits across the ID/RR boundary; the regfile read,
  // bypass mux, and CSR speculative read fire inside RR and capture into
  // rr_ex1_reg_t at the RR/EX1 boundary.  rr_ex1_reg_t mirrors id_ex_reg_t
  // plus a registered csr_rdata field.
  typedef struct packed {
    logic [31:0]    pc;
    decoded_instr_t dec;
    fwd_sel_e       fwd_rs1_sel;
    fwd_sel_e       fwd_rs2_sel;
    logic           valid;
    logic           is_16b;
    logic           pred_taken;
    logic [31:0]    pred_target;
    logic [31:0]    instr;
    fault_t         fault;          // ID-owned bits only
  } id_rr_reg_t;

  typedef struct packed {
    logic [31:0]    pc;
    decoded_instr_t dec;
    logic [63:0]    rs1_data;
    logic [63:0]    rs2_data;
    logic [63:0]    rs3_data;
    fwd_sel_e       fwd_rs1_sel;
    fwd_sel_e       fwd_rs2_sel;
    logic           valid;
    logic           is_16b;
    logic           pred_taken;
    logic [31:0]    pred_target;
    logic [31:0]    instr;
    fault_t         fault;
    logic [63:0]    csr_rdata;       // speculative CSR read captured at RR
  } rr_ex1_reg_t;

  localparam id_rr_reg_t ID_RR_REG_ZERO = '{
    dec:         DECODED_INSTR_ZERO,
    fwd_rs1_sel: FWD_NONE,
    fwd_rs2_sel: FWD_NONE,
    default:     '0
  };

  localparam rr_ex1_reg_t RR_EX1_REG_ZERO = '{
    dec:         DECODED_INSTR_ZERO,
    fwd_rs1_sel: FWD_NONE,
    fwd_rs2_sel: FWD_NONE,
    default:     '0
  };

  // -------------------------------------------------------------------------
  // Floating-point types and constants
  // -------------------------------------------------------------------------

  // Writeback-tag width. 5 bits in Stage 5a (one per architectural FP reg).
  // Widened in Stage 6 when physical registers appear.
  localparam int unsigned WB_TAG_W = 5;

  // IEEE 754 canonical quiet NaN (qNaN) payloads.
  localparam logic [31:0] FP_CANON_QNAN_S = 32'h7FC0_0000;
  localparam logic [63:0] FP_CANON_QNAN_D = 64'h7FF8_0000_0000_0000;

  // NaN-box upper-half (for FLW / single-precision operand check).
  localparam logic [31:0] FP_NANBOX_UPPER = 32'hFFFF_FFFF;

  // -------------------------------------------------------------------------
  // Event-bus IDs consumed by mhpmevent/mhpmcounter (Zihpm).
  // Bits 0x00..0x11 are pre-existing; 0x14..0x1F added by Stage 5h taxonomy.
  // Indexed via `event_bus[EVT_*]`; `mhpmeventX = EVT_*` selects the bit.
  // -------------------------------------------------------------------------
  localparam logic [4:0] EVT_BRANCH_RETIRE       = 5'h01;
  localparam logic [4:0] EVT_BRANCH_MISPREDICT_P = 5'h02; // pulse, pre-existing
  localparam logic [4:0] EVT_LOAD_RETIRE         = 5'h03;
  localparam logic [4:0] EVT_STORE_RETIRE        = 5'h04;
  localparam logic [4:0] EVT_MEM_STALL           = 5'h05;
  // 0x06 (muldiv) and 0x07 (fpu) are pre-existing low-bit aliases of
  // EVT_MULDIV_STALL (0x1B) / EVT_FPU_STALL (0x1C); kept driven via literals.
  localparam logic [4:0] EVT_TRAP_TAKEN          = 5'h08;
  localparam logic [4:0] EVT_ICACHE_MISS         = 5'h10;
  localparam logic [4:0] EVT_DCACHE_MISS         = 5'h11;
  // Stage 5h taxonomy (fine-grained stall causes).
  localparam logic [4:0] EVT_LOAD_USE_STALL      = 5'h14;
  localparam logic [4:0] EVT_JALR_FWD_STALL      = 5'h15;
  localparam logic [4:0] EVT_FP_RAW_STALL        = 5'h16;
  localparam logic [4:0] EVT_FRM_HAZARD_STALL    = 5'h17;
  localparam logic [4:0] EVT_FP_INFLIGHT_STALL   = 5'h18;
  localparam logic [4:0] EVT_FENCE_I_DRAIN_STALL = 5'h19;
  localparam logic [4:0] EVT_MEM_BUSY_STALL      = 5'h1A;
  localparam logic [4:0] EVT_MULDIV_STALL        = 5'h1B;
  localparam logic [4:0] EVT_FPU_STALL           = 5'h1C;
  localparam logic [4:0] EVT_INSTR_FETCH_STALL   = 5'h1D;
  localparam logic [4:0] EVT_BRANCH_MISPREDICT   = 5'h1E;
  localparam logic [4:0] EVT_EX_REDIRECT         = 5'h1F;

  // -------------------------------------------------------------------------
  // New CSR addresses introduced in this stage.
  // Using `localparam logic [11:0]` so we can index `csr_addr_i` directly.
  // -------------------------------------------------------------------------
  // S-mode supervisor CSRs (RISC-V Privileged Spec § 4.1)
  localparam logic [11:0] CSR_SSTATUS    = 12'h100;
  localparam logic [11:0] CSR_SIE        = 12'h104;
  localparam logic [11:0] CSR_STVEC      = 12'h105;
  localparam logic [11:0] CSR_SCOUNTEREN = 12'h106;
  localparam logic [11:0] CSR_SENVCFG    = 12'h10A;
  localparam logic [11:0] CSR_SSCRATCH   = 12'h140;
  localparam logic [11:0] CSR_SEPC       = 12'h141;
  localparam logic [11:0] CSR_SCAUSE     = 12'h142;
  localparam logic [11:0] CSR_STVAL      = 12'h143;
  localparam logic [11:0] CSR_SIP        = 12'h144;
  localparam logic [11:0] CSR_SATP       = 12'h180;
  // Delegation + counter-enable
  localparam logic [11:0] CSR_MEDELEG    = 12'h302;
  localparam logic [11:0] CSR_MIDELEG    = 12'h303;
  localparam logic [11:0] CSR_MCOUNTEREN = 12'h306;
  // PMP cfg + addr (8 active regions; pmpcfg2 + pmpaddr8..15 hardwired 0).
  // The full 0..15 set is defined here so kronos_csr.sv can address every
  // entry by symbolic name (avoids the half-named / half-literal mix that
  // surfaced in #81 when only the boundary indices were in the package).
  localparam logic [11:0] CSR_PMPCFG0    = 12'h3A0;
  localparam logic [11:0] CSR_PMPCFG2    = 12'h3A2;
  localparam logic [11:0] CSR_PMPADDR0   = 12'h3B0;
  localparam logic [11:0] CSR_PMPADDR1   = 12'h3B1;
  localparam logic [11:0] CSR_PMPADDR2   = 12'h3B2;
  localparam logic [11:0] CSR_PMPADDR3   = 12'h3B3;
  localparam logic [11:0] CSR_PMPADDR4   = 12'h3B4;
  localparam logic [11:0] CSR_PMPADDR5   = 12'h3B5;
  localparam logic [11:0] CSR_PMPADDR6   = 12'h3B6;
  localparam logic [11:0] CSR_PMPADDR7   = 12'h3B7;
  localparam logic [11:0] CSR_PMPADDR8   = 12'h3B8;
  localparam logic [11:0] CSR_PMPADDR9   = 12'h3B9;
  localparam logic [11:0] CSR_PMPADDR10  = 12'h3BA;
  localparam logic [11:0] CSR_PMPADDR11  = 12'h3BB;
  localparam logic [11:0] CSR_PMPADDR12  = 12'h3BC;
  localparam logic [11:0] CSR_PMPADDR13  = 12'h3BD;
  localparam logic [11:0] CSR_PMPADDR14  = 12'h3BE;
  localparam logic [11:0] CSR_PMPADDR15  = 12'h3BF;

  // -------------------------------------------------------------------------
  // Sv39/Sv48 satp.MODE values (RISC-V Privileged Spec § 4.1.11)
  // -------------------------------------------------------------------------
  localparam logic [3:0] SATP_MODE_BARE = 4'd0;
  localparam logic [3:0] SATP_MODE_SV39 = 4'd8;
  localparam logic [3:0] SATP_MODE_SV48 = 4'd9;

  // -------------------------------------------------------------------------
  // RV64 PTE field positions (RISC-V Privileged Spec § 5.4)
  // -------------------------------------------------------------------------
  localparam int unsigned PTE_V_BIT = 0;   // valid
  localparam int unsigned PTE_R_BIT = 1;
  localparam int unsigned PTE_W_BIT = 2;
  localparam int unsigned PTE_X_BIT = 3;
  localparam int unsigned PTE_U_BIT = 4;   // user-accessible
  localparam int unsigned PTE_G_BIT = 5;   // global
  localparam int unsigned PTE_A_BIT = 6;   // accessed
  localparam int unsigned PTE_D_BIT = 7;   // dirty
  // PTE.RSW at [9:8]; PTE.PPN at [53:10]; bits [63:54] reserved (must be 0).

  // -------------------------------------------------------------------------
  // synchronous trap causes used by PMP and delegation paths.
  // Spec causes 12/13/15 (page faults) are defined here so 6b only adds
  // the path that raises them, not new constants.
  // -------------------------------------------------------------------------
  localparam logic [4:0] CAUSE_INSTR_ACCESS_FAULT = 5'd1;
  localparam logic [4:0] CAUSE_LOAD_ACCESS_FAULT  = 5'd5;
  localparam logic [4:0] CAUSE_STORE_ACCESS_FAULT = 5'd7;
  localparam logic [4:0] CAUSE_INSTR_PAGE_FAULT   = 5'd12;
  localparam logic [4:0] CAUSE_LOAD_PAGE_FAULT    = 5'd13;
  localparam logic [4:0] CAUSE_STORE_PAGE_FAULT   = 5'd15;
  localparam logic [4:0] CAUSE_ECALL_U            = 5'd8;
  localparam logic [4:0] CAUSE_ECALL_S            = 5'd9;
  localparam logic [4:0] CAUSE_ECALL_M            = 5'd11;

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

  // --- ALU op-class classifiers (consumed by kronos_alu's final result mux) -

  function automatic logic is_alu_slt(alu_op_e op);
    case (op)
      ALU_SLT, ALU_SLTU: is_alu_slt = 1'b1;
      default:           is_alu_slt = 1'b0;
    endcase
  endfunction

  function automatic logic is_alu_logic(alu_op_e op);
    case (op)
      ALU_AND, ALU_OR, ALU_XOR, ALU_PASSB: is_alu_logic = 1'b1;
      default:                             is_alu_logic = 1'b0;
    endcase
  endfunction

  function automatic logic is_alu_shift(alu_op_e op);
    case (op)
      ALU_SLL, ALU_SRL, ALU_SRA: is_alu_shift = 1'b1;
      default:                   is_alu_shift = 1'b0;
    endcase
  endfunction

endpackage
