RTL_DIR   := ../rtl
TB_DIR    := ../tb
SW_DIR    := ../sw/stage0
SW_DIR_S1 := ../sw/stage1
SW_DIR_S2 := ../sw/stage2
OBJ_DIR   := obj_dir

VERILATOR := verilator
CFLAGS    := -std=c++14

# --Wno-WIDTHEXPAND: suppress upstream axi_pkg.sv:203 width warning (PULP library bug)
# This flag is required for all invocations that include axi_pkg.sv (stage3+)

TOP       := kronos_top
SIM_BIN   := $(OBJ_DIR)/V$(TOP)

SV_FILES  := $(RTL_DIR)/kronos_pkg.sv \
             $(RTL_DIR)/stage0/kronos_alu.sv \
             $(RTL_DIR)/stage0/kronos_decode.sv \
             $(RTL_DIR)/stage0/kronos_regfile.sv \
             $(RTL_DIR)/stage0/kronos_lsu.sv \
             $(RTL_DIR)/stage0/kronos_csr.sv \
             $(RTL_DIR)/stage0/kronos_top.sv

TB_ALU_FILES := $(RTL_DIR)/kronos_pkg.sv \
                $(RTL_DIR)/stage0/kronos_alu.sv \
                $(TB_DIR)/stage0/tb_alu.sv

TB_REGFILE_FILES := $(RTL_DIR)/kronos_pkg.sv \
                    $(RTL_DIR)/stage0/kronos_regfile.sv \
                    $(TB_DIR)/stage0/tb_regfile.sv

TB_DECODE_FILES := $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage0/kronos_decode.sv \
                   $(TB_DIR)/stage0/tb_decode.sv

TB_LSU_S1_FILES := $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage1/kronos_lsu.sv \
                   $(TB_DIR)/stage1/tb_lsu_s1.sv

TB_FWD_FILES := $(RTL_DIR)/kronos_pkg.sv \
                $(RTL_DIR)/stage1/kronos_forward.sv \
                $(TB_DIR)/stage1/tb_forward.sv

TB_HZ_FILES := $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(TB_DIR)/stage1/tb_hazard.sv

SV_FILES_S1 := $(RTL_DIR)/kronos_pkg.sv \
               $(RTL_DIR)/stage0/kronos_alu.sv \
               $(RTL_DIR)/stage0/kronos_decode.sv \
               $(RTL_DIR)/stage0/kronos_regfile.sv \
               $(RTL_DIR)/stage0/kronos_csr.sv \
               $(RTL_DIR)/stage1/kronos_lsu.sv \
               $(RTL_DIR)/stage1/kronos_forward.sv \
               $(RTL_DIR)/stage1/kronos_hazard.sv \
               $(RTL_DIR)/stage1/kronos_top.sv

SIM_BIN_S1 := $(OBJ_DIR)/s1/Vkronos_top

TB_MULDIV_FILES := $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage2/kronos_muldiv.sv \
                   $(TB_DIR)/stage2/tb_muldiv.sv

SV_FILES_S2 := $(RTL_DIR)/kronos_pkg.sv \
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

.PHONY: build build-s1 build-s2 build-s3 run-% run-s0-% run-s1-% run-s2-% run-s3-% run-s3-latency-% \
        sim-alu sim-regfile sim-decode sim-compliance \
        sim-compliance-s1 sim-lsu-s1 sim-forward sim-hazard \
        sim-muldiv sim-compliance-s2 sim-lsu-s3 sim-compliance-s3 clean

build: $(SIM_BIN)

$(SIM_BIN): $(SV_FILES) sim_main.cpp
	$(VERILATOR) --cc --exe --build -Wall --Wno-UNUSED \
	  --top-module $(TOP) \
	  $(SV_FILES) sim_main.cpp \
	  -CFLAGS "$(CFLAGS)" \
	  -o V$(TOP)

build-s1: $(SIM_BIN_S1)

$(SIM_BIN_S1): $(SV_FILES_S1) sim_main.cpp
	$(VERILATOR) --cc --exe --build -Wall --Wno-UNUSED \
	  --top-module kronos_top \
	  $(SV_FILES_S1) sim_main.cpp \
	  -CFLAGS "$(CFLAGS)" \
	  -Mdir $(OBJ_DIR)/s1 \
	  -o Vkronos_top

run-%: build
	./$(SIM_BIN) $(SW_DIR)/build/$*.hex

run-s0-%: build
	./$(SIM_BIN) $(SW_DIR)/build/$*.hex

run-s1-%: build-s1
	./$(SIM_BIN_S1) $(SW_DIR_S1)/build/$*.hex

sim-alu:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_alu $(TB_ALU_FILES) -o tb_alu
	./obj_dir/tb_alu

sim-regfile:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_regfile $(TB_REGFILE_FILES) -o tb_regfile
	./obj_dir/tb_regfile

sim-decode:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_decode $(TB_DECODE_FILES) -o tb_decode
	./obj_dir/tb_decode

sim-lsu-s1:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_lsu_s1 $(TB_LSU_S1_FILES) -o tb_lsu_s1
	./obj_dir/tb_lsu_s1

sim-forward:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_forward $(TB_FWD_FILES) -o tb_forward
	./obj_dir/tb_forward

sim-hazard:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_hazard $(TB_HZ_FILES) -o tb_hazard
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
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD \
	  --top-module tb_muldiv $(TB_MULDIV_FILES) -o tb_muldiv
	./obj_dir/tb_muldiv

build-s2: $(SIM_BIN_S2)

$(SIM_BIN_S2): $(SV_FILES_S2) sim_main.cpp
	$(VERILATOR) --cc --exe --build -Wall --Wno-UNUSED \
	  --top-module kronos_top \
	  $(SV_FILES_S2) sim_main.cpp \
	  -CFLAGS "$(CFLAGS)" \
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

PULP_AXI_INC  := -I/home/popes/opensoc/hw/ip/pulp_axi/include
AXI_PKG_SV    := /home/popes/opensoc/hw/ip/pulp_axi/src/axi_pkg.sv
SW_DIR_S3     := ../sw/stage3

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
               $(RTL_DIR)/stage3/kronos_top.sv \
               sim_top.sv

TOP_S3     := sim_top
SIM_BIN_S3 := $(OBJ_DIR)/s3/V$(TOP_S3)

TB_LSU_S3_FILES := $(AXI_PKG_SV) \
                   $(RTL_DIR)/kronos_pkg.sv \
                   $(RTL_DIR)/stage3/kronos_lsu.sv \
                   $(TB_DIR)/stage3/tb_lsu_s3.sv

build-s3: $(SIM_BIN_S3)

$(SIM_BIN_S3): $(SV_FILES_S3) sim_main.cpp
	$(VERILATOR) --cc --exe --build -Wall --Wno-UNUSED --Wno-WIDTHEXPAND --Wno-PINCONNECTEMPTY \
	  --top-module $(TOP_S3) \
	  $(SV_FILES_S3) sim_main.cpp \
	  -CFLAGS "$(CFLAGS)" \
	  -Mdir $(OBJ_DIR)/s3 \
	  $(PULP_AXI_INC) \
	  -o V$(TOP_S3)

run-s3-%: build-s3
	./$(SIM_BIN_S3) $(SW_DIR_S3)/build/$*.hex

run-s3-latency-%: build-s3
	./$(SIM_BIN_S3) $(SW_DIR_S3)/build/$*.hex 2 4

sim-lsu-s3:
	$(VERILATOR) --binary -Wall --Wno-UNUSED --Wno-TIMESCALEMOD --Wno-WIDTHEXPAND \
	  --top-module tb_lsu_s3 $(TB_LSU_S3_FILES) \
	  $(PULP_AXI_INC) -Mdir $(OBJ_DIR)/tb_lsu_s3
	./$(OBJ_DIR)/tb_lsu_s3/Vtb_lsu_s3

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

clean:
	rm -rf $(OBJ_DIR)
	$(MAKE) -C $(SW_DIR) clean
	$(MAKE) -C $(SW_DIR)/compliance clean
