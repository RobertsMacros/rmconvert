#!/usr/bin/env python3
import json, os, subprocess, tempfile, zipfile, re, math
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='rmconvert-office-layouts-',dir='/private/tmp'))
cli=Path(f'/private/tmp/rmconvert-build-{os.getuid()}/rmconvert.app/Contents/MacOS/rmconvert')
env=dict(os.environ,RMCONVERT_LOG_DIRECTORY=str(root/'logs'))
checks=0

def check(ok,label):
 global checks
 assert ok,label
 checks+=1;print('PASS',label,flush=True)
def job(p,target):
 r=subprocess.run([str(cli),'--to',target,'--',str(p)],env=env,text=True,capture_output=True,timeout=650)
 assert r.returncode==0,(r.stderr,r.stdout)
 return Path(json.loads(r.stdout)['results'][0]['outputs'][0])
workbook=root/'Three sheets.xlsx'
ns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'
with zipfile.ZipFile(workbook,'w') as z:
 z.writestr('[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'+''.join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' for i in range(1,4))+'</Types>')
 z.writestr('_rels/.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
 z.writestr('xl/workbook.xml',f'<workbook xmlns="{ns}" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Visible" sheetId="1" r:id="rId1"/><sheet name="Hidden" state="hidden" sheetId="2" r:id="rId2"/><sheet name="Empty" sheetId="3" r:id="rId3"/></sheets></workbook>')
 z.writestr('xl/_rels/workbook.xml.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+''.join(f'<Relationship Id="rId{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i}.xml"/>' for i in range(1,4))+'</Relationships>')
 for i,label in enumerate(['Visible value','Hidden value',''],1):
  row=f'<row r="1"><c r="A1" t="inlineStr"><is><t>{label}</t></is></c></row>' if label else ''
  z.writestr(f'xl/worksheets/sheet{i}.xml',f'<worksheet xmlns="{ns}"><sheetData>{row}</sheetData></worksheet>')
folder=job(workbook,'csv');files=list(folder.glob('*.csv'))
check(len(files)==3,'workbook exports visible, hidden and empty sheets')
check(any('Hidden' in p.name and 'Hidden value' in p.read_text() for p in files),'hidden sheet named and included')
check(any('Empty' in p.name for p in files),'empty sheet named and included')
pdf=job(workbook,'pdf');text=subprocess.check_output(['/opt/homebrew/bin/pdftotext',str(pdf),'-'],text=True)
check('Visible value' in text and 'Hidden value' not in text,'PDF follows visible sheet print layout')
# Minimal OpenDocument presentation with two independent slide labels.
nsdoc='xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"'
slides=''.join(f'<draw:page draw:name="Slide {i}" draw:master-page-name="Default"><draw:frame svg:x="2cm" svg:y="2cm" svg:width="15cm" svg:height="5cm"><draw:text-box><text:p>Slide {i}</text:p></draw:text-box></draw:frame></draw:page>' for i in [1,2])
odp=root/'Two slides.odp'
with zipfile.ZipFile(odp,'w') as z:
 z.writestr('mimetype','application/vnd.oasis.opendocument.presentation')
 z.writestr('content.xml',f'<office:document-content {nsdoc} office:version="1.2"><office:body><office:presentation>{slides}</office:presentation></office:body></office:document-content>')
 z.writestr('styles.xml',f'<office:document-styles {nsdoc} office:version="1.2"><office:automatic-styles><style:page-layout style:name="PM1"><style:page-layout-properties fo:page-width="28cm" fo:page-height="21cm" style:print-orientation="landscape"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name="Default" style:page-layout-name="PM1"/></office:master-styles></office:document-styles>')
 z.writestr('META-INF/manifest.xml','<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.presentation"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/><manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/></manifest:manifest>')
folder=job(odp,'png');check(len(list(folder.glob('*.png')))==2,'one PNG per presentation slide')
pdf=job(odp,'pdf')
info=subprocess.check_output(['/opt/homebrew/bin/pdfinfo',str(pdf)],text=True)
size=re.search(r'Page size:\s+([0-9.]+) x ([0-9.]+)',info)
expected=[float(v)*300/72 for v in size.groups()]
actual=list(map(int,subprocess.check_output(['/opt/homebrew/bin/magick','identify','-format','%wx%h',str(next(folder.glob('*.png')))],text=True).split('x')))
check(all(abs(a-e)<=1 for a,e in zip(actual,expected)),'slide images match the PDF export dimensions at 300 dpi')
print(f'PASS: {checks} office-layout checks. Fixtures: {root}',flush=True)
