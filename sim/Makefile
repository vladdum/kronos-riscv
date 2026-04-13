RTL_DIR  := ../rtl
TB_DIR   := ../tb
SW_DIR   := ../sw/stage0
OBJ_DIR  := obj_dir

VERILATOR := verilator
CFLAGS    := -std=c++14

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

.PHONY: build run-% sim-alu sim-regfile sim-decode clean

build: $(SIM_BIN)

$(SIM_BIN): $(SV_FILES) sim_main.cpp
	$(VERILATOR) --cc --exe --build -Wall --Wno-UNUSED \
	  --top-module $(TOP) \
	  $(SV_FILES) sim_main.cpp \
	  -CFLAGS "$(CFLAGS)" \
	  -o V$(TOP)

run-%: build
	./$(SIM_BIN) $(SW_DIR)/$*.hex

sim-alu:
	$(VERILATOR) --binary -Wall --Wno-UNUSED \
	  --top-module tb_alu $(TB_ALU_FILES) -o obj_dir/tb_alu
	./obj_dir/tb_alu

sim-regfile:
	$(VERILATOR) --binary -Wall --Wno-UNUSED \
	  --top-module tb_regfile $(TB_REGFILE_FILES) -o obj_dir/tb_regfile
	./obj_dir/tb_regfile

sim-decode:
	$(VERILATOR) --binary -Wall --Wno-UNUSED \
	  --top-module tb_decode $(TB_DECODE_FILES) -o obj_dir/tb_decode
	./obj_dir/tb_decode

clean:
	rm -rf $(OBJ_DIR)
