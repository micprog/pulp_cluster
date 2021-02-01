// Copyright 2021 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

`include "pulp_soc_defines.sv"
`include "periph_bus_defines.sv"

// USER DEFINED MACROS to improve self-testing capabilities
`ifndef PULP_FPGA_SIM
  `define DEBUG_FETCH_INTERFACE
`endif
//`define DATA_MISS
//`define DUMP_INSTR_FETCH

module core_region_new #(
  // CORE PARAMETERS
  parameter CORE_TYPE_CL        = 0                                      , // 0 for RISCY, 1 for IBEX RV32IMC (formerly ZERORISCY), 2 for IBEX RV32EC (formerly MICRORISCY)
  // parameter USE_FPU             = 1,
  // parameter USE_HWPE            = 1,
  localparam N_EXT_PERF_COUNTERS = 5                                      ,
  parameter CORE_ID             = 0                                      ,
  parameter ADDR_WIDTH          = 32                                     ,
  parameter DATA_WIDTH          = 32                                     ,
  parameter INSTR_RDATA_WIDTH   = 32                                     ,
  parameter CLUSTER_ALIAS_BASE  = 12'h000                                ,
  parameter REMAP_ADDRESS       = 0                                      ,
  
  parameter APU_NARGS_CPU       = 2                                      ,
  parameter APU_WOP_CPU         = 1                                      ,
  parameter WAPUTYPE            = 3                                      ,
  parameter APU_NDSFLAGS_CPU    = 3                                      ,
  parameter APU_NUSFLAGS_CPU    = 5                                      ,
  
  parameter FPU                 = 0                                      ,
  parameter FP_DIVSQRT          = 0                                      ,
  parameter SHARED_FP           = 0                                      ,
  parameter SHARED_FP_DIVSQRT   = 0                                      ,
  
  parameter DEBUG_START_ADDR    = `DEBUG_START_ADDR                      ,
  
  parameter L2_SLM_FILE         = "./slm_files/l2_stim.slm"              ,
  parameter ROM_SLM_FILE        = "../sw/apps/boot/slm_files/l2_stim.slm"
) (
  input  logic                               clk_i                ,
  input  logic                               rst_ni               ,
  input  logic                               init_ni              ,
  input  logic [                  3:0]       base_addr_i          , // FOR CLUSTER VIRTUALIZATION
  input  logic [                  5:0]       cluster_id_i         ,
  input  logic                               irq_req_i            ,
  output logic                               irq_ack_o            ,
  input  logic [                  4:0]       irq_id_i             ,
  output logic [                  4:0]       irq_ack_id_o         ,
  input  logic                               clock_en_i           ,
  input  logic                               fetch_en_i           ,
  input  logic                               fregfile_disable_i   ,
  input  logic [                 31:0]       boot_addr_i          ,
  input  logic                               test_mode_i          ,
  output logic                               core_busy_o          ,
  // Interface to Instruction Logarithmic interconnect (Req->grant handshake)
  output logic                               instr_req_o          ,
  input  logic                               instr_gnt_i          ,
  output logic [                 31:0]       instr_addr_o         ,
  input  logic [INSTR_RDATA_WIDTH-1:0]       instr_r_rdata_i      ,
  input  logic                               instr_r_valid_i      ,
  input  logic                               debug_req_i          ,
  //XBAR_TCDM_BUS.Slave     debug_bus,
  //output logic            debug_core_halted_o,
  //input logic             debug_core_halt_i,
  //input logic             debug_core_resume_i,
  // Interface for DEMUX to TCDM INTERCONNECT ,PERIPHERAL INTERCONNECT and DMA CONTROLLER
  XBAR_TCDM_BUS.Master                       tcdm_data_master     ,
  //XBAR_TCDM_BUS.Master dma_ctrl_master,
  XBAR_PERIPH_BUS.Master                     eu_ctrl_master       ,
  XBAR_PERIPH_BUS.Master                     periph_data_master
  // new interface signals
`ifdef SHARED_FPU_CLUSTER
  // TODO: Ensure disable if CORE_TYPE_CL != 0
  ,
  output logic                               apu_master_req_o     ,
  input  logic                               apu_master_gnt_i     ,
  // request channel
  output logic [         WAPUTYPE-1:0]       apu_master_type_o    ,
  output logic [    APU_NARGS_CPU-1:0][31:0] apu_master_operands_o,
  output logic [      APU_WOP_CPU-1:0]       apu_master_op_o      ,
  output logic [ APU_NDSFLAGS_CPU-1:0]       apu_master_flags_o   ,
  // response channel
  output logic                               apu_master_ready_o   ,
  input  logic                               apu_master_valid_i   ,
  input  logic [                 31:0]       apu_master_result_i  ,
  input  logic [ APU_NUSFLAGS_CPU-1:0]       apu_master_flags_i
`endif
);
  

  XBAR_TCDM_BUS s_core_bus();
  logic [N_EXT_PERF_COUNTERS-1:0] perf_counters;

  cluster_core_assist #(
    .ADDR_WIDTH         (ADDR_WIDTH         ),
    .DATA_WIDTH         (DATA_WIDTH         ),
    .BE_WIDTH           (DATA_WIDTH/8       ),
    .CLUSTER_ALIAS_BASE (CLUSTER_ALIAS_BASE ),
    .INSTR_RDATA_WIDTH  (INSTR_RDATA_WIDTH  ),
    .N_EXT_PERF_COUNTERS(N_EXT_PERF_COUNTERS)
  ) core_assist_i (
    .clk_i             (clk_i             ),
    .rst_ni            (rst_ni            ),
    .clock_en_i        (clock_en_i        ),
    .test_mode_i       (test_mode_i       ),
    .cluster_id_i      (cluster_id_i      ),
    .base_addr_i       (base_addr_i       ),
    .perf_counters_o   (perf_counters     ),
    .core_bus_slave    (s_core_bus        ),
    .tcdm_data_master  (tcdm_data_master  ),
    .eu_ctrl_master    (eu_ctrl_master    ),
    .periph_data_master(periph_data_master)
  );

  cluster_core_wrap #(
    .CORE_TYPE_CL       (CORE_TYPE_CL       ),
    .N_EXT_PERF_COUNTERS(N_EXT_PERF_COUNTERS),
    .FPU                (FPU                ),
    .FP_DIVSQRT         (FP_DIVSQRT         ),
    .SHARED_FP          (SHARED_FP          ),
    .SHARED_FP_DIVSQRT  (SHARED_FP_DIVSQRT  ),
    .WAPUTYPE           (WAPUTYPE           ),
    .DEBUG_START_ADDR   (DEBUG_START_ADDR   ),
    .INSTR_RDATA_WIDTH  (INSTR_RDATA_WIDTH  ),
    .APU_NARGS_CPU      (APU_NARGS_CPU      ),
    .APU_WOP_CPU        (APU_WOP_CPU        ),
    .APU_NDSFLAGS_CPU   (APU_NDSFLAGS_CPU   ),
    .APU_NUSFLAGS_CPU   (APU_NUSFLAGS_CPU   )
  ) core_wrap_i (
    .clk_i                (clk_i                ),
    .rst_ni               (rst_ni               ),
    .core_id_i            (CORE_ID[3:0]         ),
    .cluster_id_i         (cluster_id_i         ),
    .irq_req_i            (irq_req_i            ),
    .irq_ack_o            (irq_ack_o            ),
    .irq_id_i             (irq_id_i             ),
    .irq_ack_id_o         (irq_ack_id_o         ),
    .clock_en_i           (clock_en_i           ),
    .fetch_en_i           (fetch_en_i           ),
    .fregfile_disable_i   (fregfile_disable_i   ),
    .boot_addr_i          (boot_addr_i          ),
    .test_mode_i          (test_mode_i          ),
    .core_busy_o          (core_busy_o          ),
    .instr_req_o          (instr_req_o          ),
    .instr_gnt_i          (instr_gnt_i          ),
    .instr_addr_o         (instr_addr_o         ),
    .instr_r_rdata_i      (instr_r_rdata_i      ),
    .instr_r_valid_i      (instr_r_valid_i      ),
    .debug_req_i          (debug_req_i          ),
    .core_bus_master      (s_core_bus           ),
    .apu_master_req_o     (apu_master_req_o     ),
    .apu_master_gnt_i     (apu_master_gnt_i     ),
    .apu_master_type_o    (apu_master_type_o    ),
    .apu_master_operands_o(apu_master_operands_o),
    .apu_master_op_o      (apu_master_op_o      ),
    .apu_master_flags_o   (apu_master_flags_o   ),
    .apu_master_ready_o   (apu_master_ready_o   ),
    .apu_master_valid_i   (apu_master_valid_i   ),
    .apu_master_result_i  (apu_master_result_i  ),
    .apu_master_flags_i   (apu_master_flags_i   ),
    .perf_counters_i      (perf_counters        )
  );

`ifndef SHARED_FPU_CLUSTER
  assign apu_master_gnt_i    = '1;
  assign apu_master_valid_i  = '0;
  assign apu_master_result_i = '0;
  assign apu_master_flags_i  = '0;
`endif

endmodule : core_region_new
