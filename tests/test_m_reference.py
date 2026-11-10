import random
import unittest

from verif.core import reference as ref
from tools import run_coremark as coremark


def expected(op, a, b, bits):
    mask=(1<<bits)-1
    signed=lambda x: x-(1<<bits) if x>>(bits-1) else x
    x=signed(a) if op in (1,2,4,6) else a
    y=signed(b) if op in (1,4,6) else b
    if op<4:
        product=sum(x<<i for i in range(abs(y).bit_length()) if abs(y)&(1<<i))
        if y<0: product=-product
        return (product if op==0 else product>>bits)&mask
    if not y:return mask if op in (4,5) else a
    q,r=divmod(x,y)
    if r and (x<0)!=(y<0):q+=1;r-=y
    return (q if op in (4,5) else r)&mask


class MReferenceTests(unittest.TestCase):
    def test_m_is_illegal_by_default(self):
        for op in range(8):
            ins=(1<<25)|(2<<20)|(1<<15)|(op<<12)|(3<<7)|0x33
            r=ref.Reference(ins.to_bytes(4,'little'))
            event=r.step()
            self.assertEqual(event['trap_cause'],2)
            self.assertEqual(event['trap_value'],ins)

    def test_enabled_m_retires_and_records_operands(self):
        for op in range(8):
            ins=(1<<25)|(2<<20)|(1<<15)|(op<<12)|(3<<7)|0x33
            r=ref.Reference(ins.to_bytes(4,'little'),m_extension=True)
            r.registers[1]=0xfffffff9;r.registers[2]=2
            e=r.step()
            self.assertFalse(e.get('trap',0));self.assertEqual(e['retired'],1)
            self.assertEqual(e['rd_value'],expected(op,0xfffffff9,2,32))
            self.assertEqual((e['rs1_addr'],e['rs1_value'],e['rs2_addr'],e['rs2_value']),(1,0xfffffff9,2,2))
            self.assertEqual(r.registers[3],e['rd_value']);self.assertEqual(r.pc,4)

    def test_x0_and_neighbor_encoding(self):
        for f7 in (1,2,3,33):
            ins=(f7<<25)|(2<<20)|(1<<15)|0x33
            r=ref.Reference(ins.to_bytes(4,'little'),m_extension=True)
            r.registers[1]=0x80000000;r.registers[2]=0xffffffff
            e=r.step()
            self.assertEqual(bool(e.get('trap')),f7!=1)
            self.assertNotIn('rd_value',e);self.assertEqual(r.registers[0],0)

    def test_misa_and_destination_overlap(self):
        self.assertFalse(ref.Reference(b'').csrs[0x301]>>12&1)
        self.assertTrue(ref.Reference(b'',m_extension=True).csrs[0x301]>>12&1)
        ins=(1<<25)|(2<<20)|(1<<15)|(2<<12)|(1<<7)|0x33
        r=ref.Reference(ins.to_bytes(4,'little'),m_extension=True)
        r.registers[1]=0xffffffff;r.registers[2]=0xffffffff
        self.assertEqual(r.step()['rd_value'],0xffffffff);self.assertEqual(r.registers[1],0xffffffff)  # MULHSU; MULHU gives ...fe, MULH 0

    def test_exhaustive_small_width(self):
        for bits in range(1,7):
            for a in range(1<<bits):
                for b in range(1<<bits):
                    for op in range(8):
                        self.assertEqual(ref.m_result(op,a,b,bits),expected(op,a,b,bits),(op,a,b,bits))

    def test_random_32bit_and_boundaries(self):
        rng=random.Random(20261108)
        edges=[0,1,2,0x7fffffff,0x80000000,0xfffffffe,0xffffffff]
        pairs=[(a,b) for a in edges for b in edges]+[(rng.getrandbits(32),rng.getrandbits(32)) for _ in range(5000)]
        for a,b in pairs:
            for op in range(8):self.assertEqual(ref.m_result(op,a,b),expected(op,a,b,32),(op,a,b))

    def test_coremark_architecture_is_explicit_and_default_stable(self):
        self.assertEqual(coremark.compiler_flags(),['-O2','-march=rv32i','-mabi=ilp32'])
        self.assertEqual(coremark.compiler_flags('rv32im'),['-O2','-march=rv32im','-mabi=ilp32'])
        with self.assertRaises(ValueError):coremark.compiler_flags('rv64im')
        args=('cached_core',{'parameters':{}},{},{},b'image',2,1,{'warm':(16,3,32,1),'terminal':48},1)
        i=coremark.run_manifest(*args);m=coremark.run_manifest(*args,march='rv32im')
        self.assertNotEqual(coremark.manifest_digest(i),coremark.manifest_digest(m))
        self.assertEqual(i['flags'],coremark.FLAGS)


if __name__=='__main__':unittest.main()
