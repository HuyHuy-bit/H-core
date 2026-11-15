// chip_top bench for RTL and gate-level builds: the perf-mode memory target at a fixed latency of one cycle,
// with a hash of every port handshake so two builds can be compared cycle for cycle.
#include "Vchip_top.h"
#include "verilated.h"
#include "fields.hpp"
#include "../common/packed_bits.hpp"
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

using packed_bits::get32;
using packed_bits::put;

static void require(bool ok, const std::string& message) { if (!ok) throw std::runtime_error(message); }

struct Transaction {
    bool pending=false, write=false, uncached=false;
    unsigned id=0, address=0, mask=0, size=0;
    std::array<uint32_t,8> words{};
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        require(argc>=5, "usage: image max_cycles log_address idle_cycles");
        std::ifstream file(argv[1], std::ios::binary);
        require(bool(file), "cannot open program");
        std::vector<uint8_t> memory((std::istreambuf_iterator<char>(file)), {});
        require(memory.size()<=65536, "program exceeds RAM");
        memory.resize(65536);
        const uint64_t max_cycles=std::stoull(argv[2]);
        const unsigned log_address=std::stoul(argv[3], nullptr, 0);
        const uint64_t idle_cycles=std::stoull(argv[4]);  // stop once both ports stay quiet this long
        std::array<uint8_t,48> mmio{};
        auto byte=[&](unsigned address) -> uint8_t& {
            if (address<memory.size()) return memory[address];
            if (address>=0x10000000 && address<0x10000010) return mmio[address-0x10000000];
            if (address>=0x10001000 && address<0x10001020) return mmio[16+address-0x10001000];
            throw std::runtime_error("request outside PMA");
        };
        uint64_t hash=1469598103934665603ull;
        auto mix=[&](uint64_t value) { for (int n=0;n<8;++n) { hash^=(value>>(8*n))&0xff; hash*=1099511628211ull; } };
        Vchip_top dut;
        Transaction instruction, data;
        auto respond=[&](const Transaction& tx, auto& response) {
            for (unsigned n=0;n<RESPONSE_WORDS;++n) response[n]=0;
            if (!tx.pending) return;
            put(response, RSP_TRANSACTION_ID, 4, tx.id);
            if (tx.write) return;
            if (tx.uncached) put(response, RSP_UNCACHED_READ_DATA, 32, tx.words[0]);
            else for (unsigned n=0;n<8;++n) put(response, RSP_LINE_READ_DATA+32*n, 32, tx.words[n]);
        };
        // read data is captured at acceptance; writes land at their response handshake.
        auto accept=[&](Transaction& tx, const auto& request, unsigned port, uint64_t cycle) {
            mix(cycle); mix(port);
            for (unsigned n=0;n<REQUEST_WORDS;++n) mix(request[n]);
            tx.pending=true;
            tx.id=get32(request, REQ_TRANSACTION_ID, 4); tx.address=get32(request, REQ_ADDRESS, 32);
            tx.uncached=get32(request, REQ_UNCACHED, 1); tx.write=get32(request, REQ_WRITE, 1);
            tx.size=get32(request, REQ_UNCACHED_SIZE, 2);
            require(tx.uncached || !(tx.address&31), "unaligned line request");
            tx.mask=get32(request, tx.uncached ? REQ_UNCACHED_WRITE_STROBE:REQ_LINE_WRITE_MASK, tx.uncached ? 4:32);
            const unsigned base=tx.uncached ? tx.address&~3u:tx.address;
            for (unsigned w=0;w<(tx.uncached ? 1u:8u);++w) {
                if (tx.write) tx.words[w]=get32(request, (tx.uncached ? REQ_UNCACHED_WRITE_DATA:REQ_LINE_WRITE_DATA)+w*32, 32);
                else {
                    uint32_t value=0;
                    for (unsigned lane=0;lane<4;++lane) value|=uint32_t(byte(base+4*w+lane))<<(8*lane);
                    if (tx.uncached) value&=(tx.size==2 ? 0xffffffffu:(1u<<(8u<<tx.size))-1)<<(8*(tx.address&3));
                    tx.words[w]=value;
                }
            }
        };
        auto complete=[&](Transaction& tx) {
            if (tx.write) {
                const unsigned base=tx.uncached ? tx.address&~3u:tx.address;
                for (unsigned lane=0;lane<(tx.uncached ? 4u:32u);++lane)
                    if ((tx.mask>>lane)&1) byte(base+lane)=uint8_t(tx.words[lane/4]>>(8*(lane%4)));
            }
            tx.pending=false;
        };
        dut.rst_i=1; dut.response_valid_i=0; dut.data_response_valid_i=0;
        for (int n=0;n<3;++n) { dut.clk_i=0; dut.eval(); dut.clk_i=1; dut.eval(); }
        dut.rst_i=0;
        uint64_t cycle=0, last=0, requests[2]={};
        for (;cycle<max_cycles && (cycle<1000 || cycle-last<idle_cycles);++cycle) {
            dut.clk_i=0;
            dut.request_ready_i=!instruction.pending;
            dut.data_request_ready_i=!data.pending;
            respond(instruction, dut.response_i);
            respond(data, dut.data_response_i);
            dut.response_valid_i=instruction.pending;
            dut.data_response_valid_i=data.pending;
            dut.eval();
            require(!dut.fatal_o, "platform fatal at cycle "+std::to_string(cycle));
            if (dut.response_valid_i && dut.response_ready_o) { instruction.pending=false; mix(cycle); mix(2); }
            if (dut.data_response_valid_i && dut.data_response_ready_o) { complete(data); mix(cycle); mix(3); }
            if (dut.request_valid_o && dut.request_ready_i) { accept(instruction, dut.request_o, 0, cycle); ++requests[0]; last=cycle; }
            if (dut.data_request_valid_o && dut.data_request_ready_i) { accept(data, dut.data_request_o, 1, cycle); ++requests[1]; last=cycle; }
            dut.clk_i=1; dut.eval();
            if (cycle%100000==0) std::cout<<"CHECKPOINT cycle="<<cycle<<" hash="<<std::hex<<hash<<std::dec<<std::endl;
        }
        std::string log;
        for (unsigned a=log_address;a<log_address+2048 && memory[a];++a) log+=char(memory[a]);
        std::cout<<"GLS END cycles="<<cycle<<" last_request="<<last<<" instruction_requests="<<requests[0]
                 <<" data_requests="<<requests[1]<<" hash="<<std::hex<<hash<<std::dec
                 <<" log_validated="<<(log.find("Correct operation validated")!=std::string::npos)<<'\n';
        if (!log.empty()) std::cout<<"LOG\n"<<log<<'\n';
        return 0;
    } catch (const std::exception& error) { std::cerr<<"GLS FAIL "<<error.what()<<'\n'; return 1; }
}
