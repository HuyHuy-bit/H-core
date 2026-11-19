`default_nettype none
// address generation for one load/store: address, mask, data, fault and path class, held until taken.
module load_store_prepare (
  input  wire clk_i, rst_i, flush_i,
  input  wire launch_i,
  input  wire [12:0] id_i,
  input  wire [31:0] instruction_i, pc_i, source1_i, source2_i,
  input  wire take_i,

  output wire ready_o,
  output wire valid_o,
  output wire [12:0] id_o,
  output wire [31:0] instruction_o, pc_o, source1_o, source2_o,
  output wire [31:0] address_o, write_data_o, cause_o, trap_value_o,
  output wire [3:0] byte_mask_o,
  output wire [1:0] size_o,
  output wire store_o, load_unsigned_o, uncached_o, head_only_o, fault_o
);

  import core_pkg::*;
  import platform_pkg::*;

  typedef struct packed {
    logic [12:0] id;
    logic [31:0] instruction, pc, source1, source2, address, write_data, cause, trap_value;
    logic [3:0] mask;
    logic [1:0] size;
    logic store, load_unsigned, uncached, head_only, fault;
  } descriptor_t;
  descriptor_t built, saved_q, visible;
  decoded_t decoded;
  logic pending_q;
  wire unused_decode = ^decoded;

  decoder decode (.instruction_i, .decoded_o(decoded));

  // Raw I/S fields let address generation run alongside decode.
  wire [31:0] base = instruction_i[19:15] == 0 ? 32'd0 : source1_i;
  wire [31:0] immediate = {{20{instruction_i[31]}}, instruction_i[31:25],
                           instruction_i[5] ? instruction_i[11:7] : instruction_i[24:20]};
  wire [31:0] address;
  prefix_add32 address_add (.a_i(base), .b_i(immediate), .sum_o(address));

  wire store = decoded.op == OP_STORE;
  wire [31:0] data = decoded.rs2 == 0 ? 32'd0 : source2_i;
  wire misaligned = (decoded.funct3[1:0] == 1 && address[0])
      || (decoded.funct3[1:0] == 2 && address[1:0] != 0);
  wire fault = misaligned || !accessible(address, store);
  wire idempotent = (in_region(address, BRAM_BASE, BRAM_SIZE) && BRAM_IDEMPOTENT)
    || (in_region(address, UART_BASE, UART_SIZE) && UART_IDEMPOTENT)
    || (in_region(address, GPIO_BASE, GPIO_SIZE) && GPIO_IDEMPOTENT);

  // access classification and byte lanes
  always_comb begin
    built = '0;
    built.id = id_i;
    built.instruction = instruction_i;
    built.pc = pc_i;
    built.source1 = base;
    built.source2 = data;
    built.address = address;
    built.store = store;
    built.size = decoded.funct3[1:0];
    built.load_unsigned = decoded.op == OP_LOAD && decoded.funct3[2];
    built.fault = fault;
    if (fault) begin
      built.cause = misaligned
          ? (store ? CAUSE_STORE_ADDRESS_MISALIGNED : CAUSE_LOAD_ADDRESS_MISALIGNED)
          : (store ? CAUSE_STORE_ACCESS_FAULT : CAUSE_LOAD_ACCESS_FAULT);
      built.trap_value = address;
    end
    built.head_only = fault || built.store || !cached(address) || !idempotent;
    if (!fault) begin
      built.uncached = !cached(address);
      case (built.size)
        0: built.mask = 4'b0001 << address[1:0];
        1: built.mask = 4'b0011 << address[1:0];
        default: built.mask = 4'b1111;
      endcase
      if (built.store) built.write_data = (data << {address[1:0], 3'b000}) & byte_mask(built.mask);
    end
  end

  // descriptor storage; the consumer owns ordering and memory-side-effect admission.
  always_ff @(posedge clk_i) begin
    if (rst_i || flush_i) pending_q <= 0;
    else begin
      if (take_i) pending_q <= 0;
      if (launch_i) begin
        pending_q <= 1;
        saved_q <= built;
      end
    end
  end

  assign valid_o = pending_q && !rst_i && !flush_i;
  assign ready_o = !rst_i && !flush_i && (!pending_q || take_i);
  assign visible = valid_o ? saved_q : '0;
  assign {id_o, instruction_o, pc_o, source1_o, source2_o, address_o,
    write_data_o, cause_o, trap_value_o, byte_mask_o, size_o,
    store_o, load_unsigned_o, uncached_o, head_only_o, fault_o} = visible;

  // assertions
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) if (!rst_i && !flush_i) begin
    assert (!launch_i || ready_o) else $fatal(1, "LS_PREP_CAPACITY");
    assert (!take_i || valid_o) else $fatal(1, "LS_PREP_TAKE");
    assert (!launch_i || decoded.op inside {OP_LOAD, OP_STORE}) else $fatal(1, "LS_PREP_OPERATION");
    assert (!launch_i || pc_i[1:0] == 0) else $fatal(1, "LS_PREP_PC");
  end
`endif
endmodule
`default_nettype wire
