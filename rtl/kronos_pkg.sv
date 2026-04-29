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
  // Stage 6a: Privilege modes (RISC-V Privileged Spec Table 1.1)
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    PRIV_U = 2'b00,
    PRIV_S = 2'b01,
    PRIV_M = 2'b11
  } priv_e;

  // -------------------------------------------------------------------------
  // Stage 6b: which TLB requested a PTW walk
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    TLB_NONE  = 2'b00,
    TLB_FETCH = 2'b01,
    TLB_LOAD  = 2'b10,
    TLB_STORE = 2'b11
  } tlb_op_e;

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
    FP_FADD, FP_FSUB, FP_FMUL, FP_FDIV, FP_FSQRT,
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
    // Retire-trace: original 32-bit instruction word (already expanded from
    // the C-extension alignment unit, so this is the fully-expanded form).
    logic [31:0] instr;
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
    logic           is_16b;      // needed so WB computes correct pc4 link address
    logic           pred_taken;  // propagated for MEM-stage bpred target check
    logic [31:0]    pred_target; // propagated for MEM-stage bpred target check
    // Retire-trace: original 32-bit instruction word and the rs1 value fed
    // into kronos_csr (snapshot of the CSR write source operand).
    logic [31:0]    instr;
    logic [63:0]    csr_wdata;
  } ex_mem_reg_t;

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

  // -------------------------------------------------------------------------
  // Stage 5h: Event-bus IDs consumed by mhpmevent/mhpmcounter (Zihpm).
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
  // Stage 6a: New CSR addresses introduced in this stage.
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
  // PMP cfg + addr (8 active regions; pmpcfg2 + pmpaddr8..15 hardwired 0)
  localparam logic [11:0] CSR_PMPCFG0    = 12'h3A0;
  localparam logic [11:0] CSR_PMPCFG2    = 12'h3A2;
  localparam logic [11:0] CSR_PMPADDR0   = 12'h3B0;
  localparam logic [11:0] CSR_PMPADDR7   = 12'h3B7;
  localparam logic [11:0] CSR_PMPADDR8   = 12'h3B8;
  localparam logic [11:0] CSR_PMPADDR15  = 12'h3BF;

  // -------------------------------------------------------------------------
  // Stage 6b: Sv39/Sv48 satp.MODE values (RISC-V Privileged Spec § 4.1.11)
  // -------------------------------------------------------------------------
  localparam logic [3:0] SATP_MODE_BARE = 4'd0;
  localparam logic [3:0] SATP_MODE_SV39 = 4'd8;
  localparam logic [3:0] SATP_MODE_SV48 = 4'd9;

  // -------------------------------------------------------------------------
  // Stage 6b: RV64 PTE field positions (RISC-V Privileged Spec § 5.4)
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
  // Stage 6a: synchronous trap causes used by PMP and delegation paths.
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

  // -------------------------------------------------------------------------
  // Stage 7a: Reorder Buffer types
  // -------------------------------------------------------------------------
  localparam int unsigned ROB_DEPTH   = 16;
  localparam int unsigned ROB_IDX_W   = 4;  // $clog2(ROB_DEPTH)
  localparam int unsigned ROB_COUNT_W = 5;  // distinguishes empty vs full when head==tail

  typedef logic [ROB_IDX_W-1:0] rob_idx_t;

  // Per-arch-reg busy entry (used by kronos_busy.sv).
  typedef struct packed {
    logic     busy;
    rob_idx_t prod_idx;  // youngest in-flight ROB index that writes this arch reg
  } busy_entry_t;

  // Reorder buffer entry. ~24 bytes; 16 entries = ~3 Kbit register array.
  typedef struct packed {
    logic           valid;
    logic           complete;
    logic [31:0]    pc;
    logic [31:0]    instr;
    decoded_instr_t dec;
    logic [63:0]    result;
    logic [4:0]     fflags;
    logic [63:0]    csr_new_val;
    logic           trap_taken;
    logic [4:0]     trap_cause;
    logic [63:0]    tval;
    logic           actual_taken;
    logic [31:0]    actual_target;
    logic           mispredict;
    logic [63:0]    mem_addr;
    logic [63:0]    mem_wdata;
    logic [2:0]     mem_funct3;
  } rob_entry_t;

endpackage
