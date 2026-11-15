`default_nettype none
// RV32M producer with a result holder: multiply takes three edges; division holds the operation for 34 edges.
module muldiv_unit (
  input  wire clk_i, rst_i, flush_i,
  input  wire recover_i,
  input  wire [4:0] recover_slot_i, head_slot_i,
  input  wire launch_i,
  input  wire [12:0] id_i,
  input  wire [31:0] instruction_i, pc_i, source1_i, source2_i,
  input  wire take_i,

  output wire ready_o,
  output wire valid_o,
  output logic [12:0] id_o,
  output commit_event_pkg::commit_event_t event_o,
  output wire held_o             // a result is held, before recovery gating
);

  import commit_event_pkg::*;

  logic op_q, start_q, hold_q;
  logic [12:0] op_id_q;
  logic [31:0] instruction_q, pc_q, a_q, b_q;
  logic [31:0] remainder_q;
  logic [31:0] quotient_q, divisor_q;
  logic [5:0] count_q;
  logic signed [63:0] product;
  // multiply pipeline: four registered 17x17 partial products, then their sum.
  logic signed [33:0] ll_q, lh_q, hl_q, hh_q;
  logic partial_q;
  logic [31:0] result;
  commit_event_t built;

  // recovery keeps older work; flush or a younger slot kills it.
  function automatic logic killed(input logic [4:0] slot);
    return flush_i || (recover_i && 5'(slot - head_slot_i) > 5'(recover_slot_i - head_slot_i));
  endfunction

  // operation progress and completion capacity
  wire [2:0] f3 = instruction_q[14:12];
  wire divide = f3[2];
  wire done = divide ? start_q && count_q == 0 : partial_q;
  wire hold_free = !hold_q || take_i;
  wire advance = op_q && done && hold_free;
  // offers use registered occupancy; kill clears the holder and the ROB rejects killed results.
  assign ready_o = !rst_i && (!op_q || advance);
  assign valid_o = hold_q && !rst_i;
  assign held_o = hold_q;

  // arithmetic
  wire a_signed = f3 inside {3'd1, 3'd2, 3'd4, 3'd6};
  wire b_signed = f3 inside {3'd1, 3'd4, 3'd6};
  wire a_negative = a_signed && a_q[31];
  wire b_negative = b_signed && b_q[31];
  wire [32:0] trial = {remainder_q, quotient_q[31]} - {1'b0, divisor_q};
  wire signed [16:0] a_high = {a_signed && a_q[31], a_q[31:16]}, a_low = {1'b0, a_q[15:0]};
  wire signed [16:0] b_high = {b_signed && b_q[31], b_q[31:16]}, b_low = {1'b0, b_q[15:0]};
  wire signed [63:0] partial_sum = (64'(hh_q) <<< 32) + (64'(lh_q) <<< 16) + (64'(hl_q) <<< 16) + 64'(ll_q);
  always_ff @(posedge clk_i) begin
    ll_q <= a_low * b_low;
    lh_q <= a_low * b_high;
    hl_q <= a_high * b_low;
    hh_q <= a_high * b_high;
    // partial products belong to the operands held for the preceding cycle.
    partial_q <= !rst_i && op_q && !advance;
  end
  always_comb begin
    product = partial_sum;
    if (!divide) result = f3 == 0 ? product[31:0] : product[63:32];
    else if (!f3[1]) result = a_negative != b_negative && b_q != 0 ? -quotient_q : quotient_q;
    else result = a_negative ? -remainder_q : remainder_q;
  end

  // completion event construction
  always_comb begin
    built = '0;
    built.valid = 1;
    built.retired = 1;
    built.privilege = 3;
    built.instruction = instruction_q;
    built.pc_before = pc_q;
    built.pc_after = pc_q + 32'd4;
    built.rs1_addr = instruction_q[19:15];
    built.rs1_value = a_q;
    built.rs2_addr = instruction_q[24:20];
    built.rs2_value = b_q;
    if (instruction_q[11:7] != 0) begin
      built.rd_addr = instruction_q[11:7];
      built.rd_value = result;
      built.rd_write_mask = '1;
    end
  end

  // operation, divider and result state
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      op_q <= 0;
      start_q <= 0;
      hold_q <= 0;
    end else begin
      // result holding
      if (killed(id_o[4:0]) || take_i) hold_q <= 0;
      if (advance) begin
        hold_q <= !killed(op_id_q[4:0]);
        id_o <= op_id_q;
        event_o <= built;
      end

      // divider: one start edge takes magnitudes, then 32 restoring steps
      if (op_q && divide && !start_q) begin
        remainder_q <= 0;
        quotient_q <= a_negative ? -a_q : a_q;
        divisor_q <= b_negative ? -b_q : b_q;
        count_q <= 6'd32;
        start_q <= 1;
      end else if (start_q && count_q != 0) begin
        remainder_q <= trial[32] ? {remainder_q[30:0], quotient_q[31]} : trial[31:0];
        quotient_q <= {quotient_q[30:0], !trial[32]};
        count_q <= count_q - 6'd1;
      end

      // operation register
      if (advance || killed(op_id_q[4:0])) begin
        op_q <= 0;
        start_q <= 0;
      end
      if (launch_i && ready_o && !killed(id_i[4:0])) begin
        op_q <= 1;
        start_q <= 0;
        op_id_q <= id_i;
        instruction_q <= instruction_i;
        pc_q <= pc_i;
        a_q <= source1_i;
        b_q <= source2_i;
      end
    end
  end
  // producer handshake assertions
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i && !flush_i) begin
      assert (!launch_i || ready_o) else $fatal(1, "MULDIV_CAPACITY");
      assert (!take_i || valid_o) else $fatal(1, "MULDIV_TAKE");
      assert (!launch_i || (instruction_i[6:0] == 7'h33 && instruction_i[31:25] == 7'd1))
        else $fatal(1, "MULDIV_OPERATION");
    end
  end
`endif
endmodule
`default_nettype wire
