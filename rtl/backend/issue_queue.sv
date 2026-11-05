`default_nettype none
// 16-entry unified issue queue: wakeup on accepted writebacks, oldest-first select for two ports.
module issue_queue (
  // inputs
  input  wire clk_i, rst_i, flush_i,
  input  wire recover_i,
  input  wire [4:0] head_slot_i, recover_slot_i,
  input  wire [1:0] dispatch_i,
  input  wire [25:0] dispatch_id_i,
  input  wire [23:0] dispatch_source_i,
  input  wire [3:0] dispatch_ready_i, dispatch_eligible_i,
  input  wire [11:0] dispatch_destination_i,
  input  wire [127:0] dispatch_payload_i,
  input  wire [1:0] wb_accept_i,
  input  wire [11:0] wb_destination_i,
  input  wire [1:0] port_ready_i,

  // outputs
  output logic [1:0] dispatch_ready_o,
  output logic [1:0] issue_o,
  output logic [25:0] issue_id_o,
  output logic [23:0] read_address_o,
  output logic [11:0] issue_destination_o,
  output logic [127:0] issue_payload_o,
  output logic [4:0] occupancy_o
);
  logic [15:0] valid_q;
  logic [12:0] id_q [16];
  logic [11:0] source_q [16];
  logic [1:0] ready_q [16], eligible_q [16];
  logic [5:0] destination_q [16];
  logic [63:0] payload_q [16];
  logic [1:0] awake [16];
  logic [15:0] chosen [2], candidate [2], older [16];
  logic [15:0] first0, first1, second1, select1;
  logic [15:0][4:0] age;
  logic launch0;
  logic [3:0] free_slot [2];
  logic found_free;
  wire stop = rst_i || flush_i || recover_i;

  // dispatch capacity and free slots
  always_comb begin
    occupancy_o = 0;
    free_slot[0] = 0;
    free_slot[1] = 0;
    found_free = 0;
    for (int slot = 0; slot < 16; slot++) begin
      occupancy_o = occupancy_o + 5'(valid_q[slot]);
      if (!valid_q[slot]) begin
        if (!found_free) free_slot[0] = 4'(slot);
        else free_slot[1] = 4'(slot);
        found_free = 1;
      end
    end
    dispatch_ready_o[0] = !stop && occupancy_o < 16;
    dispatch_ready_o[1] = !stop && occupancy_o < 15;
  end

  // operand wakeup
  // only the backend's accepted writes may wake a resident instruction.
  always_comb begin
    for (int slot = 0; slot < 16; slot++) begin
      awake[slot] = ready_q[slot];
      for (int operand = 0; operand < 2; operand++) begin
        awake[slot][operand] = awake[slot][operand] || source_q[slot][operand*6 +: 6] == 0;
        for (int lane = 0; lane < 2; lane++)
          if (wb_accept_i[lane] && wb_destination_i[lane*6 +: 6] != 0
              && wb_destination_i[lane*6 +: 6] == source_q[slot][operand*6 +: 6])
            awake[slot][operand] = 1;
      end
    end
  end

  function automatic logic exactly_one(input logic [15:0] mask);
    logic [15:0] any_node, multiple_node;
    any_node = mask;
    multiple_node = 0;
    for (int width = 8; width >= 1; width = width / 2)
      for (int node = 0; node < width; node++) begin
        multiple_node[node] = multiple_node[2*node] || multiple_node[2*node+1]
            || (any_node[2*node] && any_node[2*node+1]);
        any_node[node] = any_node[2*node] || any_node[2*node+1];
      end
    return any_node[0] && !multiple_node[0];
  endfunction

  // oldest-ready issue selection
  // port zero selects first; rob-relative age is independent of iq storage order.
  // Age ordering precedes wakeup; both ports rank ready candidates in parallel.
  always_comb begin
    issue_o = 0;
    issue_id_o = 0;
    read_address_o = 0;
    issue_destination_o = 0;
    issue_payload_o = 0;
    for (int slot = 0; slot < 16; slot++) begin
      age[slot] = 5'(id_q[slot][4:0] - head_slot_i);
      for (int port_id = 0; port_id < 2; port_id++)
        candidate[port_id][slot] = valid_q[slot] && (&awake[slot]) && eligible_q[slot][port_id];
    end
    for (int slot = 0; slot < 16; slot++) older[slot] = 0;
    for (int slot = 0; slot < 16; slot++)
      for (int other = 0; other < slot; other++) begin
        older[slot][other] = age[other] <= age[slot];
        older[other][slot] = !older[slot][other];
      end
    for (int slot = 0; slot < 16; slot++) begin
      first0[slot] = candidate[0][slot] && !(|(candidate[0] & older[slot]));
      first1[slot] = candidate[1][slot] && !(|(candidate[1] & older[slot]));
      second1[slot] = candidate[1][slot] && exactly_one(candidate[1] & older[slot]);
    end
    launch0 = !stop && port_ready_i[0] && (|first0);
    select1 = launch0 && (|(first0 & first1)) ? second1 : first1;
    for (int port_id = 0; port_id < 2; port_id++) begin
      chosen[port_id] = !stop && port_ready_i[port_id] ? (port_id == 0 ? first0 : select1) : 16'd0;
      issue_o[port_id] = |chosen[port_id];
      for (int slot = 0; slot < 16; slot++) begin
        issue_id_o[port_id*13 +: 13] |= {13{chosen[port_id][slot]}} & id_q[slot];
        read_address_o[port_id*12 +: 12] |= {12{chosen[port_id][slot]}} & source_q[slot];
        issue_destination_o[port_id*6 +: 6] |= {6{chosen[port_id][slot]}} & destination_q[slot];
        issue_payload_o[port_id*64 +: 64] |= {64{chosen[port_id][slot]}} & payload_q[slot];
      end
    end
  end

  // queue allocation, issue and recovery
  always_ff @(posedge clk_i) begin
    if (rst_i || flush_i) valid_q <= 0;
    else begin
      for (int slot = 0; slot < 16; slot++) begin
        if (valid_q[slot]) ready_q[slot] <= awake[slot];
        if (recover_i && 5'(id_q[slot][4:0] - head_slot_i) > 5'(recover_slot_i - head_slot_i))
          valid_q[slot] <= 0;
        if (chosen[0][slot] || chosen[1][slot]) valid_q[slot] <= 0;
      end
      for (int lane = 0; lane < 2; lane++) begin
        if (!stop && dispatch_i[lane]) begin
          valid_q[free_slot[lane]] <= 1;
          id_q[free_slot[lane]] <= dispatch_id_i[lane*13 +: 13];
          source_q[free_slot[lane]] <= dispatch_source_i[lane*12 +: 12];
          ready_q[free_slot[lane]] <= dispatch_ready_i[lane*2 +: 2];
          eligible_q[free_slot[lane]] <= dispatch_eligible_i[lane*2 +: 2];
          destination_q[free_slot[lane]] <= dispatch_destination_i[lane*6 +: 6];
          payload_q[free_slot[lane]] <= dispatch_payload_i[lane*64 +: 64];
        end
      end
    end
  end

  // checks
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!stop) begin
      assert (dispatch_i != 2'b10 && (dispatch_i & ~dispatch_ready_o) == 0) else $fatal(1, "IQ_DISPATCH");
      for (int lane = 0; lane < 2; lane++) begin
        if (dispatch_i[lane]) begin
          assert (dispatch_eligible_i[lane*2 +: 2] != 0) else $fatal(1, "IQ_ELIGIBILITY");
          for (int slot = 0; slot < 16; slot++)
            assert (!valid_q[slot] || id_q[slot][4:0] != dispatch_id_i[lane*13 +: 5])
              else $fatal(1, "IQ_IDENTITY");
        end
      end
      assert (dispatch_i != 2'b11 || dispatch_id_i[4:0] != dispatch_id_i[17:13])
        else $fatal(1, "IQ_IDENTITY");
      assert ((chosen[0] & chosen[1]) == 0) else $fatal(1, "IQ_DUPLICATE_ISSUE");
    end
  end
`endif
endmodule
`default_nettype wire
