`default_nettype none
// read-only two-way L1 cache with 32-byte lines, one-cycle lookup and one outstanding fill.
module l1_icache #(parameter int HIT_STAGES = 1, SETS = 16) (
  input  wire clk_i, rst_i,
  input  wire invalidate_i,
  input  wire lookup_valid_i,                  // demand; accepted every cycle
  input  wire [31:5] lookup_line_i,
  input  wire prefetch_valid_i,                // prefetch check; a hit returns hit_data_o.
  input  wire [31:5] prefetch_line_i,
  input  wire prefetch_cancel_i,               // registered: the pending or staged prefetch check is stale
  input  wire mem_request_ready_i,
  input  wire mem_response_valid_i,
  input  memory_protocol_pkg::mem_response_t mem_response_i,

  output wire hit_valid_o,                     // HIT_STAGES after the lookup
  output wire [255:0] hit_data_o,
  output wire miss_o,
  output wire fill_valid_o,                    // the demand line fill_line_o arrived in fill_data_o
  output wire [255:0] fill_data_o,
  output wire fill_fault_o,                    // the demand line's fill was an access fault; nothing installed
  output wire [31:5] fill_line_o,
  output wire prefetch_ready_o,
  output wire prefetch_hit_o,                  // the accepted prefetch's check hit; its line is on hit_data_o
  output wire busy_o,
  output wire fatal_o,                         // sticky protocol fault: handshakes stop and busy stays high.
  output wire mem_request_valid_o,
  output memory_protocol_pkg::mem_request_t mem_request_o,
  output wire mem_response_ready_o
);

  import memory_protocol_pkg::*;

  localparam int WAYS = 2, INDEX_BITS = $clog2(SETS), TAG_BITS = 27 - INDEX_BITS;

  // configuration requires one-cycle hits because install-race guards assume that latency.
  if (HIT_STAGES != 1) begin : g_hit_stages
    $error("l1_icache implements HIT_STAGES = 1 only");
  end

  // lookup, demand and fill state
  typedef enum logic [1:0] {IDLE, REQUEST, RESPONSE, DELIVER} state_e;

  state_e state_q;
  logic [SETS-1:0][WAYS-1:0] valid_q;
  logic [SETS-1:0] lru_q;                          // the least recently used way of each set
  logic [WAYS-1:0] valid_snap_q;
  logic stage_valid_q, stage_prefetch_q, prefetch_pending_q, demand_valid_q, invalidated_q, fault_q;
  logic deliver_last_q, fatal_q;
  logic [26:0] stage_line_q, prefetch_line_q, demand_line_q, mshr_line_q;
  logic [255:0] line_q;
  logic [3:0] transaction_q;
  wire [WAYS-1:0][TAG_BITS-1:0] read_tag;
  wire [WAYS-1:0][255:0] read_data;

  // read arbitration gives demand lookups priority over pending prefetch checks.
  wire prefetch_read = prefetch_pending_q && !lookup_valid_i && !prefetch_cancel_i;
  wire [26:0] read_line = lookup_valid_i ? lookup_line_i : prefetch_line_q;

  // lookup decision uses tags and valid bits sampled at the same edge (T7-A1).
  wire [INDEX_BITS-1:0] stage_set = stage_line_q[INDEX_BITS-1:0];
  wire [INDEX_BITS-1:0] mshr_set = mshr_line_q[INDEX_BITS-1:0];
  wire [WAYS-1:0] hit_way;
  for (genvar w = 0; w < WAYS; w++) begin : g_hit
    assign hit_way[w] = valid_snap_q[w] && read_tag[w] == stage_line_q[26 -: TAG_BITS];
  end
  wire hit = |hit_way;
  // retry misses around same-set installation; the registered read may predate it (T7-A2).
  wire install_race = (state_q == DELIVER || deliver_last_q) && stage_set == mshr_set;
  wire stage_miss = stage_valid_q && !hit && !install_race && !(stage_prefetch_q && prefetch_cancel_i);
  wire demand_miss = stage_miss && !stage_prefetch_q;
  assign hit_valid_o = stage_valid_q && !stage_prefetch_q && hit && !fatal_q;
  assign hit_data_o = hit_way[0] ? read_data[0] : read_data[1];
  assign miss_o = demand_miss && !fatal_q;
  assign prefetch_hit_o = stage_valid_q && stage_prefetch_q && hit && !fatal_q;

  // miss admission prioritizes the newest demand, then a waiting demand, then prefetch.
  wire idle = state_q == IDLE;
  wire start = idle && (stage_miss || demand_valid_q);
  wire [26:0] start_line = demand_valid_q && !demand_miss ? demand_line_q : stage_line_q;
  assign prefetch_ready_o = idle && !prefetch_pending_q && !(stage_valid_q && stage_prefetch_q) && !fatal_q;

  // fill delivery and installation use line_q; invalidation suppresses both for the in-flight transaction.
  wire deliver = state_q == DELIVER && demand_valid_q && demand_line_q == mshr_line_q && !invalidated_q;
  assign fill_valid_o = deliver && !fault_q && !fatal_q;
  assign fill_fault_o = deliver && fault_q && !fatal_q;
  assign fill_data_o = line_q;
  assign fill_line_o = mshr_line_q;
  wire install_go = state_q == DELIVER && !fault_q && !invalidated_q && !fatal_q;
  wire install_way = !valid_q[mshr_set][0] ? 1'b0 : !valid_q[mshr_set][1] ? 1'b1 : lru_q[mshr_set];
  l1_cache_array #(.SETS(SETS), .WAYS(WAYS), .TAG_BITS(TAG_BITS), .BYTE_WRITE(1'b0)) u_array (
    .clk_i, .rst_i, .read_set_i(read_line[INDEX_BITS-1:0]), .write_i(install_go), .write_tag_i(1'b1),
    .write_set_i(mshr_set), .write_way_i(install_way), .write_tag_value_i(mshr_line_q[26 -: TAG_BITS]),
    .write_byte_mask_i('1), .write_data_i(line_q), .read_tag_o(read_tag), .read_data_o(read_data));

  // memory port holds one transaction from registered state through request and response.
  assign mem_request_valid_o = state_q == REQUEST && !fatal_q;
  assign mem_response_ready_o = state_q == RESPONSE && !fatal_q;
  wire malformed = mem_response_valid_i && (state_q != RESPONSE || mem_response_i.transaction_id != transaction_q
    || !(mem_response_i.status inside {MEM_STATUS_OK, MEM_STATUS_ACCESS_FAULT})
    || mem_response_i.uncached_read_data != 0
    || (mem_response_i.status != MEM_STATUS_OK && mem_response_i.line_read_data != 0));
  wire responded = mem_response_valid_i && state_q == RESPONSE && !malformed;
  always_comb begin
    mem_request_o = '0;
    if (mem_request_valid_o) begin
      mem_request_o.transaction_id = transaction_q;
      mem_request_o.address = {mshr_line_q, 5'd0};
    end
  end
  assign busy_o = fatal_q || !idle || demand_valid_q || prefetch_pending_q || stage_valid_q;
  assign fatal_o = fatal_q;

  // unreset payload capture; DELIVER uses the response-edge value under reset control state.
  always_ff @(posedge clk_i) begin
    stage_prefetch_q <= !lookup_valid_i;
    stage_line_q <= read_line;
    valid_snap_q <= valid_q[read_line[INDEX_BITS-1:0]] & {WAYS{!invalidate_i}};
    line_q <= mem_response_i.line_read_data;
    fault_q <= mem_response_i.status == MEM_STATUS_ACCESS_FAULT;
  end

  // lookup, line-validity and transaction updates
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= IDLE;
      {valid_q, lru_q} <= '0;
      {stage_valid_q, prefetch_pending_q, demand_valid_q, invalidated_q, deliver_last_q, fatal_q} <= '0;
      transaction_q <= '0;
    end else begin
      // lookup and prefetch state; cancel discards stale checks and install-racing prefetch misses are dropped.
      stage_valid_q <= lookup_valid_i || prefetch_read;
      if (prefetch_valid_i && prefetch_ready_o) prefetch_line_q <= prefetch_line_i;
      prefetch_pending_q <= (prefetch_valid_i && prefetch_ready_o)
        || (prefetch_pending_q && lookup_valid_i && !prefetch_cancel_i);

      // demand: set by a miss, cleared when its fill or fault is delivered
      if (deliver) demand_valid_q <= 0;
      if (demand_miss) {demand_valid_q, demand_line_q} <= {1'b1, stage_line_q};

      // line state; an invalidate in an install cycle wins over the install
      if (stage_valid_q && hit) lru_q[stage_set] <= !hit_way[1];
      if (install_go) begin
        valid_q[mshr_set][install_way] <= 1;
        lru_q[mshr_set] <= !install_way;
      end
      if (invalidate_i) valid_q <= '0;

      // fill transaction state; invalidation marks only the transaction already in flight (T7-A4).
      invalidated_q <= !idle && (invalidated_q || invalidate_i);
      deliver_last_q <= state_q == DELIVER;
      if (responded) transaction_q <= transaction_q + 1'b1;
      if (malformed) fatal_q <= 1;
      case (state_q)
        IDLE: if (start) begin
          mshr_line_q <= start_line;
          state_q <= REQUEST;
        end
        REQUEST: if (mem_request_ready_i) state_q <= RESPONSE;
        RESPONSE: if (responded) state_q <= DELIVER;
        default: state_q <= IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // protocol diagnostics; fill access faults remain precise demand faults.
  always_ff @(posedge clk_i)
    if (!rst_i && !fatal_q && malformed)
      $display("IC_PROTOCOL status=%0d id=%0d", mem_response_i.status, mem_response_i.transaction_id);
`endif
endmodule
`default_nettype wire
