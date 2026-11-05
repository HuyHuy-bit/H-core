#include "perf_attribution.hpp"
#include <functional>
#include <iostream>
#include <sstream>

using namespace perf_attribution;
static Instruction ins(unsigned id,uint32_t pc,uint32_t op=0x13) {
    return {true,false,id,pc,op,pc+4};
}
static Frame frame(unsigned cycle,std::initializer_list<unsigned> ids={}) {
    Frame f; f.cycle=cycle;
    for (unsigned id:ids) { f.rob_valid|=1u<<(id&31); f.rob_id[id&31]=id; }
    return f;
}
static void issue(Frame& f,unsigned id,unsigned port=0) {
    f.iq[0]={true,id,3,3,1u<<port,{0,0}};
    f.port_ready=1u<<port; f.issue=1u<<port; f.issue_id[port]=id;
}
static void expect(const Observer& o,unsigned scope,const std::string& key,uint64_t value) {
    const auto& c=o.totals()[scope];
    check((c.count(key) ? c.at(key):0)==value,key.c_str());
}
static void rejected(const std::string& message,const std::function<void()>& action) {
    try { action(); } catch (const std::runtime_error& e) {
        check(e.what()=="ATTRIBUTION "+message,"wrong negative signature"); return;
    }
    throw std::runtime_error("missed negative: "+message);
}
static void head_window() {
    Observer o;
    auto f=frame(0); f.allocated[0]=ins(0,16); o.sample(f);
    f=frame(1,{0}); f.region=true; f.head_read=true; f.port_ready=2;
    f.load_pending=f.completion1_accept=true;
    f.iq[0]={true,0,3,3,2,{0,0}}; o.sample(f);
    f=frame(2,{0}); issue(f,0,1); o.sample(f);
    f=frame(3,{0}); f.retired[0]=ins(0,16); o.sample(f);
    expect(o,1,"head_opportunity",1); expect(o,1,"head_opportunity_retired",1);
    expect(o,1,"retired",0); expect(o,1,"live_at_start",1); expect(o,1,"live_at_end",1);
    expect(o,1,"head_opportunity_load_result_pending",1);
    std::ostringstream text; o.print(text,true);
    check(text.str().find("ATTR all live_at_end 0\n")!=std::string::npos ||
          text.str().find("ATTR all live_at_end")==std::string::npos,"terminal live count");
}
static void branch_gap(bool flush) {
    Observer o;
    auto f=frame(0); f.allocated[0]=ins(0,16,0x63); o.sample(f);
    f=frame(1,{0}); issue(f,0); o.sample(f);
    f=frame(2,{0}); f.region=true; f.resolve=f.mispredict=f.recover=f.taken=true;
    f.resolve_id=0; f.resolved_pc=64; f.stop=true; o.sample(f);
    f=frame(3,{0}); f.retired[0]=ins(0,16,0x63); f.retired[0].next_pc=64; o.sample(f);
    f=frame(4); f.flush=flush;
    if (!flush) f.allocated[0]=ins(1,64);
    o.sample(f);
    expect(o,0,"retired_cfi_misses",1); expect(o,1,"retired_cfi_misses",0);
    expect(o,1,flush ? "redirect_dispatch_cancelled":"redirect_dispatch_samples",1);
    expect(o,0,"retired_miss_recovery_samples",flush ? 0:1);
    expect(o,0,"retired_miss_redirect_dispatch_cycles",flush ? 0:2);
}
static void wrong_path_branch() {
    Observer o;
    auto f=frame(0); f.allocated={ins(0,16,0x63),ins(1,20,0x63)}; o.sample(f);
    f=frame(1,{0,1}); issue(f,1); o.sample(f);
    f=frame(2,{0,1}); f.resolve=true; f.resolve_id=1; f.resolved_pc=24; issue(f,0); o.sample(f);
    f=frame(3,{0,1}); f.resolve=f.mispredict=f.recover=f.taken=f.stop=true;
    f.resolve_id=0; f.resolved_pc=64; o.sample(f);
    f=frame(4,{0}); f.retired[0]=ins(0,16,0x63); f.retired[0].next_pc=64; o.sample(f);
    f=frame(5); f.allocated[0]=ins(2,64); o.sample(f);
    expect(o,0,"cfi_resolved",2); expect(o,0,"squashed_resolved_cfi",1);
    expect(o,0,"retired_cfi",1); expect(o,0,"retired_cfi_misses",1);
}
static void identity_negatives() {
    Observer o;
    auto f=frame(0); f.allocated[0]=ins(0,16); o.sample(f);
    f=frame(1,{0}); f.retired[0]=ins(0,16); o.sample(f);
    f=frame(2); f.allocated[0]=ins(32,20); o.sample(f);
    rejected("ROB membership",[&] { o.sample(frame(3,{0})); });
    f=frame(3,{32}); issue(f,0);
    rejected("identity mismatch",[&] { o.sample(f); });
    Observer missing;
    rejected("unobserved ROB allocation",[&] { missing.sample(frame(0,{0})); });
    Observer prediction;
    f=frame(0); f.allocated[0]=ins(0,16,0x63); prediction.sample(f);
    f=frame(1,{0}); issue(f,0); prediction.sample(f);
    f=frame(2,{0}); f.resolve=true; f.resolved_pc=64; f.taken=true;
    rejected("accepted prediction",[&] { prediction.sample(f); });
    Observer readiness;
    f=frame(0); f.allocated[0]=ins(0,16); readiness.sample(f);
    f=frame(1,{0}); f.iq[0]={true,0,0,3,1,{7,8}};
    rejected("operand readiness",[&] { readiness.sample(f); });
}
static void forwarding() {
    Frame f;
    Load l{true,true,true,false,6,2,128};
    f.stores[0]={true,true,1,15,15,128};
    auto d=disambiguate(f,l);
    check(d.reason==Dependence::clear && d.forwarded==15 && !d.memory,"committed forwarding");
    f.stores[1]={true,true,8,2,0,128};
    check(disambiguate(f,l).reason==Dependence::data,"youngest store data");
    f.stores[1].rank=12;
    check(disambiguate(f,l).reason==Dependence::clear,"younger store ignored");
    f.stores[1]={true,false,8,0,0,256};
    check(disambiguate(f,l).reason==Dependence::address,"unknown older address");
    f.stores[1].valid=false; f.stores[0].mask=3;
    d=disambiguate(f,l);
    check(d.reason==Dependence::partial && d.forwarded==3 && d.memory==12,"partial overlap");
    Observer o; f=frame(0); f.loads=true; f.lq[0]=l; f.pick_found=f.lsq_valid=true;
    f.pick_id=6; f.memory_mask=1;
    rejected("load masks",[&] { o.sample(f); });
}
static void load_timing() {
    Observer o;
    auto f=frame(0); f.allocated={ins(0,16,3),ins(1,20)}; o.sample(f);
    f=frame(1,{0,1}); issue(f,0,1); o.sample(f);
    f=frame(2,{0,1}); f.loads=f.response=f.response_live=true; f.response_id=0; o.sample(f);
    f=frame(3,{0,1}); f.loads=f.load_complete=true; f.load_complete_id=0;
    f.wb=2; f.wb_tag[1]=7; f.iq[0]={true,1,2,3,2,{7,0}}; o.sample(f);
    f=frame(4,{0,1}); issue(f,1,1); f.retired[0]=ins(0,16,3); o.sample(f);
    f=frame(5,{1}); f.head=1; f.retired[0]=ins(1,20); o.sample(f);
    expect(o,0,"load_response_to_wb_samples",1); expect(o,0,"load_response_to_wb_cycles",1);
    expect(o,0,"resident_load_consumer_issues",1); expect(o,0,"resident_load_wb_to_issue_cycles",1);
    expect(o,0,"resident_load_consumer_retired",1); expect(o,0,"resident_load_consumer_retired_delay",1);
    f=frame(6); f.alu1_pending=f.load_pending=f.completion1_accept=true; o.sample(f);
    expect(o,0,"completion1_conflict",1); expect(o,0,"completion1_alu_wait",1);
    expect(o,0,"completion1_load_wait",0);
}
int main() {
    try {
        head_window(); branch_gap(false); branch_gap(true); wrong_path_branch();
        identity_negatives(); forwarding(); load_timing();
        std::cout<<"ATTRIBUTION TEST PASS: windows, recovery, wrong-path, generation, readiness, forwarding, load timing\n";
        return 0;
    } catch (const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
}
