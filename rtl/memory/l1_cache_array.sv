`default_nettype none
// shared L1 flop storage with clock gates for tags and data bytes or whole lines.

// use SKY130 gates for synthesis and the latch model for Verilator, including mutant builds.
`ifdef SYNTHESIS
`ifndef VERILATOR
`define L1_CACHE_GATE_CELL
`endif
`endif

`ifdef L1_CACHE_GATE_CELL
(* blackbox *) module sky130_fd_sc_hd__dlclkp_1 (input wire CLK, input wire GATE, output wire GCLK);
endmodule
`endif

/* verilator lint_off DECLFILENAME */
module l1_cache_array_gate (
  input  wire clk_i,
  input  wire enable_i,

  output wire gclk_o
);
`ifdef L1_CACHE_GATE_CELL
  sky130_fd_sc_hd__dlclkp_1 u_gate (.CLK(clk_i), .GATE(enable_i), .GCLK(gclk_o));
`else
  // latch the enable while the clock is low to prevent gated-clock glitches.
  logic enable_q;
  always_latch if (!clk_i) enable_q = enable_i;
  assign gclk_o = clk_i & enable_q;
`endif
endmodule
/* verilator lint_on DECLFILENAME */

// unreset tag/data array; cache controllers own validity and reads have no same-cycle write bypass.
module l1_cache_array #(
  parameter int SETS = 16,
  parameter int WAYS = 2,
  parameter int TAG_BITS = 23,
  parameter bit REGISTER_READ = 1'b1,
  parameter bit BYTE_WRITE = 1'b1  // zero shares one gate between the tag and a full-line write.
) (
  input  wire clk_i,
  /* verilator lint_off UNUSEDSIGNAL */
  input  wire rst_i,
  /* verilator lint_on UNUSEDSIGNAL */
  input  wire [$clog2(SETS)-1:0] read_set_i,
  input  wire write_i,
  /* verilator lint_off UNUSEDSIGNAL */
  input  wire write_tag_i,
  input  wire [31:0] write_byte_mask_i,
  /* verilator lint_on UNUSEDSIGNAL */
  input  wire [$clog2(SETS)-1:0] write_set_i,
  input  wire [$clog2(WAYS)-1:0] write_way_i,
  input  wire [TAG_BITS-1:0] write_tag_value_i,
  input  wire [255:0] write_data_i,

  output logic [WAYS-1:0][TAG_BITS-1:0] read_tag_o,
  output logic [WAYS-1:0][255:0] read_data_o
);

  // tag and line storage; no reset is needed because controllers own validity.
  wire [SETS-1:0][WAYS-1:0][TAG_BITS-1:0] tag_q;
  wire [SETS-1:0][WAYS-1:0][255:0] data_q;

  // clock-gated writes use one gate per tag and byte, or one gate per whole entry.
  for (genvar s = 0; s < SETS; s++) begin : g_set
    for (genvar w = 0; w < WAYS; w++) begin : g_way
      wire entry_write = write_i && write_set_i == $clog2(SETS)'(s) && write_way_i == $clog2(WAYS)'(w);
      wire tag_gclk;
      logic [TAG_BITS-1:0] entry_tag_q;

      l1_cache_array_gate u_tag_gate (.clk_i(clk_i), .enable_i(entry_write && (write_tag_i || !BYTE_WRITE)),
                                      .gclk_o(tag_gclk));
      always_ff @(posedge tag_gclk) entry_tag_q <= write_tag_value_i;
      assign tag_q[s][w] = entry_tag_q;

      if (BYTE_WRITE) begin : g_bytes
        for (genvar b = 0; b < 32; b++) begin : g_byte
          wire byte_gclk;
          logic [7:0] byte_q;

          l1_cache_array_gate u_gate (.clk_i(clk_i), .enable_i(entry_write && write_byte_mask_i[b]),
                                      .gclk_o(byte_gclk));
          always_ff @(posedge byte_gclk) byte_q <= write_data_i[8*b +: 8];
          assign data_q[s][w][8*b +: 8] = byte_q;
        end
      end else begin : g_line
        logic [255:0] line_q;
        always_ff @(posedge tag_gclk) line_q <= write_data_i;
        assign data_q[s][w] = line_q;
      end
    end
  end

  // read selection defaults to registered output; combinational mode supports timing probes.
  if (REGISTER_READ) begin : g_registered
    always_ff @(posedge clk_i) begin
      read_tag_o <= tag_q[read_set_i];
      read_data_o <= data_q[read_set_i];
    end
  end else begin : g_combinational
    always_comb begin
      read_tag_o = tag_q[read_set_i];
      read_data_o = data_q[read_set_i];
    end
  end

  // whole-line writes must update the tag and every data byte.
`ifndef SYNTHESIS
  if (!BYTE_WRITE) begin : g_line_contract
    always_ff @(posedge clk_i)
      assert (!write_i || (write_tag_i && &write_byte_mask_i)) else $fatal(1, "L1_ARRAY_LINE_WRITE");
  end
`endif
endmodule
`default_nettype wire
