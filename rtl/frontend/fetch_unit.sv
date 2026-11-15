`default_nettype none
// two-wide predicted fetch with retained lines, next-line prefetch and optional L1 instruction cache.
module fetch_unit #(parameter bit PREDICT = 0, parameter bit AHEAD = 0,
                    parameter bit TAGE = 0, parameter int CHECKPOINT_BITS = TAGE ? 36 : 12,
                    parameter bit ICACHE = 0, parameter bit REDIRECT_CYCLE = 1, parameter int L0_LINES = 4,
                    parameter bit PARALLEL_TAGE = 0) (  // L0_LINES: a power of two
  input  wire clk_i, rst_i, enable_i,
  input  wire redirect_i,
  input  wire [31:0] redirect_pc_i,
  input  wire invalidate_i,                // ICACHE: fence.i, once the data cache is clean
  input  wire hold_i,                      // ICACHE: fence.i before its invalidate; no new instruction-port request
  input  wire request_ready_i,
  input  wire response_valid_i,
  input  memory_protocol_pkg::mem_response_t response_i,
  input  wire [1:0] take_i,
  input  wire repair_i,
  input  wire [CHECKPOINT_BITS-1:0] repair_checkpoint_i,
  input  wire [1:0] retire_i,
  input  wire [63:0] retire_instruction_i, retire_pc_i, retire_next_i,

  output wire request_valid_o,
  output memory_protocol_pkg::mem_request_t request_o,
  output wire response_ready_o,
  output logic [1:0] valid_o,
  output logic [63:0] instruction_o, pc_o,
  // decode payload is qualified only by valid_o at the consumer.
  output wire [63:0] decode_instruction_o,
  output wire decode_fault_o,
  output wire fault_o,
  output wire [31:0] fault_cause_o,
  output wire busy_o,
  output logic fatal_o,
  output wire [1:0] predict_taken_o,
  output wire [63:0] predict_pc_o,
  output wire [2*CHECKPOINT_BITS-1:0] predict_checkpoint_o
);

  import memory_protocol_pkg::*;
  import platform_pkg::*;
  import core_pkg::executable;

  // current PC, line data and delivery signals
  logic [31:0] pc_q;
  logic misaligned_q;
  wire active = !rst_i && !fatal_o;
  // compute PC+4 and PC+8 before late lane selection; the sliced +8 preserves separate adders.
  wire [31:0] fall_through = take_i[1] ? {pc_q[31:3] + 29'd1, pc_q[2:0]} : pc_q + 32'd4;
  wire [1:0] taken;
  wire [63:0] target;
  wire deliver, faulted;   // pc_q's line is held; the fault token is offered
  wire [255:0] line;
  wire [63:0] ahead_target;  // each lane's jal or branch target, where the fetch unit computes it ahead of delivery
  wire targets_ready;        // they are in for pc_q's line; until then a jal or branch waits, other instructions go
  wire [2:0] next_word = pc_q[4:2] + 3'd1;
  wire [63:0] words = {line[32*next_word +: 32], line[32*pc_q[4:2] +: 32]};

  // branch prediction
  if (PREDICT) begin : prediction
    branch_predictor #(.TAGE(TAGE), .PARALLEL_TAGE(PARALLEL_TAGE), .TARGET_INPUT(ICACHE)) predictor (
      .clk_i, .rst_i, .pc_i(pc_o), .instruction_i(words), .target_i(ahead_target), .taken_o(taken), .target_o(target),
      .take_i(take_i & {2{deliver}}), .checkpoint_o(predict_checkpoint_o), .redirect_i, .repair_i,
      .repair_checkpoint_i, .retire_i, .retire_instruction_i, .retire_pc_i, .retire_next_i
    );
  end else begin : sequential
    assign taken = 0;
    assign target = 0;
    assign predict_checkpoint_o = 0;
    wire unused = ^{repair_i, repair_checkpoint_i, retire_i, retire_instruction_i, retire_pc_i, retire_next_i, words, ahead_target};
  end

  // fetch delivery ends at the first predicted-taken lane.
  assign predict_taken_o = taken & valid_o & {2{deliver}};
  assign predict_pc_o = {predict_taken_o[1] ? target[63:32] : pc_o[63:32] + 32'd4,
                         predict_taken_o[0] ? target[31:0] : pc_o[31:0] + 32'd4};
  wire last = take_i[1];
  wire jump = predict_taken_o[last];
  wire [31:0] jump_pc = last ? target[63:32] : target[31:0];
  // suppress next-line prefetch when a remaining backward branch or jump may reuse this line.
  logic loop_back;
  always_comb begin
    loop_back = 0;
    for (int w = 0; w < 8; w++)
      if (3'(w) >= pc_q[4:2] && line[32*w+31] && line[32*w +: 7] inside {7'h63, 7'h6f}) loop_back = 1;
  end

  // instruction delivery and precise frontend faults
  assign fault_o = valid_o[0] && faulted;
  assign fault_cause_o = misaligned_q ? CAUSE_INSTRUCTION_ADDRESS_MISALIGNED
                                    : CAUSE_INSTRUCTION_ACCESS_FAULT;
  assign decode_instruction_o = deliver ? words : 64'd0;
  assign decode_fault_o = faulted;
  always_comb begin
    valid_o = '0;
    pc_o = {pc_q + 32'd4, pc_q};
    instruction_o = '0;
    if (active && !redirect_i) begin
      if (deliver) begin
        valid_o = pc_q[4:2] == 3'd7 ? 2'b01 : 2'b11;
        if (taken[0]) valid_o = 2'b01;
        if (!targets_ready) begin
          if (words[6:0] inside {7'h63, 7'h6f}) valid_o = 2'b00;
          else if (words[38:32] inside {7'h63, 7'h6f}) valid_o = 2'b01;
        end
        instruction_o[31:0] = words[31:0];
        if (valid_o[1]) instruction_o[63:32] = words[63:32];
      end else if (faulted) valid_o = 2'b01;
    end
  end

  // cached fetch retains lines by address; redirects move only the PC.
  if (ICACHE) begin : cached
    localparam int LINES = L0_LINES + 2, PTR_BITS = $clog2(LINES);
    typedef enum logic [2:0] {RUN, REQUEST, RESPONSE, FAULT, STOP} state_e;
    state_e state_q;
    logic [LINES-1:0] valid_q;
    logic [26:0] line_q [LINES];
    logic [255:0] data_q [LINES];
    // register per-word branch/JAL targets after installation to keep adders before word selection.
    logic [7:0][31:1] target_q [LINES];
    logic [LINES-1:0] decoded_q;
    logic fresh_q;
    logic [PTR_BITS-1:0] fresh_slot_q;
    logic [7:0][31:1] fresh_target;
    always_comb for (int w = 0; w < 8; w++) begin
      automatic logic [31:0] ins = data_q[fresh_slot_q][32*w +: 32];
      fresh_target[w] = {line_q[fresh_slot_q], 3'(w), 1'b0}
        + (ins[6:0] == 7'h6f ? {{12{ins[31]}}, ins[19:12], ins[20], ins[30:21]}
                             : {{20{ins[31]}}, ins[7], ins[30:25], ins[11:8]});
    end

    // cached-fetch lookup, prefetch and replacement state
    logic [PTR_BITS-1:0] ptr_q;      // first-in first-out replacement
    logic [26:0] request_line_q, check_line_q;
    logic check_q;                   // a prefetch check is with the cache
    logic hold_q, offered_q, redirect_q;
    wire ic_hit, ic_miss, ic_fill, ic_fill_fault, ic_prefetch_ready, ic_prefetch_hit, ic_busy, ic_fatal;
    wire cache_request_valid, ic_response_ready;
    wire [255:0] ic_hit_data, ic_fill_data;
    wire [26:0] ic_fill_line;
    wire [26:0] next_line = pc_q[31:5] + 27'd1;
    logic [LINES-1:0] here, next_held, check_held;
    logic [255:0] here_data;
    logic [7:0][31:1] here_target;
    always_comb begin
      here_data = '0;
      here_target = '0;
      for (int n = 0; n < LINES; n++) begin
        here[n] = valid_q[n] && line_q[n] == pc_q[31:5];
        next_held[n] = valid_q[n] && line_q[n] == next_line;
        check_held[n] = valid_q[n] && line_q[n] == check_line_q;
        if (here[n]) here_data |= data_q[n];
        if (here[n]) here_target |= target_q[n];
      end
    end
    assign line = here_data;
    assign ahead_target = {here_target[next_word], 1'b0, here_target[pc_q[4:2]], 1'b0};
    assign deliver = state_q == RUN && here != 0 && pc_q[1:0] == 0;
    assign targets_ready = (here & decoded_q) != 0;
    assign faulted = state_q == FAULT;
    // look up a missing current line; REQUEST takes the answer and RESPONSE waits for its fill.
    wire lookup = state_q == RUN && here == 0 && enable_i && !redirect_i && pc_q[1:0] == 0 && executable(pc_q);
    // next-line prefetch uses early state; a redirect cancels its check on the following cycle.
    wire offer = AHEAD && deliver && !check_q && enable_i && !loop_back && next_held == 0
      && executable({next_line, 5'd0}) && ic_prefetch_ready;
    wire fill = state_q == RESPONSE && here == 0 && (ic_fill || ic_fill_fault) && ic_fill_line == request_line_q;
    wire demand_install = (state_q == REQUEST && here == 0 && ic_hit) || (fill && !ic_fill_fault);
    // one line installs per cycle; a check that loses is offered again
    wire check_install = check_q && ic_prefetch_hit && check_held == 0 && !demand_install;
    // the oldest line goes, but never the one pc_q is in
    wire [PTR_BITS-1:0] after = ptr_q == PTR_BITS'(LINES - 1) ? '0 : ptr_q + 1'b1;
    wire [PTR_BITS-1:0] slot = here[ptr_q] ? after : ptr_q;
    // fence.i holds back a new request; one already offered stays offered
    wire hold = hold_q && !offered_q;
    l1_icache cache (
      .clk_i, .rst_i, .invalidate_i, .lookup_valid_i(lookup), .lookup_line_i(pc_q[31:5]),
      .prefetch_valid_i(offer), .prefetch_line_i(next_line), .prefetch_cancel_i(redirect_q),
      .mem_request_ready_i(request_ready_i && !hold), .mem_response_valid_i(response_valid_i),
      .mem_response_i(response_i), .hit_valid_o(ic_hit), .hit_data_o(ic_hit_data), .miss_o(ic_miss),
      .fill_valid_o(ic_fill), .fill_data_o(ic_fill_data), .fill_fault_o(ic_fill_fault), .fill_line_o(ic_fill_line),
      .prefetch_ready_o(ic_prefetch_ready), .prefetch_hit_o(ic_prefetch_hit), .busy_o(ic_busy), .fatal_o(ic_fatal),
      .mem_request_valid_o(cache_request_valid), .mem_request_o(request_o),
      .mem_response_ready_o(ic_response_ready)
    );
    assign request_valid_o = active && cache_request_valid && !hold;
    assign response_ready_o = active && ic_response_ready;
    assign busy_o = active && ic_busy;

    // registered request hold preserves offers across FENCE.I.
    always_ff @(posedge clk_i) begin
      if (rst_i) {hold_q, offered_q, redirect_q} <= '0;
      else begin
        hold_q <= hold_i;
        redirect_q <= redirect_i;
        offered_q <= request_valid_o && !request_ready_i;
      end
    end

    // cached-fetch state, line installation and redirect handling
    always_ff @(posedge clk_i) begin
      if (rst_i) begin
        state_q <= RUN;
        pc_q <= RESET_PC;
        valid_q <= '0;
        ptr_q <= '0;
        check_q <= 0;
        fresh_q <= 0;
        misaligned_q <= 0;
        fatal_o <= 0;
      end else if (!fatal_o) begin
        if (ic_fatal) fatal_o <= 1;
        case (state_q)
          RUN: if (deliver) begin
            if (take_i[0] && !redirect_i) pc_q <= jump ? jump_pc : fall_through;
          end else if (enable_i && !redirect_i) begin
            misaligned_q <= pc_q[1:0] != 0;
            if (pc_q[1:0] != 0 || !executable(pc_q)) state_q <= FAULT;
            else begin
              request_line_q <= pc_q[31:5];
              state_q <= REQUEST;
            end
          end
          // a retry looks up again
          REQUEST: state_q <= here == 0 && !ic_hit && ic_miss ? RESPONSE : RUN;
          RESPONSE: if (here != 0) state_q <= RUN;
          else if (fill) begin
            misaligned_q <= 0;
            state_q <= ic_fill_fault ? FAULT : RUN;
          end
          FAULT: if (take_i[0] && !redirect_i) state_q <= STOP;
          default: ;
        endcase
        if (offer && !redirect_i) begin
          check_line_q <= next_line;
          check_q <= 1;
        end else if (check_q && (ic_prefetch_hit || ic_prefetch_ready)) check_q <= 0;
        fresh_q <= demand_install || check_install;
        fresh_slot_q <= slot;
        if (fresh_q) begin
          target_q[fresh_slot_q] <= fresh_target;
          decoded_q[fresh_slot_q] <= 1;
        end
        if (demand_install || check_install) begin
          valid_q[slot] <= 1;
          decoded_q[slot] <= 0;
          line_q[slot] <= check_install ? check_line_q : request_line_q;
          data_q[slot] <= fill ? ic_fill_data : ic_hit_data;
          ptr_q <= slot == PTR_BITS'(LINES - 1) ? '0 : slot + 1'b1;
        end
        // every redirect but a mispredict repair, including FENCE.I's, drops the held lines.
        if (redirect_i) begin
          if (!(PREDICT && repair_i)) valid_q <= '0;
          pc_q <= redirect_pc_i;
          check_q <= 0;
          state_q <= RUN;
        end
      end
    end
    wire unused_cached = REDIRECT_CYCLE;
    // retained-line and target assertions
`ifndef SYNTHESIS
    logic reset_seen_q;
    initial reset_seen_q = 1'b0;
    always_ff @(posedge clk_i) if (rst_i) reset_seen_q <= 1'b1;
    // held lines are distinct, once a reset has cleared them
    always_ff @(posedge clk_i) if (!rst_i && reset_seen_q)
      for (int a = 0; a < LINES; a++) for (int b = a + 1; b < LINES; b++)
        assert (!(valid_q[a] && valid_q[b] && line_q[a] == line_q[b])) else $fatal(1, "FETCH_LINE_DUPLICATE");
    // a delivered jal or branch carries the target its own word gives
    always_ff @(posedge clk_i) if (!rst_i) for (int lane = 0; lane < 2; lane++) begin
      automatic logic [31:0] ins = words[32*lane +: 32];
      if (valid_o[lane] && deliver && ins[6:0] inside {7'h63, 7'h6f})
        assert (ahead_target[32*lane +: 32] == pc_o[32*lane +: 32]
            + (ins[6:0] == 7'h6f ? {{12{ins[31]}}, ins[19:12], ins[20], ins[30:21], 1'b0}
                                 : {{20{ins[31]}}, ins[7], ins[30:25], ins[11:8], 1'b0}))
          else $fatal(1, "FETCH_TARGET_STALE");
    end
`endif

  // direct fetch uses a line buffer, retained lines and one next-line prefetch.
  end else begin : direct
    typedef enum logic [2:0] {EMPTY, REQUEST, RESPONSE, BUFFER, FAULT, STOP, WAIT} state_e;
    typedef enum logic [1:0] {A_IDLE, A_REQ, A_RESP, A_HAVE} ahead_e;
    ahead_e ahead_q;
    logic [26:0] ahead_line_q;
    logic [255:0] ahead_data_q;
    logic ahead_drop_q;
    // direct-fetch retained lines use FIFO replacement and swap back without a memory request.
    localparam int L0_BITS = L0_LINES > 1 ? $clog2(L0_LINES) : 1;
    logic [L0_LINES-1:0] l0_valid_q;
    logic [26:0] l0_line_q [L0_LINES];
    logic [255:0] l0_data_q [L0_LINES];
    logic [L0_BITS-1:0] l0_ptr_q;
    state_e state_q;
    logic [26:0] request_line_q;
    logic [255:0] line_q;
    logic [3:0] id_q;
    logic discard_q;
    assign line = line_q;
    assign ahead_target = '0;
    assign targets_ready = 1;
    assign deliver = state_q == BUFFER;
    assign faulted = state_q == FAULT;

    // fetch advance and line selection
    wire crossing = {1'b0, pc_q[4:2]} + (take_i[1] ? 4'd2 : 4'd1) >= 4'd8;
    wire [26:0] sequential_line = pc_q[31:5] + 27'd1;
    // compare both targets before late dispatch selects the final lane.
    wire [1:0] jump_crossing = {target[63:37] != pc_q[31:5], target[31:5] != pc_q[31:5]};
    wire leave = state_q == BUFFER && take_i[0] && !redirect_i && (jump ? jump_crossing[last] : crossing);
    wire ahead_flight = ahead_q == A_REQ || ahead_q == A_RESP;
    wire [1:0] ahead_predicted = {ahead_line_q == target[63:37], ahead_line_q == target[31:5]};
    wire ahead_sequential = ahead_line_q == sequential_line;
    wire ahead_match = ahead_q != A_IDLE && (jump ? ahead_predicted[last] : ahead_sequential);
    wire ahead_cancel = redirect_i || (leave && !ahead_match) || (state_q == EMPTY && ahead_q == A_HAVE);
    // retained-line lookup covers predicted, sequential and repair targets.
    logic [L0_LINES-1:0] l0_hit_vec, l0_seq_vec, l0_redirect_vec;
    logic [255:0] l0_data;
    always_comb begin
      l0_data = '0;
      for (int n = 0; n < L0_LINES; n++) begin
        l0_hit_vec[n] = l0_valid_q[n] && (jump ? (last ? l0_line_q[n] == target[63:37]
            : l0_line_q[n] == target[31:5]) : l0_line_q[n] == sequential_line);
        l0_seq_vec[n] = l0_valid_q[n] && l0_line_q[n] == sequential_line;
        l0_redirect_vec[n] = l0_valid_q[n] && l0_line_q[n] == redirect_pc_i[31:5];
        if (redirect_i ? l0_redirect_vec[n] : l0_hit_vec[n]) l0_data |= l0_data_q[n];
      end
    end
    wire previous_match = PREDICT && l0_hit_vec != 0;
    wire previous_next = PREDICT && l0_seq_vec != 0;
    // a mispredict repair (never a trap, flush or fence.i) into a held line restarts without a request.
    wire repair_reuse = PREDICT && repair_i && enable_i && redirect_pc_i[1:0] == 0
      && !(state_q inside {REQUEST, RESPONSE});
    wire repair_current = repair_reuse && state_q == BUFFER && redirect_pc_i[31:5] == pc_q[31:5];
    wire repair_previous = repair_reuse && l0_redirect_vec != 0;

    // next-line prefetch admission
    wire ahead_offer = AHEAD && state_q == BUFFER && ahead_q == A_IDLE && enable_i && !loop_back && !previous_next
      && executable({pc_q[31:5] + 27'd1, 5'd0});
    wire ahead_start = ahead_offer && !redirect_i && !leave;
    wire malformed = response_valid_i && (!(state_q == RESPONSE || ahead_q == A_RESP)
      || response_i.transaction_id != id_q
      || !(response_i.status inside {MEM_STATUS_OK, MEM_STATUS_ACCESS_FAULT})
      || response_i.uncached_read_data != 0
      || (response_i.status != MEM_STATUS_OK && response_i.line_read_data != 0));

    // a redirect cannot withdraw an offered request or release an owned id.
    wire ahead_request = active && ahead_q == A_REQ;
    assign request_valid_o = ahead_request || active && state_q == REQUEST;
    assign response_ready_o = active && (state_q == RESPONSE || ahead_q == A_RESP);
    assign busy_o = active && (state_q == REQUEST || state_q == RESPONSE || ahead_flight);
    always_comb begin
      request_o = '0;
      request_o.transaction_id = id_q;
      request_o.address = {request_line_q, 5'd0};
      if (ahead_q == A_REQ) request_o.address = {ahead_line_q, 5'd0};
    end
    wire unused_direct = ^{invalidate_i, hold_i, REDIRECT_CYCLE};

    // fetch, prefetch and redirect state
    always_ff @(posedge clk_i) begin
      if (rst_i) begin
        state_q <= EMPTY;
        pc_q <= RESET_PC;
        id_q <= 0;
        discard_q <= 0;
        ahead_q <= A_IDLE;
        ahead_drop_q <= 0;
        l0_valid_q <= '0;
        l0_ptr_q <= 0;
        misaligned_q <= 0;
        fatal_o <= 0;
      end else if (!fatal_o) begin
        if (malformed) fatal_o <= 1;
        case (state_q)
          EMPTY: if (enable_i && !redirect_i && !ahead_flight) begin
            misaligned_q <= pc_q[1:0] != 0;
            if (pc_q[1:0] != 0 || !executable(pc_q)) state_q <= FAULT;
            else begin
              request_line_q <= pc_q[31:5];
              discard_q <= 0;
              state_q <= REQUEST;
            end
          end
          REQUEST: if (request_ready_i) state_q <= RESPONSE;
          RESPONSE: if (response_valid_i && !malformed) begin
            discard_q <= 0;
            if (discard_q || redirect_i) state_q <= EMPTY;
            else if (response_i.status == MEM_STATUS_ACCESS_FAULT) begin
              misaligned_q <= 0;
              state_q <= FAULT;
            end else begin
              line_q <= response_i.line_read_data;
              state_q <= BUFFER;
            end
          end
          BUFFER: if (take_i[0] && !redirect_i) begin
            pc_q <= jump ? jump_pc : fall_through;
            if (leave) begin
              if (PREDICT) begin
                // a hit slot takes the line being left (no eviction); a miss writes the oldest slot
                if (!(ahead_match && ahead_q == A_HAVE) && previous_match) begin
                  for (int n = 0; n < L0_LINES; n++) if (l0_hit_vec[n]) begin
                    l0_line_q[n] <= pc_q[31:5];
                    l0_data_q[n] <= line_q;
                  end
                end else begin
                  l0_valid_q[l0_ptr_q] <= 1;
                  l0_line_q[l0_ptr_q] <= pc_q[31:5];
                  l0_data_q[l0_ptr_q] <= line_q;
                  l0_ptr_q <= l0_ptr_q + 1'b1;
                end
              end
              if (ahead_match && ahead_q == A_HAVE) begin
                line_q <= ahead_data_q;
                ahead_q <= A_IDLE;
              end else if (previous_match) line_q <= l0_data;
              else state_q <= ahead_match ? WAIT : EMPTY;
            end
          end
          WAIT: if (ahead_q == A_HAVE) begin
            line_q <= ahead_data_q;
            ahead_q <= A_IDLE;
            state_q <= BUFFER;
          end else if (ahead_q == A_IDLE) state_q <= EMPTY;
          FAULT: if (take_i[0] && !redirect_i) state_q <= STOP;
          default: ;
        endcase
        if (response_valid_i && response_ready_o && !malformed) id_q <= id_q + 1'b1;
        // discard stale or faulting prefetches; demand fetch reports faults precisely.
        case (ahead_q)
          A_IDLE: if (ahead_start) begin
            ahead_line_q <= pc_q[31:5] + 27'd1;
            ahead_drop_q <= 0;
            ahead_q <= A_REQ;
          end
          A_REQ: if (request_ready_i) ahead_q <= A_RESP;
          A_RESP: if (response_valid_i && !malformed) begin
            if (ahead_drop_q || ahead_cancel || response_i.status != MEM_STATUS_OK) ahead_q <= A_IDLE;
            else begin
              ahead_data_q <= response_i.line_read_data;
              ahead_q <= A_HAVE;
            end
          end
          A_HAVE: if (ahead_cancel) ahead_q <= A_IDLE;
          default: ;
        endcase
        if (ahead_cancel && ahead_flight) ahead_drop_q <= 1;
        // every redirect but a mispredict repair drops the retained line.
        if (redirect_i) begin
          if (!(PREDICT && repair_i)) l0_valid_q <= '0;
          // a repair that restarts from a fresh lookup must not leave the same line held
          if (PREDICT && repair_i && !repair_previous)
            for (int n = 0; n < L0_LINES; n++) if (l0_redirect_vec[n]) l0_valid_q[n] <= 0;
          pc_q <= redirect_pc_i;
          if (state_q == REQUEST || state_q == RESPONSE) begin
            if (!(state_q == RESPONSE && response_valid_i && !malformed)) discard_q <= 1;
          end else if (repair_current) state_q <= BUFFER;
          else if (repair_previous) begin
            line_q <= l0_data;
            for (int n = 0; n < L0_LINES; n++) if (l0_redirect_vec[n]) begin
              if (state_q == BUFFER) begin
                l0_line_q[n] <= pc_q[31:5];
                l0_data_q[n] <= line_q;
              end else l0_valid_q[n] <= 0;
            end
            state_q <= BUFFER;
          end else state_q <= EMPTY;
        end
      end
    end
    // retained-line and target assertions
`ifndef SYNTHESIS
    logic reset_seen_q;
    initial reset_seen_q = 1'b0;
    always_ff @(posedge clk_i) if (rst_i) reset_seen_q <= 1'b1;
    // held lines are distinct from each other and from the line in the buffer, once a reset has cleared them
    always_ff @(posedge clk_i) if (!rst_i && reset_seen_q) for (int a = 0; a < L0_LINES; a++) begin
      assert (!(l0_valid_q[a] && state_q == BUFFER && l0_line_q[a] == pc_q[31:5])) else $fatal(1, "FETCH_L0_CURRENT");
      for (int b = a + 1; b < L0_LINES; b++)
        assert (!(l0_valid_q[a] && l0_valid_q[b] && l0_line_q[a] == l0_line_q[b])) else $fatal(1, "FETCH_L0_DUPLICATE");
    end
`endif
  end

  // fetch acceptance assertions
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) if (!rst_i)
    assert (!(take_i[1] && !take_i[0]) && (take_i & ~valid_o) == 0) else $fatal(1, "FETCH_PREFIX");
`endif
endmodule
`default_nettype wire
