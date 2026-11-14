from pathlib import Path
import subprocess,wave,array,math,sys
p=Path(sys.argv[1])
for name,rate,duration in [('lead48',48000,362),('lead44',44100,362),('tail44',44100,2),('tail48',48000,2),('tail32',32000,2),('tail96',96000,2)]:
 wav=p/(name+'.wav')
 with wave.open(str(wav),'wb') as w:
  w.setnchannels(1);w.setsampwidth(2);w.setframerate(rate)
  for second in range(duration):
   data=array.array('h',[0])*rate
   if second in [0,duration-1]:
    for n in range(rate//2,rate*3//5):data[n]=int(22000*math.sin(2*math.pi*880*n/rate))
   w.writeframes(data.tobytes())
 expression=f"between(t,0.5,0.6)+between(t,{duration-0.5},{duration-0.4})"
 vf=f"drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='{expression}'"
 subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i',f'color=c=black:s=160x90:r=30:d={duration}',
  '-i',str(wav),'-vf',vf,'-c:v','libx264','-preset','ultrafast','-crf','18','-c:a','aac','-ar',str(rate),'-shortest',str(p/(name+'.mov')),'-y'],check=True)
 print(name,flush=True)

# Preserve a genuine nonzero audio start/edit-list offset as well.
subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=black:s=160x90:r=30:d=2.2',
 '-itsoffset','0.2','-i',str(p/'tail32.wav'),'-c:v','libx264','-preset','ultrafast',
 '-c:a','aac','-ar','32000',str(p/'offset32.mov'),'-y'],check=True)
