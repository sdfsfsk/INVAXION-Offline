"""Version-locked, reversible patches preserving the original assembly layout."""
from pathlib import Path
import hashlib
import json
import struct
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent/'pythonlibs'))
import dnfile
from dncil.cil.body.reader import read_method_body_from_bytes
from recover_headers import recover, recover_il, ROOT

original = (ROOT/'original'/'Assembly-CSharp.dll').read_bytes()
manifest = json.loads((ROOT/'bin'/'patch-manifest.json').read_text())
assert hashlib.sha256(original).hexdigest() == manifest['original_sha256']
clear = recover_il(recover(original))
pe = dnfile.dnPE(data=clear)
output = bytearray(original)
methods = {}
for t in pe.net.mdtables.TypeDef.rows:
    name = str(t.TypeNamespace)+'.'+str(t.TypeName) if str(t.TypeNamespace) else str(t.TypeName)
    for index in t.MethodList:
        key = name+'::'+str(index.row.Name)
        methods.setdefault(key, []).append((0x06000000|index.row_index, index.row))

def method(key):
    rows = methods[key]
    assert len(rows)==1, key
    return rows[0]

def call(key):
    return bytes([0x37])+struct.pack('<I', method(key)[0])

def integer(n):
    return bytes([0x2f])+struct.pack('<i', n)

def construct(key):
    return bytes([0x82])+struct.pack('<I', method(key)[0])

def field(key):
    typename, name = key.split('::')
    for t in pe.net.mdtables.TypeDef.rows:
        full = str(t.TypeNamespace)+'.'+str(t.TypeName) if str(t.TypeNamespace) else str(t.TypeName)
        if full == typename:
            for index in t.FieldList:
                if str(index.row.Name) == name:
                    return struct.pack('<I', 0x04000000|index.row_index)
    raise ValueError(key)

def member(typename, name):
    matches=[]
    for i, m in enumerate(pe.net.mdtables.MemberRef.rows):
        if str(m.Name)==name and str(getattr(m.Class.row, 'TypeName', ''))==typename:
            matches.append(0x0a000000|i+1)
    assert len(matches)==1, (typename, name, matches)
    return struct.pack('<I', matches[0])

def ldstr(s):
    # Resolve existing #US literal, without adding tokens to the protected module.
    heap = pe.net.user_strings
    for key, rows in methods.items():
        for _, m in rows:
            if not m.Rva: continue
            body = read_method_body_from_bytes(pe.get_data(m.Rva, 100000))
            for ins in body.instructions:
                if ins.opcode.name == 'ldstr' and str(heap.get(ins.operand.value & 0xffffff)) == s:
                    return bytes([0x81])+struct.pack('<I', ins.operand.value)
    raise ValueError(s)

report = []
patched = {}
byte_patches = []

def body(key):
    _, m = method(key)
    offset = pe.get_offset_from_rva(m.Rva)
    return offset, read_method_body_from_bytes(pe.get_data(m.Rva,100000))

def splice(key, relative, old_bytes, new_bytes):
    assert len(old_bytes)==len(new_bytes)
    offset, b = body(key)
    offset += b.header_size+relative
    assert output[offset:offset+len(old_bytes)]==old_bytes
    output[offset:offset+len(new_bytes)]=new_bytes
    byte_patches.append({'method':key,'offset':offset,'old_bytes':old_bytes.hex(),'new_bytes':new_bytes.hex()})

def existing_member_call(key, name):
    _, b = body(key)
    matches=[]
    for ins in b.instructions:
        if ins.opcode.name=='call' and ins.operand.value>>24==0x0a:
            ref=pe.net.mdtables.MemberRef.rows[(ins.operand.value&0xffffff)-1]
            if str(ref.Name)==name: matches.append(ins.operand.value)
    assert len(matches)==1,(key,name,matches)
    return b'\x37'+struct.pack('<I',matches[0])

class Code:
    def __init__(self): self.data=bytearray();self.labels={};self.branches=[]
    def emit(self, code): self.data.extend(code)
    def label(self, name): self.labels[name]=len(self.data)
    def branch(self, opcode, name):
        self.emit(bytes([opcode,0]));self.branches.append((len(self.data)-1,name))
    def finish(self):
        for at,name in self.branches:
            delta=self.labels[name]-at-1
            assert -128<=delta<128
            self.data[at]=delta&255
        return bytes(self.data)
def patch(key, code):
    token, m = method(key)
    offset = pe.get_offset_from_rva(m.Rva)
    oldbody = read_method_body_from_bytes(pe.get_data(m.Rva, 100000))
    newbody = (bytes([(len(code)<<2)|2]) if len(code)<64 else struct.pack('<HHII',0x3003,8,len(code),0))+code
    assert len(code)<64 or offset%4==0, key
    assert len(newbody)<=oldbody.header_size+oldbody.code_size, key
    if offset in patched:
        assert patched[offset]==newbody, 'Conflicting shared body: '+key
    else:
        # A shared body may be changed only when all its users receive the same patch.
        patched[offset]=newbody
    output[offset:offset+len(newbody)] = newbody
    report.append({'method':key, 'token':hex(token), 'offset':offset,
                   'old_body_size':oldbody.header_size+oldbody.code_size,
                   'new_bytes':newbody.hex()})

RET=b'\x39'
FALSE=b'\x25\x39'
TRUE=b'\x26\x39'
NULL=b'\x23\x39'
POP=b'\x35'
ARG0=b'\x11'

code = call('Aquatrax.PlayerFullData::getInstance')
code += call('Aquatrax.PlayerFullData::initOfflineFullDataWithoutData')
for data_type, prop in [('TeamData','team'), ('PlayerCurrencyInfo','currencyInfo')]:
    code += call('Aquatrax.PlayerFullData::getInstance')+call('Aquatrax.PlayerFullData::getCharFullData')
    code += construct('cometScene.'+data_type+'::.ctor')+call('cometScene.CharacterFullData::set_'+prop)
code += call('Aquatrax.PlayerFullData::getInstance')+integer(10010)+call('Aquatrax.PlayerFullData::setCurCharacterId')
code += call('Aquatrax.PlayerFullData::getInstance')+b'\x26'+call('Aquatrax.PlayerFullData::setCharLevel')
code += call('SteamManager::init')+POP
code += call('Aquatrax.AchievementManager::getInstance')+POP
code += ldstr('PC_newQuickPlay')+ldstr('QuickPlay')+call('Aquatrax.MenuSwitchScene::NewInstance')+POP+RET
patch('Aquatrax.LoginView::OnClickOffline', code)
patch('Aquatrax.LoginView::prepareBeforeLogin', ARG0+call('Aquatrax.LoginView::OnClickOffline')+RET)
for name in ['Update','ConnectLoginServer','RegAccount','LoginAccount','QuickToken','QuickLogin',
             'RequestThirdLogin','RequestBindAccount','requestAnnouncement','requestGameVersion']:
    patch('Aquatrax.LoginServer::'+name, RET)
for name in ['Reconnect','sendGateMsg','sendFailedMsg','Ret_UserGameTime']:
    patch('Aquatrax.NetManager::'+name, RET)
# Replace the former network heartbeat with local F8/F9 handling. frameCount
# prevents multiple FixedUpdate calls in one rendered frame from double toggling.
keycode = bytearray()
labels = {}
branches = []
def emit(b): keycode.extend(b)
def branch(op, label):
    emit(bytes([op,0])); branches.append((len(keycode)-1,label))
emit(ARG0+b'\x8a'+field('Aquatrax.NetManager::lastTime'))
emit(b'\x37'+member('Time','get_frameCount')+b'\x7a')
branch(0x3d,'end') # beq.s
emit(ARG0+b'\x37'+member('Time','get_frameCount')+b'\x7a\x8c'+field('Aquatrax.NetManager::lastTime'))
emit(integer(289)+b'\x37'+member('Input','GetKeyDown'))
branch(0x3b,'f9') # brfalse.s
emit(b'\x8d'+field('Aquatrax.PlayData::isAuto')+b'\x25\xfe\x01\x8f'+field('Aquatrax.PlayData::isAuto'))
labels['f9']=len(keycode)
emit(integer(290)+b'\x37'+member('Input','GetKeyDown'))
branch(0x3b,'end')
emit(b'\x25\x8f'+field('Aquatrax.PlayData::isAuto'))
labels['end']=len(keycode)
emit(RET)
for at,label in branches:
    distance=labels[label]-at-1
    assert -128<=distance<128
    keycode[at]=distance&255
patch('Aquatrax.NetManager::FixedUpdate', bytes(keycode))
# Unity GetKeyDown must be sampled each rendered frame, so rename only this
# MethodDef's name index to the already existing Update string. Other methods
# sharing the FixedUpdate string remain untouched.
_, heartbeat = method('Aquatrax.NetManager::FixedUpdate')
name_offset = heartbeat.struct.get_field_absolute_offset('Name_StringIndex')
update_name = next(m.struct.Name_StringIndex for m in pe.net.mdtables.MethodDef.rows if str(m.Name)=='Update')
assert heartbeat.struct.get_field_absolute_offset('Signature_BlobIndex')-name_offset==4
struct.pack_into('<I', output, name_offset, update_name)
for name in ['EnterGate','canConnectToServer','isConnect']:
    patch('Aquatrax.NetManager::'+name, FALSE)
patch('Aquatrax.NetManager::getIP', b'\x11'+RET) # return supplied string, never resolve DNS
for name in ['CreateLoginSocket','CreateGatewaySocket','ParseCmd','Disconnect']:
    patch('EagleTcp::'+name, RET)
for name in ['SendLoginCmd','SendGateCmd','SendCmd','IsConnected']:
    patch('EagleTcp::'+name, FALSE)
# Steam initialization, callbacks, SetAchievement and StoreStats remain original.
# Publisher authentication tickets are unrelated to achievement synchronization.
patch('Aquatrax.tpSDKCtrl::steamUserAuthenticate_Encrypted', RET)
patch('Aquatrax.GlobalConfig::isUseLocalAssets', TRUE)

# Preserve the singleton and only construct the original native-callback holder
# when Steam initialized successfully. A Steam-unavailable session can still play.
achi=Code()
achi.emit(b'\x8d'+field('Aquatrax.AchievementManager::_instance')+b'\x34')
achi.branch(0x3c,'return') # brtrue.s, retaining the duplicate instance
achi.emit(POP+construct('Aquatrax.AchievementManager::.ctor')+b'\x34\x8f'+field('Aquatrax.AchievementManager::_instance'))
achi.emit(call('SteamManager::get_Initialized'))
achi.branch(0x3b,'return')
achi.emit(b'\x34'+call('Aquatrax.GlobalConfig::getInstance')+call('Aquatrax.GlobalConfig::getChievementList'))
achi.emit(construct('Aquatrax.SteamAchievement::.ctor')+b'\x8c'+field('Aquatrax.AchievementManager::steamAchi'))
achi.label('return');achi.emit(RET)
patch('Aquatrax.AchievementManager::getInstance',achi.finish())

# Replace the original publisher-offline guard with a Steam-availability guard.
# Equal-length edit keeps all original locals, exception regions and branches.
offset, b = body('Aquatrax.AchievementManager::checkAchievement')
guard = next(i for i in b.instructions if i.opcode.name=='call' and i.operand.value==method('Aquatrax.PlayerFullData::getInstance')[0])
at=guard.offset-b.header_size
old=original[offset+guard.offset:offset+guard.offset+10]
new=call('SteamManager::get_Initialized')+b'\x25\xfe\x01\x3a\x00'
splice('Aquatrax.AchievementManager::checkAchievement',at,old,new)

# Local quick-play results can invoke the existing achievement conditions without
# waiting for the defunct publisher's Ret_FinishSong response. No fabricated data.
result=ARG0+ARG0+call('Aquatrax.ResultView_single::prepareSongData')
result+=ARG0+b'\x8a'+field('Aquatrax.ResultView_single::tempFinishLevel')
result+=call('Aquatrax.ResultView_single::checkAchievement')+RET
patch('Aquatrax.ResultView_single::uploadData',result)

# Cloud totals may exceed this fresh local profile. Preserve accumulated Steam
# progress: only increase a statistic, never replace it with a lower local total.
stat=Code()
stat.emit(call('SteamManager::get_Initialized'));stat.branch(0x3b,'return')
stat.emit(ARG0+b'\x12'+call('Aquatrax.SteamAchievement::checkAchiUnlocked'));stat.branch(0x3c,'return')
stat.emit(b'\x13'+ARG0+b'\x12'+call('Aquatrax.SteamAchievement::getStatValue'));stat.branch(0x40,'return') # ble.s
stat.emit(ARG0+b'\x12'+call('Aquatrax.SteamAchievement::getAchiInfoByID'))
stat.emit(b'\x8a'+field('Aquatrax.AchievementInfo::StatName')+b'\x13')
stat.emit(existing_member_call('Aquatrax.SteamAchievement::UpdateStat','SetStat'));stat.branch(0x3b,'return')
stat.emit(existing_member_call('Aquatrax.SteamAchievement::UpdateStat','StoreStats')+POP)
stat.label('return');stat.emit(RET)
patch('Aquatrax.SteamAchievement::UpdateStat',stat.finish())
# Stop the generated HTTP download coroutine before it creates a WWW request.
candidates = [key for key in methods if '<downloadprogress>' in key and key.endswith('::MoveNext')]
assert len(candidates)==1, candidates
patch(candidates[0], FALSE)
patch('Aquatrax.SingleContentDownloader::ReDownload', RET)

# Shared RVA audit, before producing any installable output.
requested = {r['method'] for r in report}
for key, rows in methods.items():
    for _, m in rows:
        if m.Rva and pe.get_offset_from_rva(m.Rva) in patched:
            assert key in requested, 'Unrequested shared method body: '+key

out = ROOT/'bin'
out.mkdir(exist_ok=True)
(out/'Assembly-CSharp.offline.dll').write_bytes(output)
report_data = {'original_sha256':hashlib.sha256(original).hexdigest(),
               'patched_sha256':hashlib.sha256(output).hexdigest(), 'patches':report}
report_data['metadata_patches']=[{'description':'NetManager.FixedUpdate renamed to Update',
    'offset':name_offset,'new_bytes':struct.pack('<I',update_name).hex()}]
report_data['byte_patches']=byte_patches
report_data['steam_achievements_enabled']=True
report_data['version']='2.0-steam-achievements'
report_data['compatible_previous_sha256']=manifest.get('compatible_previous_sha256', [])

# An optional second build enables the game's existing autoplay for each song.
# It does not claim to be the independent input scheduler in the reference tools.
auto_output = bytearray(output)
_, start_method = method('Aquatrax.PlayData::Start')
start_offset = pe.get_offset_from_rva(start_method.Rva)
start_body = read_method_body_from_bytes(pe.get_data(start_method.Rva,100000))
first = start_body.instructions[0]
assert first.opcode.name=='ldsfld' and struct.pack('<I',first.operand.value)==field('Aquatrax.SkillData::AutoWithoutScore')
auto_output[start_offset+first.offset:start_offset+first.offset+5]=integer(1)
(out/'Assembly-CSharp.autoplay.dll').write_bytes(auto_output)
report_data['autoplay_sha256']=hashlib.sha256(auto_output).hexdigest()
report_data['autoplay_patch']={'method':'Aquatrax.PlayData::Start','offset':start_offset+first.offset,'bytes':integer(1).hex()}
(out/'patch-manifest.json').write_text(json.dumps(report_data, indent=2))
(ROOT/'analysis').mkdir(exist_ok=True)
(ROOT/'analysis'/'Assembly-CSharp.offline.readable.dll').write_bytes(recover_il(recover(output)))
print('Built', len(report), 'method patches;', report_data['patched_sha256'])
