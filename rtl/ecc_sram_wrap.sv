// Copyright 2020 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
// 
// Adapts bus to sram adding ecc bits

module ecc_sram_wrap #(
  parameter BANK_SIZE     = 256,
  parameter INPUT_ECC     = 0, // 0: no ECC on input
                               // 1: SECDED on input
  parameter OUTPUT_ECC    = 0, // 0: SECDED on word stores, valid bit
                               // 1: SECDED on all stores, single cycle return (buffering)
  // Set params
  localparam DATA_IN_WIDTH = 32,
  localparam BE_IN_WIDTH   = 4
) (
  input  logic clk_i,
  input  logic rst_ni,

  TCDM_BANK_MEM_BUS.Slave tcdm_slave,
  output logic tcdm_gnt_o
);
  
  localparam DATA_OUT_WIDTH = OUTPUT_ECC == 0 ? 40 : 39;
  localparam BYTE_OUT_WIDTH = OUTPUT_ECC == 0 ? 8 : 39;
  localparam BE_OUT_WIDTH   = OUTPUT_ECC == 0 ? 5 : 1;
  
  logic                         bank_req;
  logic                         bank_we;
  logic [$clog2(BANK_SIZE)-1:0] bank_add;
  logic [DATA_OUT_WIDTH-1:0]    bank_wdata;
  logic [BE_OUT_WIDTH-1:0]      bank_be;
  logic [DATA_OUT_WIDTH-1:0]    bank_rdata;

  if ( OUTPUT_ECC == 0 ) begin : ECC_0_ASSIGN
    // Adds additional byte for {valid_bit, ECC_bits[6:0]}
    // Valid bit currently used to differentiate sw (ECC working) from sb and sh (be != 4'b1111)

    logic [31:0] ecc_decoded;
    assign bank_req =  tcdm_slave.req;
    assign bank_we  = ~tcdm_slave.wen;
    assign bank_add =  tcdm_slave.add[$clog2(BANK_SIZE)-1:0];
    assign tcdm_gnt_o   = 1'b1;

    prim_secded_39_32_enc ecc_encode (
      .in  ( tcdm_slave.wdata ),
      .out ( bank_wdata[38:0] )
    );

    assign bank_be = { 1'b1, tcdm_slave.be };
    
    prim_secded_39_32_dec ecc_decode (
      .in         ( bank_rdata[38:0]    ),
      .d_o        ( ecc_decoded ),
      .syndrome_o (),
      .err_o      ()
    );
    
    always_comb begin : proc_rdata_assign
      case ( bank_rdata[39] )
        1'b0    : tcdm_slave.rdata = bank_rdata[31:0];
        1'b1    : tcdm_slave.rdata = ecc_decoded;
        default : tcdm_slave.rdata = bank_rdata[31:0];
      endcase
    end

    assign bank_wdata[39] = tcdm_slave.be == 4'b1111 ? 1'b1 : 1'b0;
  end
  else if ( OUTPUT_ECC == 1 ) begin : ECC_1_ASSIGN
    // Loads  -> loads full data
    // Stores ->
    //   If BE_in == 1111: adds ECC and stores directly
    //   If BE_in != 1111: loads stored and buffers input (responds success to store command)
    //                     re-calculates ECC and stores correctly
    
    logic [DATA_IN_WIDTH-1:0] to_store;
    logic [DATA_IN_WIDTH-1:0] loaded;
    logic [DATA_IN_WIDTH-1:0] be_selector;

    typedef enum logic { NORMAL, LOAD_AND_STORE } store_state_e;
    store_state_e store_state_d, store_state_q;

    logic [DATA_IN_WIDTH-1:0] input_buffer_d, input_buffer_q;
    logic [$clog2(BANK_SIZE)-1:0] add_buffer_d, add_buffer_q;
    logic [BE_IN_WIDTH-1:0] be_buffer_d, be_buffer_q;

    prim_secded_39_32_dec ecc_decode (
      .in         ( bank_rdata ),
      .d_o        ( loaded ),
      .syndrome_o (),
      .err_o      ()
    );

    prim_secded_39_32_enc ecc_encode (
      .in  ( to_store   ),
      .out ( bank_wdata )
    );

    assign tcdm_slave.rdata = loaded;
    assign bank_be = 1'b1;
    assign add_buffer_d = tcdm_slave.add[$clog2(BANK_SIZE)-1:0];
    assign input_buffer_d = tcdm_slave.wdata;
    assign be_buffer_d = tcdm_slave.be;
    assign be_selector = {{8{be_buffer_q[3]}},{8{be_buffer_q[2]}},{8{be_buffer_q[1]}},{8{be_buffer_q[0]}}};

    always_comb begin : proc_load_and_store_comb
      store_state_d = NORMAL;
      tcdm_gnt_o = 1'b1;
      to_store = tcdm_slave.wdata;
      bank_we = ~tcdm_slave.wen;
      bank_req = tcdm_slave.req;
      bank_add = tcdm_slave.add[$clog2(BANK_SIZE)-1:0];
      if (store_state_q == NORMAL) begin
        if (tcdm_slave.req & (tcdm_slave.be != 4'b1111) & ~tcdm_slave.wen) begin
          store_state_d = LOAD_AND_STORE;
          bank_we = 1'b0;
        end
      end else begin
        tcdm_gnt_o = 1'b0;
        to_store = (be_selector & input_buffer_q) | (~be_selector & loaded);
        bank_we = 1'b1;
        bank_req = 1'b1;
        bank_add = add_buffer_q;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_load_and_store_ff
      if(~rst_ni) begin
        store_state_q <= NORMAL;
        add_buffer_q <= '0;
        input_buffer_q <= '0;
        be_buffer_q <= '0;
      end else begin
        add_buffer_q <= add_buffer_d;
        store_state_q <= store_state_d;
        input_buffer_q <= input_buffer_d;
        be_buffer_q <= be_buffer_d;
      end
    end

// Signals needed
    // bank_req
    // bank_we
    // bank_add
    // bank_wdata
    // bank_be
    // tcdm_slave.rdata
    // tcdm_gnt_o


  end

  tc_sram #(
    .NumWords  ( BANK_SIZE      ), // Number of Words in data array
    .DataWidth ( DATA_OUT_WIDTH ), // Data signal width
    .ByteWidth ( BYTE_OUT_WIDTH ), // Width of a data byte
    .NumPorts  ( 1              ), // Number of read and write ports
    .Latency   ( 1              ), // Latency when the read data is available
    .SimInit   ( "zeros"        )
  ) i_bank (
    .clk_i,                     // Clock
    .rst_ni,                    // Asynchronous reset active low

    .req_i   ( bank_req   ),    // request
    .we_i    ( bank_we    ),    // write enable
    .addr_i  ( bank_add   ),    // request address
    .wdata_i ( bank_wdata ),    // write data
    .be_i    ( bank_be    ),    // write byte enable

    .rdata_o ( bank_rdata )     // read data
  );

endmodule
