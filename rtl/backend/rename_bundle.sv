`default_nettype none
// two-wide rename planning: source mappings, free tags and same-bundle RAW/WAW dependencies.
module rename_bundle (
  input  wire rst_i, recover_i, resources_ready_i,
  input  wire [1:0] valid_i, checkpoint_i,
  input  wire [9:0] rs1_i, rs2_i, rd_i,
  input  wire [191:0] rat_i,
  input  wire [63:0] free_i, ready_i,
  input  wire [6:0] free_count_i,  // the number of free tags, from a register: admission does not wait for the pick

  output logic [1:0] accept_o,
  output logic [11:0] source1_o, source2_o, destination_o, stale_o,
  output logic [3:0] source_ready_o,
  output logic [63:0] allocation_o
);

  logic [1:0] selected, allocate;
  logic [63:0] free, first, second, pick [0:1], one_below, two_below;
  logic [5:0] destination [0:1], source1 [0:1], source2 [0:1], stale [0:1];
  logic [1:0] operand_ready [0:1];
  logic enough;

  // log-depth prefix: bit i marks whether at least one or two free tags occur below i.
  function automatic logic [127:0] below(input logic [62:0] v);
    logic [63:0] one, two;
    one = {v, 1'b0};
    two = '0;
    for (int d = 1; d < 64; d = d * 2) begin
      two = two | (two << d) | (one & (one << d));
      one = one | (one << d);
    end
    return {two, one};
  endfunction

  function automatic logic [5:0] encode(input logic [63:0] onehot);
    logic [63:0] mask;
    for (int k = 0; k < 6; k++) begin
      for (int i = 0; i < 64; i++) mask[i] = 1'((i >> k) & 1);
      encode[k] = |(onehot & mask);
    end
  endfunction

  // bundle admission and physical tag allocation
  always_comb begin
    selected = valid_i;
    if (checkpoint_i[0]) selected[1] = 0;
    free = free_i & 64'hfffffffffffffffe;
    {two_below, one_below} = below(free[62:0]);
    first = free & ~one_below;
    second = free & one_below & ~two_below;
    for (int lane = 0; lane < 2; lane++) begin
      source1[lane] = rat_i[rs1_i[lane*5 +: 5]*6 +: 6];
      source2[lane] = rat_i[rs2_i[lane*5 +: 5]*6 +: 6];
      stale[lane] = rd_i[lane*5 +: 5] == 0 ? 6'd0 : rat_i[rd_i[lane*5 +: 5]*6 +: 6];
      operand_ready[lane] = {ready_i[source2[lane]], ready_i[source1[lane]]};
      allocate[lane] = selected[lane] && rd_i[lane*5 +: 5] != 0;
    end

    // lowest free tag first; lane one takes the next one up when lane zero also allocates.
    pick[0] = allocate[0] ? first : '0;
    pick[1] = !allocate[1] ? '0 : allocate[0] ? second : first;
    destination[0] = allocate[0] ? encode(first) : '0;
    destination[1] = !allocate[1] ? '0 : allocate[0] ? encode(second) : encode(first);
    enough = valid_i != 2'b10 && !(allocate[0] && free_count_i == 0)
      && !(allocate[1] && free_count_i < (allocate[0] ? 7'd2 : 7'd1));

    // lane one sees lane zero's new mapping, including its stale tag on waw.
    if (selected[0] && rd_i[0 +: 5] != 0) begin
      if (rs1_i[5 +: 5] == rd_i[0 +: 5]) begin
        source1[1] = destination[0];
        operand_ready[1][0] = 0;
      end
      if (rs2_i[5 +: 5] == rd_i[0 +: 5]) begin
        source2[1] = destination[0];
        operand_ready[1][1] = 0;
      end
      if (rd_i[5 +: 5] == rd_i[0 +: 5]) stale[1] = destination[0];
    end

    accept_o = 0;
    source1_o = 0;
    source2_o = 0;
    destination_o = 0;
    stale_o = 0;
    source_ready_o = 0;
    allocation_o = 0;
    if (!rst_i && !recover_i && resources_ready_i && enough) begin
      accept_o = selected;
      for (int lane = 0; lane < 2; lane++) begin
        if (selected[lane]) begin
          source1_o[lane*6 +: 6] = source1[lane];
          source2_o[lane*6 +: 6] = source2[lane];
          destination_o[lane*6 +: 6] = destination[lane];
          stale_o[lane*6 +: 6] = stale[lane];
          source_ready_o[lane*2 +: 2] = operand_ready[lane];
          allocation_o |= pick[lane];
        end
      end
    end
  end

  // only lane zero can cut a two-instruction bundle; lane one already ends it.
  wire unused_checkpoint_lane1 = checkpoint_i[1];
endmodule
`default_nettype wire
