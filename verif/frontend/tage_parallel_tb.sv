`default_nettype none
module tage_parallel_tb;
  logic clk;
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end
  logic rst = 1, redirect = 0, repair = 0;
  logic [63:0] pc = 0, instruction = 0, retire_pc = 0, retire_instruction = 0, retire_next = 0;
  logic [1:0] take = 0, retire = 0;
  logic [35:0] checkpoint = 0;
  wire [1:0] serial_taken, parallel_taken;
  wire [63:0] serial_target, parallel_target;
  wire [71:0] serial_checkpoint, parallel_checkpoint;
  branch_predictor #(.TAGE(1)) serial (
    .clk_i(clk), .rst_i(rst), .pc_i(pc), .instruction_i(instruction), .take_i(take),
    .redirect_i(redirect), .repair_i(repair), .repair_checkpoint_i(checkpoint),
    .retire_i(retire), .retire_pc_i(retire_pc), .retire_instruction_i(retire_instruction), .retire_next_i(retire_next),
    .taken_o(serial_taken), .target_o(serial_target), .checkpoint_o(serial_checkpoint)
  );
  branch_predictor #(.TAGE(1), .PARALLEL_TAGE(1)) parallel (
    .clk_i(clk), .rst_i(rst), .pc_i(pc), .instruction_i(instruction), .take_i(take),
    .redirect_i(redirect), .repair_i(repair), .repair_checkpoint_i(checkpoint),
    .retire_i(retire), .retire_pc_i(retire_pc), .retire_instruction_i(retire_instruction), .retire_next_i(retire_next),
    .taken_o(parallel_taken), .target_o(parallel_target), .checkpoint_o(parallel_checkpoint)
  );
  function automatic logic [31:0] word(input int choice);
    case (choice)
      0: return 32'h00000463;
      1: return 32'h00000263;
      2: return 32'h00002463;
      3: return 32'h00000163;
      4: return 32'h000000ef;
      5: return 32'h00008067;
      6: return 32'h000100e7;
      7: return 32'h00000073;
      default: return 32'h00108093;
    endcase
  endfunction
  task automatic compare_state;
    if (serial.ghr_q !== parallel.ghr_q || serial.ghr_next !== parallel.ghr_next
        || serial.commit_ghr_q !== parallel.commit_ghr_q || serial.ras_ptr_q !== parallel.ras_ptr_q
        || serial.commit_ptr_q !== parallel.commit_ptr_q || serial.ras_q !== parallel.ras_q
        || serial.jalr_valid_q !== parallel.jalr_valid_q) $fatal(1, "PARALLEL_STATE");
    for (int k = 0; k < 64; k++)
      if (serial.jalr_valid_q[k] && serial.jalr_target_q[k] !== parallel.jalr_target_q[k]) $fatal(1, "PARALLEL_TARGET_STATE");
    if (serial.tage_direction.direction.base_q !== parallel.tage_direction.direction.base_q
        || serial.tage_direction.direction.table_q !== parallel.tage_direction.direction.table_q
        || serial.tage_direction.direction.history_q !== parallel.tage_direction.direction.history_q
        || serial.tage_direction.direction.chooser_q !== parallel.tage_direction.direction.chooser_q
        || serial.tage_direction.direction.age_q !== parallel.tage_direction.direction.age_q
        || serial.train_drop !== parallel.train_drop
        || serial.tage_direction.direction.train_queue.count_q !== parallel.tage_direction.direction.train_queue.count_q)
      $fatal(1, "PARALLEL_TRAIN_STATE");
    for (int k = 0; k < 4; k++)
      if (k < int'(serial.tage_direction.direction.train_queue.count_q)
          && serial.tage_direction.direction.train_queue.queue_q[k] !== parallel.tage_direction.direction.train_queue.queue_q[k])
        $fatal(1, "PARALLEL_QUEUE_STATE");
  endtask
  initial begin
    automatic int differences = 0, blocked = 0, pairs = 0, plus4 = 0, invalid = 0, repairs = 0, dual_train = 0;
    repeat (2) @(negedge clk);
    rst = 0;
    if ($test$plusargs("bad_prefix")) begin
      instruction = {32'h00000463,32'h00000463}; take = 3;
      @(posedge clk); #1; $fatal(1, "MISSED_PREFIX_GUARD");
    end
    for (int n = 0; n < 12000; n++) begin
      instruction = {word(int'($urandom_range(0, 9))),word(int'($urandom_range(0, 9)))};
      pc = {32'($urandom_range(0, 7) << 2), 32'($urandom_range(0, 7) << 2)};
      take = 2'($urandom_range(0, 3));
      if (!take[0] || instruction[6:0] == 7'h63) take[1] = 0;
      repair = n % 13 == 0; redirect = n % 17 == 0 || repair;
      checkpoint = {4'($urandom_range(0, 15)), $urandom};
      rst = n % 257 == 0;
      retire = n % 16 < 8 ? 2'b11 : 2'($urandom_range(0, 3));
      retire_instruction = {word(int'($urandom_range(0, 9))),word(int'($urandom_range(0, 9)))};
      if (n % 16 < 8) retire_instruction = {32'h00000463,32'h00000463};
      retire_pc = {32'h104,32'h100};
      retire_next = {$urandom_range(0, 1) != 0 ? 32'h10c : 32'h108, $urandom_range(0, 1) != 0 ? 32'h108 : 32'h104};
      #1;
      if (serial_taken[0] !== parallel_taken[0]
          || serial_checkpoint[35:0] !== parallel_checkpoint[35:0]) $fatal(1, "PARALLEL_LANE0");
      for (int lane = 0; lane < 2; lane++)
        if ((serial_taken[lane] || parallel_taken[lane])
            && serial_target[lane*32 +: 32] !== parallel_target[lane*32 +: 32]) $fatal(1, "PARALLEL_TARGET");
      if ((take[1] || instruction[6:0] != 7'h63)
          && (serial_taken[1] !== parallel_taken[1] || serial_checkpoint[71:36] !== parallel_checkpoint[71:36]))
        $fatal(1, "PARALLEL_LANE1");
      if (instruction[6:0] == 7'h63 && serial_taken[1] != parallel_taken[1]) differences++;
      if (instruction[6:0] == 7'h63 && take == 0) blocked++;
      if (take == 3) pairs++;
      if (instruction[31:0] == 32'h00000263) plus4++;
      if (instruction[31:0] == 32'h00002463) invalid++;
      if (repair) repairs++;
      if (retire == 3) dual_train++;
      @(posedge clk); #1; compare_state(); @(negedge clk);
    end
    if (differences == 0 || blocked == 0 || pairs == 0 || plus4 == 0 || invalid == 0 || repairs == 0 || dual_train == 0)
      $fatal(1, "PARALLEL_COVERAGE");
    $display("PASS parallel cycles=12000 rejected_differences=%0d blocked=%0d pairs=%0d plus4=%0d illegal=%0d repair=%0d dual_train=%0d",
      differences, blocked, pairs, plus4, invalid, repairs, dual_train);
    $finish;
  end
endmodule
`default_nettype wire
