import json
from pathlib import Path

actions, routes = [], []
def action(id, label, menu='Convert', group=10, order=0, output=None, minimum=1, maximum=None, same=False, current=False, pages=False):
    actions.append(dict(id=id,label=label,menu=menu,group=group,order=order,outputFormat=output,minimumCount=minimum,maximumCount=maximum,sameDirectory=same,showCurrent=current,needsPages=pages))
def route(id, sources, handler, backend='native', **extra):
    routes.append(dict(action=id,from_=sources,handler=handler,backend=backend,priority=10,label=None,group=None,options={},**extra))
images=['jpg','png','tiff','heic','bmp','webp','gif','avif','psd']
for index, (ext, name) in enumerate([('jpg','JPEG'),('png','PNG'),('heic','HEIC'),('tiff','TIFF')]):
    action('convert.'+ext,name,order=index,output=ext,current=True)
    route('convert.'+ext,images,'image')
for ext,name in [('webp','WebP'),('avif','AVIF'),('icns','ICNS'),('ico','ICO')]:
    action('convert.'+ext,name,group=40 if ext in ['icns','ico'] else 10,order=8,output=ext,current=True)
    route('convert.'+ext,images,'image.extra','magick')
    if ext in ['icns','ico']: routes[-1]['options']['note']='The image is fitted without cropping; small images are upscaled to supply standard icon sizes.'
action('convert.pdf','PDF',group=20,output='pdf')
route('convert.pdf',images,'image.pdf')
routes[-1]['label']='PDF, one per image'
for ext in ['png','jpg','pdf']:
    route('convert.'+ext,['svg'],'image.extra','magick')
    if ext=='pdf': routes[-1]['label']='PDF, rasterised'
action('pdf.combine-images','Combine into one PDF',menu='PDF',output='pdf',minimum=2,same=True)
route('pdf.combine-images',images,'image.pdf')
action('pdf.combine','Combine PDFs',menu='PDF',output='pdf',minimum=2,same=True)
route('pdf.combine',['pdf'],'pdf')
for index,(id,name,pages) in enumerate([('split','Split into separate PDFs',False),('extract','Extract pages…',True),('remove','Remove pages…',True),('rotate-right','Rotate clockwise',False),('rotate-left','Rotate anticlockwise',False)]):
    action('pdf.'+id,name,menu='PDF',group=20 if index<3 else 30,order=index,output='pdf',maximum=1 if pages else None,pages=pages)
    route('pdf.'+id,['pdf'],'pdf')
for ext in ['png','jpg']:
    route('convert.'+ext,['pdf'],'pdf.raster','pdftoppm')
    routes[-1]['label']=('PNG' if ext=='png' else 'JPEG')+', one per page'
action('convert.txt','Plain text',order=20,output='txt',current=True)
route('convert.txt',['pdf'],'pdf.text','pdftotext')
action('pdf.compress','Compress PDF',menu='PDF',group=40,output='pdf')
route('pdf.compress',['pdf'],'pdf.compress','qpdf')
route('convert.pdf',['docx','doc','odt','rtf','txt','pptx','ppt','odp','xlsx','xls','ods'],'office','soffice')
routes[-1]['group']=0
route('convert.png',['pptx','ppt','odp'],'office.raster','soffice')
routes[-1]['requires']=['pdftoppm']
routes[-1]['label']='PNG, one per slide'
route('convert.pdf',['rtfd'],'rtfd.pdf','soffice')
route('convert.pdf',['md','html','epub'],'pandoc.pdf','pandoc')
routes[-1]['requires']=['soffice']
for ext,name in [('md','Markdown'),('html','HTML'),('rtf','RTF'),('doc','DOC'),('docx','DOCX'),('rtfd','RTFD'),('epub','EPUB'),('csv','CSV'),('tsv','TSV'),('json','JSON'),('yaml','YAML'),('toml','TOML'),('xml','XML'),('xlsx','XLSX')]:
    action('convert.'+ext,name,order=30,output=ext,current=True)
for ext in ['txt','rtf','doc','docx','rtfd','html']:
    route('convert.'+ext,['txt','rtf','rtfd','doc','docx','html'],'textutil','textutil')
for ext in ['md','html','txt']:
    route('convert.'+ext,['docx','odt','html','epub','rst','tex','md'],'pandoc','pandoc')
    routes[-1]['priority']=5
route('convert.epub',['md','html','docx','odt'],'pandoc','pandoc')
route('convert.csv',['xlsx','xls','ods'],'office','soffice')
routes[-1]['label']='CSV, one per sheet'
route('convert.xlsx',['csv','tsv'],'office','soffice')
for ext in ['csv','tsv','json','md']:
    route('convert.'+ext,['csv','tsv'],'data')
for ext in ['yaml','xml','csv','toml']:
    route('convert.'+ext,['json'],'data','native' if ext in ['csv','xml'] else 'yq')
route('convert.json',['yaml','toml'],'data','yq')
route('convert.json',['xml'],'data')
routes[-1]['options']['note']='XML elements keep their names; attributes use @name and leaf text stays a string. Repeated elements become ordered arrays; mixed content and namespaces are rejected.'
for entry in routes:
    if entry['action']=='convert.csv' and 'json' in entry['from_']: entry['options']['note']='Missing and null JSON fields both become empty CSV cells.'
for encoding,name in [('xml','XML property list'),('binary','Binary property list')]:
    action('plist.'+encoding,name,output='plist')
    route('plist.'+encoding,['plist'],'plist')
videos=['mov','mp4','mkv','avi','webm','m4v','flv','wmv']
audio=['mp3','wav','flac','aiff','m4a','ogg','opus','wma']
for ext,name in [('mp4','MP4'),('mov','MOV'),('mkv','MKV'),('webm','WebM'),('gif','GIF'),('mp3','MP3'),('m4a','M4A'),('wav','WAV'),('flac','FLAC'),('aiff','AIFF'),('m4r','Ringtone, first 40 seconds'),('srt','SRT'),('vtt','WebVTT')]:
    action('convert.'+ext,name,order=10,output=ext,current=True)
    if ext in ['srt','vtt']: sources=['srt','vtt','ass']
    elif ext=='m4r': sources=['mp3','m4a','wav']
    elif ext in ['mp3','m4a','wav','flac','aiff']: sources=videos+audio
    else: sources=videos+(['gif'] if ext=='mp4' else [])
    route('convert.'+ext,sources,'media','ffmpeg')
    routes[-1]['requires']=['ffprobe']
    if ext in ['mp3','m4a','wav','flac','aiff']:
        routes[-1]['options']['note']='One file per audio track for video inputs.'
for item in routes: item['from']=item.pop('from_')
Path('Resources/manifest.json').write_text(json.dumps(dict(schemaVersion=3,actions=actions,routes=routes),indent=2)+'\n')
