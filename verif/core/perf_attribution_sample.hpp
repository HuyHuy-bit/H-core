#pragma once
#include "perf_attribution.hpp"
#include <type_traits>

template<class T> static uint32_t attribution_bits(const T& value,unsigned offset,unsigned width) {
    if constexpr (std::is_integral_v<T>) return uint32_t(uint64_t(value)>>offset)&uint32_t((uint64_t(1)<<width)-1);
    else return packed_bits::get32(value,offset,width);
}
#define ATTR_IQ(name) BACKEND(backend__DOT__queue__DOT__##name)
#define ATTR_LSU(name) MEMORY(early_loads__DOT__lsu__DOT__##name)
#define ATTR_LSQ(name) ATTR_LSU(queues__DOT__##name)
static perf_attribution::Frame attribution_frame(Vcpu_top& dut,uint64_t cycle,bool region) {
    static_assert(TB_EARLY_LOADS && TB_DCACHE && TB_ICACHE,"attribution requires cached_core");
    using namespace perf_attribution;
    Frame f;
    f.cycle=cycle; f.region=region;
    f.head=ROB(head_q); f.rob_valid=ROB(valid_q);
    for (unsigned s=0;s<32;++s) f.rob_id[s]=(unsigned(ROB(generation_q)[s])<<5)|s;
    f.head_read=BACKEND(head_read); f.stop=ATTR_IQ(stop); f.flush=BACKEND(producer_flush);
    f.recover=CORE(branch_redirect); f.resolve=BACKEND(resolve_accept_o);
    f.resolve_id=BACKEND(resolve_id_o); f.mispredict=BACKEND(resolve_mispredict_o);
    f.taken=BACKEND(resolve_taken_o); f.resolved_pc=BACKEND(resolve_pc_o);
    f.issue=BACKEND(issue_o); f.port_ready=BACKEND(producer_ready)&BACKEND(execution_ready_i);
    f.wb=BACKEND(wb_accept_o);
    f.fetch_valid=dut.fetch_valid_o; f.redirect=dut.redirect_o;
    f.fetch_enabled=CORE(frontend__DOT__enable_i); f.fetch_hold=CORE(fetch_hold);
    f.frontend_state=CORE(frontend__DOT__state_q);
    for (unsigned lane=0;lane<2;++lane) {
        f.issue_id[lane]=attribution_bits(BACKEND(issue_id_o),13*lane,13);
        f.wb_tag[lane]=attribution_bits(BACKEND(backend__DOT__wb_destination_o),6*lane,6);
        auto& a=f.allocated[lane];
        a.valid=dut.dispatch_o>>lane&1;
        a.id=attribution_bits(BACKEND(allocate_id_o),13*lane,13);
        a.pc=attribution_bits(BACKEND(pc_i),32*lane,32);
        a.instruction=attribution_bits(BACKEND(instruction_i),32*lane,32);
        a.predicted_taken=BACKEND(predicted_taken_i)>>lane&1;
        a.next_pc=attribution_bits(BACKEND(predicted_pc_i),32*lane,32);
        auto& r=f.retired[lane];
        r.valid=dut.retire_accept_o>>lane&1;
        r.id=f.rob_id[(f.head+lane)&31];
        r.pc=get32(dut.retire_event_o,lane*EVENT_BITS+EV_PC_BEFORE,32);
        r.instruction=get32(dut.retire_event_o,lane*EVENT_BITS+EV_INSTRUCTION,32);
        r.next_pc=get32(dut.retire_event_o,lane*EVENT_BITS+EV_PC_AFTER,32);
    }
    for (unsigned i=0;i<16;++i) {
        auto& q=f.iq[i];
        q.valid=ATTR_IQ(valid_q)>>i&1; q.id=ATTR_IQ(id_q)[i];
        q.ready=ATTR_IQ(ready_q)[i]; q.awake=ATTR_IQ(awake)[i]; q.eligible=ATTR_IQ(eligible_q)[i];
        q.source={unsigned(ATTR_IQ(source_q)[i]&63),unsigned(ATTR_IQ(source_q)[i]>>6)};
    }
    f.loads=true;
    f.engine_ready=ATTR_LSU(engine_ready); f.forward_busy=ATTR_LSU(forward_valid_q);
    f.pick_found=ATTR_LSQ(pick_found); f.pick_id=ATTR_LSU(lsq_id); f.lsq_valid=ATTR_LSU(lsq_valid);
    f.forward_mask=ATTR_LSU(forward_mask); f.memory_mask=ATTR_LSU(memory_mask);
    f.launch_memory=ATTR_LSU(launch_memory); f.launch_forward=ATTR_LSU(launch_forward);
    f.response=ATTR_LSU(cached__DOT__dc_response); f.response_id=ATTR_LSU(cached__DOT__dc_id);
    for (unsigned e=0;e<2;++e)
        f.response_live|=(ATTR_LSU(cached__DOT__entry_valid_q)>>e&1)
            && ATTR_LSU(cached__DOT__entry_id_q)[e]==f.response_id;
    f.load_complete=ATTR_LSU(complete_valid_o) && ATTR_LSU(complete_take_i);
    f.alu1_pending=BACKEND(alu1_valid); f.load_pending=ATTR_LSU(complete_valid_o);
    f.completion1_accept=BACKEND(completion_accept_o)&2;
    f.agu_ready=ATTR_LSU(unused_ready);
    f.load_complete_id=ATTR_LSU(complete_id_o);
    for (unsigned i=0;i<8;++i) {
        auto& l=f.lq[i];
        l.valid=ATTR_LSQ(lq_live)>>i&1; l.ready=ATTR_LSQ(lq_ready_q)>>i&1;
        l.early=ATTR_LSQ(lq_early_q)>>i&1; l.issued=ATTR_LSQ(lq_issued_q)>>i&1;
        l.id=attribution_bits(ATTR_LSQ(lq_id_q),13*i,13);
        l.address=attribution_bits(ATTR_LSQ(lq_address_q),32*i,32);
        l.size=attribution_bits(ATTR_LSQ(lq_size_q),2*i,2);
    }
    for (unsigned i=0;i<12;++i) {
        auto& s=f.stores[i];
        if (i<4) {
            s.valid=ATTR_LSU(retired_valid)>>i&1; s.ready=true; s.rank=i; s.data_ready=15;
            s.address=attribution_bits(ATTR_LSU(retired_address),32*i,32);
            s.mask=attribution_bits(ATTR_LSU(retired_mask),4*i,4);
        } else {
            const unsigned j=i-4;
            s.valid=ATTR_LSQ(sq_live)>>j&1; s.ready=ATTR_LSQ(sq_ready_q)>>j&1;
            s.rank=age(attribution_bits(ATTR_LSQ(sq_id_q),13*j,13),f.head)+4;
            s.data_ready=(ATTR_LSQ(sq_data_ready_q)>>j&1) ? 15:0;
            s.address=attribution_bits(ATTR_LSQ(sq_address_q),32*j,32);
            s.mask=attribution_bits(ATTR_LSQ(sq_mask_q),4*j,4);
        }
    }
    return f;
}
#undef ATTR_IQ
#undef ATTR_LSU
#undef ATTR_LSQ
