"""Pure file transformation; never executes donor code. Run by GitHub Actions."""
from pathlib import Path
import base64,hashlib,json,zipfile,io
ROOT=Path(__file__).resolve().parents[1]
META=[('aetheryx','Aetheryx','aetheryx.lua','aa'),('angelwings','Angelwings','angelwings.lua','aa'),('annesty','Annesty','annesty.lua','aa'),('bluhgang','Bluhgang','bluhgang.lua','aa'),('dormant','Dormant Aimbot','dormant aimbot (1).lua','helper'),('emberlash_v2','Emberlash v2','emberlash (2).lua','aa'),('emberlash_legacy','Emberlash legacy','emberlash.lua','aa'),('evalate','Evalate','evalate.lua','aa'),('kamidere','Kamidere','kamidere.lua','aa'),('luasense','Luasense','luasense (2) (1).lua','aa'),('resistance','Resistance','resistance.lua','aa'),('rinnegan','Rinnegan','rinnegan.lua','aa')]
originals=ROOT/'sources';originals.mkdir(exist_ok=True)
if not any(originals.glob('*.lua')):
    config=json.loads((ROOT/'bootstrap/package.json').read_text())
    encoded=''.join((ROOT/'bootstrap'/f'archive-{i:03}.b64').read_text() for i in range(config['parts']))
    blob=base64.b64decode(encoded,validate=True)
    assert hashlib.sha256(blob).hexdigest()==config['sha256']
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        for _,_,name,_ in META:
            data=z.read(name);(originals/name).write_bytes(data)
modules=ROOT/'modules';modules.mkdir(exist_ok=True)
def literal(text):
    eq='='
    while ']'+eq+']' in text:eq+='='
    return '['+eq+'[\n'+text+']'+eq+']'
# Quarantine a user-reported crashing recovery build; keep original for diagnosis.
BLOCKED={'annesty': 'User-reported client crash; recovery build not runtime-validated'}
manifest={'schema':1,'scripts':[]};audit=[]
for id,name,filename,group in META:
    raw=(originals/filename).read_bytes()
    # BOM is a file header; Lua loadstring does not accept it inside a string payload.
    source=raw.decode('utf-8-sig')
    wrapper='''local source=%s
local bridge
return {api_version=1,
 start=function(ctx)
  if not bridge then bridge=ctx:legacy(source,%s)end
  bridge:start(ctx)
 end,
 stop=function(ctx)if bridge then bridge:stop()end end}
'''%(literal(source),json.dumps('@sources/'+filename,ensure_ascii=False))
    target=modules/f'{id}.lua';target.write_text(wrapper,encoding='utf-8',newline='\n')
    digest=hashlib.sha256(target.read_bytes()).hexdigest()
    if id not in BLOCKED: manifest['scripts'].append({'id':id,'name':name,'version':digest[:12],'path':f'modules/{id}.lua','group':group,'legacy':True})
    audit.append({'id':id,'source':filename,'original_bytes':len(raw),'original_sha256':hashlib.sha256(raw).hexdigest(),'module_bytes':target.stat().st_size,'module_sha256':digest,'runtime_validation':BLOCKED.get(id,'not run in Gamesense'),'available_in_catalogue':id not in BLOCKED,'optimization':'managed lifecycle + repeated text metrics cache; donor algorithms unchanged'})
(ROOT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
(ROOT/'BUILD_REPORT.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2)+'\n')
print('Built',len(audit),'modules without executing donor code')
