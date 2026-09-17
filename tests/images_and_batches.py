#!/usr/bin/env python3
import hashlib, json, os, shutil, subprocess, tempfile, time
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='rmconvert-images-batches-',dir=os.environ.get('RMCONVERT_TEST_ROOT','/private/tmp')))
cli=Path(os.environ.get('RMCONVERT_TEST_APP',f'/private/tmp/rmconvert-build-{os.getuid()}/rmconvert.app'))/'Contents/MacOS/rmconvert'
env=dict(os.environ,RMCONVERT_LOG_DIRECTORY=str(root/'logs'))
magick='/opt/homebrew/bin/magick'
checks=0

def check(ok,label):
    global checks
    assert ok,label
    checks+=1
    print('PASS',label,flush=True)

def job(paths,target,fails=False):
    if isinstance(paths,Path): paths=[paths]
    p=subprocess.run([str(cli),'--to',target,'--']+list(map(str,paths)),env=env,capture_output=True,text=True,timeout=1000)
    r=json.loads(p.stdout)
    assert p.returncode==(1 if fails else 0),(p.stderr,r)
    return r

def output(r): return Path(r['results'][0]['outputs'][0])
def dimensions(p): return subprocess.check_output([magick,'identify','-format','%wx%h',str(p)+'[0]'],text=True)
png=root/'Colours.png'
subprocess.run([magick,'-size','80x40','gradient:red-blue',str(png)],check=True)
source_hash=hashlib.sha256(png.read_bytes()).hexdigest()
for ext in ['webp','avif','icns','ico']:
    p=output(job(png,ext)); check(p.stat().st_size>0,ext+' valid output')
    if ext in ['webp','avif']: check(dimensions(p)=='80x40',ext+' dimensions')
svg=root/'Vector.svg';svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 40"><rect width="80" height="40" fill="red"/></svg>')
for ext in ['png','jpg','pdf']:
    p=output(job(svg,ext));check(p.is_file(),'SVG '+ext)
    if ext!='pdf':check(dimensions(p)=='1024x512','SVG ratio '+ext)
psd=root/'Layers.psd'
subprocess.run([magick,str(png),str(psd)],check=True)
p=output(job(psd,'png'));check(dimensions(p)=='80x40','PSD composite')
gif=root/'Animated.gif'
subprocess.run([magick,'-size','20x20','xc:red','xc:blue','-delay','10','-loop','0',str(gif)],check=True)
check(job(gif,'png',fails=True)['results'][0]['status']=='failed','animated image is rejected by static converter')
xml=root/'Data.xml';xml.write_text('<root id="a"><value>001</value><value>002</value></root>')
check(json.loads(output(job(xml,'json')).read_text())=={'root':{'@id':'a','value':['001','002']}},'XML attributes and repeated elements')
xml.write_text('<root>Before <b>bold</b> after</root>')
check(job(xml,'json',fails=True)['results'][0]['status']=='failed','mixed XML content rejected')
html=root/'Page.html';html.write_text('<html><body><h1>Local HTML</h1><p>Body text</p></body></html>')
check(output(job(html,'rtf')).stat().st_size>0,'HTML to RTF')
html.write_text('<html><img src="https://example.invalid/picture.png"></html>')
check(job(html,'rtf',fails=True)['results'][0]['status']=='failed','remote HTML resource rejected')
text=root/'Seed.txt';text.write_text('Batch conversion test\nRoberts Macros\n')
docx=output(job(text,'docx'))
batchdir=root/'Batch';batchdir.mkdir()
inputs=[]
for i in range(200):
    p=batchdir/f'Document {i:03}.docx';shutil.copyfile(docx,p);inputs.append(p)
t0=time.monotonic();r=job(inputs,'pdf');elapsed=time.monotonic()-t0
check(len(r['results'])==200 and all(x['status']=='converted' for x in r['results']),'200 Office documents converted')
check(all('batch of 20' in x['detail'] for x in r['results']),'Office jobs are batched in twenties')
for item in r['results']:
    subprocess.run(['/opt/homebrew/bin/qpdf','--check',item['outputs'][0]],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
check(True,'all 200 output PDFs pass independent validation')
check(all(p.read_bytes()==docx.read_bytes() for p in inputs),'all batch source files unchanged')
bad=batchdir/'Bad.docx';bad.write_bytes(b'broken zip')
r=job([inputs[0],bad,inputs[1]],'pdf',fails=True)
check(sum(x['status']=='converted' for x in r['results'])==2 and sum(x['status']=='failed' for x in r['results'])==1,'bad Office file does not stop good files')
check(hashlib.sha256(png.read_bytes()).hexdigest()==source_hash,'image original unchanged')
print(f'PASS: {checks} image and batch checks; 200-file run {elapsed:.1f}s. Fixtures: {root}',flush=True)
