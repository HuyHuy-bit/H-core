`default_nettype none
// port-zero branch/jump/ALU producer with independent resolution and completion handshakes.
module control_flow_pipeline (
  input  wire clk_i, rst_i, flush_i,
  input  wire launch_i,
  input  wire [12:0] id_i,
  input  wire [31:0] instruction_i, pc_i, source1_i, source2_i,
  input  wire predicted_taken_i,
  input  wire [31:0] predicted_pc_i,
  input  wire resolve_take_i,
  input  wire take_i,

  output wire ready_o, busy_o,
  output wire resolve_valid_o,
  output logic taken_o, mispredict_o,
  output wire [31:0] next_pc_o,
  output wire valid_o,
  output logic [12:0] id_o,
  output commit_event_pkg::commit_event_t event_o,
  output wire [31:0] result_o,   // this cycle's register result, before it is held
  output wire held_o,            // a result is held, before flush gating
  output wire recover_pending_o  // a mispredicted branch waits to resolve, before flush gating
);

  import core_pkg::*;
  import commit_event_pkg::*;

  decoded_t decoded;
  wire [31:0] result, next_pc, cause, trap_value;
  wire execute_trap, taken;
  wire cfi = decoded.op inside {OP_BRANCH, OP_JAL, OP_JALR};
  logic pending_q, cfi_q, resolved_q, done_q;
  commit_event_t built;

  // correct predictions may resolve and complete together; mispredicted branches resolve first.
  wire resolve_pending = cfi_q && !event_o.trap && !resolved_q;
  wire free = (!resolve_pending || resolve_take_i) && (done_q || take_i);
  assign busy_o = pending_q && !rst_i && !flush_i;
  assign held_o = pending_q;
  assign recover_pending_o = pending_q && resolve_pending && mispredict_o;
  // offers use registered occupancy; flush clears the holder and the ROB blocks acceptance.
  wire live = pending_q && !rst_i;
  assign ready_o = !rst_i && (!pending_q || free);
  assign resolve_valid_o = live && resolve_pending;
  assign valid_o = live && !done_q && (!cfi_q || event_o.trap || resolved_q || !mispredict_o);
  assign next_pc_o = event_o.pc_after;

  // decode and execution datapath
  decoder decode (.instruction_i, .decoded_o(decoded));
  execute_unit execute (
    .decoded_i(decoded), .pc_i, .instruction_i, .source1_i, .source2_i,
    .csr_value_i(32'd0), .mepc_i(32'd0), .csr_legal_i(1'b0),
    .result_o(result), .next_pc_o(next_pc), .address_o(),
    .trap_o(execute_trap), .cause_o(cause), .trap_value_o(trap_value), .taken_o(taken)
  );

  assign result_o = built.rd_value;

  // completion event construction
  always_comb begin
    built = '0;
    built.valid = 1;
    built.retired = !execute_trap;
    built.privilege = 3;
    built.instruction = instruction_i;
    built.pc_before = pc_i;
    built.pc_after = next_pc;
    built.rs1_addr = decoded.rs1;
    built.rs1_value = source1_i;
    built.rs2_addr = decoded.rs2;
    built.rs2_value = source2_i;
    built.trap = execute_trap;
    built.trap_cause = cause;
    built.trap_value = trap_value;
    if (!execute_trap && decoded.rd != 0) begin
      built.rd_addr = decoded.rd;
      built.rd_value = result;
      built.rd_write_mask = '1;
    end
  end

  // resolution and completion each acknowledge once; correct predictions allow either order.
  always_ff @(posedge clk_i) begin
    if (rst_i || flush_i) begin
      pending_q <= 0;
      cfi_q <= 0;
      resolved_q <= 0;
      done_q <= 0;
    end else begin
      if (resolve_take_i) resolved_q <= 1;
      if (take_i) done_q <= 1;
      if (pending_q && free) pending_q <= 0;
      if (launch_i) begin
        pending_q <= 1;
        cfi_q <= cfi;
        resolved_q <= 0;
        done_q <= 0;
        id_o <= id_i;
        event_o <= built;
        taken_o <= taken;
        mispredict_o <= cfi && (predicted_taken_i != taken || predicted_pc_i != next_pc);
      end
    end
  end

  // assertions
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i && !flush_i) begin
      assert (!launch_i || ready_o) else $fatal(1, "CF_PIPE_CAPACITY");
      assert (!take_i || valid_o) else $fatal(1, "CF_PIPE_TAKE");
      assert (!resolve_take_i || resolve_valid_o) else $fatal(1, "CF_PIPE_RESOLVE");
      assert (!launch_i || decoded.op inside {OP_ALU, OP_LUI, OP_AUIPC, OP_BRANCH, OP_JAL, OP_JALR})
        else $fatal(1, "CF_PIPE_OPERATION");
    end
  end
`endif
endmodule
`default_nettype wire
