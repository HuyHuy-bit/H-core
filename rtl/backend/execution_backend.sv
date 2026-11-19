`default_nettype none
// execution backend: decode, issue queue, alu/branch producers, head system/memory service and early loads.
module execution_backend #(parameter bit SYSTEM_SERVICE = 0, parameter bit MEMORY_SERVICE = 0, parameter bit DCACHE = 0,
  parameter bit EARLY_LOADS = 0, parameter bit TRACE = 1, parameter int CHECKPOINT_BITS = 12, parameter bit M_EXTENSION = 0) (
  input  wire clk_i, rst_i, flush_i, drained_i,
  input  wire [1:0] valid_i,
  input  wire [1:0][31:0] instruction_i, pc_i, predicted_pc_i,
  input  wire [1:0] predicted_taken_i,
  input  wire [2*CHECKPOINT_BITS-1:0] predicted_checkpoint_i,
  input  wire [1:0] frontend_fault_i,
  input  wire [1:0][31:0] frontend_cause_i, frontend_value_i,
  input  wire [1:0] execution_ready_i, completion_enable_i, retire_ready_i,
  input  wire resolve_grant_i,
  input  wire trap_ready_i,
  input  wire cancel_system_i,
  input  wire memory_issue_allowed_i, admit_valid_i,
  input  wire [12:0] admit_id_i,
  input  wire data_request_ready_i,
  input  wire data_response_valid_i,
  input  memory_protocol_pkg::mem_response_t data_response_i,

  output wire [1:0] supported_o, allocate_accept_o,
  output wire [1:0][12:0] allocate_id_o,
  output wire [CHECKPOINT_BITS-1:0] redirect_checkpoint_o,
  output wire resolve_valid_o, resolve_accept_o, resolve_taken_o, resolve_mispredict_o,
  output wire [12:0] resolve_id_o,
  output wire [31:0] resolve_pc_o,
  output wire redirect_o,
  output wire [1:0] issue_o, producer_busy_o,
  output wire [1:0][12:0] issue_id_o,
  output wire [1:0] completion_valid_o, completion_accept_o, wb_accept_o,
  output wire [1:0][12:0] completion_id_o,
  output commit_event_pkg::commit_event_t [1:0] completion_event_o,
  output wire [1:0] retire_valid_o, retire_accept_o,
  output commit_event_pkg::commit_event_t [1:0] retire_event_o,
  output wire trap_accept_o,
  output wire fault_pending_o,
  output commit_event_pkg::commit_event_t fault_event_o,
  output wire system_prepare_o, system_busy_o, system_redirect_o,
  output wire [31:0] system_redirect_pc_o,
  output wire icache_invalidate_o, fetch_hold_o,     // fence.i: invalidate after its clean; hold fetch requests until then
  output wire system_trap_valid_o,
  output commit_event_pkg::commit_event_t system_trap_event_o,
  output wire admission_valid_o,
  output wire [12:0] admission_id_o,
  output wire [31:0] admission_address_o, admission_data_o,
  output wire [3:0] admission_mask_o,
  output wire [1:0] admission_size_o,
  output wire memory_prepare_o, memory_busy_o, memory_committed_o, memory_irrevocable_o, memory_fatal_o,
  output wire committed_valid_o,
  output wire [31:0] committed_address_o, committed_data_o,
  output wire [3:0] committed_mask_o,
  output wire data_request_valid_o,
  output memory_protocol_pkg::mem_request_t data_request_o,
  output wire data_response_ready_o,
  output wire [12:0] head_id_o,
  output wire [5:0] occupancy_o,
  output wire [4:0] issue_occupancy_o,
  output wire [7:0] checkpoint_valid_o,
  output wire identity_drain_o
);

  import core_pkg::*;

  // decode and dispatch signals
  decoded_t [1:0] decoded;
  wire [1:0][4:0] rs1, rs2, rd;
  wire [1:0] cfi, selected, producer_ready, system_op, memory_op, serial_op, admitted, dispatch_solo, muldiv_op;
  wire [5:0] rename_source, rename_source2, unused_rename_source, unused_rename_source2;
  wire [3:0] unused_read_ready;
  // head operands are registered after the read; readiness requires an unchanged source address.
  wire [1:0] head_ready_now;
  wire [63:0] head_data_now;
  logic [1:0] head_ready_q;
  logic [63:0] head_data_q;
  logic [11:0] head_source_q;
  wire [63:0] head_data = head_data_q;
  wire [1:0] read_ready;
  wire head_valid, head_read, serial_offer, serial_accept, illegal_offer, illegal_accept, backend_trap_ready;
  wire [12:0] serial_id, illegal_id;
  wire [31:0] head_pc;
  commit_event_pkg::commit_event_t serial_event, illegal_event;

  // head-service completion routing
  wire [1:0] backend_complete_accept;
  wire memory_serial_owner, memory_serial_offer, memory_fault_offer, memory_trap_ready, memory_read;
  wire [12:0] memory_serial_id, memory_fault_id;
  commit_event_pkg::commit_event_t memory_serial_event, memory_fault_event;
  wire raw_offer = illegal_offer || memory_fault_offer;
  wire [12:0] raw_id = memory_fault_offer ? memory_fault_id : illegal_id;
  // head faults reserve completion lanes one cycle after their first offer.
  logic raw_q;
  commit_event_pkg::commit_event_t raw_event;
  assign raw_event = memory_fault_offer ? memory_fault_event : illegal_event;
  assign serial_op = system_op | memory_op;
  wire [1:0] backend_complete_offer = raw_q ? {1'b0, raw_offer && completion_enable_i[0]} : completion_valid_o & completion_enable_i;
  wire [1:0][12:0] backend_complete_id = raw_q ? {13'd0, head_id_o} : completion_id_o;
  wire [1:0] backend_complete_solo = {1'b0, raw_q};
  wire [11:0] system_sources;
  assign read_ready = head_ready_q & {head_source_q[11:6] == system_sources[11:6], head_source_q[5:0] == system_sources[5:0]}
      & {2{!(flush_i || fault_pending_o)}};
  always_ff @(posedge clk_i) begin
    head_ready_q <= rst_i ? 2'b00 : head_ready_now;
    raw_q <= !rst_i && raw_offer && !(raw_q && backend_complete_accept[0]);
    head_data_q <= head_data_now;
    head_source_q <= system_sources;
  end
  commit_event_pkg::commit_event_t [1:0] backend_complete_event;
  assign backend_complete_event = raw_q ? {commit_event_pkg::commit_event_t'('0), raw_event} : completion_event_o;
  assign completion_accept_o = raw_q ? 2'b00 : backend_complete_accept;
  assign illegal_accept = raw_q && illegal_offer && backend_complete_accept[0];

  // issue payloads and saved branch predictions
  wire [1:0][1:0] eligible;
  wire [1:0][63:0] issue_payload;
  wire [1:0][1:0][31:0] read_data;   // [port][operand]
  // fetch-time prediction of each in-flight cfi, indexed by the rename checkpoint the cfi holds
  wire [2:0] allocate_checkpoint, issue_checkpoint, resolve_checkpoint;
  logic [31:0] prediction_pc_q [8];
  logic [7:0] prediction_taken_q;
  logic [CHECKPOINT_BITS-1:0] prediction_checkpoint_q [8];
  assign redirect_checkpoint_o = prediction_checkpoint_q[resolve_checkpoint];
  wire [1:0][63:0] payload;
  wire [1:0][31:0] executable_instruction;
  commit_event_pkg::commit_event_t [1:0] producer_event;
  wire alu1_valid, lsu_issue, lsu_complete, lsu_allocate_ready, lsu_head_memory;
  wire alu1_ready, memory_issue, memory_complete, muldiv_issue, muldiv_valid, muldiv_ready;
  wire [12:0] alu1_id, lsu_complete_id, muldiv_id;
  wire [5:0] lsu_complete_destination;
  commit_event_pkg::commit_event_t alu1_event, lsu_event, muldiv_event;

  // execute-stage and waiting-packet storage
  logic [1:0] stage_valid_q;
  logic [12:0] stage_id_q [2];
  logic [63:0] stage_payload_q [2], stage_data_q [2];
  logic [2:0] stage_checkpoint_q;
  logic [5:0] stage_destination_q [2];
  logic [1:0] stage_early_q;
  // one waiting packet per port makes issue capacity depend on registered occupancy.
  logic [1:0] wait_valid_q, wait_early_q;
  logic [12:0] wait_id_q [2];
  logic [63:0] wait_payload_q [2], wait_data_q [2];
  logic [2:0] wait_checkpoint_q;
  logic [5:0] wait_destination_q [2];
  wire [1:0] stage_keep, wait_keep, issue_early;
  wire [1:0][5:0] issue_destination;
  wire [1:0][1:0][5:0] issue_source;   // [port][operand]
  wire [31:0] early_result [2];
  // single-cycle staged results wake consumers before completion.
  wire [1:0] early_valid = stage_valid_q & stage_early_q;
  // held results bypass from producer registers before flush gating; recovery blocks issue.
  logic [5:0] issued_destination_q [32];
  wire [3:0] held;
  wire [12:0] held_id [4];
  wire [5:0] held_destination [4];
  wire [31:0] early_data [6];
  wire [5:0] early_valid_all;
  wire [5:0][5:0] early_destination;
  assign held_id[0] = completion_id_o[0];
  assign held_id[1] = alu1_id;
  assign held_id[2] = muldiv_id;
  assign held_id[3] = lsu_complete_id;
  wire held0, recover_pending;
  // head system/memory ownership and pending faults block branch recovery.
  wire head_owned = SYSTEM_SERVICE && (system_busy_o || fault_pending_o || memory_irrevocable_o);
  // an allowed mispredict holds younger work until registered recovery follows resolution.
  wire recover_hold = (recover_pending && !head_owned) || redirect_o;

  // early-result data and destination routing
  assign held[0] = held0 && !producer_event[0].trap;
  assign held[3] = memory_complete && !lsu_event.trap;
  assign early_data[0] = early_result[0];
  assign early_data[1] = early_result[1];
  assign early_data[2] = producer_event[0].rd_value;
  assign early_data[3] = alu1_event.rd_value;
  assign early_data[4] = muldiv_event.rd_value;
  assign early_data[5] = lsu_event.rd_value;
  assign early_valid_all[1:0] = early_valid;
  assign early_destination[1:0] = {stage_destination_q[1], stage_destination_q[0]};
  for (genvar holder = 0; holder < 4; holder++) begin : done
    // the load unit keeps its result's destination in a register
    assign held_destination[holder] = holder == 3 ? lsu_complete_destination : issued_destination_q[held_id[holder][4:0]];
    assign early_valid_all[2 + holder] = held[holder] && held_destination[holder] != 0;
    assign early_destination[2 + holder] = held_destination[holder];
  end

  // launch admission and recovery membership
  logic [3:0] read_early;
  logic [1:0][1:0][31:0] operand;   // [port][operand]
  // registered flush, trap and recovery state block producer launches.
  wire [1:0] launch = stage_valid_q & producer_ready & execution_ready_i & {2{!(recover_hold || flush_i || fault_pending_o)}};
  for (genvar port_id = 0; port_id < 2; port_id++) begin : stage_control
    // recovery keeps an older packet and kills a younger one.
    assign stage_keep[port_id] = stage_valid_q[port_id] && !launch[port_id]
        && !(redirect_o && 5'(stage_id_q[port_id][4:0] - head_id_o[4:0]) > 5'(resolve_id_o[4:0] - head_id_o[4:0]));
    assign wait_keep[port_id] = wait_valid_q[port_id]
        && !(redirect_o && 5'(wait_id_q[port_id][4:0] - head_id_o[4:0]) > 5'(resolve_id_o[4:0] - head_id_o[4:0]));
    // only single-cycle work with a nonzero destination supplies staged early results.
    assign issue_early[port_id] = issue_destination[port_id] != 0 && (port_id == 0
        || !(issue_payload[1][6:0] inside {7'h03, 7'h23} || (issue_payload[1][6:0] == 7'h33 && issue_payload[1][31:25] == 7'h01)));
  end
  // lsu_issue/lsu_complete include memory and RV32M work that bypasses alu1 on port 1.
  assign memory_issue = EARLY_LOADS && launch[1] && stage_payload_q[1][6:0] inside {7'h03, 7'h23};
  assign muldiv_issue = M_EXTENSION && launch[1] && stage_payload_q[1][6:0] == 7'h33 && stage_payload_q[1][31:25] == 7'h01;
  assign lsu_issue = memory_issue || muldiv_issue;
  assign lsu_complete = memory_complete || muldiv_valid;
  assign completion_valid_o[1] = alu1_valid || lsu_complete;
  assign completion_id_o[1] = memory_complete ? lsu_complete_id : muldiv_valid ? muldiv_id : alu1_id;
  assign producer_event[1] = memory_complete ? lsu_event : muldiv_valid ? muldiv_event : alu1_event;
  assign producer_ready[1] = alu1_ready && muldiv_ready;

  // frontend fault metadata
  logic [31:0] fault_q;
  // ROB entries supply PC and four-bit causes; saved instruction/PC fields serve TRACE.
  logic [31:0] fault_instruction_q [32], fault_pc_q [32], fault_value_q [32];
  logic [3:0] fault_cause_q [32];
  wire producer_flush = flush_i || trap_accept_o;

  // execute input storage holds issued operands until producer launch, with one waiting packet per port.
  always_ff @(posedge clk_i) begin
    if (rst_i || producer_flush) begin
      stage_valid_q <= 0;
      wait_valid_q <= 0;
    end else for (int port_id = 0; port_id < 2; port_id++) begin
      if (issue_o[port_id]) issued_destination_q[issue_id_o[port_id][4:0]] <= issue_destination[port_id];
      if (stage_keep[port_id]) begin
        // the stage is held: a new packet waits behind it.
        if (issue_o[port_id]) begin
          wait_valid_q[port_id] <= 1;
          wait_id_q[port_id] <= issue_id_o[port_id];
          wait_payload_q[port_id] <= issue_payload[port_id];
          wait_data_q[port_id] <= operand[port_id];
          wait_destination_q[port_id] <= issue_destination[port_id];
          wait_early_q[port_id] <= issue_early[port_id];
        end else wait_valid_q[port_id] <= wait_keep[port_id];
      end else begin
        wait_valid_q[port_id] <= 0;
        stage_valid_q[port_id] <= wait_keep[port_id] || issue_o[port_id];
        if (wait_keep[port_id]) begin
          stage_id_q[port_id] <= wait_id_q[port_id];
          stage_payload_q[port_id] <= wait_payload_q[port_id];
          stage_data_q[port_id] <= wait_data_q[port_id];
          stage_destination_q[port_id] <= wait_destination_q[port_id];
          stage_early_q[port_id] <= wait_early_q[port_id];
        end else if (issue_o[port_id]) begin
          stage_id_q[port_id] <= issue_id_o[port_id];
          stage_payload_q[port_id] <= issue_payload[port_id];
          stage_data_q[port_id] <= operand[port_id];
          stage_destination_q[port_id] <= issue_destination[port_id];
          stage_early_q[port_id] <= issue_early[port_id];
        end
      end
    end
    if (stage_keep[0]) begin
      if (issue_o[0]) wait_checkpoint_q <= issue_checkpoint;
    end else if (wait_keep[0]) stage_checkpoint_q <= wait_checkpoint_q;
    else if (issue_o[0]) stage_checkpoint_q <= issue_checkpoint;
  end
  // operand bypass uses staged results, which are final even before their producers launch.
  always_comb begin
    operand = read_data;
    read_early = 0;
    for (int port_id = 0; port_id < 2; port_id++)
      for (int source = 0; source < 2; source++)
        for (int producer = 0; producer < 6; producer++)
          if (early_valid_all[producer] && issue_source[port_id][source] == early_destination[producer]) begin
            operand[port_id][source] = early_data[producer];
            read_early[port_id*2 + source] = 1;
          end
  end
  wire cancel_alu1 = redirect_o && 5'(alu1_id[4:0] - head_id_o[4:0])
      > 5'(resolve_id_o[4:0] - head_id_o[4:0]);

  assign selected = {valid_i[1] && !cfi[0] && !frontend_fault_i[0], valid_i[0]};
  assign resolve_id_o = completion_id_o[0];
  assign producer_busy_o[1] = completion_valid_o[1] || stage_valid_q[1] || wait_valid_q[1];

  // instruction decode and dispatch
  for (genvar lane = 0; lane < 2; lane++) begin : lanes
    assign executable_instruction[lane] = frontend_fault_i[lane] ? 32'h00000013 : instruction_i[lane];
    assign payload[lane] = {frontend_fault_i[lane] ? 32'd0 : pc_i[lane], executable_instruction[lane]};
    decoder #(.M_EXTENSION(M_EXTENSION)) decode (.instruction_i(executable_instruction[lane]), .decoded_o(decoded[lane]));
    assign system_op[lane] = SYSTEM_SERVICE && !frontend_fault_i[lane] && (decoded[lane].op inside {OP_CSR, OP_MRET, OP_WFI}
      || (MEMORY_SERVICE && decoded[lane].op inside {OP_FENCE, OP_FENCE_I}));
    assign memory_op[lane] = MEMORY_SERVICE && !frontend_fault_i[lane] && decoded[lane].op inside {OP_LOAD, OP_STORE};
    assign cfi[lane] = decoded[lane].op inside {OP_BRANCH, OP_JAL, OP_JALR};
    assign muldiv_op[lane] = M_EXTENSION && !frontend_fault_i[lane] && decoded[lane].op == OP_MULDIV;
    assign supported_o[lane] = frontend_fault_i[lane] || ((cfi[lane] || serial_op[lane] || muldiv_op[lane] || decoded[lane].op inside {OP_ALU, OP_LUI, OP_AUIPC})
      && pc_i[lane][1:0] == 0);
    assign rs1[lane] = decoded[lane].rs1;
    assign rs2[lane] = decoded[lane].rs2;
    assign rd[lane] = decoded[lane].rd;
    assign eligible[lane] = cfi[lane] ? 2'b01 : EARLY_LOADS && memory_op[lane] || muldiv_op[lane] ? 2'b10 : 2'b11;
  end

  // Per-slot tables retain frontend faults and each branch's fetch-time prediction.
  always_ff @(posedge clk_i) begin
    for (int lane = 0; lane < 2; lane++) begin
      automatic logic [4:0] slot = allocate_id_o[lane][4:0];
      if (allocate_accept_o[lane]) begin
        fault_q[slot] <= frontend_fault_i[lane];
        if (frontend_fault_i[lane]) begin
          if (TRACE) begin
            fault_instruction_q[slot] <= instruction_i[lane];
            fault_pc_q[slot] <= pc_i[lane];
          end
          fault_cause_q[slot] <= frontend_cause_i[lane][3:0];
          fault_value_q[slot] <= frontend_value_i[lane];
        end
      end
      if (allocate_accept_o[lane] && cfi[lane]) begin
        prediction_pc_q[allocate_checkpoint] <= predicted_pc_i[lane];
        prediction_taken_q[allocate_checkpoint] <= predicted_taken_i[lane];
        prediction_checkpoint_q[allocate_checkpoint] <= predicted_checkpoint_i[lane*CHECKPOINT_BITS +: CHECKPOINT_BITS];
      end
    end
  end

  // Fault tokens complete in the ROB with saved metadata and no register result.
  always_comb begin
    completion_event_o = producer_event;
    for (int lane = 0; lane < 2; lane++) begin
      automatic logic [4:0] slot = completion_id_o[lane][4:0];
      if (fault_q[slot]) begin
        completion_event_o[lane] = '0;
        completion_event_o[lane].valid = 1;
        completion_event_o[lane].privilege = 3;
        completion_event_o[lane].instruction = TRACE ? fault_instruction_q[slot] : 32'd0;
        completion_event_o[lane].pc_before = TRACE ? fault_pc_q[slot] : 32'd0;
        completion_event_o[lane].pc_after = TRACE ? fault_pc_q[slot] : 32'd0;
        completion_event_o[lane].trap = 1;
        completion_event_o[lane].trap_cause = 32'(fault_cause_q[slot]);
        completion_event_o[lane].trap_value = fault_value_q[slot];
      end
    end
  end

  // Port 0 executes ALU and control-flow work and alone resolves predictions.
  wire producer0_busy;
  assign producer_busy_o[0] = producer0_busy || stage_valid_q[0] || wait_valid_q[0];
  control_flow_pipeline producer0 (
    .clk_i, .rst_i, .flush_i(producer_flush), .launch_i(launch[0]), .ready_o(producer_ready[0]), .busy_o(producer0_busy),
    .id_i(stage_id_q[0]), .instruction_i(stage_payload_q[0][31:0]), .pc_i(stage_payload_q[0][63:32]),
    .source1_i(stage_data_q[0][31:0]), .source2_i(stage_data_q[0][63:32]),
    .predicted_taken_i(prediction_taken_q[stage_checkpoint_q]), .predicted_pc_i(prediction_pc_q[stage_checkpoint_q]),
    .valid_o(completion_valid_o[0]), .id_o(completion_id_o[0]), .event_o(producer_event[0]), .result_o(early_result[0]),
    .held_o(held0), .recover_pending_o(recover_pending),
    .take_i(completion_accept_o[0]), .resolve_valid_o, .taken_o(resolve_taken_o),
    .mispredict_o(resolve_mispredict_o), .next_pc_o(resolve_pc_o), .resolve_take_i(resolve_accept_o)
  );

  // Cancel younger held port-1 results when port 0 resolves a misprediction.
  alu_pipeline producer1 (
    .clk_i, .rst_i, .flush_i(producer_flush || cancel_alu1), .launch_i(launch[1] && !lsu_issue), .ready_o(alu1_ready),
    .id_i(stage_id_q[1]), .instruction_i(stage_payload_q[1][31:0]), .pc_i(stage_payload_q[1][63:32]),
    .source1_i(stage_data_q[1][31:0]), .source2_i(stage_data_q[1][63:32]),
    .valid_o(alu1_valid), .id_o(alu1_id), .event_o(alu1_event), .result_o(early_result[1]), .held_o(held[1]),
    .take_i(completion_accept_o[1] && !lsu_complete)
  );

  // port one rv32m execution; it cancels its own younger work like alu1's held result.
  if (M_EXTENSION) begin : muldiv
    muldiv_unit producer (
      .clk_i, .rst_i, .flush_i(producer_flush), .recover_i(redirect_o),
      .recover_slot_i(resolve_id_o[4:0]), .head_slot_i(head_id_o[4:0]),
      .launch_i(muldiv_issue), .id_i(stage_id_q[1]), .instruction_i(stage_payload_q[1][31:0]), .pc_i(stage_payload_q[1][63:32]),
      .source1_i(stage_data_q[1][31:0]), .source2_i(stage_data_q[1][63:32]),
      .take_i(completion_accept_o[1] && !memory_complete && muldiv_valid),
      .ready_o(muldiv_ready), .valid_o(muldiv_valid), .id_o(muldiv_id), .event_o(muldiv_event), .held_o(held[2])
    );
  end else begin : no_muldiv
    assign {muldiv_ready, muldiv_valid, muldiv_id, held[2]} = {1'b1, 15'd0};
    assign muldiv_event = '0;
  end

  // ROB-head system and memory service
  if (SYSTEM_SERVICE) begin : systems
    wire descriptor_busy, killed, owner_valid, owner_memory, system_offer, system_trap_valid;
    wire clean_request, clean_done;
    wire [12:0] system_serial_id;
    commit_event_pkg::commit_event_t system_serial_event, system_trap_event;
    wire [12:0] system_id;
    wire [31:0] system_instruction, owner_pc;
    wire [11:0] dispatch_sources, lsu_head_sources;
    wire [31:0] lsu_head_instruction;
    wire memory_head = EARLY_LOADS ? lsu_head_memory : owner_memory && system_id == head_id_o;
    assign system_sources = EARLY_LOADS && memory_read ? lsu_head_sources : dispatch_sources;
    assign head_read = (owner_valid && !owner_memory) || memory_read;
    assign serial_offer = system_offer || memory_serial_offer;
    assign serial_id = memory_serial_owner ? memory_serial_id : system_serial_id;
    assign serial_event = memory_serial_owner ? memory_serial_event : system_serial_event;
    // registered trap offers follow head preparation by one cycle and persist until acceptance or cancel.
    logic trap_armed_q;
    wire trap_prepared = system_trap_valid && (!memory_head || memory_trap_ready);
    always_ff @(posedge clk_i) trap_armed_q <= !rst_i && trap_prepared && !trap_accept_o;
    assign system_trap_valid_o = trap_armed_q && !(flush_i || cancel_system_i);
    assign system_trap_event_o = system_trap_valid_o ? system_trap_event : '0;

    // serial payload ownership assertions
`ifndef SYNTHESIS
    always_ff @(posedge clk_i) if (!rst_i) begin
      assert (!(system_offer && memory_serial_offer)
          && (!memory_serial_offer || memory_serial_owner) && (!system_offer || !memory_serial_owner))
        else $fatal(1, "SERIAL_PAYLOAD_OWNER");
      assert ((!memory_serial_offer || (serial_id == memory_serial_id && serial_event == memory_serial_event))
          && (!system_offer || (serial_id == system_serial_id && serial_event == system_serial_event)))
        else $fatal(1, "SERIAL_PAYLOAD_ROUTE");
    end
`endif

    // serialized dispatch ownership
    head_dispatch #(.HOLD_MEMORY(!EARLY_LOADS)) dispatch (
      .clk_i, .rst_i, .flush_i(flush_i || trap_accept_o || cancel_system_i), .drained_i,
      .hold_i(flush_i || fault_pending_o || cancel_system_i || recover_hold),
      .valid_i(selected), .serial_i(serial_op), .cfi0_i(cfi[0]), .memory_i(memory_op[0]),
      .instruction_i(instruction_i[0]), .pc_i(pc_i[0]),
      .dispatch_valid_o(admitted), .dispatch_solo_o(dispatch_solo),
      .allocate_accept_i(allocate_accept_o), .allocate_id_i(allocate_id_o[0]), .source1_i(rename_source[5:0]), .source2_i(rename_source2),
      .queue_dispatch_o(), .head_valid_i(head_valid), .head_id_i(head_id_o), .head_pc_i(head_pc),
      .recover_i(redirect_o), .recover_slot_i(resolve_id_o[4:0]),
      .retire_accept_i(serial_accept && !(EARLY_LOADS && memory_serial_offer)), .retire_id_i(serial_id),
      .busy_o(descriptor_busy), .owner_valid_o(owner_valid), .killed_o(killed),
      .owner_id_o(system_id), .owner_instruction_o(system_instruction), .owner_pc_o(owner_pc), .owner_sources_o(dispatch_sources), .owner_memory_o(owner_memory)
    );

    // system instructions and trap service
    head_system_controller #(.CLEAN(DCACHE), .M_EXTENSION(M_EXTENSION)) head (
      .clk_i, .rst_i, .cancel_i(flush_i || cancel_system_i), .retire_accept_i(retire_accept_o),
      .head_valid_i(head_valid), .head_id_i(head_id_o), .head_pc_i(head_pc),
      .system_valid_i(owner_valid && !owner_memory), .system_id_i(system_id), .instruction_i(system_instruction),
      .source_ready_i(read_ready[0]), .source_i(head_data[31:0]), .order_ready_i(!memory_busy_o),
      .prepare_o(system_prepare_o), .busy_o(system_busy_o),
      .fault_valid_i(fault_pending_o), .fault_event_i(fault_event_o),
      .serial_offer_o(system_offer), .serial_id_o(system_serial_id), .serial_event_o(system_serial_event), .serial_accept_i(serial_accept && system_offer),
      .illegal_offer_o(illegal_offer), .illegal_id_o(illegal_id), .illegal_event_o(illegal_event), .illegal_accept_i(illegal_accept),
      .trap_valid_o(system_trap_valid), .trap_event_o(system_trap_event), .trap_accept_i(trap_accept_o),
      .redirect_o(system_redirect_o), .redirect_pc_o(system_redirect_pc_o),
      .clean_done_i(clean_done), .clean_o(clean_request), .invalidate_o(icache_invalidate_o), .fence_i_o(fetch_hold_o)
    );
    if (MEMORY_SERVICE) begin : memory_service
      wire [11:0] unused_fatal;
      wire head_busy, head_fatal, head_request_valid, head_request_ready, head_response_valid, head_response_ready;
      memory_protocol_pkg::mem_request_t head_request;
      wire lsu_busy, lsu_fatal, lsu_write_done, store_buffer_full, store_buffer_pending, head_committed;
      wire [31:0] head_committed_address, head_committed_data, lsu_write_address, lsu_write_data;
      wire [3:0] head_committed_mask, lsu_write_mask;
      logic committed_busy_q;

      // rob-head memory service
      head_memory_controller #(.DCACHE(DCACHE)) memory_head_controller (
        .clk_i, .rst_i, .recovery_i(flush_i || recover_hold || fault_pending_o), .cancel_i(flush_i),
        .memory_valid_i((EARLY_LOADS ? lsu_head_memory : owner_valid && owner_memory) && !cancel_system_i),
        .memory_id_i(EARLY_LOADS ? head_id_o : system_id),
        .instruction_i(EARLY_LOADS ? lsu_head_instruction : system_instruction),
        .pc_i(EARLY_LOADS ? head_pc : owner_pc),
        .head_valid_i(head_valid), .head_id_i(head_id_o), .head_pc_i(head_pc),
        .source_ready_i(read_ready), .source1_i(head_data[31:0]), .source2_i(head_data[63:32]),
        .issue_allowed_i(memory_issue_allowed_i), .read_request_o(memory_read),
        .prepare_o(memory_prepare_o), .busy_o(head_busy),
        .admission_valid_o, .admission_id_o, .admission_address_o, .admission_data_o,
        .admission_mask_o, .admission_size_o, .admit_valid_i, .admit_id_i,
        .serial_offer_o(memory_serial_offer), .serial_owner_o(memory_serial_owner), .serial_id_o(memory_serial_id), .serial_event_o(memory_serial_event),
        .serial_accept_i(serial_accept && memory_serial_offer),
        .fault_offer_o(memory_fault_offer), .fault_id_o(memory_fault_id), .fault_event_o(memory_fault_event),
        .fault_accept_i(raw_q && memory_fault_offer && backend_complete_accept[0]),
        .trap_ready_o(memory_trap_ready), .trap_accept_i(trap_accept_o && memory_head),
        .store_buffer_full_i(store_buffer_full), .store_buffer_pending_i(store_buffer_pending),
        .committed_o(head_committed), .committed_address_o(head_committed_address),
        .committed_data_o(head_committed_data), .committed_mask_o(head_committed_mask),
        .irrevocable_o(memory_irrevocable_o), .fatal_o(head_fatal),
        .fatal_sources_o(unused_fatal[11:8]), .fatal_reason_o(unused_fatal[7:0]),
        .request_valid_o(head_request_valid), .request_ready_i(head_request_ready), .request_o(head_request),
        .response_valid_i(head_response_valid), .response_ready_o(head_response_ready), .response_i(data_response_i)
      );
      assign memory_busy_o = head_busy || lsu_busy;
      assign memory_fatal_o = head_fatal || lsu_fatal;

      // Emit stores once in retirement order; cached stores follow any victim writeback.
      always_ff @(posedge clk_i) begin
        if (rst_i) committed_busy_q <= 0;
        else committed_busy_q <= memory_committed_o;
      end
      assign memory_committed_o = DCACHE ? store_buffer_pending : head_committed;
      assign committed_valid_o = DCACHE ? lsu_write_done : memory_committed_o && !committed_busy_q;
      assign committed_address_o = DCACHE ? lsu_write_address : head_committed_address;
      assign committed_data_o = DCACHE ? lsu_write_data : head_committed_data;
      assign committed_mask_o = DCACHE ? lsu_write_mask : head_committed_mask;

      if (EARLY_LOADS) begin : early_loads

        // early-load scheduling and execution
        load_store_unit #(.TRACE(TRACE), .DCACHE(DCACHE)) lsu (
          .clk_i, .rst_i, .flush_i(producer_flush), .recover_i(redirect_o), .recover_slot_i(resolve_id_o[4:0]),
          .head_valid_i(head_valid), .head_id_i(head_id_o), .head_step_i(retire_accept_o),
          .allocate_valid_i(admitted), .allocate_memory_i(memory_op),
          .allocate_store_i({decoded[1].op == OP_STORE, decoded[0].op == OP_STORE}),
          .allocate_ready_o(lsu_allocate_ready), .allocate_i(allocate_accept_o), .allocate_id_i(allocate_id_o),
          .allocate_instruction_i(instruction_i[0]), .allocate_pc_i(pc_i[0]),
          .allocate_sources_i({rename_source2, rename_source[5:0]}),
          .issue_i(memory_issue), .issue_id_i(stage_id_q[1]), .issue_destination_i(stage_destination_q[1]),
          .issue_instruction_i(stage_payload_q[1][31:0]),
          .issue_pc_i(stage_payload_q[1][63:32]), .source1_i(stage_data_q[1][31:0]), .source2_i(stage_data_q[1][63:32]),
          .retire_i(retire_accept_o[0]), .clean_i(clean_request), .clean_done_o(clean_done),
          .store_buffer_full_o(store_buffer_full), .store_buffer_pending_o(store_buffer_pending),
          .write_done_o(lsu_write_done), .write_address_o(lsu_write_address), .write_data_o(lsu_write_data),
          .write_mask_o(lsu_write_mask),
          .head_memory_o(lsu_head_memory), .head_instruction_o(lsu_head_instruction),
          .head_sources_o(lsu_head_sources), .issue_allowed_i(memory_issue_allowed_i),
          .committed_valid_i(head_committed), .committed_address_i(head_committed_address),
          .committed_data_i(head_committed_data), .committed_mask_i(head_committed_mask),
          .complete_valid_o(memory_complete), .complete_id_o(lsu_complete_id),
          .complete_destination_o(lsu_complete_destination), .complete_event_o(lsu_event),
          .complete_take_i(completion_accept_o[1] && memory_complete), .busy_o(lsu_busy), .fatal_o(lsu_fatal),
          .head_request_valid_i(head_request_valid), .head_request_ready_o(head_request_ready),
          .head_request_i(head_request), .head_response_valid_o(head_response_valid),
          .head_response_ready_i(head_response_ready),
          .request_valid_o(data_request_valid_o), .request_ready_i(data_request_ready_i), .request_o(data_request_o),
          .response_valid_i(data_response_valid_i), .response_ready_o(data_response_ready_o), .response_i(data_response_i)
        );
      end else begin : head_only_memory
        assign {lsu_busy, lsu_fatal, lsu_write_done, store_buffer_full, store_buffer_pending, clean_done} = 0;
        assign {lsu_write_address, lsu_write_data, lsu_write_mask} = 0;
        wire unused_clean = clean_request;
        assign {data_request_valid_o, head_request_ready, head_response_valid, data_response_ready_o}
          = {head_request_valid, data_request_ready_i, data_response_valid_i, head_response_ready};
        assign data_request_o = head_request;
      end
    end
    if (!MEMORY_SERVICE) begin : unused_memory_owner
      assign clean_done = 0;
      wire unused_owner = ^owner_pc ^ read_ready[1] ^ ^head_data[63:32] ^ ^lsu_head_instruction ^ clean_request;
    end
    if (!(MEMORY_SERVICE && EARLY_LOADS)) begin : no_lsu_head
      assign {lsu_head_instruction, lsu_head_sources} = 0;
    end
    assign backend_trap_ready = system_trap_valid_o && trap_ready_i;
`ifndef SYNTHESIS
    always_ff @(posedge clk_i) if (!rst_i) begin
      assert (!(system_busy_o && redirect_o)) else $fatal(1, "CF_SYSTEM_RECOVERY");
      assert (!system_trap_valid_o || trap_prepared) else $fatal(1, "CF_TRAP_ARMED");
      assert (!(system_offer && memory_serial_offer) && !(illegal_offer && memory_fault_offer))
        else $fatal(1, "CF_HEAD_EXCLUSIVE");
      assert (!memory_irrevocable_o || !redirect_o) else $fatal(1, "CF_MEMORY_RECOVERY");
      assert (!drained_i || (!descriptor_busy && !system_busy_o && !memory_busy_o)) else $fatal(1, "CF_SYSTEM_DRAIN");
      assert (!killed || !system_prepare_o) else $fatal(1, "CF_SYSTEM_CANCEL");
    end
`endif
  end else begin : no_systems
    wire unused_lsu = lsu_head_memory;
    assign admitted = selected;
    assign dispatch_solo = 0;
    assign head_read = 0;
    assign system_sources = 0;
    assign serial_offer = 0;
    assign serial_id = 0;
    assign serial_event = '0;
    assign illegal_offer = 0;
    assign illegal_id = 0;
    assign illegal_event = '0;
    assign backend_trap_ready = trap_ready_i;
    assign system_prepare_o = 0;
    assign system_busy_o = 0;
    assign system_redirect_o = 0;
    assign system_redirect_pc_o = 0;
    assign {icache_invalidate_o, fetch_hold_o} = 0;
    assign system_trap_valid_o = 0;
    assign system_trap_event_o = '0;
    wire unused_system = cancel_system_i ^ head_valid ^ ^head_pc ^ ^rename_source ^ ^rename_source2 ^ ^read_ready ^ ^head_data
      ^ serial_accept ^ illegal_accept ^ memory_serial_owner ^ memory_serial_offer ^ memory_trap_ready ^ memory_read ^ ^memory_serial_id
      ^ ^memory_serial_event;
  end

  // Disable memory completions when early-load service is absent.
  if (!(SYSTEM_SERVICE && MEMORY_SERVICE && EARLY_LOADS)) begin : no_early_loads
    assign {memory_complete, lsu_complete_id, lsu_complete_destination, lsu_head_memory} = 0;
    assign lsu_event = '0;
    assign lsu_allocate_ready = 1;
  end

  // disabled memory-service outputs
  if (!MEMORY_SERVICE) begin : no_memory
    assign {memory_prepare_o, memory_busy_o, memory_committed_o, memory_irrevocable_o, memory_fatal_o} = 0;
    assign {committed_valid_o, committed_address_o, committed_data_o, committed_mask_o} = 0;
    assign {memory_serial_owner, memory_read, memory_serial_offer, memory_fault_offer, memory_trap_ready} = 0;
    assign {memory_serial_id, memory_fault_id, admission_id_o} = 0;
    assign {memory_serial_event, memory_fault_event, data_request_o} = '0;
    assign {admission_valid_o, admission_address_o, admission_data_o, admission_mask_o, admission_size_o} = 0;
    assign {data_request_valid_o, data_response_ready_o} = 0;
    wire unused_memory = memory_issue_allowed_i ^ admit_valid_i ^ ^admit_id_i ^ data_request_ready_i
      ^ data_response_valid_i ^ ^data_response_i;
  end

  // configuration checks
  if (MEMORY_SERVICE && !SYSTEM_SERVICE) begin : invalid_memory_configuration
    initial $error("MEMORY_SERVICE_REQUIRES_SYSTEM_SERVICE");
  end
  if (DCACHE && !EARLY_LOADS) begin : invalid_cache_configuration
    initial $error("DCACHE_REQUIRES_EARLY_LOADS");
  end
  if (EARLY_LOADS && !MEMORY_SERVICE) begin : invalid_early_load_configuration
    initial $error("EARLY_LOADS_REQUIRES_MEMORY_SERVICE");
  end

  // rename, issue and retirement
  issue_backend #(.TRACE(TRACE)) backend (
    .queue_skip_i(EARLY_LOADS ? system_op : serial_op), .head_read_i(head_read), .head_source_i(system_sources),
    .serial_offer_i(serial_offer), .serial_id_i(serial_id), .serial_event_i(serial_event), .serial_accept_o(serial_accept),
    .clk_i, .rst_i, .flush_i, .drained_i,
    .resources_ready_i((admitted & ~supported_o) == 0 && lsu_allocate_ready),
    .valid_i(admitted), .cfi_i(cfi), .solo_i(dispatch_solo), .rs1_i(rs1), .rs2_i(rs2), .rd_i(rd), .pc_i,
    .eligible_i(eligible), .payload_i(payload), .allocate_accept_o, .allocate_id_o,
    .source1_o({unused_rename_source, rename_source}), .source2_o({unused_rename_source2, rename_source2}), .destination_o(), .stale_o(), .source_ready_o(),
    .complete_offer_i(backend_complete_offer), .complete_solo_i(backend_complete_solo),
    .complete_id_i(backend_complete_id), .complete_event_i(backend_complete_event),
    .complete_accept_o(backend_complete_accept), .wb_accept_o, .wb_destination_o(), .wb_data_o(),
    .resolve_offer_i(resolve_valid_o),
    .resolve_grant_i(resolve_grant_i && !head_owned), .recover_hold_i(recover_hold),
    .mispredict_i(resolve_mispredict_o), .resolve_id_i(resolve_id_o),
    .resolve_accept_o, .branch_recover_o(redirect_o),
    .retire_ready_i, .retire_valid_o, .retire_accept_o,
    .retire_rd_o(), .retire_destination_o(), .retire_stale_o(), .retire_event_o,
    .trap_ready_i(backend_trap_ready), .trap_valid_o(fault_pending_o), .trap_accept_o, .trap_event_o(fault_event_o),
    .port_ready_i(~wait_valid_q), .issue_o, .issue_id_o, .issue_destination_o(issue_destination),
    .early_valid_i(early_valid_all), .early_destination_i(early_destination),
    .read_early_i(read_early),
    .issue_source_o(issue_source), .issue_payload_o(issue_payload), .read_data_o(read_data), .read_ready_o(unused_read_ready), .head_data_o(head_data_now), .head_ready_o(head_ready_now),
    .head_valid_o(head_valid), .head_id_o, .head_pc_o(head_pc), .occupancy_o, .issue_occupancy_o, .identity_drain_o,
    .rat_o(), .committed_o(), .free_o(), .ready_o(),
    .checkpoint_accept_o(), .checkpoint_id_o(allocate_checkpoint), .checkpoint_valid_o, .checkpoint_released_o(),
    .issue_checkpoint_o(issue_checkpoint), .resolve_checkpoint_o(resolve_checkpoint)
  );
  // backend protocol assertions
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      assert (valid_i != 2'b10) else $fatal(1, "CF_BACKEND_PREFIX");
      for (int lane = 0; lane < 2; lane++)
        assert (!(allocate_accept_o[lane] && frontend_fault_i[lane]) || frontend_cause_i[lane] < 16)
          else $fatal(1, "CF_FAULT_CAUSE");
      assert (!drained_i || producer_busy_o == 0) else $fatal(1, "CF_BACKEND_DRAIN");
      assert (!resolve_accept_o || (resolve_valid_o && resolve_grant_i)) else $fatal(1, "CF_BACKEND_RESOLVE");
      assert (!redirect_o || (allocate_accept_o == 0 && issue_o == 0 && retire_accept_o == 0))
        else $fatal(1, "CF_BACKEND_RECOVERY");
      assert ((issue_o & wait_valid_q) == 0) else $fatal(1, "CF_STAGE_CAPACITY");
      assert (!held[3] || lsu_complete_destination == issued_destination_q[lsu_complete_id[4:0]])
        else $fatal(1, "CF_HELD_DESTINATION");
      assert (!raw_offer || raw_id == head_id_o) else $fatal(1, "CF_HEAD_FAULT_IDENTITY");
    end
  end
`endif
endmodule
`default_nettype wire
