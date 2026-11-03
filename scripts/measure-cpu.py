#!/usr/bin/env python3
"""Read-only macOS process counters; wake counters are not total scheduler wakeups."""
import argparse,ctypes,json,pathlib,subprocess,time
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('pid',type=int)
parser.add_argument('--warmup',type=float,default=30)
parser.add_argument('--duration',type=float,default=120)
parser.add_argument('--output',type=pathlib.Path,required=True)
args=parser.parse_args()
if args.duration<=0 or args.warmup<0:parser.error('invalid measurement duration')
class Usage(ctypes.Structure):
    _fields_=[('uuid',ctypes.c_uint8*16)]+[(name,ctypes.c_uint64) for name in ['user','system','pkg_idle_wakeups','interrupt_wakeups','pageins','wired','resident','footprint','start','exit','childuser','childsystem','childpkg','childinterrupt','childpageins','childelapsed','readbytes','writebytes']]
class Timebase(ctypes.Structure):
    _fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
lib=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
kernel=ctypes.CDLL('/usr/lib/libSystem.B.dylib')
base=Timebase()
if kernel.mach_timebase_info(ctypes.byref(base))!=0:raise RuntimeError('timebase unavailable')
command=subprocess.check_output(['ps','-p',str(args.pid),'-o','command='],text=True).strip()
def snap():
    u=Usage()
    if lib.proc_pid_rusage(args.pid,2,ctypes.byref(u))!=0:raise OSError(ctypes.get_errno(),'proc_pid_rusage')
    return {name:getattr(u,name) for name in ['user','system','pkg_idle_wakeups','interrupt_wakeups','readbytes','writebytes','pageins']}
print(f'PID {args.pid}: warmup {args.warmup}s; measuring {args.duration}s',flush=True)
time.sleep(args.warmup)
start=snap();started=time.monotonic();rows=[];last_print=0
while time.monotonic()-started<args.duration:
    time.sleep(min(10,max(0,args.duration-(time.monotonic()-started))))
    sample=snap();elapsed=time.monotonic()-started
    delta={k:sample[k]-start[k] for k in start}
    row={'seconds':elapsed,**delta,'cpu_percent':(delta['user']+delta['system'])*base.numer/base.denom/1e9/elapsed*100}
    rows.append(row)
    if elapsed-last_print>=29 or elapsed>=args.duration:
        print(f'{elapsed:.0f}s: {row["cpu_percent"]:.3f}% CPU',flush=True);last_print=elapsed
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(json.dumps({'pid':args.pid,'command':command,'warmup_seconds':args.warmup,'timebase_numer':base.numer,'timebase_denom':base.denom,'rows':rows},indent=2)+'\n')
print(args.output,flush=True)
