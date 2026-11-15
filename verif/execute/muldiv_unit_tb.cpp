#include "Vmuldiv_unit.h"
#include "verilated.h"
#include "backend_event_layout.hpp"
#include "../common/packed_bits.hpp"
#include "../common/rv32_reference.hpp"
#include <array>
#include <cstdint>
#include <iostream>
#include <map>
#include <random>
#include <stdexcept>
#include <string>

using packed_bits::bit;
using packed_bits::put;
using Event = std::array<uint32_t, (EVENT_BITS+31)/32>;
constexpr unsigned DIVIDE_EDGES = 33;  // start edge plus 32 restoring steps before the result may move
constexpr unsigned MULTIPLY_EDGES = 1; // the partial-product edge before the result may move

struct Op { bool valid = false; unsigned id = 0, edges = 0; uint32_t instruction = 0, pc = 0, a = 0, b = 0; };

struct Held { bool valid = false; unsigned id = 0; Event event{}; };

struct Inputs { bool reset = false, flush = false, recover = false, take = false, launch = false;
                unsigned recover_slot = 0, head = 0; Op op; };

static Event expected_event(const Op& op) {
    Event e{};
    const unsigned rd = (op.instruction >> 7) & 31;
    put(e, VALID_OFFSET, 1, 1); put(e, RETIRED_OFFSET, 1, 1); put(e, PRIVILEGE_OFFSET, 2, 3);
    put(e, INSTRUCTION_OFFSET, 32, op.instruction); put(e, PC_BEFORE_OFFSET, 32, op.pc); put(e, PC_AFTER_OFFSET, 32, op.pc+4);
    put(e, RS1_ADDR_OFFSET, 5, (op.instruction >> 15) & 31); put(e, RS1_VALUE_OFFSET, 32, op.a);
    put(e, RS2_ADDR_OFFSET, 5, (op.instruction >> 20) & 31); put(e, RS2_VALUE_OFFSET, 32, op.b);
    if (rd) {
        put(e, RD_ADDR_OFFSET, 5, rd);
        put(e, RD_VALUE_OFFSET, 32, rv32::m_result((op.instruction >> 12) & 7, op.a, op.b));
        put(e, RD_WRITE_MASK_OFFSET, 32, 0xffffffffU);
    }
    return e;
}

struct Check {
    Vmuldiv_unit dut;
    Op op; Held held;
    uint64_t cycles = 0;
    std::map<std::string, uint64_t> coverage;

    void require(bool ok, const std::string& what) {
        if (!ok) throw std::runtime_error("muldiv mismatch cycle="+std::to_string(cycles)+" "+what);
    }

    static bool divide(const Op& o) { return (o.instruction >> 14) & 1; }

    static bool done(const Op& o) { return o.edges >= (divide(o) ? DIVIDE_EDGES : MULTIPLY_EDGES); }

    static bool killed(const Inputs& in, unsigned id) {
        return in.flush || (in.recover && ((id - in.head) & 31) > ((in.recover_slot - in.head) & 31));
    }

    static uint32_t field(const Event& e, unsigned offset, unsigned width) { return packed_bits::get32(e, offset, width); }

    void drive(const Inputs& in, bool launch) {
        dut.rst_i = in.reset; dut.flush_i = in.flush; dut.recover_i = in.recover;
        dut.recover_slot_i = in.recover_slot; dut.head_slot_i = in.head; dut.take_i = in.take;
        dut.launch_i = launch; dut.id_i = in.op.id; dut.instruction_i = in.op.instruction;
        dut.pc_i = in.op.pc; dut.source1_i = in.op.a; dut.source2_i = in.op.b;
        dut.eval();
    }

    bool hold_free(const Inputs& in) const { return !held.valid || in.take; }

    bool advance(const Inputs& in) const { return op.valid && done(op) && hold_free(in); }
    // a kill clears the result at the edge; the reorder buffer does not accept a killed result, so it stays offered
    bool ready(const Inputs& in) const { return !in.reset && (!op.valid || advance(in)); }

    bool valid(const Inputs& in) const { return held.valid && !in.reset; }

    void observe(const Inputs& in) {
        require(bool(dut.ready_o) == ready(in), "ready");
        require(bool(dut.valid_o) == valid(in), "valid");
        require(bool(dut.held_o) == held.valid, "held");
        if (valid(in)) {
            require(dut.id_o == held.id, "id");
            for (unsigned b = 0; b < EVENT_BITS; b++) require(bit(dut.event_o, b) == bit(held.event, b), "event bit="+std::to_string(b));
        }
    }

    void cover(const Inputs& in) {
        if (in.reset) return;
        const bool kills = in.flush || in.recover;
        if (op.valid && kills && killed(in, op.id)) {
            if (!divide(op)) coverage["kill_mul_op"]++;
            else if (op.edges == 0) coverage["kill_div_start"]++;
            else if (!done(op)) coverage["kill_div_mid"]++;
            else coverage["kill_div_waiting"]++;
            if (in.flush && divide(op) && !done(op)) coverage["flush_mid_div"]++;
        }
        if (op.valid && in.recover && !in.flush && !killed(in, op.id)) coverage["recover_keeps_op"]++;
        if (held.valid && kills && killed(in, held.id)) coverage["kill_holder"]++;
        if (held.valid && in.recover && !in.flush && !killed(in, held.id)) coverage["recover_keeps_holder"]++;
        if (op.valid && done(op) && !hold_free(in)) coverage[divide(op) ? "backpressure_div" : "backpressure_mul"]++;
        if (in.launch && in.recover && !in.flush) coverage[killed(in, in.op.id) ? "launch_recover_younger" : "launch_recover_older"]++;
        if (in.launch && advance(in)) coverage["launch_on_advance"]++;
        if (valid(in) && in.take) {
            const uint32_t f3 = field(held.event, INSTRUCTION_OFFSET+12, 3), a = field(held.event, RS1_VALUE_OFFSET, 32),
                           b = field(held.event, RS2_VALUE_OFFSET, 32);
            coverage["op_"+std::to_string(f3)]++; coverage["completed"]++;
            if (!field(held.event, RD_ADDR_OFFSET, 5)) coverage["rd_zero"]++;
            if (f3 >= 4 && b == 0) coverage["zero_divisor_"+std::to_string(f3)]++;
            if ((f3 == 4 || f3 == 6) && a == 0x80000000U && b == 0xffffffffU) coverage["overflow_"+std::to_string(f3)]++;
            if (held.id >> 5) coverage["generation_nonzero"]++;
        }
    }
    // One cycle: outputs are checked before and after the launch inputs settle, then the edge updates the model.
    void step(const Inputs& in) {
        drive(in, false); observe(in);
        drive(in, in.launch); observe(in);
        if (in.launch) require(ready(in), "bench launched while not ready");
        cover(in);
        if (in.reset) { op = {}; held = {}; }
        else {
            const bool moves = advance(in);
            Held next = held;
            if (killed(in, held.id) || in.take) next.valid = false;
            if (moves) next = Held{!killed(in, op.id), op.id, expected_event(op)};
            if (op.valid) op.edges++;
            if (moves || killed(in, op.id)) op.valid = false;
            if (in.launch && !killed(in, in.op.id)) { op = in.op; op.valid = true; op.edges = 0; }
            held = next;
        }
        dut.clk_i = 1; dut.eval(); dut.clk_i = 0; dut.eval();
        cycles++;
    }
};

static uint32_t operand(std::mt19937& rng) {
    static const uint32_t edges[] = {0, 1, 2, 3, 0x7fffffffU, 0x80000000U, 0x80000001U, 0xfffffffeU, 0xffffffffU};
    return rng() % 3 ? rng() : edges[rng() % 9];
}

static Op random_op(std::mt19937& rng, unsigned head, unsigned f3) {
    Op o;
    o.id = ((rng() & 255) << 5) | ((head + rng() % 32) & 31);
    o.instruction = (1U << 25) | ((rng() & 31) << 20) | ((rng() & 31) << 15) | (f3 << 12) | ((rng() % 4 ? rng() & 31 : 0) << 7) | 0x33;
    o.pc = rng() & ~3U; o.a = operand(rng); o.b = rng() % 8 ? operand(rng) : 0;
    if (rng() % 16 == 0) { o.a = 0x80000000U; o.b = 0xffffffffU; }
    return o;
}

// Directed: from an empty unit with a free holder, results appear exactly 3 (mul) or 35 (divide) cycles after launch.
static void latency(Check& c, std::mt19937& rng) {
    for (unsigned f3 = 0; f3 < 8; f3++) {
        Inputs in; in.launch = true; in.op = random_op(rng, 0, f3); in.op.id &= ~31U;
        c.step(in);
        const unsigned expected = (f3 >= 4 ? DIVIDE_EDGES : MULTIPLY_EDGES) + 2;
        unsigned waited = 1;
        for (Inputs idle; !c.dut.valid_o; waited++) { c.require(waited < 64, "latency progress"); c.step(idle); }
        c.require(waited == expected, "latency f3="+std::to_string(f3)+" waited="+std::to_string(waited));
        Inputs take; take.take = true; c.step(take);
        c.coverage["latency_"+std::to_string(f3)]++;
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        const unsigned seed = argc > 1 ? std::stoul(argv[1]) : 1;
        const std::string misuse = argc > 2 ? argv[2] : "";
        std::mt19937 rng(seed);
        Check c;
        Inputs reset; reset.reset = true;
        for (int n = 0; n < 3; n++) c.step(reset);
        // caller misuse: each must stop on the unit's own assertion
        if (misuse == "launch_busy" || misuse == "bad_operation") {
            Inputs in; in.launch = true; in.op = random_op(rng, 0, 4);
            if (misuse == "bad_operation") in.op.instruction &= ~(1U << 25);
            c.step(in);
            c.drive(in, true); c.dut.clk_i = 1; c.dut.eval();
            return 0;
        }
        if (misuse == "take_empty") { c.drive(Inputs{}, false); c.dut.take_i = 1; c.dut.clk_i = 1; c.dut.eval(); return 0; }
        latency(c, rng);
        unsigned head = 0;
        for (unsigned n = 0; n < 60000; n++) {
            Inputs in;
            const unsigned phase = (n / 5000) % 4;  // vary take pressure and recovery rate across phases
            if (rng() % 4000 == 0) { in.reset = true; c.coverage["random_reset"]++; }
            in.head = head;
            in.flush = rng() % (phase == 3 ? 40 : 400) == 0;
            in.recover = rng() % (phase == 2 ? 6 : 40) == 0;
            in.recover_slot = (head + rng() % 32) & 31;
            in.take = c.valid(in) && !Check::killed(in, c.held.id) && rng() % (phase == 1 ? 48 : 2) == 0;
            if (c.ready(in) && rng() % 3) {
                in.launch = true;
                in.op = random_op(rng, head, rng() % 4 ? rng() % 4 : 4 + rng() % 4);
            }
            c.step(in);
            if (!c.op.valid && !c.held.valid && rng() % 3 == 0) {
                const unsigned next = (head + 1 + rng() % 7) & 31;
                if (next < head) c.coverage["head_wrap"]++;
                head = next;
            }
        }
        std::cout << "MULDIV PASS seed=" << seed << " cycles=" << c.cycles;
        for (const auto& [name, count] : c.coverage) std::cout << ' ' << name << '=' << count;
        std::cout << '\n';
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
