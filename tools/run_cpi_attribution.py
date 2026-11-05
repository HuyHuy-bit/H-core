#!/usr/bin/env python3
"""Read-only cached-core attribution, checked against identical uninstrumented execution."""
import argparse
from collections import deque
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from threading import Timer

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.run_cpi import check as check_reference
from tools.run_coremark import input_files, snapshot, verify_snapshot, tool_versions
from tools.run_sail_differential import build_fetched
from verif.core.perf_programs import PROGRAMS

SAVED = ROOT/'out/promotion_serial_payload_2026-11-03/measured_result/coremark'
CASES = (('dependency', 1), ('branches', 1), ('branches', 50), ('store_hit', 1),
         ('load_hit', 1), ('load_hit', 50), ('forward', 1), ('loop_memory', 10))


def require(ok, message):
    if not ok: raise ValueError(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def check_attribution(row):
    require(set(row['attribution']) == set(row['counters']), 'attribution scopes')
    for scope, c in row['counters'].items():
        a = row['attribution'][scope]
        get = lambda key: a.get(key, 0)
        require(get('cycles') == c['cycles'], 'attribution cycle window')
        require(get('retired') == c.get('retire_1', 0) + 2*c.get('retire_2', 0), 'attribution retirement window')
        require(get('head_read') == c['head_read'], 'head-read window')
        require(sum(get('head_'+k) for k in ('stop','no_ready_candidate','port_unavailable','opportunity'))
                == get('head_read'), 'head partition')
        require(get('head_opportunity_alu') + get('head_opportunity_memory') == get('head_opportunity'), 'head candidates')
        require(sum(get('head_opportunity_'+k) for k in ('retired','squashed','pending'))
                == get('head_opportunity'), 'head survival partition')
        require(sum(v for k,v in a.items() if k.startswith('frontend_') and not k.endswith(('_progress','_no_progress')))
                == c['cycles'], 'frontend partition')
        for k,v in a.items():
            if k.startswith('frontend_') and not k.endswith(('_progress','_no_progress')):
                require(get(k+'_progress') + get(k+'_no_progress') == v, 'frontend progress partition')
        require(get('allocated') + get('live_at_start') == get('retired') + get('squashed') + get('live_at_end'),
                'identity conservation')
        require(get('cfi_resolved') == sum(c.get('resolve_'+k,0) for k in ('branch','jal','jalr','return')), 'resolution counts')
        require(get('cfi_redirects') == sum(c.get('branch_redirect_'+k,0) for k in ('branch','jalr','return','jal')), 'redirect counts')
        require(get('cfi_redirects') == sum(get('redirect_dispatch_'+k) for k in ('samples','cancelled','pending')), 'recovery partition')
        require(get('retired_cfi_iq_issued') == get('retired_cfi'), 'retired branch issue accounting')
        require(get('retired_cfi_misses') <= get('retired_cfi'), 'retired branch misses')
        require(get('retired_miss_recovery_samples') <= get('retired_cfi_misses'), 'retired recovery samples')
        pcs = row['per_pc'].get(scope, {})
        require(sum(p.get('retired',0) for p in pcs.values()) == get('retired_cfi'), 'per-PC retirement')
        require(sum(p.get('misses',0) for p in pcs.values()) == get('retired_cfi_misses'), 'per-PC misses')
        require(sum(get('load_'+k) for k in ('stop','store_address','store_data','partial_overlap','engine_capacity',
                                          'forward_capacity','forward','memory')) == get('load_selected'), 'load partition')
        require(get('load_memory') == c['early_memory_launch'] and get('load_forward') == c['forward_launch'], 'load launch counts')


def measure(binary, raw, program, latency, enabled=False, calibration=False):
    schema = json.loads((ROOT/'config/commit_event.yaml').read_text())
    offset = schema['max_csr_effects']*sum(f['width'] for f in schema['csr_fields'])
    fields = {}
    for field in reversed(schema['slot_fields']):
        fields[field['name']] = offset, field['width']; offset += field['width']
    size = (offset+7)//8
    get = lambda packed,name: packed >> fields[name][0] & ((1 << fields[name][1])-1)
    command = [str(binary), str(raw), '1', str(program.get('limit', 4000)), 'perf', f'+read_latency={latency}',
               f'+write_latency={latency}', f'+terminal={program["terminal"]}']
    if 'warm' in program: command.append('+warm='+':'.join(map(str,program['warm'])))
    if enabled: command.append('+attribution=1')
    old_hash, packed_hash = hashlib.sha256(), hashlib.sha256()
    counts, attr, per_pc, perf = {}, {}, {}, None
    edges = bytearray(); seen = [0,0]; marks = [None,None]; n = 0
    passed = False; terminal = None; tail = deque(maxlen=5); output = []
    process = subprocess.Popen(command,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    timer = Timer(7200, process.kill)
    timer.daemon = True
    timer.start()
    try:
        for line in process.stdout:
            tail.append(line)
            if calibration: output.append(line)
            parts=line.split()
            if not parts: continue
            if parts[0] not in ('ATTR','ATTR_PC'): old_hash.update(line.encode())
            if parts[0]=='EVENT':
                edge,lane=int(parts[1]),int(parts[2])
                require(terminal is None or edge==terminal, 'retirement after terminal')
                packed=sum(int(w,16)<<(32*i) for i,w in enumerate(parts[3:]))
                require(get(packed,'order')==n and get(packed,'valid') and get(packed,'retired'), 'event order or validity')
                require(not get(packed,'trap'), 'perf trap')
                if len(edges)<=edge: edges.extend(bytes(edge+1-len(edges)))
                require(lane==edges[edge] and lane<2, 'event lane order')
                edges[edge]+=1; n+=1
                packed_hash.update(packed.to_bytes(size,'little'))
                pc=get(packed,'pc_before')
                if pc==program['terminal']: terminal=edge
                for k in range(2) if 'warm' in program else ():
                    if pc==program['warm'][2*k]:
                        seen[k]+=1
                        if seen[k]==program['warm'][2*k+1]: marks[k]=edge+1
            elif parts[0] in ('COUNTER','ATTR'):
                _,scope,key,value=parts
                target=counts if parts[0]=='COUNTER' else attr
                require(key not in target.setdefault(scope,{}), 'duplicate measurement key')
                target[scope][key]=int(value)
            elif parts[0]=='ATTR_PC':
                _,scope,pc,key,value=parts
                target=per_pc.setdefault(scope,{}).setdefault(pc,{})
                require(key not in target, 'duplicate per-PC key');target[key]=int(value)
            elif parts[0]=='PERF':
                require(perf is None,'duplicate PERF')
                perf={k:int(v) for k,v in (field.split('=') for field in parts[1:])}
            elif line.startswith('CORE PASS '): passed=True
        process.wait(timeout=30)
    except BaseException:
        process.kill(); process.wait(); raise
    finally:
        timer.cancel()
        process.stdout.close()
    require(process.returncode==0 and passed and terminal is not None, 'simulation failed: '+''.join(tail))
    require(perf is not None, 'missing PERF')
    expected=dict(cycles=terminal+1,retired=n,zero=edges.count(0),one=edges.count(1),two=edges.count(2),drain=perf['drain'])
    if 'warm' in program:
        require(None not in marks and marks[1]>marks[0], 'warm markers')
        expected.update(warm_start=marks[0],warm_start_edge=edges[marks[0]-1],warm_cycles=marks[1]-marks[0],
                        warm_retired=sum(edges[marks[0]:marks[1]]))
    require(perf==expected, 'PERF differs from streamed edge recount')
    for scope, window in [('all',edges)]+([('region',edges[marks[0]:marks[1]])] if 'warm' in program else []):
        c=counts[scope]
        require(c['cycles']==len(window) and all(c.get(f'retire_{k}',0)==window.count(k) for k in range(3)), 'COUNTER recount')
    row=dict(perf=perf,counters=counts,attribution=attr,per_pc=per_pc,command=command,
             original_output_sha256=old_hash.hexdigest(),packed_sha256=packed_hash.hexdigest())
    if enabled: check_attribution(row)
    if calibration: check_reference(''.join(output),program)
    return row


def compare(base, other):
    for key in ('perf','counters','original_output_sha256','packed_sha256'):
        require(base[key]==other[key], f'instrumentation changed {key}')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'out/cpi_attribution_2026-11-03')
    parser.add_argument('--baseline-binary',type=Path)
    parser.add_argument('--observer-binary',type=Path)
    parser.add_argument('--calibrations-only',action='store_true')
    args=parser.parse_args(); out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    config=json.loads((ROOT/'config/cached_core.json').read_text())
    paths=input_files('cached_core',config)+['tools/run_cpi_attribution.py','verif/core/perf_programs.py',
                                          'verif/core/programs.py','verif/common/packed_bits.hpp']
    inputs=snapshot(paths)
    baseline=args.baseline_binary or build_fetched(out/'baseline_obj',config_name='cached_core')[0]
    observer=args.observer_binary or build_fetched(out/'observer_obj',config_name='cached_core',attribution=True)[0]
    if args.baseline_binary:
        frozen=json.loads((out/'baseline_sources.json').read_text())
        for path,expected in frozen.items():
            if path.startswith('rtl/'): require(digest(ROOT/path)==expected,'baseline RTL changed: '+path)
    receipt=dict(status='running',scope='bench_only_cached_attribution',inputs_sha256=inputs,tools=tool_versions(),
                 binaries={str(b):digest(b) for b in (baseline,observer)},results=[])
    if args.baseline_binary:
        receipt['frozen_baseline_inputs_sha256'] = frozen
        receipt['baseline_source_differences'] = [p for p,h in frozen.items() if digest(ROOT/p)!=h]
    def publish():
        verify_snapshot(inputs)
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    publish()
    for name,latency in CASES:
        program=PROGRAMS[name]();raw=out/(name+'.bin');raw.write_bytes(program['image'])
        base=measure(baseline,raw,program,latency,calibration=True)
        off=measure(observer,raw,program,latency,calibration=True)
        on=measure(observer,raw,program,latency,enabled=True,calibration=True)
        compare(base,off);compare(base,on)
        receipt['results'].append(dict(program=name,latency=latency,image_sha256=digest(raw),**on))
        publish();print(f'PASS {name} latency={latency}: observer off/on equals baseline; reference and attribution checks',flush=True)
    if not args.calibrations_only:
        old=json.loads((SAVED/'receipt.json').read_text())
        saved=next(r for r in old['results'] if r['profile']=='cached_core' and r['latency']==1)
        raw=SAVED/'coremark.bin';require(digest(raw)==old['image_sha256'],'CoreMark binary mismatch')
        program=dict(terminal=saved['manifest']['terminal'],warm=saved['manifest']['region'],limit=old['instructions']+16)
        base=measure(baseline,raw,program,1)
        require(base['packed_sha256']==saved['validation']['expected_packed_binary_sha256'],'preserved reference stream mismatch')
        require(base['perf']=={k:saved[k] for k in base['perf']} and base['counters']==saved['counters'],'preserved baseline mismatch')
        print('PASS CoreMark frozen baseline and preserved reference digest',flush=True)
        on=measure(observer,raw,program,1,enabled=True)
        compare(base,on)
        receipt['results'].append(dict(program='coremark',latency=1,image_sha256=digest(raw),**on))
        receipt['coremark_reference']=dict(path=str(SAVED/'receipt.json'),sha256=digest(SAVED/'receipt.json'),
            method='fresh_RTL_matches_preserved_full_reference_digest_and_frozen_uninstrumented_execution')
        print('PASS CoreMark observer equals frozen baseline; attribution checks',flush=True)
    receipt['status']='calibrations_pass' if args.calibrations_only else 'pass'
    receipt['limitations']=['Cached profile only; CoreMark memory latency 1 only.',
        'Head opportunities are cycle observations, not a prediction of saved cycles.',
        'Resident load-consumer timing covers only IQ operands awakened by an accepted load write.',
        'Branch wait/latency totals use retirement cohorts; recovery event totals use redirect-cycle windows.',
        'Preserved CoreMark reference digest reused; no new ISA acceptance or physical timing run.']
    publish()


if __name__=='__main__': main()
