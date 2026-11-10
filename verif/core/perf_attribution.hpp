#pragma once
#include <array>
#include <cstdint>
#include <map>
#include <ostream>
#include <stdexcept>
#include <string>

namespace perf_attribution {
inline void check(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(std::string("ATTRIBUTION ")+message);
}
inline unsigned age(unsigned id, unsigned head) { return (id-head)&31; }
inline bool cfi(uint32_t instruction) {
    const unsigned op=instruction&127;
    return op==0x63 || op==0x6f || op==0x67;
}
struct Instruction {
    bool valid=false, predicted_taken=false;
    unsigned id=0;
    uint32_t pc=0, instruction=0, next_pc=0;
};
struct QueueEntry {
    bool valid=false;
    unsigned id=0, ready=0, awake=0, eligible=0;
    std::array<unsigned,2> source{};
};
struct Load {
    bool valid=false, ready=false, early=false, issued=false;
    unsigned id=0, size=0;
    uint32_t address=0;
};
struct Store {
    bool valid=false, ready=false;
    unsigned rank=0, mask=0, data_ready=0;
    uint32_t address=0;
};
struct Frame {
    uint64_t cycle=0;
    bool region=false, head_read=false, stop=false, flush=false, recover=false;
    bool resolve=false, mispredict=false, taken=false, fetch_valid=false;
    bool redirect=false, fetch_enabled=true, fetch_hold=false;
    unsigned head=0, resolve_id=0, issue=0, port_ready=0, wb=0, frontend_state=0;
    uint32_t resolved_pc=0, rob_valid=0;
    std::array<unsigned,32> rob_id{};
    std::array<unsigned,2> issue_id{}, wb_tag{};
    std::array<Instruction,2> allocated{}, retired{};
    std::array<QueueEntry,16> iq{};
    bool loads=false, engine_ready=false, forward_busy=false, pick_found=false, lsq_valid=false;
    bool launch_memory=false, launch_forward=false, response=false, response_live=false, load_complete=false;
    bool alu1_pending=false, load_pending=false, completion1_accept=false, agu_ready=true;
    unsigned pick_id=0, forward_mask=0, memory_mask=0, response_id=0, load_complete_id=0;
    std::array<Load,8> lq{};
    std::array<Store,12> stores{};
    unsigned fetch_lanes=0, recycle_state=0;
    uint32_t rob_done=0, rob_solo=0;
    bool resolve_offer=false, resolve_grant=false, system_busy=false, fault_pending=false, memory_irrevocable=false;
};
enum class Dependence { clear, address, data, partial };
struct Disambiguation { Dependence reason=Dependence::clear; unsigned forwarded=0, memory=0; };
inline Disambiguation disambiguate(const Frame& f,const Load& l) {
    check(l.size<=2 && !(l.address&((1u<<l.size)-1)),"illegal early load");
    const unsigned mask=((1u<<(1u<<l.size))-1)<<(l.address&3), rank=age(l.id,f.head)+4;
    Disambiguation d;
    bool unknown=false, missing=false;
    for (const auto& s:f.stores) if (s.valid && s.rank<rank && !s.ready) unknown=true;
    for (unsigned b=0;b<4;++b) if (mask>>b&1) {
        const Store* youngest=nullptr;
        for (const auto& s:f.stores)
            if (s.valid && s.ready && s.rank<rank && (s.address>>2)==(l.address>>2) && (s.mask>>b&1)
                && (!youngest || s.rank>=youngest->rank)) youngest=&s;
        if (youngest) { d.forwarded|=1u<<b; missing|=!(youngest->data_ready>>b&1); }
    }
    d.memory=mask&~d.forwarded;
    d.reason=unknown ? Dependence::address : missing ? Dependence::data
        : d.memory && d.forwarded ? Dependence::partial : Dependence::clear;
    return d;
}

class Observer {
    using Counts=std::map<std::string,uint64_t>;
    struct Record {
        Instruction ins;
        uint64_t sequence=0, allocated=0, issued=0, resolved=0, response=0, writeback=0;
        bool did_issue=false, did_resolve=false, miss=false, did_response=false, did_writeback=false;
        bool retired=false, retirement_region=false;
        std::array<uint64_t,7> waits{};
        std::array<uint64_t,2> opportunity{}, load_wake_count{}, load_wake_delay{};
        bool woke=false;
        uint64_t wake_cycle=0;
    };
    struct Recovery {
        bool active=false, region=false;
        uint64_t sequence=0, start=0, older_issue=0, older_retire=0;
        uint32_t target=0;
    } recovery;
    std::map<uint64_t,Record> records;
    std::array<uint64_t,32> slots{};
    std::array<Counts,2> counts;
    std::array<std::map<uint32_t,Counts>,2> pcs;
    uint64_t serial=0;
    bool was_region=false, recycling=false;
    // cycle bounds for the pairing, solo-retire, held-resolve and identity-recycle restrictions
    void restrictions(const Frame& f) {
        const auto kind=[](uint32_t i){ const unsigned op=i&127;
            return op==3 ? "load" : op==0x23 ? "store" : op==0x73 || op==0x0f ? "system" : nullptr; };
        if (f.fetch_lanes==3 && f.allocated[0].valid && !f.allocated[1].valid) {
            const uint32_t a=f.allocated[0].instruction, b=f.allocated[1].instruction;
            add(f.region,std::string("pair_lost_")+(cfi(a) ? "cfi0" : kind(a) ? std::string(kind(a))+"0"
                : kind(b) ? std::string(kind(b))+"1" : "other"));
        }
        const unsigned head=f.head&31, second=(f.head+1)&31;
        if (f.retired[0].valid && !f.retired[1].valid && (f.rob_valid>>second&1) && (f.rob_done>>second&1)) {
            const char* h=kind(f.retired[0].instruction);
            add(f.region,std::string("retire_lost_")+((f.rob_solo>>head&1) ? std::string("solo_head_")+(h ? h:"other")
                : (f.rob_solo>>second&1) ? "solo_second" : "other"));
        }
        if (f.resolve_offer && f.resolve_grant && (f.system_busy || f.fault_pending || f.memory_irrevocable)) {
            add(f.region,std::string("resolve_held_")+(f.system_busy ? "system" : f.fault_pending ? "fault":"memory"));
            add(f.region,"resolve_held_mispredict",f.mispredict);
        }
        if (f.recycle_state && !recycling) { recycling=true; add(f.region,"recycle_events"); }
        if (recycling) add(f.region,"recycle_window_cycles");
        if (recycling && !f.recycle_state && f.allocated[0].valid) recycling=false;
    }
    void add(bool region,const std::string& key,uint64_t value=1) {
        counts[0][key]+=value;
        if (region) counts[1][key]+=value;
    }
    Record& find(unsigned id) {
        auto it=records.find(slots[id&31]);
        check(it!=records.end() && !it->second.retired && it->second.ins.id==id,"identity mismatch");
        return it->second;
    }
    void gap(Record& r,uint64_t delay,uint64_t issues,uint64_t retires) {
        const bool region=r.retirement_region;
        add(region,"retired_miss_recovery_samples");
        add(region,"retired_miss_redirect_dispatch_cycles",delay);
        add(region,"retired_miss_recovery_older_issues",issues);
        add(region,"retired_miss_recovery_older_retires",retires);
    }
    struct Gap { uint64_t delay=0,issues=0,retires=0; };
    std::map<uint64_t,Gap> completed_gaps;
public:
    const auto& totals() const { return counts; }
    void sample(const Frame& f) {
        add(f.region,"cycles");
        unsigned live=0;
        for (unsigned s=0;s<32;++s) {
            if (slots[s]) {
                auto& r=records.at(slots[s]);
                check(!r.retired && (f.rob_valid>>s&1) && r.ins.id==f.rob_id[s],"ROB membership");
                ++live;
            } else check(!(f.rob_valid>>s&1),"unobserved ROB allocation");
        }
        if (f.region && !was_region) counts[1]["live_at_start"]=live;
        if (!f.region && was_region) counts[1]["live_at_end"]=live;
        was_region=f.region;
        unsigned retired=unsigned(f.retired[0].valid)+unsigned(f.retired[1].valid);
        const std::string front=f.redirect ? "redirect" : !f.fetch_enabled ? "disabled" : f.fetch_hold ? "hold"
            : f.fetch_valid ? (f.allocated[0].valid ? "accepted":"backend_wait")
            : "state_"+std::to_string(f.frontend_state);
        add(f.region,"frontend_"+front);
        add(f.region,"frontend_"+front+(f.issue || retired ? "_progress":"_no_progress"));
        add(f.region,"completion1_conflict",f.alu1_pending && f.load_pending);
        add(f.region,"completion1_load_wait",f.load_pending && !f.completion1_accept);
        add(f.region,"completion1_alu_wait",f.alu1_pending && (f.load_pending || !f.completion1_accept));
        restrictions(f);

        std::array<unsigned,16> awake{};
        std::array<int,2> winner{{-1,-1}};
        for (unsigned i=0;i<16;++i) if (f.iq[i].valid) {
            const auto& q=f.iq[i];
            auto& r=find(q.id);
            awake[i]=q.ready;
            for (unsigned src=0;src<2;++src) {
                if (!q.source[src]) awake[i]|=1u<<src;
                for (unsigned w=0;w<2;++w)
                    if ((f.wb>>w&1) && f.wb_tag[w] && q.source[src]==f.wb_tag[w]) {
                        awake[i]|=1u<<src;
                        if (f.load_complete && w==1 && !(q.ready>>src&1) && !r.woke) {
                            r.woke=true; r.wake_cycle=f.cycle;
                        }
                    }
            }
            check(awake[i]==q.awake,"operand readiness");
        }
        for (unsigned port=0;port<2;++port) {
            for (unsigned i=0;i<16;++i) {
                const auto& q=f.iq[i];
                if (!q.valid || awake[i]!=3 || !(q.eligible>>port&1)) continue;
                if (port==1 && (f.issue&1) && int(i)==winner[0]) continue;
                if (winner[port]<0 || age(q.id,f.head)<age(f.iq[winner[port]].id,f.head)) winner[port]=int(i);
            }
            const bool issued=!f.stop && !f.head_read && (f.port_ready>>port&1) && winner[port]>=0;
            check(issued==bool(f.issue>>port&1),"issue selection");
            if (issued) check(f.issue_id[port]==f.iq[winner[port]].id,"issue identity");
        }
        if (f.head_read) {
            add(f.region,"head_read");
            const std::string reason=f.stop ? "stop" : winner[1]<0 ? "no_ready_candidate"
                : !(f.port_ready&2) ? "port_unavailable" : "opportunity";
            add(f.region,"head_"+reason);
            if (reason=="opportunity") {
                auto& r=find(f.iq[winner[1]].id);
                ++r.opportunity[0]; if (f.region) ++r.opportunity[1];
                add(f.region,(r.ins.instruction&127)==3 || (r.ins.instruction&127)==0x23
                    ? "head_opportunity_memory":"head_opportunity_alu");
                add(f.region,"head_opportunity_accepted_completion",f.load_complete || bool(f.wb));
                add(f.region,"head_opportunity_load_result_pending",f.load_pending);
                add(f.region,"head_opportunity_alu_result_pending",f.alu1_pending);
                const unsigned opcode=r.ins.instruction&127;
                check((opcode!=3 && opcode!=0x23) || f.agu_ready,"head candidate AGU capacity");
            }
        }
        for (unsigned i=0;i<16;++i) if (f.iq[i].valid) {
            auto& r=find(f.iq[i].id);
            if (!cfi(r.ins.instruction)) continue;
            const bool issued=(f.issue&1) && f.issue_id[0]==r.ins.id;
            const unsigned reason=issued ? 0 : f.stop ? 1 : awake[i]!=3 ? 2 : f.head_read ? 3
                : !(f.port_ready&1) ? 4 : (f.issue&1) && cfi(find(f.issue_id[0]).ins.instruction) ? 5 : 6;
            ++r.waits[reason];
        }
        for (unsigned port=0;port<2;++port) if (f.issue>>port&1) {
            auto& r=find(f.issue_id[port]);
            check(!r.did_issue,"duplicate issue");
            r.did_issue=true; r.issued=f.cycle;
            if (r.woke) {
                add(f.region,"resident_load_consumer_issues");
                add(f.region,"resident_load_wb_to_issue_cycles",f.cycle-r.wake_cycle);
                r.load_wake_count[0]=1; r.load_wake_delay[0]=f.cycle-r.wake_cycle;
                if (f.region) { r.load_wake_count[1]=1; r.load_wake_delay[1]=f.cycle-r.wake_cycle; }
            }
            if (recovery.active && r.sequence<recovery.sequence) ++recovery.older_issue;
        }

        if (f.loads) {
            const Load* oldest=nullptr;
            for (const auto& l:f.lq) if (l.valid && l.ready && l.early && !l.issued)
                if (!oldest || age(l.id,f.head)<age(oldest->id,f.head)) oldest=&l;
            check(bool(oldest)==f.pick_found,"load pick presence");
            if (oldest) {
                check(oldest->id==f.pick_id,"oldest load pick");
                const auto d=disambiguate(f,*oldest);
                const bool stalled=d.reason==Dependence::address || d.reason==Dependence::data;
                check(f.lsq_valid==(!f.stop && !stalled),"load disambiguation");
                check(f.forward_mask==(stalled ? 0:d.forwarded) && f.memory_mask==(stalled ? 0:d.memory),"load masks");
                const bool available=!f.stop && !stalled && f.engine_ready && !f.forward_busy;
                check(f.launch_memory==(available && !d.forwarded) && f.launch_forward==(available && !d.memory),"load launch");
                const std::string reason=f.stop ? "stop" : d.reason==Dependence::address ? "store_address"
                    : d.reason==Dependence::data ? "store_data" : d.reason==Dependence::partial ? "partial_overlap"
                    : !f.engine_ready ? "engine_capacity" : f.forward_busy ? "forward_capacity"
                    : f.launch_forward ? "forward":"memory";
                add(f.region,"load_selected"); add(f.region,"load_"+reason);
                if (!f.stop && d.reason!=Dependence::clear && f.engine_ready && !f.forward_busy) {
                    bool younger=false;
                    for (const auto& l:f.lq)
                        if (l.valid && l.ready && l.early && !l.issued && age(l.id,f.head)>age(oldest->id,f.head)
                            && disambiguate(f,l).reason==Dependence::clear) younger=true;
                    add(f.region,"load_blocked_younger_safe",younger);
                }
            }
            if (f.response && f.response_live) {
                auto& r=find(f.response_id);
                check((r.ins.instruction&127)==3 && !r.did_response,"load response identity");
                r.did_response=true; r.response=f.cycle;
                add(f.region,"load_responses");
            } else if (f.response) add(f.region,"load_response_discarded");
            if (f.load_complete) {
                auto& r=find(f.load_complete_id);
                check((r.ins.instruction&127)==3 && !r.did_writeback,"load completion identity");
                r.did_writeback=true; r.writeback=f.cycle;
                add(f.region,"load_completions");
                add(f.region,"load_writebacks",bool(f.wb&2));
                if (r.did_response && (f.wb&2)) {
                    add(f.region,"load_response_to_wb_samples");
                    add(f.region,"load_response_to_wb_cycles",f.cycle-r.response);
                }
            }
        }
        if (f.resolve) {
            auto& r=find(f.resolve_id);
            check(cfi(r.ins.instruction) && r.did_issue && !r.did_resolve,"resolution lifecycle");
            check(f.mispredict==(r.ins.predicted_taken!=f.taken || r.ins.next_pc!=f.resolved_pc),"accepted prediction");
            r.did_resolve=true; r.resolved=f.cycle; r.miss=f.mispredict;
            r.ins.next_pc=f.resolved_pc;
            add(f.region,"cfi_resolved"); add(f.region,"cfi_redirects",f.mispredict);
        }
        if (recovery.active && f.allocated[0].valid) {
            check(f.allocated[0].pc==recovery.target,"redirect target dispatch");
            auto& r=records.at(recovery.sequence);
            Gap g{f.cycle-recovery.start,recovery.older_issue,recovery.older_retire};
            add(recovery.region,"redirect_dispatch_samples");
            add(recovery.region,"redirect_dispatch_cycles",g.delay);
            if (r.retired) { gap(r,g.delay,g.issues,g.retires); records.erase(recovery.sequence); }
            else completed_gaps[recovery.sequence]=g;
            recovery.active=false;
        }
        for (const auto& e:f.retired) if (e.valid) {
            auto& r=find(e.id);
            check(r.ins.pc==e.pc && r.ins.instruction==e.instruction,"retirement instruction");
            if (recovery.active && r.sequence<recovery.sequence) ++recovery.older_retire;
            r.retired=true; r.retirement_region=f.region;
            add(f.region,"retired");
            for (unsigned scope=0;scope<2;++scope) {
                counts[scope]["head_opportunity_retired"]+=r.opportunity[scope];
                counts[scope]["resident_load_consumer_retired"]+=r.load_wake_count[scope];
                counts[scope]["resident_load_consumer_retired_delay"]+=r.load_wake_delay[scope];
            }
            if (cfi(r.ins.instruction)) {
                check(r.did_resolve && r.ins.next_pc==e.next_pc,"retired unresolved branch");
                add(f.region,"retired_cfi"); add(f.region,"retired_cfi_misses",r.miss);
                if ((r.ins.instruction&127)==0x63) {
                    add(f.region,"retired_conditional"); add(f.region,"retired_conditional_misses",r.miss);
                }
                add(f.region,"retired_cfi_dispatch_issue_cycles",r.issued-r.allocated);
                add(f.region,"retired_cfi_issue_resolve_cycles",r.resolved-r.issued);
                static const char* waits[]={"issued","stop","operands","head_read","capacity","older_cfi","other_selected"};
                for (unsigned k=0;k<7;++k) add(f.region,std::string("retired_cfi_iq_")+waits[k],r.waits[k]);
                for (unsigned scope=0;scope<1u+f.region;++scope) {
                    ++pcs[scope][e.pc]["retired"]; pcs[scope][e.pc]["misses"]+=r.miss;
                }
                auto g=completed_gaps.find(r.sequence);
                if (g!=completed_gaps.end()) { gap(r,g->second.delay,g->second.issues,g->second.retires); completed_gaps.erase(g); }
            }
            slots[e.id&31]=0;
            if (!recovery.active || recovery.sequence!=r.sequence) records.erase(r.sequence);
        }
        if (f.recover || f.flush) {
            if (f.flush && recovery.active && records.at(recovery.sequence).retired) {
                add(recovery.region,"redirect_dispatch_cancelled");
                records.erase(recovery.sequence); recovery.active=false;
            }
            for (auto& s:slots) if (s) {
                auto& r=records.at(s);
                if (!f.flush && age(r.ins.id,f.head)<=age(f.resolve_id,f.head)) continue;
                add(f.region,"squashed");
                if (r.did_resolve) { add(f.region,"squashed_resolved_cfi"); add(f.region,"squashed_resolved_misses",r.miss); }
                for (unsigned scope=0;scope<2;++scope) counts[scope]["head_opportunity_squashed"]+=r.opportunity[scope];
                completed_gaps.erase(s);
                if (recovery.active && recovery.sequence==s) {
                    add(recovery.region,"redirect_dispatch_cancelled"); recovery.active=false;
                }
                records.erase(s); s=0;
            }
            if (f.recover) {
                check(f.resolve && f.mispredict && !recovery.active,"recovery lifecycle");
                recovery={true,f.region,find(f.resolve_id).sequence,f.cycle,0,0,f.resolved_pc};
            }
        }
        for (const auto& e:f.allocated) if (e.valid) {
            check(!slots[e.id&31],"occupied allocation");
            Record r; r.ins=e; r.sequence=++serial; r.allocated=f.cycle;
            slots[e.id&31]=serial; records.emplace(serial,r);
            add(f.region,"allocated");
        }
    }
    void print(std::ostream& out,bool region) const {
        auto result=counts;
        for (const auto& [sequence,r]:records) {
            (void)sequence;
            if (!r.retired) {
                ++result[0]["live_at_end"];
                if (was_region) ++result[1]["live_at_end"];
            }
            if (!r.retired)
                for (unsigned scope=0;scope<2;++scope) result[scope]["head_opportunity_pending"]+=r.opportunity[scope];
        }
        if (recovery.active) {
            ++result[0]["redirect_dispatch_pending"];
            if (recovery.region) ++result[1]["redirect_dispatch_pending"];
        }
        for (unsigned scope=0;scope<1u+region;++scope) {
            for (const auto& [key,value]:result[scope]) out<<"ATTR "<<(scope ? "region ":"all ")<<key<<' '<<value<<'\n';
            for (const auto& [pc,values]:pcs[scope])
                for (const auto& [key,value]:values) out<<"ATTR_PC "<<(scope ? "region ":"all ")<<pc<<' '<<key<<' '<<value<<'\n';
        }
    }
};
}
