// SPDX-License-Identifier: GPL-3.0-only
// AppleSMC ABI informed by kamenlevi/MagHue and Weta-Technologies/JuiceLeft.
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <poll.h>
#include <time.h>
typedef struct { unsigned char a,b,c,d; unsigned short e; } Version;
typedef struct { unsigned short a,b; unsigned int c,d,e; } Limits;
typedef struct { unsigned int size,type; unsigned char attr; } Info;
typedef struct { unsigned int key; Version version; Limits limits; Info info; unsigned char result,status,command; unsigned int index; unsigned char bytes[32]; } Packet;
_Static_assert(sizeof(Packet)==80,"SMC ABI");
static io_connect_t connection;
static volatile sig_atomic_t stopped;
static void stop(int s) { (void)s; stopped=1; }
static int call(Packet *p) { Packet out={0}; size_t n=sizeof(out); kern_return_t k=IOConnectCallStructMethod(connection,2,p,sizeof(*p),&out,&n); if(k || out.result || n!=sizeof(out)) { fprintf(stderr,"SMC error kernel=0x%x result=0x%x size=%zu\n",k,out.result,n); return -1; } *p=out; return 0; }
static int led(int value) { Packet p={.key=0x41434c43,.command=9}; if(call(&p)||p.info.size!=1) return -1; p=(Packet){.key=0x41434c43,.command=value<0?5:6,.info.size=1}; if(value>=0) p.bytes[0]=value; if(call(&p)) return -1; return value<0?p.bytes[0]:0; }
static int connectSMC(void) { io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC")); if(!s)return -1; int r=IOServiceOpen(s,mach_task_self(),0,&connection); IOObjectRelease(s); return r; }
static void restore(void) {
 // Seed the expected charge color before releasing control (ACLC latch caveat).
 io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSmartBattery"));
 int color=4;
 if(s) { CFTypeRef full=IORegistryEntryCreateCFProperty(s,CFSTR("FullyCharged"),kCFAllocatorDefault,0); if(full) { if(CFGetTypeID(full)==CFBooleanGetTypeID() && CFBooleanGetValue(full))color=3; CFRelease(full); } IOObjectRelease(s); }
 led(color); usleep(300000); if(led(0)==0)fprintf(stderr,"Restored ACLC=0 (system)\n");
}
int main(int argc,char **argv) {
 if(argc<2 || argc>3 || (strcmp(argv[1],"read")&&strcmp(argv[1],"idle")&&strcmp(argv[1],"working")&&strcmp(argv[1],"finished")&&strcmp(argv[1],"demo")&&strcmp(argv[1],"watch"))) { fprintf(stderr,"usage: magdot read|idle|working|finished|demo [seconds 1..3600] | watch STATE_FILE\n"); return 64; }
 int watching=!strcmp(argv[1],"watch"); if(watching && argc!=3)return 64;
 char *end=NULL; long duration=(!watching && argc==3)?strtol(argv[2],&end,10):20;
 if(end && (*end || end==argv[2]))return 64;
 int seconds=watching?3600:(duration>=1 && duration<=3600?(int)duration:0); if(seconds<1||seconds>3600)return 64;
 if(connectSMC()) { fprintf(stderr,"Cannot open AppleSMC\n"); return 1; }
 int initial=led(-1); if(initial<0)return 1;
 if(!strcmp(argv[1],"read")){printf("ACLC=%d\n",initial);return 0;}
 if(geteuid()!=0){fprintf(stderr,"LED writes require macOS administrator authentication\n");return 77;}
 int lock=open("/var/run/magdot.lock",O_CREAT|O_RDWR|O_NOFOLLOW,0600); if(lock<0||flock(lock,LOCK_EX|LOCK_NB)){fprintf(stderr,"Another controller owns LED\n");return 1;}
 if(!strcmp(argv[1],"idle")){restore();return 0;}
 if(initial!=0 && initial!=3 && initial!=4){fprintf(stderr,"ACLC=%d: possible competing LED controller; refusing takeover\n",initial);return 1;}
 int pipefd[2]; if(pipe(pipefd))return 1;
 pid_t guardian=fork(); if(guardian<0)return 1;
 if(!guardian){ close(pipefd[1]); IOServiceClose(connection); if(connectSMC())_exit(1); struct pollfd p={pipefd[0],POLLIN,0}; char c; while(poll(&p,1,3000)>0 && read(pipefd[0],&c,1)==1){} restore(); _exit(0); }
 close(pipefd[0]); signal(SIGINT,stop);signal(SIGTERM,stop);signal(SIGHUP,stop);signal(SIGPIPE,SIG_IGN);
 int previous=initial,failed=0;
 for(int phase=0;!stopped && phase*0.75<seconds;phase++){
  if(watching) {
   char state[16]={0}; long expiry=0; FILE *f=fopen(argv[2],"r");
   if(f){if(fscanf(f,"%15s %ld",state,&expiry)!=2)expiry=0;fclose(f);}
   long now=time(NULL);
   int mode=(expiry>=now && expiry<=now+10)?(!strcmp(state,"working")?1:!strcmp(state,"finished")?2:0):0;
   if(!mode){if(previous!=0){restore();previous=0;} if(write(pipefd[1],".",1)!=1)break;usleep(750000);continue;}
   if(previous==0)previous=led(-1);
   else if(led(-1)!=previous){fprintf(stderr,"LED ownership changed; stopping\n");failed=1;break;}
   // The state file carries only a bounded enum, never executable input.
   seconds=3600;
   int value=phase%2?(mode==2?1:4):3;
   if(led(value)){failed=1;break;}previous=value;
   if(write(pipefd[1],".",1)!=1)break;usleep(750000);continue;
  }
  int current=led(-1); if(current!=previous){fprintf(stderr,"LED ownership changed; stopping\n");failed=1;break;}
  int finished=!strcmp(argv[1],"finished")||(!strcmp(argv[1],"demo")&&phase*0.75>=seconds/2.0);
  int value=phase%2?(finished?1:4):3;
  if(led(value)){failed=1;break;} previous=value;
  printf("ACLC write=%d readback=%d\n",value,led(-1));fflush(stdout);
  if(write(pipefd[1],".",1)!=1){failed=1;break;} usleep(750000);
 }
 close(pipefd[1]);waitpid(guardian,NULL,0);IOServiceClose(connection);return failed;
}
