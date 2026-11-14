"""Check exported audio pulses against simultaneous video flashes."""
import array,json,subprocess,sys,math
from pathlib import Path
p=Path(sys.argv[1])
for name,offset,markers in [('export-long.mp4',360,[362.5,363.5]),('export-dissolve.mp4',0,[3.2,4.2])]:
 file=p/name
 info=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-of','json',str(file)]))
 video=next(s for s in info['streams'] if s['codec_type']=='video')
 a,b=map(int,video['r_frame_rate'].split('/'));fps=a/b
 raw=subprocess.check_output(['ffmpeg','-v','error','-ss',str(offset),'-i',str(file),'-vn','-ac','1','-ar','2000','-f','f32le','-'])
 audio=array.array('f');audio.frombytes(raw)
 bins=[math.sqrt(sum(x*x for x in audio[i:i+20])/20) for i in range(0,len(audio)-20,20)]
 pixels=subprocess.check_output(['ffmpeg','-v','error','-ss',str(offset),'-i',str(file),'-an','-vf','scale=1:1','-pix_fmt','gray','-f','rawvideo','-'])
 for expected in markers:
  audio_candidates=[offset+i*.01 for i,v in enumerate(bins) if v>.1 and abs(offset+i*.01-expected)<.2]
  video_candidates=[offset+i/fps for i,v in enumerate(pixels) if v>128 and abs(offset+i/fps-expected)<.2]
  assert audio_candidates and video_candidates,(name,expected,'missing marker')
  at=min(audio_candidates);vt=min(video_candidates)
  assert abs(at-vt)<.04,(name,expected,at,vt)
  assert abs(at-expected)<.04 and abs(vt-expected)<.04,(name,expected,at,vt)
  print('PASS exported AV sync:',name,'marker',expected,'audio',round(at,4),'video',round(vt,4),'difference',round(at-vt,4))
