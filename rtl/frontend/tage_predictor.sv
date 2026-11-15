`default_nettype none
// TAGE512 speculative lookup and ordered retirement training; single-port defaults update immediately.
module tage_predictor #(parameter int AGE_BITS = 18, parameter int LOOKUPS = 1, parameter int UPDATES = 1,
                        parameter bit EXTERNAL_HISTORY = 0, parameter bit TRAIN_QUEUE = 0,
                        parameter bit SERIAL_LOOKUPS = 1) (  // AGE_BITS < 18 only to test aging
  input  wire clk_i, rst_i,
  input  wire [LOOKUPS-1:0] lookup_valid_i,
  input  wire [LOOKUPS*32-1:0] lookup_pc_i,
  input  wire [31:0] lookup_history_i,
  input  wire [LOOKUPS-1:0] lookup_branch_i, lookup_path_i,
  input  wire [UPDATES-1:0] update_valid_i, update_taken_i,
  input  wire [UPDATES*32-1:0] update_pc_i, update_history_i,  // history before the branch; TRAIN_QUEUE only

  output logic [LOOKUPS-1:0] lookup_taken_o,
  output logic [1:0] update_dropped_o
);

  // prediction, hashing and training types
  typedef struct packed {
    logic valid;
    logic [7:0] tag;
    logic [2:0] counter;  // signed, >= 0 predicts taken
    logic [1:0] useful;
  } entry_t;
  typedef struct packed {
    logic [7:0] base_index;
    logic [3:0][5:0] index;
    logic [3:0][7:0] tag;
  } hash_t;
  typedef struct packed {
    logic taken;
    hash_t hash;
  } train_t;
  typedef struct packed {
    logic provider_hit, alternate_hit;
    logic [1:0] provider, alternate;
    logic provider_prediction, alternate_prediction, weak_new, prediction;
    logic [1:0] useful;
  } lookup_t;

  // base and tagged tables with history, chooser and aging state
  logic [255:0][1:0] base_q, base_n;
  entry_t [3:0][63:0] table_q, table_n;
  logic [31:0] history_q, history_n;
  logic [3:0] chooser_q, chooser_n;  // signed, >= 0 selects the alternate for weak/new providers
  logic [AGE_BITS-1:0] age_q, age_n;

  // xor of consecutive width-bit chunks
  function automatic logic [7:0] fold(input logic [31:0] h, input int width);
    logic [7:0] r = 0;
    logic [39:0] x = {8'd0, h};  // the last chunk may run past bit 31
    for (int i = 0; i < 32; i += width) r ^= x[i +: 8] & 8'((1 << width) - 1);
    return r;
  endfunction

  function automatic int saturate(input int value, input logic up, input int low, high);
    return up ? (value < high ? value + 1 : high) : (value > low ? value - 1 : low);
  endfunction

  function automatic hash_t hash_of(input logic [17:2] pc, input logic [31:0] history);  // the hashes use no other pc bits
    hash_t r;
    r.base_index = pc[9:2];
    for (int b = 0; b < 4; b++) begin
      automatic logic [31:0] h = history & (32'hffffffff >> (32 - (4 << b)));
      r.index[b] = pc[7:2] ^ pc[13:8] ^ fold(h, 6)[5:0];
      r.tag[b] = pc[9:2] ^ pc[17:10] ^ fold(h, 8) ^ {fold(h, 7)[6:0], 1'b0};
    end
    return r;
  endfunction

  // provider selection uses the longest tag hit, with the next longest hit or base as alternate.
  function automatic lookup_t probe(input logic [3:0][7:0] tag, input logic base_taken, input entry_t [3:0] e,
                                    input logic alternate_weak);
    lookup_t r = '0;
    for (int b = 0; b < 4; b++) begin
      if (e[b].valid && e[b].tag == tag[b]) begin
        r.alternate_hit = r.provider_hit;
        r.alternate = r.provider;
        r.provider_hit = 1;
        r.provider = 2'(b);
      end
    end
    r.alternate_prediction = r.alternate_hit ? !e[r.alternate].counter[2] : base_taken;
    r.provider_prediction = r.alternate_prediction;
    r.prediction = r.alternate_prediction;
    if (r.provider_hit) begin
      automatic logic [2:0] counter = e[r.provider].counter;
      r.provider_prediction = !counter[2];
      r.useful = e[r.provider].useful;
      r.weak_new = r.useful == 0 && (counter == 3'b111 || counter == 3'b000);
      r.prediction = r.weak_new && alternate_weak ? r.alternate_prediction : r.provider_prediction;
    end
    return r;
  endfunction

  function automatic lookup_t lookup(input logic [17:2] pc, input logic [31:0] history,
      input logic [255:0][1:0] base, input entry_t [3:0][63:0] banks, input logic alternate_weak);
    automatic hash_t k = hash_of(pc, history);
    automatic entry_t [3:0] e;
    for (int b = 0; b < 4; b++) e[b] = banks[b][k.index[b]];
    return probe(k.tag, base[k.base_index][1], e, alternate_weak);
  endfunction

  // speculative direction lookup
  always_comb begin
    automatic logic [31:0] h = EXTERNAL_HISTORY ? lookup_history_i : history_q;
    for (int lane = 0; lane < LOOKUPS; lane++) begin
      lookup_taken_o[lane] = lookup_valid_i[lane]
        && lookup(lookup_pc_i[lane*32+2 +: 16], h, base_q, table_q, !chooser_q[3]).prediction;
      if (SERIAL_LOOKUPS && lookup_valid_i[lane] && lookup_branch_i[lane])
        h = {h[30:0], lookup_taken_o[lane] && lookup_path_i[lane]};
    end
  end
  wire unused_lookup_sequence = !SERIAL_LOOKUPS && ^{lookup_branch_i, lookup_path_i};
  for (genvar lane = 0; lane < LOOKUPS; lane++) begin : unused_lookup
    wire unused = ^{lookup_pc_i[lane*32+18 +: 14], lookup_pc_i[lane*32 +: 2]};
  end
  for (genvar lane = 0; lane < UPDATES; lane++) begin : unused_update
    wire unused = ^{update_pc_i[lane*32+18 +: 14], update_pc_i[lane*32 +: 2]};
  end
  if (!TRAIN_QUEUE) begin : unused_history
    wire unused = ^update_history_i;
  end

  // retirement training queue drains one entry per cycle and drops youngest overflow arrivals.
  localparam int DEPTH = 4;
  train_t head;
  logic head_valid;
  if (TRAIN_QUEUE) begin : train_queue
    train_t queue_q [DEPTH], queue_n [DEPTH], incoming [UPDATES];
    logic [2:0] count_q, base, room;
    logic [2:0] arrivals, accepted;
    wire pop = count_q != 0;
    always_comb begin
      automatic int n = 0;
      for (int k = 0; k < UPDATES; k++) incoming[k] = '0;
      for (int lane = 0; lane < UPDATES; lane++) begin
        // hash per lane first, then compact, so a lane-one-only arrival carries lane one's history
        if (update_valid_i[lane]) begin
          incoming[n] = '{taken: update_taken_i[lane],
                          hash: hash_of(update_pc_i[lane*32+2 +: 16], update_history_i[lane*32 +: 32])};
          n++;
        end
      end
      arrivals = 3'(n);
      base = count_q - 3'(pop);
      room = 3'(DEPTH) - base;
      accepted = arrivals <= room ? arrivals : room;
      update_dropped_o = 2'(arrivals - accepted);
      for (int i = 0; i < DEPTH; i++) queue_n[i] = pop ? (i + 1 < DEPTH ? queue_q[(i + 1) % DEPTH] : '0) : queue_q[i];
      for (int k = 0; k < UPDATES; k++) if (3'(k) < accepted) queue_n[(base + 3'(k)) % 4] = incoming[k];
    end
    always_ff @(posedge clk_i) begin
      queue_q <= queue_n;
      count_q <= rst_i ? 3'd0 : base + accepted;
    end
    assign head = queue_q[0];
    assign head_valid = pop;
  end else begin : no_queue
    assign head = '0;
    assign head_valid = 0;
    assign update_dropped_o = 0;
  end

  // ordered training forwards earlier indexed writes and aging into later update steps.
  localparam int STEPS = TRAIN_QUEUE ? 1 : UPDATES;
  always_comb begin
    automatic logic [STEPS-1:0] step_valid, step_aging;
    automatic hash_t [STEPS-1:0] step_hash;
    automatic entry_t [STEPS-1:0][3:0] step_entry;
    automatic logic [STEPS-1:0][1:0] step_base;
    {step_valid, step_aging, step_hash, step_entry, step_base} = '0;
    chooser_n = chooser_q;
    age_n = age_q;
    history_n = history_q;
    for (int step = 0; step < STEPS; step++) begin
      automatic hash_t k = TRAIN_QUEUE ? head.hash : hash_of(update_pc_i[step*32+2 +: 16], history_n);
      automatic logic taken = TRAIN_QUEUE ? head.taken : update_taken_i[step];
      automatic logic [1:0] base = base_q[k.base_index];
      automatic entry_t [3:0] e;
      automatic lookup_t r;
      for (int b = 0; b < 4; b++) e[b] = table_q[b][k.index[b]];
      for (int t = 0; t < step; t++) begin
        if (step_valid[t] && step_hash[t].base_index == k.base_index) base = step_base[t];
        for (int b = 0; b < 4; b++) begin
          if (step_valid[t] && step_hash[t].index[b] == k.index[b]) e[b] = step_entry[t][b];
          if (step_aging[t]) e[b].useful = e[b].useful >> 1;
        end
      end
      r = probe(k.tag, base[1], e, !chooser_n[3]);
      step_valid[step] = TRAIN_QUEUE ? head_valid : update_valid_i[step];
      step_aging[step] = 0;
      if (step_valid[step]) begin
        age_n = age_n + 1'b1;
        if (!r.provider_hit) begin
          base = 2'(saturate(int'(base), taken, 0, 3));
        end else begin
          if (r.weak_new && r.provider_prediction != r.alternate_prediction)
            chooser_n = 4'(saturate(int'($signed(chooser_n)), r.alternate_prediction == taken, -8, 7));
          e[r.provider].counter = 3'(saturate(int'($signed(e[r.provider].counter)), taken, -4, 3));
          if (r.provider_prediction != r.alternate_prediction)
            e[r.provider].useful = 2'(saturate(int'(e[r.provider].useful), r.provider_prediction == taken, 0, 3));
          // usefulness is the pre-update value
          if (r.useful == 0) begin
            if (!r.alternate_hit) base = 2'(saturate(int'(base), taken, 0, 3));
            else e[r.alternate].counter = 3'(saturate(int'($signed(e[r.alternate].counter)), taken, -4, 3));
          end
        end
        // a correct new provider should mature instead of causing another allocation.
        if (r.prediction != taken && !(r.weak_new && r.provider_prediction == taken)) begin
          automatic logic found = 0;
          for (int b = 0; b < 4; b++) begin
            if ((!r.provider_hit || b > int'(r.provider)) && !found && (!e[b].valid || e[b].useful == 0)) begin
              e[b] = '{valid: 1, tag: k.tag[b], counter: taken ? 3'b000 : 3'b111, useful: 0};
              found = 1;
            end
          end
          // every longer candidate is useful: wear them down and defer allocation
          if (!found) for (int b = 0; b < 4; b++) if (!r.provider_hit || b > int'(r.provider))
            e[b].useful = e[b].useful - 2'(e[b].useful != 0);
        end
        step_aging[step] = age_n == 0;
        history_n = {history_n[30:0], taken};
      end
      step_hash[step] = k;
      step_entry[step] = e;
      step_base[step] = base;
    end
    // indexed writeback uses registered step validity for all four banks.
    base_n = base_q;
    table_n = table_q;
    for (int step = 0; step < STEPS; step++) begin
      for (int i = 0; i < 256; i++)
        if (step_valid[step] && step_hash[step].base_index == 8'(i)) base_n[i] = step_base[step];
      for (int b = 0; b < 4; b++) for (int i = 0; i < 64; i++) begin
        if (step_valid[step] && step_hash[step].index[b] == 6'(i)) table_n[b][i] = step_entry[step][b];
        if (step_aging[step]) table_n[b][i].useful = table_n[b][i].useful >> 1;
      end
    end
  end

  // table, history and aging storage
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      base_q <= {256{2'b01}};
      table_q <= {256{entry_t'{valid: 0, tag: 0, counter: 3'b111, useful: 0}}};
      history_q <= 0;
      chooser_q <= 0;
      age_q <= 0;
    end else if (TRAIN_QUEUE ? head_valid : |update_valid_i) begin
      base_q <= base_n;
      table_q <= table_n;
      chooser_q <= chooser_n;
      age_q <= age_n;
      history_q <= history_n;
    end
  end
endmodule
`default_nettype wire
