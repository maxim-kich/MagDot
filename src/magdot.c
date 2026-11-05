// SPDX-License-Identifier: MIT
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
#include <sys/stat.h>
#include <errno.h>
#include "service.h"

typedef struct { unsigned char a,b,c,d; unsigned short e; } Version;
typedef struct { unsigned short a,b; unsigned int c,d,e; } Limits;
typedef struct { unsigned int size,type; unsigned char attr; } Info;
typedef struct { unsigned int key; Version version; Limits limits; Info info; unsigned char result,status,command; unsigned int index; unsigned char bytes[32]; } Packet;
_Static_assert(sizeof(Packet)==80,"SMC ABI");
static io_connect_t connection;
static volatile sig_atomic_t stopped;
static const char *statusPath="/var/run/magdot.status";
static const char *lockPath="/var/run/magdot.lock";
static void stop(int s) { (void)s; stopped=1; }
static int call(Packet *p) { Packet out={0}; size_t n=sizeof(out); kern_return_t k=IOConnectCallStructMethod(connection,2,p,sizeof(*p),&out,&n); if(k || out.result || n!=sizeof(out)) { fprintf(stderr,"SMC error kernel=0x%x result=0x%x size=%zu\n",k,out.result,n); return -1; } *p=out; return 0; }
static int led(int value) {
#ifdef MAGDOT_TEST
 static int mock=0;if(value<0)return mock;mock=value;return 0;
#endif
 Packet p={.key=0x41434c43,.command=9}; if(call(&p)||p.info.size!=1) return -1; p=(Packet){.key=0x41434c43,.command=value<0?5:6,.info.size=1}; if(value>=0) p.bytes[0]=value; if(call(&p)) return -1; return value<0?p.bytes[0]:0; }
static int connectSMC(void) {
#ifdef MAGDOT_TEST
 return 0;
#endif
 io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC")); if(!s)return -1; int r=IOServiceOpen(s,mach_task_self(),0,&connection); IOObjectRelease(s); return r; }
static int restore(void) {
 // Seed the expected charge color before releasing control (ACLC latch caveat).
 io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSmartBattery"));
 int color=4;
 if(s) { CFTypeRef full=IORegistryEntryCreateCFProperty(s,CFSTR("FullyCharged"),kCFAllocatorDefault,0); if(full) { if(CFGetTypeID(full)==CFBooleanGetTypeID() && CFBooleanGetValue(full))color=3; CFRelease(full); } IOObjectRelease(s); }
 int seeded=led(color); usleep(300000); int released=led(0);
 if(released==0)fprintf(stderr,"Restored ACLC=0 (system)\n");
 return seeded!=0 || released!=0;
}
static int controllerMain(int argc,char **argv) {
#ifdef MAGDOT_TEST
 char testStatus[1024],testLock[1024];const char *testDir=getenv("MAGDOT_TEST_DIR");if(!testDir)return 64;
 snprintf(testStatus,sizeof(testStatus),"%s/status",testDir);snprintf(testLock,sizeof(testLock),"%s/lock",testDir);statusPath=testStatus;lockPath=testLock;
#endif

 if(argc<2 || argc>3 || (strcmp(argv[1],"read")&&strcmp(argv[1],"idle")&&strcmp(argv[1],"working")&&strcmp(argv[1],"finished")&&strcmp(argv[1],"demo")&&strcmp(argv[1],"watch")&&strcmp(argv[1],"attention"))) { fprintf(stderr,"usage: magdot read|idle|working|finished|attention|demo [seconds 1..3600] | watch STATE_FILE\n"); return 64; }
 int watching=!strcmp(argv[1],"watch");
 int streaming=watching && argc==3 && !strcmp(argv[2],"-"); if(watching && argc!=3)return 64;
 char *end=NULL; long duration=(!watching && argc==3)?strtol(argv[2],&end,10):20;
 if(end && (*end || end==argv[2]))return 64;
 int seconds=watching?86400:(duration>=1 && duration<=3600?(int)duration:0); if(seconds<1||(!watching && seconds>3600))return 64;
 if(connectSMC()) { fprintf(stderr,"Cannot open AppleSMC\n"); return 1; }
 int initial=led(-1); if(initial<0)return 1;
 if(!strcmp(argv[1],"read")){printf("ACLC=%d\n",initial);return 0;}
 #ifndef MAGDOT_TEST
 if(geteuid()!=0){fprintf(stderr,"LED writes require macOS administrator authentication\n");return 77;}
#endif
 int lock=open(lockPath,O_CREAT|O_RDWR|O_NOFOLLOW,0600); if(lock<0||flock(lock,LOCK_EX|LOCK_NB)){fprintf(stderr,"Another controller owns LED\n");return 1;}
 if(!strcmp(argv[1],"idle")){return restore();}
 if(initial!=0 && initial!=3 && initial!=4){fprintf(stderr,"ACLC=%d: possible competing LED controller; refusing takeover\n",initial);return 1;}
 signal(SIGPIPE,SIG_IGN);
 int pipefd[2]; if(pipe(pipefd))return 1;
 pid_t guardian=fork(); if(guardian<0)return 1;
 if(!guardian){ close(pipefd[1]); IOServiceClose(connection); if(connectSMC())_exit(1); struct pollfd p={pipefd[0],POLLIN,0}; char c; while(poll(&p,1,3000)>0 && read(pipefd[0],&c,1)==1){} int failed=restore(); if(streaming && !failed){dprintf(STDOUT_FILENO,"RESTORED\n");} unlink(statusPath); _exit(failed); }
 close(pipefd[0]);
 struct sigaction action={0};action.sa_handler=stop;sigemptyset(&action.sa_mask);
 sigaction(SIGINT,&action,NULL);sigaction(SIGTERM,&action,NULL);sigaction(SIGHUP,&action,NULL);signal(SIGPIPE,SIG_IGN);
 // Authorization/background launchers may pass a blocked signal mask.
 sigset_t mask;sigemptyset(&mask);sigprocmask(SIG_SETMASK,&mask,NULL);
 int statusFD=open(statusPath,O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW,0644);
 if(statusFD>=0){dprintf(statusFD,"%d %s\n",getpid(),watching?argv[2]:argv[1]);close(statusFD);}

 if(streaming)dprintf(STDOUT_FILENO,"READY\n");
 int previous=initial,failed=0,lastMode=-1;
 char streamState[16]="idle";long streamExpiry=time(NULL)+4;int streamPreset=-1,streamMS=1000,lastPreset=-2,lastMS=0;
 char streamBuffer[256]={0};size_t streamUsed=0;
 struct timespec start,nowtime;clock_gettime(CLOCK_MONOTONIC,&start);
 for(int phase=0;!stopped;phase++){
  clock_gettime(CLOCK_MONOTONIC,&nowtime);
  double elapsed=nowtime.tv_sec-start.tv_sec+(nowtime.tv_nsec-start.tv_nsec)/1e9;
  if(!watching && elapsed>=seconds)break;
  if(watching) {
   char state[16]={0}; long expiry=0; int stateFD=open(argv[2],O_RDONLY|O_NOFOLLOW|O_NONBLOCK);
   struct stat info; FILE *f=NULL;
   if(stateFD>=0){if(fstat(stateFD,&info)==0 && S_ISREG(info.st_mode) && info.st_size<128)f=fdopen(stateFD,"r");else close(stateFD);}
   if(f){if(fscanf(f,"%15s %ld",state,&expiry)!=2)expiry=0;fclose(f);}
   if(streaming){
    ssize_t n=recv(STDIN_FILENO,streamBuffer+streamUsed,sizeof(streamBuffer)-1-streamUsed,MSG_DONTWAIT);
    if(n==0){break;} else if(n>0){
     streamUsed+=(size_t)n;streamBuffer[streamUsed]=0;
     char *line=streamBuffer,*newline;
     while((newline=strchr(line,'\n'))){*newline=0;streamPreset=-1;streamMS=1000;int fields=sscanf(line,"%15s %ld %d %d",streamState,&streamExpiry,&streamPreset,&streamMS);if(fields!=2 && fields!=4)streamExpiry=0;if(fields==4 && (streamPreset<0 || streamPreset>3 || streamMS<400 || streamMS>1600))streamExpiry=0;line=newline+1;}
     size_t left=streamUsed-(size_t)(line-streamBuffer);memmove(streamBuffer,line,left);streamUsed=left;
     if(streamUsed==sizeof(streamBuffer)-1){failed=1;break;}
    } else if(errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR){failed=1;break;}
    strlcpy(state,streamState,sizeof(state));expiry=streamExpiry;
   }
   long now=time(NULL);
   if(!strcmp(state,"quit") || expiry<now || expiry>now+10){fprintf(stderr,"Session ended or lease expired\n");break;}
   int mode=(expiry>=now && expiry<=now+10)?(!strcmp(state,"working")?1:!strcmp(state,"finished")?2:!strcmp(state,"attention")?3:0):0;
   if(streaming && streamPreset>=0)mode=streamPreset==0?0:streamPreset==1?2:streamPreset==2?3:1;
   if(mode!=lastMode || streamPreset!=lastPreset || streamMS!=lastMS){phase=0;lastMode=mode;lastPreset=streamPreset;lastMS=streamMS;}
   if(!mode){if(previous!=0){if(restore()){failed=1;break;}previous=0;} if(write(pipefd[1],".",1)!=1)break;usleep(750000);continue;}
   if(previous==0)previous=led(-1);
   else if(led(-1)!=previous){fprintf(stderr,"LED ownership changed; stopping\n");failed=1;break;}
   // The state file carries only a bounded enum, never executable input.
   seconds=3600;
   int value=phase%2?(mode==1?4:1):(mode==3?4:3);
   if(led(value)){failed=1;break;}previous=value;
   if(write(pipefd[1],".",1)!=1)break;usleep((useconds_t)(streamMS*1000*(mode!=1 && phase%2?1.5:1)));continue;
  }
  int current=led(-1); if(current!=previous){fprintf(stderr,"LED ownership changed; stopping\n");failed=1;break;}
  int finished=!strcmp(argv[1],"finished")||(!strcmp(argv[1],"demo")&&elapsed>=seconds/2.0);
  int attention=!strcmp(argv[1],"attention");
  int value=phase%2?(finished||attention?1:4):(attention?4:3);
  if(led(value)){failed=1;break;} previous=value;
  printf("ACLC write=%d readback=%d\n",value,led(-1));fflush(stdout);
  if(write(pipefd[1],".",1)!=1){failed=1;break;} usleep((finished||attention) && phase%2?1500000:1000000);
 }
 close(pipefd[1]);int guardianStatus=0;
 while(waitpid(guardian,&guardianStatus,0)<0 && errno==EINTR){}
 unlink(statusPath);IOServiceClose(connection);return failed || guardianStatus!=0;
}

int main(int argc,char **argv) {
 if(argc==2 && !strcmp(argv[1],"daemon"))return daemonMain();
 return controllerMain(argc,argv);
}
