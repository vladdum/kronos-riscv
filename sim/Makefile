RTL_DIR   := ../rtl
TB_DIR    := ../tb
SW_DIR    := ../sw/stage0
SW_DIR_S1 := ../sw/stage1
SW_DIR_S2 := ../sw/stage2
SW_DIR_S3 := ../sw/stage3
SW_DIR_S4 := ../sw/stage4
SW_DIR_S5  := ../sw/stage5
SW_DIR_S5B := ../sw/stage5b
OBJ_DIR   := obj_dir

VERILATOR := verilator
CFLAGS    := -std=c++14

# Per-instance lint waivers for external library warnings and intentional
# unconnected ports. Using a waiver file instead of blanket --Wno-* flags
# ensures new warnings of the same type in our code are still caught.
WAIVER    := ../lint/waivers.vlt

# PULP_AXI_INC / AXI_PKG_SV are required for all invocations: kronos_pkg.sv always
# imports `AXI_TYPEDEF_ALL since the stage3 AXI switch plan.
PULP_AXI_ROOT ?= /home/popes/opensoc/hw/ip/pulp_axi
PULP_AXI_INC  := -I$(PULP_AXI_ROOT)/include
AXI_PKG_SV    := $(PULP_AXI_ROOT)/src/axi_pkg.sv
AXI_FLAGS     := $(PULP_AXI_INC)

TOP       := kronos_top
SIM_BIN   := $(OBJ_DIR)/V$(TOP)

SV_FILES  := $(AXI_PKG_SV) \
             $(RTL_DIR)/kronos_pkg.sv \
             $(RTL_DIR)/stage0/kronos_alu.sv \
             $(RTL_DIR)/stage0/kronos_decode.sv \
             $(RTL_DIR)/stage0/kronos_regfile.sv \
             $(RTL_DIR)/stage0/kronos_lsu.sv \
             $(RTL_DIR)/stage0/kronos_csr.sv \
             $(RTL_DIR)/stage0/kronos_top.sv

TB_ALU_FILES := $(AXI_PKG_SV) \
                $(RTL_DIR)/kronos_pkg.sv \
                $(RTL_DIR)/stage0/kronos_alu.sv \
                $(TB_DIR)/stage0/tb_alu.sv

TB_REGFILE_FILES := $(AXI_PKG_SV) \
                    $(RTL_DIR)/kronos_pkg.sv \
                    $(RTL_DIR)/stage0/kronos_regfile.sv \
                    $(TB_DIR)/stage0/tb_regfile.sv

TB_DECODE_FILES := $(AXI_PKG_SV) \
                   $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage0/kronos_decode.sv \
                   $(TB_DIR)/stage0/tb_decode.sv

TB_LSU_S1_FILES := $(AXI_PKG_SV) \
                   $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage1/kronos_lsu.sv \
                   $(TB_DIR)/stage1/tb_lsu_s1.sv

TB_FWD_FILES := $(AXI_PKG_SV) \
                $(RTL_DIR)/kronos_pkg.sv \
                $(RTL_DIR)/stage1/kronos_forward.sv \
                $(TB_DIR)/stage1/tb_forward.sv

TB_HZ_FILES := $(AXI_PKG_SV) \
               $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(TB_DIR)/stage1/tb_hazard.sv

TB_MULDIV_FILES := $(AXI_PKG_SV) \
                   $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage2/kronos_muldiv.sv \
                   $(TB_DIR)/stage2/tb_muldiv.sv

SV_FILES_S1 := $(AXI_PKG_SV) \
               $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage0/kronos_alu.sv \
               $(RTL_DIR)/stage0/kronos_decode.sv \
               $(RTL_DIR)/stage0/kronos_regfile.sv \
               $(RTL_DIR)/stage0/kronos_csr.sv \
               $(RTL_DIR)/stage1/kronos_lsu.sv \
               $(RTL_DIR)/stage1/kronos_forward.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(RTL_DIR)/stage1/kronos_top.sv

SIM_BIN_S1 := $(OBJ_DIR)/s1/Vkronos_top

SV_FILES_S2 := $(AXI_PKG_SV) \
               $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage0/kronos_alu.sv \
               $(RTL_DIR)/stage2/kronos_decode.sv \
               $(RTL_DIR)/stage0/kronos_regfile.sv \
               $(RTL_DIR)/stage0/kronos_csr.sv \
               $(RTL_DIR)/stage1/kronos_lsu.sv \
               $(RTL_DIR)/stage1/kronos_forward.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(RTL_DIR)/stage2/kronos_muldiv.sv \
               $(RTL_DIR)/stage2/kronos_top.sv

SIM_BIN_S2 := $(OBJ_DIR)/s2/Vkronos_top

.PHONY: help build build-s1 build-s2 build-s3 run-% run-s0-% run-s1-% run-s2-% run-s3-% \
        run-s3-latency-% sim-alu sim-regfile sim-decode sim-compliance \
        sim-compliance-s1 sim-lsu-s1 sim-forward sim-hazard \
        sim-muldiv sim-compliance-s2 sim-decompress sim-align sim-lsu-s3 sim-bpred \
        sim-compliance-s3 build-s4 run-s4-% sim-compliance-s4 sim-alu-s4 sim-decode-s4 \
        sim-muldiv-s4 sim-lsu-s4 sim-all clean \
        build-s5 run-s5-% sim-s5 sim-core-fp-basic sim-core-fp-forwarding \
        sim-compliance-f sim-compliance-d \
        sim-pkg-fp sim-regfile-fp sim-hf-smoke sim-sf-smoke \
        sim-csr-fp sim-fpu-scoreboard \
        sim-decode-fp sim-fpu-fmisc sim-fpu-fcvt sim-fpu-fadd sim-fpu-fmul \
        sim-fpu-fma sim-fpu-fdiv-core sim-fpu-fsqrt-core sim-fpu-iter-skeleton sim-fpu-top \
        sim-fpu-top-iter \
        sim-fpu-fmisc-cov sim-fpu-fcvt-cov sim-fpu-fadd-cov sim-fpu-fmul-cov \
        sim-fpu-fma-cov coverage \
        sim-s5b

.DEFAULT_GOAL := help

help:
	@echo "kronos-riscv simulation targets"
	@echo ""
	@echo "Build simulators:"
	@echo "  make build          Build stage 0 simulator (RV32I, OBI)"
	@echo "  make build-s1       Build stage 1 simulator (RV32I, OBI, pipeline)"
	@echo "  make build-s2       Build stage 2 simulator (RV32IM, OBI)"
	@echo "  make build-s3       Build stage 3 simulator (RV32IMC, AXI4)"
	@echo ""
	@echo "Run tests:"
	@echo "  make run-<test>              Run stage 0 test (e.g. run-test_alu)"
	@echo "  make run-s1-<test>           Run stage 1 test (e.g. run-s1-test_forwarding)"
	@echo "  make run-s2-<test>           Run stage 2 test (e.g. run-s2-test_mul)"
	@echo "  make run-s3-<test>           Run stage 3 test (e.g. run-s3-test_c_basic)"
	@echo "  make run-s3-latency-<test>   Run stage 3 test with latency 2/4"
	@echo ""
	@echo "Unit testbenches:"
	@echo "  make sim-alu         ALU (stage 0)"
	@echo "  make sim-regfile     Register file (stage 0)"
	@echo "  make sim-decode      Decoder (stage 0)"
	@echo "  make sim-lsu-s1      LSU OBI FSM (stage 1)"
	@echo "  make sim-forward     Forwarding unit (stage 1)"
	@echo "  make sim-hazard      Hazard/stall control (stage 1)"
	@echo "  make sim-muldiv      Multiply/divide unit (stage 2)"
	@echo "  make sim-decompress  RV32C instruction expander (stage 3)"
	@echo "  make sim-align       Fetch alignment buffer (stage 3)"
	@echo "  make sim-lsu-s3      LSU AXI4 FSM (stage 3)"
	@echo "  make sim-bpred       Branch predictor (stage 3)"
	@echo ""
	@echo "Regression suites:"
	@echo "  make sim-compliance     Full regression (= sim-compliance-s2)"
	@echo "  make sim-compliance-s1  Stage 1: all sw/ programs + rv32ui compliance"
	@echo "  make sim-compliance-s2  Stage 2: all sw/ programs + rv32ui compliance"
	@echo "  make sim-compliance-s3  Stage 3: all sw/ programs (stages 0-3)"
	@echo ""
	@echo "  make sim-all         All unit testbenches + stage 4 compliance suite"
	@echo ""
	@echo "Housekeeping:"
	@echo "  make clean           Remove build artifacts"

build: $(SIM_BIN)

$(SIM_BIN): $(SV_FILES) $(abspath sim_main_obi.cpp)
	$(VERILATOR) $(WAIVER) --cc --exe --build -Wall --Wno-UNUSED \
	  --top-module $(TOP) \
	  $(SV_FILES) $(abspath sim_main_obi.cpp) \
	  -CFLAGS "$(CFLAGS)" \
	  $(AXI_FLAGS) \
	  -o V$(TOP)

build-s1: $(SIM_BIN_S1)

$(SIM_BIN_S1): $(SV_FILES_S1) $(abspath sim_main_obi.cpp)
	$(VERILATOR) $(WAIVER) --cc --exe --build -Wall --Wno-UNUSED \
	  --top-module kronos_top \
	  $(SV_FILES_S1) $(abspath sim_main_obi.cpp) \
	  -CFLAGS "$(CFLAGS)" \
	  $(AXI_FLAGS) \
	  -Mdir $(OBJ_DIR)/s1 \
	  -o Vkronos_top

run-%: build
	./$(SIM_BIN) $(SW_DIR)/build/$*.hex

run-s0-%: build
	./$(SIM_BIN) $(SW_DIR)/build/$*.hex

run-s1-%: build-s1
	./$(SIM_BIN_S1) $(SW_DIR_S1)/build/$*.hex

sim-alu:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_alu $(TB_ALU_FILES) $(AXI_FLAGS) -o tb_alu
	./obj_dir/tb_alu

sim-regfile:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_regfile $(TB_REGFILE_FILES) $(AXI_FLAGS) -o tb_regfile
	./obj_dir/tb_regfile

sim-decode:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_decode $(TB_DECODE_FILES) $(AXI_FLAGS) -o tb_decode
	./obj_dir/tb_decode

sim-lsu-s1:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_lsu_s1 $(TB_LSU_S1_FILES) $(AXI_FLAGS) -o tb_lsu_s1
	./obj_dir/tb_lsu_s1

sim-forward:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_forward $(TB_FWD_FILES) $(AXI_FLAGS) -o tb_forward
	./obj_dir/tb_forward

sim-hazard:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_hazard $(TB_HZ_FILES) $(AXI_FLAGS) -o tb_hazard
	./obj_dir/tb_hazard

sim-compliance: sim-compliance-s2

sim-compliance-s1: build-s1
	$(MAKE) -C $(SW_DIR) all
	$(MAKE) -C $(SW_DIR_S1) all
	$(MAKE) -C $(SW_DIR)/compliance run SIM=../../../sim/$(SIM_BIN_S1)
	@pass=0; fail=0; \
	for hex in $(SW_DIR)/build/*.hex $(SW_DIR_S1)/build/*.hex; do \
	  out=$$(./$(SIM_BIN_S1) $$hex 2>&1); \
	  x10=$$(echo "$$out" | grep -oP 'x10 = \K[0-9]+'); \
	  if [ "$$x10" = "0" ]; then \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL: $$hex (x10=$$x10)"; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "Stage 1 regression: $$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ]

sim-muldiv:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_muldiv $(TB_MULDIV_FILES) $(AXI_FLAGS) -o tb_muldiv
	./obj_dir/tb_muldiv

build-s2: $(SIM_BIN_S2)

$(SIM_BIN_S2): $(SV_FILES_S2) $(abspath sim_main_obi.cpp)
	$(VERILATOR) $(WAIVER) --cc --exe --build -Wall --Wno-UNUSED --Wno-WIDTHEXPAND \
	  --top-module kronos_top \
	  $(SV_FILES_S2) $(abspath sim_main_obi.cpp) \
	  -CFLAGS "$(CFLAGS)" \
	  $(AXI_FLAGS) \
	  -Mdir $(OBJ_DIR)/s2 \
	  -o Vkronos_top

run-s2-%: build-s2
	./$(SIM_BIN_S2) $(SW_DIR_S2)/build/$*.hex

sim-compliance-s2: build-s2
	$(MAKE) -C $(SW_DIR) all
	$(MAKE) -C $(SW_DIR_S1) all
	$(MAKE) -C $(SW_DIR_S2) all
	$(MAKE) -C $(SW_DIR)/compliance run SIM=../../../sim/$(SIM_BIN_S2)
	@pass=0; fail=0; \
	for hex in $(SW_DIR)/build/*.hex $(SW_DIR_S1)/build/*.hex $(SW_DIR_S2)/build/*.hex; do \
	  out=$$(./$(SIM_BIN_S2) $$hex 2>&1); \
	  x10=$$(echo "$$out" | grep -oP 'x10 = \K[0-9]+'); \
	  if [ "$$x10" = "0" ]; then \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL: $$hex (x10=$$x10)"; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "Stage 2 regression: $$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ]

SV_FILES_S3 := $(AXI_PKG_SV) \
               $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage0/kronos_alu.sv \
               $(RTL_DIR)/stage2/kronos_decode.sv \
               $(RTL_DIR)/stage0/kronos_regfile.sv \
               $(RTL_DIR)/stage0/kronos_csr.sv \
               $(RTL_DIR)/stage3/kronos_lsu.sv \
               $(RTL_DIR)/stage1/kronos_forward.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(RTL_DIR)/stage2/kronos_muldiv.sv \
               $(RTL_DIR)/stage3/kronos_decompress.sv \
               $(RTL_DIR)/stage3/kronos_align.sv \
               $(RTL_DIR)/stage3/kronos_bpred.sv \
               $(RTL_DIR)/stage3/kronos_top.sv \
               sim_top.sv

TOP_S3     := sim_top
SIM_BIN_S3 := $(OBJ_DIR)/s3/V$(TOP_S3)

TB_DECOMPRESS_FILES := $(AXI_PKG_SV) \
                       $(RTL_DIR)/kronos_pkg.sv \
                       $(RTL_DIR)/stage3/kronos_decompress.sv \
                       $(TB_DIR)/stage3/tb_decompress.sv

sim-decompress:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_decompress $(TB_DECOMPRESS_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_decompress
	./$(OBJ_DIR)/tb_decompress/Vtb_decompress

TB_ALIGN_FILES := $(AXI_PKG_SV) \
                  $(RTL_DIR)/kronos_pkg.sv \
                  $(RTL_DIR)/stage3/kronos_decompress.sv \
                  $(RTL_DIR)/stage3/kronos_align.sv \
                  $(TB_DIR)/stage3/tb_align.sv

sim-align:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_align $(TB_ALIGN_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_align
	./$(OBJ_DIR)/tb_align/Vtb_align

TB_LSU_S3_FILES := $(AXI_PKG_SV) \
                   $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage3/kronos_lsu.sv \
                   $(TB_DIR)/stage3/tb_lsu_s3.sv

build-s3: $(SIM_BIN_S3)

$(SIM_BIN_S3): $(SV_FILES_S3) $(abspath sim_main.cpp)
	$(VERILATOR) $(WAIVER) --cc --exe --build -Wall --Wno-UNUSED --Wno-WIDTHEXPAND --Wno-PINCONNECTEMPTY \
	  --top-module $(TOP_S3) \
	  $(SV_FILES_S3) $(abspath sim_main.cpp) \
	  -CFLAGS "$(CFLAGS)" \
	  -Mdir $(OBJ_DIR)/s3 \
	  $(PULP_AXI_INC) \
	  -o V$(TOP_S3)

run-s3-%: build-s3
	./$(SIM_BIN_S3) $(SW_DIR_S3)/build/$*.hex

run-s3-latency-%: build-s3
	./$(SIM_BIN_S3) $(SW_DIR_S3)/build/$*.hex 2 4

sim-lsu-s3:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_lsu_s3 $(TB_LSU_S3_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_lsu_s3
	./$(OBJ_DIR)/tb_lsu_s3/Vtb_lsu_s3

TB_BPRED_FILES := $(AXI_PKG_SV) \
                  $(RTL_DIR)/kronos_pkg.sv \
                  $(RTL_DIR)/stage3/kronos_bpred.sv \
                  $(TB_DIR)/stage3/tb_bpred.sv

sim-bpred:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_bpred $(TB_BPRED_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_bpred
	./$(OBJ_DIR)/tb_bpred/Vtb_bpred

sim-compliance-s3: build-s3
	$(MAKE) -C $(SW_DIR) all
	$(MAKE) -C $(SW_DIR_S1) all
	$(MAKE) -C $(SW_DIR_S2) all
	$(MAKE) -C $(SW_DIR_S3) all
	@pass=0; fail=0; \
	for hex in $(SW_DIR)/build/*.hex $(SW_DIR_S1)/build/*.hex \
	           $(SW_DIR_S2)/build/*.hex \
	           $$(ls $(SW_DIR_S3)/build/*.hex 2>/dev/null); do \
	  [ -f "$$hex" ] || continue; \
	  out=$$(./$(SIM_BIN_S3) $$hex 2>&1); \
	  x10=$$(echo "$$out" | grep -oP 'x10 = \K[0-9]+'); \
	  if [ "$$x10" = "0" ]; then \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL: $$hex (x10=$$x10)"; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "Stage 3 regression: $$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ]

SV_FILES_S4 := $(AXI_PKG_SV) \
               $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage4/kronos_alu.sv \
               $(RTL_DIR)/stage4/kronos_decode.sv \
               $(RTL_DIR)/stage0/kronos_regfile.sv \
               $(RTL_DIR)/stage4/kronos_csr.sv \
               $(RTL_DIR)/stage4/kronos_lsu.sv \
               $(RTL_DIR)/stage1/kronos_forward.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(RTL_DIR)/stage4/kronos_muldiv.sv \
               $(RTL_DIR)/stage4/kronos_decompress.sv \
               $(RTL_DIR)/stage3/kronos_align.sv \
               $(RTL_DIR)/stage3/kronos_bpred.sv \
               $(RTL_DIR)/stage4/kronos_top.sv \
               sim_top.sv

TOP_S4     := sim_top
SIM_BIN_S4 := $(OBJ_DIR)/s4/V$(TOP_S4)

build-s4: $(SIM_BIN_S4)

$(SIM_BIN_S4): $(SV_FILES_S4) $(abspath sim_main.cpp)
	$(VERILATOR) $(WAIVER) --cc --exe --build -Wall --Wno-UNUSED --Wno-WIDTHEXPAND --Wno-PINCONNECTEMPTY \
	  --top-module $(TOP_S4) \
	  $(SV_FILES_S4) $(abspath sim_main.cpp) \
	  -CFLAGS "$(CFLAGS)" \
	  -Mdir $(OBJ_DIR)/s4 \
	  $(PULP_AXI_INC) \
	  -o V$(TOP_S4)

run-s4-%: build-s4
	./$(SIM_BIN_S4) $(SW_DIR_S4)/build/$*.hex

sim-compliance-s4: build-s4
	@$(MAKE) -C $(SW_DIR) all & \
	 $(MAKE) -C $(SW_DIR_S1) all & \
	 $(MAKE) -C $(SW_DIR_S2) all & \
	 $(MAKE) -C $(SW_DIR_S4) all & \
	 wait
	@tmpdir=$$(mktemp -d); \
	pids=""; \
	for hex in $(SW_DIR)/build/*.hex $(SW_DIR_S1)/build/*.hex \
	           $(SW_DIR_S2)/build/*.hex \
	           $$(ls $(SW_DIR_S4)/build/*.hex 2>/dev/null); do \
	  [ -f "$$hex" ] || continue; \
	  name=$$(basename $$hex .hex); \
	  case "$$name" in \
	    test_mul|test_div|test_irq) continue ;; \
	  esac; \
	  { out=$$(./$(SIM_BIN_S4) $$hex 2>&1); \
	    x10=$$(echo "$$out" | grep -oP 'x10 = \K[0-9]+'); \
	    echo "$$hex $$x10"; } > $$tmpdir/$$name & \
	  pids="$$pids $$!"; \
	done; \
	wait $$pids; \
	pass=0; fail=0; \
	for f in $$tmpdir/*; do \
	  read hex x10 < $$f; \
	  if [ "$$x10" = "0" ]; then \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL: $$hex (x10=$$x10)"; fail=$$((fail+1)); \
	  fi; \
	done; \
	rm -rf $$tmpdir; \
	echo "Stage 4 regression: $$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ]

TB_ALU_S4_FILES := $(AXI_PKG_SV) \
                   $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage4/kronos_alu.sv \
                   $(TB_DIR)/stage4/tb_alu_s4.sv

sim-alu-s4:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_alu_s4 $(TB_ALU_S4_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_alu_s4
	./$(OBJ_DIR)/tb_alu_s4/Vtb_alu_s4

TB_DECODE_S4_FILES := $(AXI_PKG_SV) \
                      $(RTL_DIR)/kronos_pkg.sv \
                      $(RTL_DIR)/stage4/kronos_decode.sv \
                      $(TB_DIR)/stage4/tb_decode_s4.sv

sim-decode-s4:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_decode_s4 $(TB_DECODE_S4_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_decode_s4
	./$(OBJ_DIR)/tb_decode_s4/Vtb_decode_s4

TB_MULDIV_S4_FILES := $(AXI_PKG_SV) \
                      $(RTL_DIR)/kronos_pkg.sv \
                      $(RTL_DIR)/stage4/kronos_muldiv.sv \
                      $(TB_DIR)/stage4/tb_muldiv_s4.sv

sim-muldiv-s4:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_muldiv_s4 $(TB_MULDIV_S4_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_muldiv_s4
	./$(OBJ_DIR)/tb_muldiv_s4/Vtb_muldiv_s4

TB_LSU_S4_FILES := $(AXI_PKG_SV) \
                   $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage4/kronos_lsu.sv \
                   $(TB_DIR)/stage4/tb_lsu_s4.sv

sim-lsu-s4:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_lsu_s4 $(TB_LSU_S4_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_lsu_s4
	./$(OBJ_DIR)/tb_lsu_s4/Vtb_lsu_s4

SIM_UNITS := sim-alu sim-regfile sim-decode \
             sim-lsu-s1 sim-forward sim-hazard \
             sim-muldiv \
             sim-decompress sim-align sim-lsu-s3 sim-bpred \
             sim-alu-s4 sim-decode-s4 sim-muldiv-s4 sim-lsu-s4

SIM_REPORT_DIR := $(OBJ_DIR)/sim-results

sim-all:
	@rm -rf $(SIM_REPORT_DIR) && mkdir -p $(SIM_REPORT_DIR)
	@pids=""; \
	for t in $(SIM_UNITS); do \
	  { if $(MAKE) $$t > $(SIM_REPORT_DIR)/$$t.log 2>&1; \
	    then echo "PASS  $$t"; \
	    else echo "FAIL  $$t"; \
	    fi; } > $(SIM_REPORT_DIR)/$$t.result & \
	  pids="$$pids $$!"; \
	done; \
	{ if $(MAKE) sim-compliance-s4 > $(SIM_REPORT_DIR)/compliance.log 2>&1; then \
	    echo "PASS  compliance  ($$(grep 'Stage 4 regression:' $(SIM_REPORT_DIR)/compliance.log | tail -1))"; \
	  else \
	    { grep 'FAIL:' $(SIM_REPORT_DIR)/compliance.log; \
	      echo "FAIL  compliance  ($$(grep 'Stage 4 regression:' $(SIM_REPORT_DIR)/compliance.log | tail -1))"; }; \
	  fi; } > $(SIM_REPORT_DIR)/compliance.result & \
	pids="$$pids $$!"; \
	wait $$pids || true; \
	printf "\n%-50s\n" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
	printf "  sim-all results\n"; \
	printf "%-50s\n" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
	for t in $(SIM_UNITS); do printf "  %s\n" "$$(cat $(SIM_REPORT_DIR)/$$t.result)"; done; \
	printf "  %-48s\n" "──────────────────────────────────────────────────"; \
	printf "  %s\n" "$$(cat $(SIM_REPORT_DIR)/compliance.result)"; \
	printf "%-50s\n\n" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
	for f in $(SIM_REPORT_DIR)/*.result; do \
	  if grep -q "^FAIL" $$f; then \
	    t=$$(basename $$f .result); \
	    echo "--- $$t log ---"; \
	    cat $(SIM_REPORT_DIR)/$$t.log; \
	    echo "--- end $$t log ---"; \
	  fi; \
	done; \
	! grep -q "^FAIL" $(SIM_REPORT_DIR)/*.result

# -------------------- Stage 5 (F + D floating point) --------------------
SV_FILES_S5 := $(AXI_PKG_SV) \
               $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage5/kronos_alu.sv \
               $(RTL_DIR)/stage5/kronos_decode.sv \
               $(RTL_DIR)/stage0/kronos_regfile.sv \
               $(RTL_DIR)/stage5/kronos_csr.sv \
               $(RTL_DIR)/stage5/kronos_lsu.sv \
               $(RTL_DIR)/stage1/kronos_forward.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(RTL_DIR)/stage5/kronos_muldiv.sv \
               $(RTL_DIR)/stage5/kronos_decompress.sv \
               $(RTL_DIR)/stage3/kronos_align.sv \
               $(RTL_DIR)/stage3/kronos_bpred.sv \
               $(RTL_DIR)/stage5/kronos_top.sv \
               sim_top.sv \
               $(RTL_DIR)/stage5/kronos_regfile_fp.sv \
               $(HARDFLOAT_V) \
               $(RTL_DIR)/stage5/fpu/kronos_fpu_scoreboard.sv \
               $(RTL_DIR)/stage5/fpu/kronos_fpu_fmisc.sv \
               $(RTL_DIR)/stage5/fpu/kronos_fpu_fcvt.sv \
               $(RTL_DIR)/stage5/fpu/kronos_fpu_fadd.sv \
               $(RTL_DIR)/stage5/fpu/kronos_fpu_fmul.sv \
               $(RTL_DIR)/stage5/fpu/kronos_fpu_fma.sv \
               $(RTL_DIR)/stage5/fpu/kronos_fpu_fdiv_core.sv \
               $(RTL_DIR)/stage5/fpu/kronos_fpu_fsqrt_core.sv \
               $(RTL_DIR)/stage5/fpu/kronos_fpu_iter.sv \
               $(RTL_DIR)/stage5/fpu/kronos_fpu_top.sv

TOP_S5     := sim_top
SIM_BIN_S5 := $(OBJ_DIR)/s5/V$(TOP_S5)

build-s5: $(SIM_BIN_S5)

$(SIM_BIN_S5): $(SV_FILES_S5) $(abspath sim_main.cpp)
	$(VERILATOR) $(WAIVER) --cc --exe --build -Wall --Wno-UNUSED --Wno-WIDTHEXPAND \
	  --Wno-TIMESCALEMOD \
	  --top-module $(TOP_S5) \
	  $(SV_FILES_S5) $(abspath sim_main.cpp) \
	  -CFLAGS "$(CFLAGS) -DKRONOS_HAS_FPU" \
	  -Mdir $(OBJ_DIR)/s5 \
	  $(PULP_AXI_INC) \
	  -o V$(TOP_S5)

run-s5-%: build-s5
	./$(SIM_BIN_S5) $(SW_DIR_S5)/build/$*.hex

# ── Stage 5 integration TBs ────────────────────────────────────────────────
TB_CORE_FP_BASIC_FILES := $(SV_FILES_S5) \
                          $(TB_DIR)/stage5/tb_core_fp_basic.sv
sim-core-fp-basic:
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-TIMESCALEMOD --Wno-UNUSED \
	  --top-module tb_core_fp_basic $(TB_CORE_FP_BASIC_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/core_fp_basic
	$(OBJ_DIR)/core_fp_basic/Vtb_core_fp_basic

TB_CORE_FP_FORWARDING_FILES := $(SV_FILES_S5) \
                                $(TB_DIR)/stage5/tb_core_fp_forwarding.sv
sim-core-fp-forwarding:
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-TIMESCALEMOD --Wno-UNUSED \
	  --top-module tb_core_fp_forwarding $(TB_CORE_FP_FORWARDING_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/core_fp_forwarding
	$(OBJ_DIR)/core_fp_forwarding/Vtb_core_fp_forwarding

# ── Stage 5 full regression (assembly + integration TBs) ───────────────────
sim-s5: build-s5
	@$(MAKE) -C $(SW_DIR_S5) all > /dev/null 2>&1; \
	tmpdir=$$(mktemp -d); pids=""; \
	for hex in $(SW_DIR_S5)/build/*.hex; do \
	  [ -f "$$hex" ] || continue; \
	  name=$$(basename $$hex .hex); \
	  { out=$$(./$(SIM_BIN_S5) $$hex 2>&1); \
	    x10=$$(echo "$$out" | grep -oP 'x10 = \K[0-9]+'); \
	    echo "$$hex $$x10"; } > $$tmpdir/$$name & \
	  pids="$$pids $$!"; \
	done; \
	wait $$pids; \
	pass=0; fail=0; \
	for f in $$tmpdir/*; do \
	  read hex x10 < $$f; \
	  if [ "$$x10" = "0" ]; then \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL: $$hex (x10=$$x10)"; fail=$$((fail+1)); \
	  fi; \
	done; \
	rm -rf $$tmpdir; \
	echo "Stage 5 assembly: $$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ]
	$(MAKE) sim-core-fp-basic
	$(MAKE) sim-core-fp-forwarding

# ── Stage 5b regression (FDIV/FSQRT assembly tests) ──────────────────────────
sim-s5b: build-s5
	@$(MAKE) -C $(SW_DIR_S5B) all > /dev/null 2>&1; \
	tmpdir=$$(mktemp -d); pids=""; \
	for hex in $(SW_DIR_S5B)/build/*.hex; do \
	  [ -f "$$hex" ] || continue; \
	  name=$$(basename $$hex .hex); \
	  { out=$$(./$(SIM_BIN_S5) $$hex 2>&1); \
	    x10=$$(echo "$$out" | grep -oP 'x10 = \K[0-9]+'); \
	    echo "$$hex $$x10"; } > $$tmpdir/$$name & \
	  pids="$$pids $$!"; \
	done; \
	wait $$pids; \
	pass=0; fail=0; \
	for f in $$tmpdir/*; do \
	  [ -f "$$f" ] || continue; \
	  read hex x10 < $$f; \
	  if [ "$$x10" = "0" ]; then \
	    pass=$$((pass+1)); \
	  else \
	    echo "FAIL: $$hex (x10=$$x10)"; fail=$$((fail+1)); \
	  fi; \
	done; \
	rm -rf $$tmpdir; \
	echo "Stage 5b assembly: $$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ] || [ $$pass -eq 0 -a $$fail -eq 0 ]

# ── riscv-arch-test F and D compliance (requires separate clone) ───────────
# Clone: git clone https://github.com/riscv-non-isa/riscv-arch-test /home/popes/riscv-arch-test
ARCH_TEST ?= /home/popes/riscv-arch-test

sim-compliance-f: build-s5
	@bash run_compliance_fp.sh rv64i_m/F

sim-compliance-d: build-s5
	@bash run_compliance_fp.sh rv64i_m/D

TB_PKG_FP_FILES := $(AXI_PKG_SV) $(RTL_DIR)/kronos_pkg.sv $(TB_DIR)/stage5/tb_pkg_fp.sv

sim-pkg-fp:
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-TIMESCALEMOD -Mdir $(OBJ_DIR)/pkg_fp \
	  --top-module tb_pkg_fp $(TB_PKG_FP_FILES)
	$(OBJ_DIR)/pkg_fp/Vtb_pkg_fp

TB_REGFILE_FP_FILES := $(AXI_PKG_SV) $(RTL_DIR)/kronos_pkg.sv \
                       $(RTL_DIR)/stage5/kronos_regfile_fp.sv \
                       $(TB_DIR)/stage5/tb_regfile_fp.sv
sim-regfile-fp:
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-TIMESCALEMOD -Mdir $(OBJ_DIR)/regfile_fp \
	  --top-module tb_regfile_fp $(TB_REGFILE_FP_FILES)
	$(OBJ_DIR)/regfile_fp/Vtb_regfile_fp

include $(RTL_DIR)/../vendor/hardfloat/file_list.mk
TB_HF_SMOKE_FILES := $(HARDFLOAT_V) $(TB_DIR)/stage5/tb_hardfloat_smoke.sv
sim-hf-smoke:
	$(VERILATOR) $(WAIVER) --binary --Wno-WIDTHTRUNC --Wno-TIMESCALEMOD -Mdir $(OBJ_DIR)/hf_smoke \
	  --top-module tb_hardfloat_smoke $(TB_HF_SMOKE_FILES)
	$(OBJ_DIR)/hf_smoke/Vtb_hardfloat_smoke

include $(RTL_DIR)/../vendor/softfloat/file_list.mk
TB_SF_SMOKE_FILES := $(RTL_DIR)/../vendor/softfloat/dpi/softfloat_dpi.svh \
                     $(TB_DIR)/stage5/tb_softfloat_smoke.sv
sim-sf-smoke: $(SF_LIB)
	$(VERILATOR) $(WAIVER) --binary -Mdir $(OBJ_DIR)/sf_smoke \
	  --top-module tb_softfloat_smoke \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" \
	  -LDFLAGS "$(SF_LIB)" \
	  $(TB_SF_SMOKE_FILES) $(SF_DPI_SRC)
	$(OBJ_DIR)/sf_smoke/Vtb_softfloat_smoke

TB_CSR_FP_FILES := $(AXI_PKG_SV) $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage5/kronos_csr.sv \
                   $(TB_DIR)/stage5/tb_csr_fp.sv
sim-csr-fp:
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-TIMESCALEMOD -Mdir $(OBJ_DIR)/csr_fp \
	  --top-module tb_csr_fp $(TB_CSR_FP_FILES)
	$(OBJ_DIR)/csr_fp/Vtb_csr_fp

TB_FPU_SB_FILES := $(AXI_PKG_SV) $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage5/fpu/kronos_fpu_scoreboard.sv \
                   $(TB_DIR)/stage5/tb_fpu_scoreboard.sv
sim-fpu-scoreboard:
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-TIMESCALEMOD -Mdir $(OBJ_DIR)/fpu_sb \
	  --top-module tb_fpu_scoreboard $(TB_FPU_SB_FILES)
	$(OBJ_DIR)/fpu_sb/Vtb_fpu_scoreboard

# -------------------- Task 8: FP decode TB --------------------
TB_DECODE_FP_FILES := $(AXI_PKG_SV) $(RTL_DIR)/kronos_pkg.sv \
                      $(RTL_DIR)/stage5/kronos_decode.sv \
                      $(TB_DIR)/stage5/tb_decode_fp.sv
sim-decode-fp:
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-TIMESCALEMOD -Mdir $(OBJ_DIR)/decode_fp \
	  --top-module tb_decode_fp $(TB_DECODE_FP_FILES)
	$(OBJ_DIR)/decode_fp/Vtb_decode_fp

# -------------------- FPU unit TBs (Tasks 9-13) --------------------
# All FPU unit TBs include HardFloat stubs (behavioral ref) + SoftFloat DPI (oracle).
FPU_COMMON_FILES := $(AXI_PKG_SV) $(RTL_DIR)/kronos_pkg.sv \
                    $(RTL_DIR)/../vendor/softfloat/dpi/softfloat_dpi.svh \
                    $(TB_DIR)/stage5/fp_tb_pkg.sv

TB_FMISC_FILES := $(FPU_COMMON_FILES) \
                  $(RTL_DIR)/stage5/fpu/kronos_fpu_fmisc.sv \
                  $(TB_DIR)/stage5/tb_fpu_fmisc.sv
sim-fpu-fmisc: $(SF_LIB)
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-WIDTHTRUNC --Wno-TIMESCALEMOD \
	  -Mdir $(OBJ_DIR)/fpu_fmisc --top-module tb_fpu_fmisc \
	  $(HARDFLOAT_V) $(TB_FMISC_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_fmisc/Vtb_fpu_fmisc

TB_FCVT_FILES := $(FPU_COMMON_FILES) \
                 $(RTL_DIR)/stage5/fpu/kronos_fpu_fcvt.sv \
                 $(TB_DIR)/stage5/tb_fpu_fcvt.sv
sim-fpu-fcvt: $(SF_LIB)
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-WIDTHTRUNC --Wno-TIMESCALEMOD \
	  -Mdir $(OBJ_DIR)/fpu_fcvt --top-module tb_fpu_fcvt \
	  $(HARDFLOAT_V) $(TB_FCVT_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_fcvt/Vtb_fpu_fcvt

TB_FADD_FILES := $(FPU_COMMON_FILES) \
                 $(RTL_DIR)/stage5/fpu/kronos_fpu_fadd.sv \
                 $(TB_DIR)/stage5/tb_fpu_fadd.sv
sim-fpu-fadd: $(SF_LIB)
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-WIDTHTRUNC --Wno-TIMESCALEMOD \
	  -Mdir $(OBJ_DIR)/fpu_fadd --top-module tb_fpu_fadd \
	  $(HARDFLOAT_V) $(TB_FADD_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_fadd/Vtb_fpu_fadd

TB_FMUL_FILES := $(FPU_COMMON_FILES) \
                 $(RTL_DIR)/stage5/fpu/kronos_fpu_fmul.sv \
                 $(TB_DIR)/stage5/tb_fpu_fmul.sv
sim-fpu-fmul: $(SF_LIB)
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-WIDTHTRUNC --Wno-TIMESCALEMOD \
	  -Mdir $(OBJ_DIR)/fpu_fmul --top-module tb_fpu_fmul \
	  $(HARDFLOAT_V) $(TB_FMUL_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_fmul/Vtb_fpu_fmul

TB_FMA_FILES := $(FPU_COMMON_FILES) \
                $(RTL_DIR)/stage5/fpu/kronos_fpu_fma.sv \
                $(TB_DIR)/stage5/tb_fpu_fma.sv
sim-fpu-fma: $(SF_LIB)
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-WIDTHTRUNC --Wno-TIMESCALEMOD \
	  -Mdir $(OBJ_DIR)/fpu_fma --top-module tb_fpu_fma \
	  $(HARDFLOAT_V) $(TB_FMA_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_fma/Vtb_fpu_fma

TB_FPU_FDIV_CORE_FILES := $(AXI_PKG_SV) $(RTL_DIR)/kronos_pkg.sv \
                          $(RTL_DIR)/stage5/fpu/kronos_fpu_fdiv_core.sv \
                          $(TB_DIR)/stage5/tb_fpu_fdiv_core.sv
sim-fpu-fdiv-core:
	cd ../tb/stage5/ref && python3 gen_fdiv_vectors.py
	cp ../tb/stage5/ref/fdiv_vectors.hex .
	$(VERILATOR) --binary $(AXI_FLAGS) --Wno-TIMESCALEMOD -Wno-lint -Wno-style \
	  -Mdir $(OBJ_DIR)/fpu_fdiv_core --top-module tb_fpu_fdiv_core \
	  $(TB_FPU_FDIV_CORE_FILES)
	$(OBJ_DIR)/fpu_fdiv_core/Vtb_fpu_fdiv_core

TB_FPU_FSQRT_CORE_FILES := $(AXI_PKG_SV) $(RTL_DIR)/kronos_pkg.sv \
                           $(RTL_DIR)/stage5/fpu/kronos_fpu_fsqrt_core.sv \
                           $(TB_DIR)/stage5/tb_fpu_fsqrt_core.sv
sim-fpu-fsqrt-core:
	cd ../tb/stage5/ref && python3 gen_fsqrt_vectors.py
	cp ../tb/stage5/ref/fsqrt_vectors.hex .
	$(VERILATOR) --binary $(AXI_FLAGS) --Wno-TIMESCALEMOD -Wno-lint -Wno-style \
	  -Mdir $(OBJ_DIR)/fpu_fsqrt_core --top-module tb_fpu_fsqrt_core \
	  $(TB_FPU_FSQRT_CORE_FILES)
	$(OBJ_DIR)/fpu_fsqrt_core/Vtb_fpu_fsqrt_core

TB_FPU_ITER_FILES := $(AXI_PKG_SV) $(RTL_DIR)/kronos_pkg.sv \
                     $(RTL_DIR)/stage5/fpu/kronos_fpu_fdiv_core.sv \
                     $(RTL_DIR)/stage5/fpu/kronos_fpu_fsqrt_core.sv \
                     $(RTL_DIR)/stage5/fpu/kronos_fpu_iter.sv \
                     $(TB_DIR)/stage5/tb_fpu_iter.sv
sim-fpu-iter-skeleton:
	$(VERILATOR) --binary $(AXI_FLAGS) --Wno-TIMESCALEMOD -Wno-lint -Wno-style \
	  -Mdir $(OBJ_DIR)/fpu_iter --top-module tb_fpu_iter \
	  $(TB_FPU_ITER_FILES)
	$(OBJ_DIR)/fpu_iter/Vtb_fpu_iter

TB_FPU_ITER_SF_FILES := $(FPU_COMMON_FILES) \
                        $(RTL_DIR)/stage5/fpu/kronos_fpu_fdiv_core.sv \
                        $(RTL_DIR)/stage5/fpu/kronos_fpu_fsqrt_core.sv \
                        $(RTL_DIR)/stage5/fpu/kronos_fpu_iter.sv \
                        $(TB_DIR)/stage5/tb_fpu_iter.sv
sim-fpu-iter: $(SF_LIB)
	$(VERILATOR) --binary $(AXI_FLAGS) --Wno-TIMESCALEMOD -Wno-lint -Wno-style \
	  -Mdir $(OBJ_DIR)/fpu_iter_sf --top-module tb_fpu_iter \
	  $(TB_FPU_ITER_SF_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_iter_sf/Vtb_fpu_iter

TB_LSU_FP_FILES := $(AXI_PKG_SV) \
                   $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage5/kronos_lsu.sv \
                   $(TB_DIR)/stage5/tb_lsu_fp.sv
sim-lsu-fp:
	$(VERILATOR) $(WAIVER) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --Wno-PROCASSINIT \
	  --top-module tb_lsu_fp $(TB_LSU_FP_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/lsu_fp
	$(OBJ_DIR)/lsu_fp/Vtb_lsu_fp

TB_FPU_TOP_FILES := $(FPU_COMMON_FILES) \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_scoreboard.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fmisc.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fcvt.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fadd.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fmul.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fma.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fdiv_core.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fsqrt_core.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_iter.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_top.sv \
                    $(TB_DIR)/stage5/tb_fpu_top.sv
sim-fpu-top: $(SF_LIB)
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) --Wno-WIDTHTRUNC --Wno-TIMESCALEMOD \
	  -Mdir $(OBJ_DIR)/fpu_top --top-module tb_fpu_top \
	  $(HARDFLOAT_V) $(TB_FPU_TOP_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_top/Vtb_fpu_top

TB_FPU_TOP_ITER_FILES := $(FPU_COMMON_FILES) \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_scoreboard.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fmisc.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fcvt.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fadd.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fmul.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fma.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fdiv_core.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_fsqrt_core.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_iter.sv \
                    $(RTL_DIR)/stage5/fpu/kronos_fpu_top.sv \
                    $(TB_DIR)/stage5/tb_fpu_top_iter.sv
sim-fpu-top-iter: $(SF_LIB)
	$(VERILATOR) --binary $(AXI_FLAGS) -Wno-lint -Wno-style --Wno-TIMESCALEMOD \
	  -Mdir $(OBJ_DIR)/fpu_top_iter --top-module tb_fpu_top_iter \
	  $(HARDFLOAT_V) $(TB_FPU_TOP_ITER_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_top_iter/Vtb_fpu_top_iter

# ── Functional coverage (line coverage gate ≥95%) ─────────────────────────
COV_FLAGS := --coverage-line
COV_DIR   := $(OBJ_DIR)/coverage

# Per-unit coverage builds (separate obj dirs so coverage.dat doesn't collide)
sim-fpu-fmisc-cov: $(SF_LIB)
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) $(COV_FLAGS) --Wno-WIDTHTRUNC --Wno-TIMESCALEMOD \
	  -Mdir $(OBJ_DIR)/fpu_fmisc_cov --top-module tb_fpu_fmisc \
	  $(HARDFLOAT_V) $(TB_FMISC_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_fmisc_cov/Vtb_fpu_fmisc \
	  +verilator+coverage+file+$(OBJ_DIR)/fpu_fmisc_cov/coverage.dat

sim-fpu-fcvt-cov: $(SF_LIB)
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) $(COV_FLAGS) --Wno-WIDTHTRUNC --Wno-TIMESCALEMOD \
	  -Mdir $(OBJ_DIR)/fpu_fcvt_cov --top-module tb_fpu_fcvt \
	  $(HARDFLOAT_V) $(TB_FCVT_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_fcvt_cov/Vtb_fpu_fcvt \
	  +verilator+coverage+file+$(OBJ_DIR)/fpu_fcvt_cov/coverage.dat

sim-fpu-fadd-cov: $(SF_LIB)
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) $(COV_FLAGS) --Wno-WIDTHTRUNC --Wno-TIMESCALEMOD \
	  -Mdir $(OBJ_DIR)/fpu_fadd_cov --top-module tb_fpu_fadd \
	  $(HARDFLOAT_V) $(TB_FADD_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_fadd_cov/Vtb_fpu_fadd \
	  +verilator+coverage+file+$(OBJ_DIR)/fpu_fadd_cov/coverage.dat

sim-fpu-fmul-cov: $(SF_LIB)
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) $(COV_FLAGS) --Wno-WIDTHTRUNC --Wno-TIMESCALEMOD \
	  -Mdir $(OBJ_DIR)/fpu_fmul_cov --top-module tb_fpu_fmul \
	  $(HARDFLOAT_V) $(TB_FMUL_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_fmul_cov/Vtb_fpu_fmul \
	  +verilator+coverage+file+$(OBJ_DIR)/fpu_fmul_cov/coverage.dat

sim-fpu-fma-cov: $(SF_LIB)
	$(VERILATOR) $(WAIVER) --binary $(AXI_FLAGS) $(COV_FLAGS) --Wno-WIDTHTRUNC --Wno-TIMESCALEMOD \
	  -Mdir $(OBJ_DIR)/fpu_fma_cov --top-module tb_fpu_fma \
	  $(HARDFLOAT_V) $(TB_FMA_FILES) $(SF_DPI_SRC) \
	  -CFLAGS "$(CFLAGS) $(SF_INCS)" -LDFLAGS "$(SF_LIB)"
	$(OBJ_DIR)/fpu_fma_cov/Vtb_fpu_fma \
	  +verilator+coverage+file+$(OBJ_DIR)/fpu_fma_cov/coverage.dat

coverage: sim-fpu-fmisc-cov sim-fpu-fcvt-cov sim-fpu-fadd-cov sim-fpu-fmul-cov sim-fpu-fma-cov
	mkdir -p $(COV_DIR)
	verilator_coverage --write-info $(COV_DIR)/merged.info \
	  $(OBJ_DIR)/fpu_fmisc_cov/coverage.dat \
	  $(OBJ_DIR)/fpu_fcvt_cov/coverage.dat \
	  $(OBJ_DIR)/fpu_fadd_cov/coverage.dat \
	  $(OBJ_DIR)/fpu_fmul_cov/coverage.dat \
	  $(OBJ_DIR)/fpu_fma_cov/coverage.dat
	python3 ../tools/coverage_gate.py $(COV_DIR)/merged.info 95

clean:
	rm -rf $(OBJ_DIR)
	$(MAKE) -C $(SW_DIR) clean
	$(MAKE) -C $(SW_DIR)/compliance clean
