#!/usr/bin/env python3
"""Generate synthetic inputs and exercise every advertised source/action pair."""
import argparse, concurrent.futures, hashlib, json, os, plistlib, shutil, subprocess, time, zipfile
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--source',type=Path,required=True)
parser.add_argument('--app',type=Path,default=Path('/Applications/rmconvert.app'))
parser.add_argument('--run',type=Path)
parser.add_argument('--retry-failures',action='store_true')
a=parser.parse_args()
root=(a.run or Path(__file__).parent/'runs'/time.strftime('%Y%m%d-%H%M%S')).resolve()
root.mkdir(parents=True,exist_ok=True)
fixtures=root/'fixtures';fixtures.mkdir(exist_ok=True)
cli=a.app/'Contents/MacOS/rmconvert'
manifest=json.loads((a.source/'Resources/manifest.json').read_text())
MAGICK='/opt/homebrew/bin/magick';FF='/opt/homebrew/bin/ffmpeg';PROBE='/opt/homebrew/bin/ffprobe'
SOFFICE='/Applications/LibreOffice.app/Contents/MacOS/soffice'
MARK='Conversion matrix 123'
env=dict(os.environ,RMCONVERT_LOG_DIRECTORY=str(root/'job-logs'))

def run(args,timeout=180):
    r=subprocess.run(list(map(str,args)),capture_output=True,text=True,timeout=timeout,env=env)
    if r.returncode: raise RuntimeError(f'{Path(str(args[0])).name}: {r.stderr[-1200:]} {r.stdout[-500:]}')
    return r.stdout

def write(ext,text):
    p=fixtures/('sample.'+ext);p.write_text(text);return p

def office(source,ext):
    profile=root/'profiles'/ext;out=root/'office'/ext;out.mkdir(parents=True,exist_ok=True)
    run([SOFFICE,'-env:UserInstallation='+profile.as_uri(),'--headless','--nologo','--nodefault','--norestore','--convert-to',ext,'--outdir',out,source])
    result=next(out.glob('*.'+ext));shutil.copy2(result,fixtures/('sample.'+ext))

def generate():
    for ext in ['jpg','png','tiff','heic','bmp','webp','gif','avif','psd']:
        run([MAGICK,'-size','96x64','gradient:red-blue','-depth','8',fixtures/('sample.'+ext)])
    write('svg','<svg xmlns="http://www.w3.org/2000/svg" width="96" height="64"><rect width="96" height="64" fill="blue"/></svg>')
    text=write('txt',MARK+'\nHello world.\n')
    for ext in ['doc','docx','rtf','rtfd','html']:
        run(['/usr/bin/textutil','-convert',ext,'-output',fixtures/('sample.'+ext),text])
    write('html','<!doctype html><html><head><title>Test</title></head><body><h1>'+MARK+'</h1><p>Hello world.</p></body></html>')
    md=write('md','# '+MARK+'\n\nHello **world**.\n')
    write('rst',MARK+'\n'+'='*len(MARK)+'\n\nHello world.\n')
    write('tex','\\documentclass{article}\n\\begin{document}\n'+MARK+'\n\\end{document}\n')
    for ext in ['odt','epub']:run(['/opt/homebrew/bin/pandoc',md,'-o',fixtures/('sample.'+ext)])
    csv=write('csv','Name,Count\nExample,123\nSecond,456\n')
    write('tsv','Name\tCount\nExample\t123\nSecond\t456\n')
    office(csv,'xlsx');office(fixtures/'sample.xlsx','xls');office(fixtures/'sample.xlsx','ods')
    # Use the project's independently generated two-slide fixture definition.
    code=(a.source/'tests/office_layouts.py').read_text().split('# Minimal OpenDocument presentation',1)[1]
    code=code[code.index('\n')+1:].split("folder=job(odp,'png')",1)[0]
    exec(code,{'root':fixtures,'zipfile':zipfile})
    (fixtures/'Two slides.odp').rename(fixtures/'sample.odp')
    office(fixtures/'sample.odp','pptx');office(fixtures/'sample.odp','ppt')
    write('json','{"name":"Example","count":123}')
    (fixtures/'records.json').write_text('[{"Name":"Example","Count":123},{"Name":"Second","Count":456}]')
    write('yaml','name: Example\ncount: 123\n');write('toml','name = "Example"\ncount = 123\n')
    write('xml','<root><name>Example</name><count>123</count></root>')
    (fixtures/'sample.plist').write_bytes(plistlib.dumps({'name':'Example','count':123}))
    (fixtures/'binary.plist').write_bytes(plistlib.dumps({'name':'Example','count':123},fmt=plistlib.FMT_BINARY))
    codecs={'mp4':('libx264','aac'),'mov':('libx264','aac'),'mkv':('libx264','aac'),'avi':('mpeg4','libmp3lame'),'webm':('libvpx-vp9','libopus'),'m4v':('libx264','aac'),'flv':('flv','libmp3lame'),'wmv':('wmv2','wmav2')}
    for ext,(video,audio) in codecs.items():
        args=[FF,'-v','error','-y','-f','lavfi','-i','testsrc2=size=96x64:rate=10:duration=1','-f','lavfi','-i','sine=frequency=440:duration=1','-c:v',video,'-pix_fmt','yuv420p','-c:a',audio]
        if ext=='m4v':args+=['-f','mp4']
        run(args+[fixtures/('sample.'+ext)])
    for ext,codec in {'mp3':'libmp3lame','wav':'pcm_s16le','flac':'flac','aiff':'pcm_s16be','m4a':'aac','ogg':'vorbis','opus':'libopus','wma':'wmav2'}.items():
        run([FF,'-v','error','-y','-f','lavfi','-i','sine=frequency=440:duration=1','-c:a',codec,'-ac','2','-strict','-2',fixtures/('sample.'+ext)])
    write('srt','1\n00:00:00,000 --> 00:00:00,800\n'+MARK+'\n')
    write('vtt','WEBVTT\n\n00:00.000 --> 00:00.800\n'+MARK+'\n')
    run([FF,'-v','error','-y','-i',fixtures/'sample.srt',fixtures/'sample.ass'])
    r=json.loads(run([cli,'--to','pdf','--',fixtures/'sample.txt']))
    single=Path(r['results'][0]['outputs'][0]);multi=fixtures/'two-pages.pdf'
    run(['/opt/homebrew/bin/qpdf','--empty','--pages',single,'1',single,'1','--',multi]);multi.replace(single)
    (fixtures/'ready').write_text('All fixtures generated\n')

def digest(p):
    files=sorted(p.rglob('*')) if p.is_dir() else [p]
    return [(str(f.relative_to(p)) if p.is_dir() else p.name,hashlib.sha256(f.read_bytes()).hexdigest()) for f in files if f.is_file()]

def validate(p,target):
    if p.is_dir():
        files=list(p.rglob('*'));assert any(f.is_file() for f in files),'Empty output folder'
        if target=='rtfd': assert (p/'TXT.rtf').is_file(),'Missing RTFD text';return
        for f in files:
            if f.is_file() and f.suffix.lower().lstrip('.')==target:validate(f,target)
        return
    assert p.stat().st_size>0,'Empty output file'
    if target=='pdf':run(['/opt/homebrew/bin/qpdf','--check',p])
    elif target in ['jpg','png','tiff','heic','webp','avif','ico']:
        dimensions=run([MAGICK,'identify','-format','%w %h',str(p)+'[0]']).strip().split()
        assert len(dimensions)==2 and min(map(int,dimensions))>0,'Invalid image dimensions'
    elif target=='icns':assert p.read_bytes()[:4]==b'icns','Invalid ICNS header'
    elif target in ['mp4','mov','mkv','webm','gif','mp3','m4a','wav','flac','aiff','m4r']:
        streams=json.loads(run([PROBE,'-v','error','-show_streams','-of','json',p]))['streams']
        expected='video' if target in ['mp4','mov','mkv','webm','gif'] else 'audio'
        assert any(s['codec_type']==expected for s in streams),'Missing expected stream'
        run([FF,'-v','error','-i',p,'-f','null','-'])
    elif target in ['docx','xlsx','epub']:
        with zipfile.ZipFile(p) as z:assert z.testzip() is None,'Corrupt package'
    elif target in ['doc','rtf','rtfd']:assert MARK in run(['/usr/bin/textutil','-convert','txt','-stdout',p]),'Missing text'
    elif target=='json':json.loads(p.read_text())
    elif target in ['yaml','toml']:json.loads(run(['/opt/homebrew/bin/yq','-p',target,'-o','json','.',p]))
    elif target=='xml':
        import xml.etree.ElementTree as ET
        ET.fromstring(p.read_bytes())
    elif target=='plist':plistlib.loads(p.read_bytes())
    else:assert p.read_text().strip(),'Empty text output'

def case(pair):
    action,ext=pair;folder=root/'cases'/(action+'--'+ext);folder.mkdir(parents=True,exist_ok=True)
    info=next(x for x in manifest['actions'] if x['id']==action);target=info.get('outputFormat') or 'pdf'
    source=fixtures/('records.json' if action=='convert.csv' and ext=='json' else 'binary.plist' if action=='plist.xml' else 'sample.'+ext)
    local=folder/('input.'+ext)
    if local.exists():
        if local.is_dir():shutil.rmtree(local)
        else:local.unlink()
    shutil.copytree(source,local) if source.is_dir() else shutil.copy2(source,local)
    originals=[local];args=[cli,'--action',action]
    if info.get('needsPages'):args+=['--pages','1']
    if info.get('minimumCount',1)>1:
        second=folder/('second.'+ext);shutil.copy2(source,second);originals.append(second)
    before=[digest(p) for p in originals]
    started=time.monotonic()
    result={'action':action,'source':ext,'target':target}
    try:
        report=json.loads(run(args+['--']+originals,timeout=650))
        assert all(r['status']!='failed' for r in report['results']),report
        outputs=[Path(p) for r in report['results'] for p in r['outputs']]
        same=action.startswith('convert.') and ext==target
        assert outputs or same or action=='pdf.compress','Missing output'
        for p in outputs:validate(p,target)
        if ext == 'pdf' and action.startswith('pdf.'):
            for output in outputs:
                pdfs = sorted(output.glob('*.pdf')) if output.is_dir() else [output]
                for pdf in pdfs:
                    assert MARK in run(['/opt/homebrew/bin/pdftotext',pdf,'-']), 'PDF text was lost'

        assert [digest(p) for p in originals]==before,'Original changed'
        result.update(status='skipped-same-format' if same else 'passed',outputs=len(outputs))
    except Exception as e:result.update(status='FAILED',error=str(e)[-2200:])
    result['seconds']=round(time.monotonic()-started,2)
    (folder/'result.json').write_text(json.dumps(result,indent=2))
    print(result['status'],action,ext,flush=True)
    return result

if not (fixtures/'ready').exists():generate()
pairs=sorted(set((r['action'],ext) for r in manifest['routes'] for ext in r['from']))
previous={}
if a.retry_failures and (root/'results.json').exists():
    previous={(r['action'],r['source']):r for r in json.loads((root/'results.json').read_text())}
    pairs=[p for p in pairs if previous.get(p,{}).get('status')=='FAILED']
print('RUN',root,'cases',len(pairs),flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    for result in pool.map(case,pairs):previous[(result['action'],result['source'])]=result
results=sorted(previous.values(),key=lambda x:(x['source'],x['action']))
(root/'results.json').write_text(json.dumps(results,indent=2))
failures=[r for r in results if r['status']=='FAILED']
summary={'sourceTypes':len(set(r['source'] for r in results)),'cases':len(results),'passed':sum(r['status']=='passed' for r in results),'sameFormatSkips':sum(r['status']=='skipped-same-format' for r in results),'failed':len(failures)}
(root/'summary.json').write_text(json.dumps(summary,indent=2))
lines=['# Conversion matrix results','',json.dumps(summary),'','| Source | Action | Result |','|---|---|---|']+[f"| {r['source']} | {r['action']} | {r['status']} |" for r in results]
(root/'REPORT.md').write_text('\n'.join(lines)+'\n')
print(json.dumps(summary),flush=True)
for r in failures:print('FAILURE',r,flush=True)
raise SystemExit(bool(failures))
