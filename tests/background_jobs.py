#!/usr/bin/env python3
"""Exercise the installed app's document-open worker with generated files."""
import argparse,json,os,shutil,subprocess,time,uuid
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--request-origin', choices=['extension','app'], default='extension');p.add_argument('--request-only',action='store_true');p.add_argument('--app',type=Path,default=Path('/Applications/rmconvert.app'));p.add_argument('--fixture',type=Path,required=True);p.add_argument('--root',type=Path,required=True);a=p.parse_args()
a.root.mkdir(parents=True,exist_ok=True)
requests=Path.home()/'Library/Containers/com.robertsmacros.rmconvert.Finder/Data/Library/Application Support/rmconvert/Requests'
if a.request_origin == 'app': requests=Path.home()/'Library/Application Support/rmconvert/Requests'
requests.mkdir(parents=True,exist_ok=True,mode=0o700)
logs=Path.home()/'Library/Logs/rmconvert'
for invalid in [False,True]:
 token=uuid.uuid4().hex;source=a.root/('background-'+token+'.png')
 if invalid:source.write_bytes(b'not an image')
 else:shutil.copy2(a.fixture,source)
 before=source.read_bytes()
 request=requests/(str(uuid.uuid4()).upper()+'.rmconvert-request')
 request.write_text(json.dumps({'action':'convert.jpg','paths':[str(source)],'pages':None}));request.chmod(0o600)
 start=time.time();subprocess.run(['/usr/bin/open','-g','-n','-a',str(a.app),str(request)]+([] if a.request_only else [str(source)]),check=True)
 report=None
 while time.time()-start<60:
  for f in logs.glob('*.json'):
   if f.stat().st_mtime<start:continue
   try:record=json.loads(f.read_text())
   except (ValueError,OSError):continue
   if any(r['input']==str(source) for r in record['results']):report=record;break
  if report:break
  time.sleep(.2)
 assert report,'Worker did not finish the document-open job within 60 seconds'
 result=next(r for r in report['results'] if r['input']==str(source))
 assert result['status']==('failed' if invalid else 'converted'),result
 assert source.read_bytes()==before,'Source changed'
 if not invalid:assert all(Path(f).is_file() for f in result['outputs'])
 (a.root/('failure.json' if invalid else 'success.json')).write_text(json.dumps({'status':result['status'],'elapsed':round(time.time()-start,2)},indent=2))
 print('PASS background document-open',result['status'],flush=True)
 time.sleep(1)
