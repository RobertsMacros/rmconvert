#!/usr/bin/env python3
import csv
import hashlib
import json
import os
import plistlib
import subprocess
import tempfile
import zipfile
from pathlib import Path

root = Path(tempfile.mkdtemp(prefix='rmconvert-routes-', dir=os.environ.get('RMCONVERT_TEST_ROOT','/private/tmp')))
app = Path(os.environ.get('RMCONVERT_TEST_APP',f'/private/tmp/rmconvert-build-{os.getuid()}/rmconvert.app'))
cli = app / 'Contents/MacOS/rmconvert'
env = dict(os.environ, RMCONVERT_LOG_DIRECTORY=str(root/'logs'))
checks = 0
originals = {}

def fixture(name, contents):
    path = root/name
    path.write_text(contents)
    originals[path] = hashlib.sha256(path.read_bytes()).hexdigest()
    return path

def check(value, name):
    global checks
    assert value, name
    checks += 1
    print('PASS', name, flush=True)

def job(source, target, action=False, fails=False):
    run = subprocess.run([str(cli), '--action' if action else '--to', target, '--', str(source)], env=env, text=True, capture_output=True, timeout=650)
    report = json.loads(run.stdout)
    if fails:
        check(run.returncode == 1, 'reject '+target)
        return report
    assert run.returncode == 0, (target, run.stderr, report)
    check(True, source.suffix+' to '+target)
    outputs = [Path(output) for result in report['results'] for output in result['outputs']]
    return outputs[0] if outputs else None

text = fixture("O'Brien & Sons.txt", 'Roberts Macros test\n\nThe quick brown fox.\n')
docx = job(text, 'docx')
check(zipfile.is_zipfile(docx), 'DOCX structure')
pdf = job(text, 'pdf')
out = subprocess.check_output(['/opt/homebrew/bin/pdftotext',str(pdf),'-'], text=True)
check('The quick brown fox' in out, 'Office PDF text')
for target in ['md','html','txt']:
    result = job(docx, target)
    file = next(result.glob('*.'+target)) if result.is_dir() else result
    check('quick brown fox' in file.read_text(), 'Pandoc '+target+' content')
md = fixture('Notes.md', '# A test document\n\nSome **bold** text.\n')
check(zipfile.is_zipfile(job(md,'epub')), 'EPUB structure')
check(job(md,'pdf').is_file(), 'Markdown PDF pipeline')
rtf = job(text,'rtf')
rtfd = job(rtf,'rtfd')
check(rtfd.is_dir(), 'RTFD package')
check(job(rtfd,'pdf').is_file(), 'RTFD PDF pipeline')
table = fixture('Rows.csv', 'ID,Value,Note\r\n001,=1+1,"hello, world"\r\n002,@example,"two\nlines"\r\n')
records = json.loads(job(table,'json').read_text())
check(records[0]['ID']=='001' and records[0]['Value']=='=1+1' and records[1]['Note']=='two\nlines', 'CSV cells remain strings')
tsv = job(table,'tsv')
check(json.loads(job(tsv,'json').read_text())==records, 'CSV TSV round trip')
check('| ID |' in job(table,'md').read_text(), 'Markdown table')
xlsx = job(table,'xlsx')
with zipfile.ZipFile(xlsx) as archive:
    sheet = archive.read('xl/worksheets/sheet1.xml').decode()
    check('<f>' not in sheet, 'CSV formula-like cells are not formulas')
export = job(xlsx,'csv')
with next(export.glob('*.csv')).open(newline='') as handle:
    exported = list(csv.DictReader(handle))
check(exported[0]['ID']=='001' and exported[0]['Value']=='=1+1', 'Workbook CSV values')
data = fixture('Records.json','[{"b":2,"a":"001"},{"c":null,"a":"002"}]')
with job(data,'csv').open(newline='') as handle:
    output = list(csv.reader(handle))
check(output[0]==['a','b','c'] and output[1][0]=='001', 'JSON CSV union headers')
object_file = fixture('Settings.json','{"name":"Example","enabled":true,"count":3}')
for target in ['yaml','toml']:
    output = job(object_file,target)
    restored = json.loads(job(output,'json').read_text())
    check(restored==json.loads(object_file.read_text()), 'JSON '+target+' round trip')
check('<name>Example</name>' in job(object_file,'xml').read_text(), 'XML mapping')
nested = fixture('Nested.json','[{"name":{"nested":true}}]')
job(nested,'csv',fails=True)
bad_table = fixture('Bad.csv','a,a\n1,2\n')
job(bad_table,'json',fails=True)
settings = root/'Example.plist'
settings.write_bytes(plistlib.dumps({'enabled':True,'data':b'abc','count':3}))
binary = job(settings,'plist.binary',action=True)
check(binary.read_bytes().startswith(b'bplist00'), 'binary plist encoding')
xml = job(binary,'plist.xml',action=True)
check(plistlib.loads(xml.read_bytes())==plistlib.loads(settings.read_bytes()), 'plist values preserved')
check('quick brown fox' in job(pdf,'txt').read_text(), 'PDF text extraction')
for target in ['png','jpg']:
    pages = job(pdf,target)
    check(len(list(pages.iterdir()))==1, 'PDF one image per page '+target)
compressed = job(pdf,'pdf.compress',action=True)
check(compressed is None or compressed.stat().st_size < pdf.stat().st_size, 'compression only publishes smaller PDF')
for path, digest in originals.items():
    check(hashlib.sha256(path.read_bytes()).hexdigest()==digest, 'original kept '+path.name)
print(f'PASS: {checks} external-route checks. Fixtures: {root}', flush=True)
