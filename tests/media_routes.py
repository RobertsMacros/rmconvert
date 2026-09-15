#!/usr/bin/env python3
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

root=Path(tempfile.mkdtemp(prefix='rmconvert-media-',dir='/private/tmp'))
cli=Path(f'/private/tmp/rmconvert-build-{os.getuid()}/rmconvert.app/Contents/MacOS/rmconvert')
ffmpeg='/opt/homebrew/bin/ffmpeg'
ffprobe='/opt/homebrew/bin/ffprobe'
env=dict(os.environ,RMCONVERT_LOG_DIRECTORY=str(root/'logs'))
checks=0
def check(ok,label):
    global checks
    assert ok,label
    checks+=1
    print('PASS',label,flush=True)
def create(args):
    subprocess.run([ffmpeg,'-hide_banner','-loglevel','error','-n']+args,check=True,capture_output=True,timeout=90)
def probe(path):
    return json.loads(subprocess.check_output([ffprobe,'-v','error','-show_streams','-show_format','-of','json',str(path)]))
def job(path,target,fails=False):
    result=subprocess.run([str(cli),'--to',target,'--',str(path)],env=env,text=True,capture_output=True,timeout=650)
    report=json.loads(result.stdout)
    check(result.returncode==(1 if fails else 0), f'{path.suffix} to {target}: {report["results"] if result.returncode else "success"}')
    return None if fails else Path(report['results'][0]['outputs'][0])
def hashes(path,stream):
    data=json.loads(subprocess.check_output([ffprobe,'-v','error','-select_streams',stream,'-show_packets','-show_entries','packet=data_hash','-show_data_hash','sha256','-of','json',str(path)]))
    return [packet['data_hash'] for packet in data['packets']]
video=root/'two tracks.mov'
create(['-f','lavfi','-i','testsrc2=size=160x120:rate=15:duration=2','-f','lavfi','-i','sine=frequency=440:duration=2','-f','lavfi','-i','sine=frequency=660:duration=2','-map','0:v','-map','1:a','-map','2:a','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-b:a','128k',str(video)])
original=hashlib.sha256(video.read_bytes()).hexdigest()
for target in ['mp4','mkv']:
    output=job(video,target)
    streams=probe(output)['streams']
    check(sum(s['codec_type']=='audio' for s in streams)==2,'both audio tracks retained '+target)
    check(hashes(video,'a:0')==hashes(output,'a:0'),'AAC packets copied '+target)
webm=job(video,'webm')
streams=probe(webm)['streams']
check([s['codec_name'] for s in streams]==['vp9','opus','opus'],'WebM fallback codecs')
for target in ['mp3','m4a','wav']:
    output=job(video,target)
    files=sorted(output.glob('*.'+target))
    check(len(files)==2,'one file per audio track '+target)
    if target=='m4a': check(hashes(video,'a:0')==hashes(files[0],'a:0'),'extracted AAC packets copied')
wav=root/'tone.wav'
create(['-f','lavfi','-i','sine=frequency=440:duration=1','-c:a','pcm_s16le',str(wav)])
for target in ['flac','aiff','mp3','m4a','m4r']:
    output=job(wav,target)
    check(probe(output)['streams'][0]['channels']==1,'audio channels '+target)
flac=root/'tone.flac'
roundtrip=job(flac,'wav')
def decoded(path):
    return subprocess.check_output([ffmpeg,'-v','error','-i',str(path),'-f','s16le','-c:a','pcm_s16le','-'])
check(decoded(wav)==decoded(roundtrip),'FLAC decoded samples round trip')
gif=job(video,'gif')
check(probe(gif)['streams'][0]['codec_name']=='gif','GIF generated')
mp4=job(gif,'mp4')
check(probe(mp4)['streams'][0]['codec_name']=='h264','GIF animation to MP4')
silent=root/'silent.mov'
create(['-f','lavfi','-i','testsrc2=size=160x120:rate=15:duration=1','-c:v','libx264',str(silent)])
job(silent,'mp3',fails=True)
srt=root/'Captions.srt';srt.write_text('1\n00:00:00,000 --> 00:00:01,000\nHello, world.\n\n')
vtt=job(srt,'vtt')
check('Hello, world.' in vtt.read_text(),'subtitle text retained')
check(hashlib.sha256(video.read_bytes()).hexdigest()==original,'video original unchanged')
print(f'PASS: {checks} media checks. Fixtures: {root}',flush=True)
