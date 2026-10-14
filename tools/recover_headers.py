"""Restore this installation's Mengluu PE header edits on analysis copies only."""
from pathlib import Path
import hashlib
import json
import struct
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent/'pythonlibs'))
import dnfile
from dncil.cil.opcode import OpCodes, OperandType

def recover_il(data):
    b = bytearray(data)
    pe = dnfile.dnPE(data=data)
    ops = OpCodes()
    seen = set()
    sizes = {'InlineNone':0, 'ShortInlineBrTarget':1, 'ShortInlineI':1,
             'ShortInlineVar':1, 'InlineVar':2, 'InlineI8':8, 'InlineR':8}
    for m in pe.net.mdtables.MethodDef.rows:
        if not m.Rva or m.Rva in seen:
            continue
        seen.add(m.Rva)
        start = pe.get_offset_from_rva(m.Rva)
        if b[start]&3 == 2:
            size = b[start] >> 2
            p = start+1
        elif b[start]&3 == 3:
            size = struct.unpack_from('<I', b, start+4)[0]
            p = start+(b[start+1]>>4)*4
        else:
            raise ValueError('Unknown method header')
        end = p+size
        while p < end:
            b[p] = b[p]-15 if 15 <= b[p] < 0xc0 else b[p]
            opcode = b[p]
            p += 1
            if opcode == 0xfe:
                op = ops.two_byte_op_codes[b[p]]
                p += 1
            else:
                op = ops.one_byte_op_codes[opcode]
            if op.name.startswith('UNKNOWN'):
                raise ValueError('Unknown opcode in '+str(m.Name)+' at '+hex(p-1)+' value '+hex(b[p-1]))
            if op.operand_type == OperandType.InlineSwitch:
                p += 4+4*struct.unpack_from('<I', b, p)[0]
            else:
                p += sizes.get(op.operand_type.name, 4)
        if p != end:
            raise ValueError('Invalid instruction boundary in '+str(m.Name)+' at '+hex(p))
    return bytes(b)

ROOT = Path(__file__).resolve().parents[1]

def recover(data):
    b = bytearray(data)
    if b[:2] == b'MZ':
        return bytes(b)
    if b[:2] != b'ML' or b[128:132] != b'ML\0\0':
        raise ValueError('Unrecognized protection')
    b[:2] = b'MZ'
    struct.pack_into('<I', b, 60, 128)
    b[128:132] = b'PE\0\0'
    section_start = 128 + 24 + struct.unpack_from('<H', b, 148)[0]
    sections = []
    i = 0
    while b[section_start+i*40] == ord('.'):
        p = section_start+i*40
        raw = struct.unpack_from('<I', b, p+20)[0] - 0x4d4c*(i+1)
        struct.pack_into('<I', b, p+20, raw)
        va, size = struct.unpack_from('<II', b, p+12)
        sections.append((va, size, raw))
        i += 1
    struct.pack_into('<H', b, 134, i)
    def offset(rva):
        for va, size, raw in sections:
            if va <= rva < va+size:
                return raw+rva-va
        raise ValueError(hex(rva))
    cli_rva = struct.unpack_from('<I', b, 128+24+96+14*8)[0]
    meta_rva = struct.unpack_from('<I', b, offset(cli_rva)+8)[0]
    p = offset(meta_rva)
    if b[p:p+4] != b'WSML':
        raise ValueError('Unexpected metadata signature '+repr(b[p:p+4]))
    b[p:p+4] = b'BSJB'
    return bytes(b)

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', required=True, type=Path, help='Owned INVAXION installation directory')
    args = parser.parse_args()
    managed = args.game/'INVAXION_Data'/'Managed'
    if not managed.is_dir():
        parser.error('Game Managed directory does not exist')
    out = ROOT/'analysis'/'managed'
    out.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for p in managed.glob('*.dll'):
        backup = ROOT/'original'/p.name
        original = (backup if backup.is_file() else p).read_bytes()
        restored = recover_il(recover(original)) if original[:2] == b'ML' else original
        (out/p.name).write_bytes(restored)
        manifest[p.name] = {'original_sha256': hashlib.sha256(original).hexdigest(),
                            'analysis_sha256': hashlib.sha256(restored).hexdigest()}
    (ROOT/'analysis'/'recovery-manifest.json').write_text(json.dumps(manifest, indent=2))
    print('Recovered', len(manifest), 'analysis copies')
