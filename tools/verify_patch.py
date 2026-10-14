"""Validate the installable binaries against the backed-up original and manifest."""
from pathlib import Path
import hashlib, json, sys
sys.path.insert(0,str(Path(__file__).resolve().parent/'pythonlibs'))
import dnfile
from dncil.cil.body.reader import read_method_body_from_bytes
from recover_headers import recover, recover_il

root=Path(__file__).resolve().parents[1]
manifest=json.loads((root/'bin'/'patch-manifest.json').read_text())
original=(root/'original'/'Assembly-CSharp.dll').read_bytes()
assert hashlib.sha256(original).hexdigest()==manifest['original_sha256']
results=[]
for variant,hashkey in [('offline','patched_sha256'),('autoplay','autoplay_sha256')]:
    data=(root/'bin'/('Assembly-CSharp.'+variant+'.dll')).read_bytes()
    assert len(data)==len(original)
    assert hashlib.sha256(data).hexdigest()==manifest[hashkey]
    allowed=bytearray(len(data))
    patches=manifest['patches']+manifest.get('metadata_patches',[])+manifest.get('byte_patches',[])
    if variant=='autoplay':
        patches=patches+[dict(manifest['autoplay_patch'],new_bytes=manifest['autoplay_patch']['bytes'])]
    for change in patches:
        expected=bytes.fromhex(change['new_bytes'])
        offset=change['offset']
        assert data[offset:offset+len(expected)]==expected
        allowed[offset:offset+len(expected)]=b'\x01'*len(expected)
    assert all(a==b or allowed[i] for i,(a,b) in enumerate(zip(original,data)))
    clear=recover_il(recover(data))
    pe=dnfile.dnPE(data=clear)
    for change in manifest['patches']:
        row=pe.net.mdtables.MethodDef.rows[int(change['token'],16)%0x1000000-1]
        body=read_method_body_from_bytes(pe.get_data(row.Rva,100000))
        assert body.instructions[-1].opcode.name=='ret'
    net=next(t for t in pe.net.mdtables.TypeDef.rows if str(t.TypeName)=='NetManager')
    assert sum(str(m.row.Name)=='Update' for m in net.MethodList)==1
    assert all(str(m.row.Name)!='FixedUpdate' for m in net.MethodList)
    results.append({'variant':variant, 'sha256':hashlib.sha256(data).hexdigest(),
                    'changed_bytes':sum(a!=b for a,b in zip(original,data)),
                    'method_patches':len(manifest['patches']), 'result':'PASS'})
(root/'qa').mkdir(exist_ok=True)
(root/'qa'/'binary-verification.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
