`default_nettype none
module prefix_add32 (
  input  wire [31:0] a_i, b_i,
  output wire [31:0] sum_o
);

  // Preserve the five Kogge-Stone carry levels during synthesis.
  (* keep *) wire [31:0] generate_ [6];
  (* keep *) wire [31:0] propagate [5];

  assign generate_[0] = a_i & b_i;
  assign propagate[0] = a_i ^ b_i;

  for (genvar level = 0; level < 5; level++) begin : tree
    localparam int SPAN = 1 << level;
    assign generate_[level+1] = generate_[level]
        | (propagate[level] & {generate_[level][31-SPAN:0], {SPAN{1'b0}}});
    if (level < 4) begin : next
      assign propagate[level+1] = propagate[level] & {propagate[level][31-SPAN:0], {SPAN{1'b1}}};
    end
  end

  assign sum_o = propagate[0] ^ {generate_[5][30:0], 1'b0};
  wire unused_carry = generate_[5][31];
endmodule
`default_nettype wire
