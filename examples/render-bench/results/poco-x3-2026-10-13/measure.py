import subprocess,pathlib,json,time,re,hashlib,sys
D='192.168.68.122:5555';PKG='dev.oriel.RenderBench';ROOT=pathlib.Path('/tmp/oriel-poco-results');APKS=pathlib.Path('/tmp/oriel-poco-apks')
def adb(*args,timeout=45,binary=False):
 data=subprocess.check_output(['rtk','proxy','adb','-s',D,*args],timeout=timeout,text=not binary)
 if binary and not data.startswith(b'\x89PNG\r\n\x1a\n'):
  print('Screenshot retry; received:',repr(data[:100]),flush=True)
  time.sleep(1)
  data=subprocess.check_output(['rtk','proxy','adb','-s',D,*args],timeout=timeout,text=False)
 return data
def shell(*args,**kw):return adb('shell',*args,**kw).strip()
def battery():return shell('dumpsys','battery')
def check_unplugged():
 b=battery()
 if re.search(r'(?:AC|USB|Wireless) powered: true',b):raise RuntimeError('Phone is on a charger; measurements stopped')
 return b
def save(name,data):
 (ROOT/name).write_text(json.dumps(data,indent=2)+'\n')
def install(mode):
 shell('am','force-stop',PKG)
 out=adb('install','-r',str(APKS/(mode+'.apk')),timeout=90)
 if 'Success' not in out:raise RuntimeError(out)
 print('installed',mode,flush=True)
def configure(env):
 shell('setprop','debug.oriel.env',"'"+env+"'")
 shell('settings','put','system','screen_off_timeout','600000')
 shell('input','keyevent','224')
 shell('wm','dismiss-keyguard')
def start():
 check_unplugged()
 shell('am','force-stop',PKG)
 shell('am','start','-n',PKG+'/dev.oriel.OrielLaunchActivity')
 time.sleep(4)
 capture=adb('exec-out','screencap','-p',binary=True)
 from PIL import Image
 import io
 im=Image.open(io.BytesIO(capture)).convert('RGB')
 if max(v[1] for v in im.getextrema())<20:raise RuntimeError('Screen capture is black; run invalid')
 (ROOT/f'{mode}-{kind}-start.png').write_bytes(capture)
def matching_processes():
 dump=shell('dumpsys','activity','processes')
 chunks=re.split(r'(?=^\s*\*APP\* UID )',dump,flags=re.M)
 out=[]
 for block in chunks:
  h=re.search(r'\*APP\* UID (\d+) ProcessRecord\{\S+ (\d+):([^\n]+)',block)
  pk=re.search(r'packageList=\{([^}]+)\}',block)
  if h and pk and PKG in pk.group(1).split(', '):
   out.append({'uid':int(h.group(1)),'pid':int(h.group(2)),'name':h.group(3).split('/')[0],'package_list':pk.group(1),'isolated':'ISOLATED' in block})
 return out
def memory(mode,sample):
 rows=[]
 for proc in matching_processes():
  dump=shell('dumpsys','meminfo',str(proc['pid']))
  (ROOT/f'memory-{mode}-{sample}-{proc["pid"]}.txt').write_text(dump+'\n')
  total=re.search(r'^\s*TOTAL\s+(\d+)\s+(\d+)\s+(\d+)\s+',dump,re.M)
  if not total:raise RuntimeError('Unable to parse memory TOTAL: '+dump[-1200:])
  proc.update(pss_kib=int(total.group(1)),private_dirty_kib=int(total.group(2)),private_clean_kib=int(total.group(3)))
  proc['private_kib']=proc['private_dirty_kib']+proc['private_clean_kib'];rows.append(proc)
 if not any(not p['isolated'] for p in rows):raise RuntimeError('Main app not found')
 if mode=='webview' and not any(p['isolated'] for p in rows):raise RuntimeError('Isolated WebView renderer not identified')
 return {'processes':rows,'combined_pss_mib':sum(p['pss_kib'] for p in rows)/1024,'combined_private_mib':sum(p['private_kib'] for p in rows)/1024}
def getreport(start_epoch):
 logs=adb('logcat','-d','-v','epoch','-t','5000')
 for line in reversed(logs.splitlines()):
  try:stamp=float(line.split()[0])
  except (ValueError,IndexError):continue
  if stamp<start_epoch:break
  m=re.search(r'(\{"renderer".*)',line)
  if m:
   try:return json.loads(m.group(1)),line
   except json.JSONDecodeError:continue
 return None,None
mode=sys.argv[1];kind=sys.argv[2]
install(mode)
if kind=='memory':
 configure('')
 before=check_unplugged();start();print(mode,'memory benchmark running',flush=True)
 time.sleep(60)
 capture=adb('exec-out','screencap','-p',binary=True)
 from PIL import Image
 import io
 im=Image.open(io.BytesIO(capture)).convert('RGB')
 if max(v[1] for v in im.getextrema())<20:raise RuntimeError('Memory endpoint screen is black; run invalid')
 (ROOT/f'memory-{mode}.png').write_bytes(capture)
 data={'renderer':mode,'method':'One GUI full suite; external memory after 60 and 76 seconds, after completion; isolated processes identified by ActivityManager packageList. Queries separate from power tests.','battery_before':before,'samples':[]}
 for i in range(2):
  if i:time.sleep(15)
  data['samples'].append(memory(mode,i))
 data['battery_after']=check_unplugged();data['apk_sha256']=hashlib.sha256((APKS/(mode+'.apk')).read_bytes()).hexdigest();save('memory-'+mode+'.json',data)
 print(mode,'MEMORY',[(x['combined_pss_mib'],x['combined_private_mib']) for x in data['samples']],flush=True)
 shell('am','force-stop',PKG)
else:
 configure('RENDER_BENCH=1 RENDER_BENCH_POWER=60 RENDER_BENCH_POWER_ONLY=1')
 before=check_unplugged();epoch=int(shell('date','+%s'));start();began=time.monotonic()
 print(mode,'power suite running; 60 seconds per scenario',flush=True)
 deadline=began+300;next_progress=began+45
 while time.monotonic()<deadline:
  time.sleep(10)
  report,line=getreport(epoch)
  if report is not None:
   data={'renderer':mode,'battery_before':before,'battery_after':check_unplugged(),'elapsed_s':time.monotonic()-began,'apk_sha256':hashlib.sha256((APKS/(mode+'.apk')).read_bytes()).hexdigest(),'report':report}
   save('power-'+mode+'.json',data);(ROOT/f'power-{mode}-report.txt').write_text(line+'\n')
   power=report.get('results',{}).get('power',[])
   if not power or any(p.get('plugged') or p.get('error') for p in power):raise RuntimeError('Invalid power samples: '+str(power))
   print(mode,'POWER',[(p['name'],p.get('mw'),p.get('fps'),p.get('charge_uah')) for p in power],flush=True)
   shell('am','force-stop',PKG);break
  if time.monotonic()>=next_progress:
   check_unplugged();print(mode,'power elapsed',round(time.monotonic()-began),'s',flush=True);next_progress+=45
 else:
  (ROOT/f'power-{mode}-timeout-logcat.txt').write_text(adb('logcat','-d','-v','epoch','-t','5000'))
  raise RuntimeError('No benchmark report before timeout')
