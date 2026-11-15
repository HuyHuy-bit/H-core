`default_nettype none
// two-wide core integration: fetch, prediction, execution and identity recycling.
module cpu_top #(parameter bit FRONTEND_FAULTS = 1, parameter bit TRAP_SERVICE = 1, parameter bit MEMORY_SERVICE = 0,
                              parameter bit EARLY_LOADS = 0, parameter bit TAGE = 1, parameter bit DCACHE = 0,
                              parameter bit ICACHE = 0, parameter bit M_EXTENSION = 0,
                              // TRACE=0 is the physical build: no reference-only event state
                              parameter bit TRACE = 1) (
  input  wire clk_i, rst_i, enable_i, flush_i, drained_i,
  input  wire [31:0] flush_pc_i,
  input  wire request_ready_i,
  input  wire response_valid_i,
  input  memory_protocol_pkg::mem_response_t response_i,
  input  wire data_request_ready_i,
  input  wire data_response_valid_i,
  input  memory_protocol_pkg::mem_response_t data_response_i,
  input  wire memory_issue_allowed_i, admit_valid_i,
  input  wire [12:0] admit_id_i,
  input  wire [1:0] execution_ready_i, completion_enable_i, retire_ready_i,
  input  wire resolve_grant_i,
  input  wire trap_ready_i,

  output wire request_valid_o,
  output memory_protocol_pkg::mem_request_t request_o,
  output wire response_ready_o,
  output wire data_request_valid_o,
  output memory_protocol_pkg::mem_request_t data_request_o,
  output wire data_response_ready_o,
  output wire admission_valid_o,
  output wire [12:0] admission_id_o,
  output wire [31:0] admission_address_o, admission_data_o,
  output wire [3:0] admission_mask_o,
  output wire [1:0] admission_size_o,
  output wire memory_prepare_o, memory_busy_o, memory_committed_o, memory_irrevocable_o, memory_fatal_o,
  output wire committed_valid_o,
  output wire [31:0] committed_address_o, committed_data_o,
  output wire [3:0] committed_mask_o,
  output wire flush_ready_o,
  output wire [1:0] fetch_valid_o, dispatch_o, unsupported_o, producer_busy_o,
  output wire [63:0] fetch_pc_o, fetch_instruction_o,
  output wire fetch_busy_o, fetch_fault_o,
  output wire [31:0] fetch_fault_cause_o,
  output wire [1:0] retire_valid_o, retire_accept_o,
  output commit_event_pkg::commit_event_t [1:0] retire_event_o,
  output wire redirect_o,
  output wire [31:0] redirect_pc_o,
  output wire trap_valid_o, trap_accept_o,
  output commit_event_pkg::commit_event_t trap_event_o,
  output wire backend_fault_o,
  output commit_event_pkg::commit_event_t backend_fault_event_o,
  output wire [5:0] occupancy_o,
  output wire system_prepare_o, system_busy_o,
  output wire identity_drain_o, fatal_o
);

  // configuration and fatal/flush status
  localparam int CHECKPOINT_BITS = TAGE ? 36 : 12;
  wire fetch_fatal;
  assign fatal_o = fetch_fatal || memory_fatal_o;
  assign flush_ready_o = !memory_irrevocable_o;
  wire [1:0] supported, backend_valid, frontend_fault;
  wire [63:0] frontend_cause, frontend_value;
  wire [63:0] decode_instruction;
  wire decode_fault;

  // frontend fault classification
  if (FRONTEND_FAULTS) begin : faults
    // turns fetch faults and ecall/ebreak/illegal into per-lane fault tokens.
    frontend_fault_decode #(.M_EXTENSION(M_EXTENSION)) decode (
      .valid_i(2'b11), .instruction_i(decode_instruction), .pc_i(fetch_pc_o),
      .fetch_fault_i(decode_fault), .fetch_cause_i(fetch_fault_cause_o),
      .fault_o(frontend_fault), .cause_o(frontend_cause), .value_o(frontend_value)
    );
  end else begin : no_faults
    wire unused_decode_fault = decode_fault;
    assign frontend_fault = 0;
    assign frontend_cause = 0;
    assign frontend_value = 0;
  end

  // prediction and redirect routing
  wire [1:0] predicted_taken, retire_trained;
  wire [2*CHECKPOINT_BITS-1:0] predicted_checkpoint;
  wire [CHECKPOINT_BITS-1:0] redirect_checkpoint;
  wire [63:0] predicted_pc;
  wire system_redirect, icache_invalidate, fetch_hold;
  // fetch is redirected when the mispredict is accepted; the backend recovers from a register one cycle later.
  wire resolve_accept, resolve_mispredict;
  wire branch_redirect = resolve_accept && resolve_mispredict;
  wire [31:0] system_pc;
  wire [31:0] branch_pc;
  wire running = !rst_i && !fatal_o;

  // Drain holders and restart at the committed PC before recycling identities.
  typedef enum logic [1:0] {RUN, STOP, RESTART, DRAIN} recycle_t;
  recycle_t recycle_q;
  logic [31:0] committed_pc_q;
  wire quiet = occupancy_o == 0 && flush_ready_o && !memory_busy_o && !data_request_valid_o
               && producer_busy_o == 0 && !system_busy_o && !fetch_busy_o;
  // fatal blocks recycle transitions and pending restart/drain effects.
  wire flush = flush_i || (recycle_q == RESTART && !fatal_o);
  wire drained = drained_i || (recycle_q == DRAIN && !fatal_o);

  wire fetch_enable = enable_i && recycle_q == RUN;

  // recycle state and committed restart pc
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      recycle_q <= RUN;
      committed_pc_q <= platform_pkg::RESET_PC;
    end else begin
      if (!fatal_o) case (recycle_q)
        RUN: if (identity_drain_o) recycle_q <= STOP;
        STOP: if (!identity_drain_o) recycle_q <= RUN;
              else if (quiet) recycle_q <= RESTART;
        RESTART: recycle_q <= DRAIN;
        DRAIN: recycle_q <= RUN;
      endcase
      if (trap_accept_o) committed_pc_q <= trap_event_o.pc_after;
      else if (retire_accept_o[1]) committed_pc_q <= retire_event_o[1].pc_after;
      else if (retire_accept_o[0]) committed_pc_q <= retire_event_o[0].pc_after;
      else if (flush_i && running) committed_pc_q <= flush_pc_i;
    end
  end

  // frontend redirect priority and dispatch qualification
  assign redirect_o = running && (flush || system_redirect || branch_redirect);
  assign redirect_pc_o = flush_i ? flush_pc_i : recycle_q == RESTART ? committed_pc_q
                       : system_redirect ? system_pc : branch_pc;
  assign backend_valid = fetch_valid_o & {2{running && (FRONTEND_FAULTS || !fetch_fault_o) && !drained}};
  assign unsupported_o = fetch_valid_o & ~supported & {2{!fetch_fault_o}};

  // predictor retirement training
  for (genvar lane = 0; lane < 2; lane++) begin : training
    assign retire_trained[lane] = retire_accept_o[lane] && retire_event_o[lane].retired;
  end

  // fetch buffer: fetch fills it from its own registered occupancy, dispatch drains it, so neither waits on the other.
  logic [31:0] buffer_instruction_q [4], buffer_pc_q [4], buffer_cause_q [4], buffer_predicted_q [4];
  logic [CHECKPOINT_BITS-1:0] buffer_checkpoint_q [4];
  logic [3:0] buffer_fault_q, buffer_taken_q;
  logic [1:0] buffer_head_q;
  logic [2:0] buffer_count_q;
  logic redirect_q, repair_q;
  logic [31:0] redirect_pc_q;
  logic [CHECKPOINT_BITS-1:0] repair_checkpoint_q;
  wire [1:0] offered_valid, offered_taken;
  wire [63:0] offered_instruction, offered_pc, offered_decode, offered_predicted;
  wire [2*CHECKPOINT_BITS-1:0] offered_checkpoint;
  wire offered_decode_fault, offered_fault;
  wire [31:0] offered_cause;
  // the parallel predictor looks lane 1 up without lane 0's outcome, so a branch in lane 0 is taken alone.
  wire [1:0] buffer_take = {offered_valid[1] && buffer_count_q <= 3'd2 && offered_decode[6:0] != 7'h63,
                            offered_valid[0] && buffer_count_q <= 3'd3};
  wire [1:0] second = buffer_head_q + 2'd1;
  // a fetch fault is delivered alone in lane 0.
  assign fetch_valid_o = {buffer_count_q >= 3'd2 && !buffer_fault_q[buffer_head_q] && !buffer_fault_q[second],
                          buffer_count_q != 3'd0};
  assign fetch_pc_o = {buffer_pc_q[second], buffer_pc_q[buffer_head_q]};
  assign decode_instruction = {buffer_instruction_q[second], buffer_instruction_q[buffer_head_q]};
  assign fetch_instruction_o = {fetch_valid_o[1] ? buffer_instruction_q[second] : 32'd0,
                                fetch_valid_o[0] ? buffer_instruction_q[buffer_head_q] : 32'd0};
  assign decode_fault = buffer_fault_q[buffer_head_q];
  assign fetch_fault_o = fetch_valid_o[0] && buffer_fault_q[buffer_head_q];
  assign fetch_fault_cause_o = buffer_cause_q[buffer_head_q];
  assign predicted_taken = {buffer_taken_q[second], buffer_taken_q[buffer_head_q]} & fetch_valid_o;
  assign predicted_pc = {buffer_predicted_q[second], buffer_predicted_q[buffer_head_q]};
  assign predicted_checkpoint = {buffer_checkpoint_q[second], buffer_checkpoint_q[buffer_head_q]};

  // fetch-buffer storage and registered redirect/repair
  always_ff @(posedge clk_i) begin
    redirect_q <= !rst_i && redirect_o;
    redirect_pc_q <= redirect_pc_o;
    repair_q <= running && branch_redirect && !flush && !system_redirect;
    repair_checkpoint_q <= redirect_checkpoint;
    if (rst_i || redirect_o) begin
      buffer_head_q <= 0;
      buffer_count_q <= 0;
    end else begin
      for (int lane = 0; lane < 2; lane++) if (buffer_take[lane]) begin
        automatic logic [1:0] slot = buffer_head_q + buffer_count_q[1:0] + 2'(lane);
        buffer_instruction_q[slot] <= offered_decode[lane*32 +: 32];
        buffer_pc_q[slot] <= offered_pc[lane*32 +: 32];
        buffer_cause_q[slot] <= offered_cause;
        buffer_predicted_q[slot] <= offered_predicted[lane*32 +: 32];
        buffer_checkpoint_q[slot] <= offered_checkpoint[lane*CHECKPOINT_BITS +: CHECKPOINT_BITS];
        buffer_fault_q[slot] <= offered_decode_fault;
        buffer_taken_q[slot] <= offered_taken[lane];
      end
      buffer_head_q <= buffer_head_q + 2'(dispatch_o[0]) + 2'(dispatch_o[1]);
      buffer_count_q <= buffer_count_q + 3'(buffer_take[0]) + 3'(buffer_take[1]) - 3'(dispatch_o[0]) - 3'(dispatch_o[1]);
    end
  end
  wire unused_offered = ^{offered_instruction, offered_fault};

  // the predictor trains one cycle after retirement, from registers.
  logic [1:0] train_q;
  logic [63:0] train_instruction_q, train_pc_q, train_next_q;
  always_ff @(posedge clk_i) begin
    train_q <= rst_i ? 2'b00 : retire_trained;
    train_instruction_q <= {retire_event_o[1].instruction, retire_event_o[0].instruction};
    train_pc_q <= {retire_event_o[1].pc_before, retire_event_o[0].pc_before};
    train_next_q <= {retire_event_o[1].pc_after, retire_event_o[0].pc_after};
  end

  // instruction fetch and prediction
  fetch_unit #(.PREDICT(1), .AHEAD(1), .TAGE(TAGE), .ICACHE(ICACHE), .PARALLEL_TAGE(1)) frontend (
    .clk_i, .rst_i, .enable_i(fetch_enable && !drained && !memory_fatal_o),
    .redirect_i(redirect_q), .redirect_pc_i(redirect_pc_q), .invalidate_i(icache_invalidate), .hold_i(fetch_hold),
    .request_valid_o, .request_ready_i, .request_o, .response_valid_i, .response_ready_o, .response_i,
    .valid_o(offered_valid), .take_i(buffer_take), .instruction_o(offered_instruction), .pc_o(offered_pc),
    .decode_instruction_o(offered_decode), .decode_fault_o(offered_decode_fault),
    .fault_o(offered_fault), .fault_cause_o(offered_cause), .busy_o(fetch_busy_o), .fatal_o(fetch_fatal),
    .predict_taken_o(offered_taken), .predict_pc_o(offered_predicted), .predict_checkpoint_o(offered_checkpoint),
    .repair_i(repair_q), .repair_checkpoint_i(repair_checkpoint_q),
    .retire_i(train_q), .retire_instruction_i(train_instruction_q), .retire_pc_i(train_pc_q), .retire_next_i(train_next_q)
  );

  // execution backend
  execution_backend #(.SYSTEM_SERVICE(TRAP_SERVICE), .MEMORY_SERVICE(MEMORY_SERVICE), .DCACHE(DCACHE), .EARLY_LOADS(EARLY_LOADS), .TRACE(TRACE), .CHECKPOINT_BITS(CHECKPOINT_BITS), .M_EXTENSION(M_EXTENSION)) backend (
    .memory_issue_allowed_i(memory_issue_allowed_i && running), .admit_valid_i, .admit_id_i,
    .admission_valid_o, .admission_id_o, .admission_address_o, .admission_data_o, .admission_mask_o, .admission_size_o,
    .memory_prepare_o, .memory_busy_o, .memory_committed_o, .memory_irrevocable_o, .memory_fatal_o,
    .committed_valid_o, .committed_address_o, .committed_data_o, .committed_mask_o,
    .data_request_valid_o, .data_request_ready_i, .data_request_o,
    .data_response_valid_i, .data_response_ready_o, .data_response_i,
    .cancel_system_i(flush || !running), .system_prepare_o, .system_busy_o,
    .system_redirect_o(system_redirect), .system_redirect_pc_o(system_pc),
    .icache_invalidate_o(icache_invalidate), .fetch_hold_o(fetch_hold),
    .system_trap_valid_o(trap_valid_o), .system_trap_event_o(trap_event_o),
    .clk_i, .rst_i, .flush_i(flush && running), .drained_i(drained),
    .valid_i(backend_valid), .instruction_i(decode_instruction), .pc_i(fetch_pc_o),
    .frontend_fault_i(frontend_fault), .frontend_cause_i(frontend_cause), .frontend_value_i(frontend_value),
    .predicted_pc_i(predicted_pc), .predicted_taken_i(predicted_taken), .predicted_checkpoint_i(predicted_checkpoint),
    .redirect_checkpoint_o(redirect_checkpoint),
    .supported_o(supported), .allocate_accept_o(dispatch_o), .allocate_id_o(),
    .execution_ready_i(execution_ready_i & {2{running}}),
    .completion_enable_i(completion_enable_i & {2{running}}),
    .retire_ready_i(retire_ready_i & {2{running}}), .resolve_grant_i(resolve_grant_i && running),
    .resolve_valid_o(), .resolve_accept_o(resolve_accept), .resolve_taken_o(), .resolve_mispredict_o(resolve_mispredict),
    .resolve_id_o(), .resolve_pc_o(branch_pc), .redirect_o(),
    .issue_o(), .producer_busy_o, .issue_id_o(),
    .completion_valid_o(), .completion_accept_o(), .wb_accept_o(), .completion_id_o(), .completion_event_o(),
    .retire_valid_o, .retire_accept_o, .retire_event_o,
    .trap_ready_i(trap_ready_i && TRAP_SERVICE && running && !flush), .trap_accept_o,
    .fault_pending_o(backend_fault_o), .fault_event_o(backend_fault_event_o),
    .head_id_o(), .occupancy_o, .issue_occupancy_o(), .checkpoint_valid_o(), .identity_drain_o
  );
  // fence.i invalidates the instruction cache only at the end of its data-cache clean
  if (ICACHE && !DCACHE) begin : invalid_icache_configuration
    initial $error("ICACHE_REQUIRES_DCACHE");
  end
  // core control assertions
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      assert (!flush || flush_ready_o) else $fatal(1, "FETCH_CORE_MMIO_FLUSH");
      assert (!drained || !memory_busy_o) else $fatal(1, "FETCH_CORE_MEMORY_DRAIN");
      assert (trap_accept_o == (trap_valid_o && trap_ready_i))
        else $fatal(1, "FETCH_CORE_TRAP_ATOMIC");
      assert (!trap_accept_o || (redirect_o && !branch_redirect && retire_accept_o == 0))
        else $fatal(1, "FETCH_CORE_TRAP_RECOVERY");
      assert (!drained || (!fetch_enable && !fetch_busy_o && fetch_valid_o == 0 && !fatal_o))
        else $fatal(1, "FETCH_CORE_DRAIN");
      assert (!redirect_o || (dispatch_o == 0 && (retire_accept_o == 0
              || (!flush && system_redirect && !trap_accept_o && retire_accept_o == 1))))
        else $fatal(1, "FETCH_CORE_REDIRECT");
    end
  end
`endif
endmodule
`default_nettype wire
