// SPDX-License-Identifier: MIT
// Root service accepts only the signed MagDot app from our own signing team.
#include <Security/Security.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <bsm/libbsm.h>
#include <launch.h>
static int trustedClient(int fd) {
 audit_token_t token; socklen_t size=sizeof(token);
 if(getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&token,&size))return 0;
 CFDataRef audit=CFDataCreate(NULL,(UInt8*)&token,sizeof(token));
 const void *keys[]={kSecGuestAttributeAudit}, *values[]={audit};
 CFDictionaryRef attrs=CFDictionaryCreate(NULL,keys,values,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 SecCodeRef guest=NULL,self=NULL;CFDictionaryRef info=NULL;SecRequirementRef requirement=NULL;
 int allowed=0;
 if(SecCodeCopyGuestWithAttributes(NULL,attrs,kSecCSDefaultFlags,&guest)==errSecSuccess &&
    SecCodeCopySelf(kSecCSDefaultFlags,&self)==errSecSuccess &&
    SecCodeCopySigningInformation(self,kSecCSSigningInformation,&info)==errSecSuccess){
  CFStringRef team=CFDictionaryGetValue(info,kSecCodeInfoTeamIdentifier);
  if(team){
   CFStringRef rule=CFStringCreateWithFormat(NULL,NULL,CFSTR("anchor apple generic and identifier \"com.maximkich.magdot\" and certificate leaf[subject.OU] = \"%@\""),team);
   if(SecRequirementCreateWithString(rule,kSecCSDefaultFlags,&requirement)==errSecSuccess)
    allowed=SecCodeCheckValidity(guest,kSecCSDefaultFlags,requirement)==errSecSuccess;
   CFRelease(rule);
  }
 }
 if(requirement)CFRelease(requirement);if(info)CFRelease(info);if(self)CFRelease(self);if(guest)CFRelease(guest);
 CFRelease(attrs);CFRelease(audit);return allowed;
}
static int controllerMain(int argc,char **argv);
static int daemonMain(void) {
 #ifndef MAGDOT_TEST
 if(geteuid()!=0)return 77;
#endif
 int fd=-1;
 int activated=1;
#ifdef MAGDOT_TEST
 activated=getenv("MAGDOT_TEST_LAUNCHD")!=NULL;
#endif
 if(activated){
  int *fds=NULL;size_t count=0;
  int error=launch_activate_socket("Listener",&fds,&count);
  if(error || count!=1){if(fds){for(size_t i=0;i<count;i++)close(fds[i]);free(fds);}return 1;}
  fd=fds[0];free(fds);
 } else {
#ifdef MAGDOT_TEST
  fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return 1;
  struct sockaddr_un address={.sun_family=AF_UNIX};
  const char *folder=getenv("MAGDOT_TEST_DIR");if(!folder)return 64;
  snprintf(address.sun_path,sizeof(address.sun_path),"%s/socket",folder);
  unlink(address.sun_path);
  if(bind(fd,(struct sockaddr*)&address,sizeof(address)) || chmod(address.sun_path,0600) || listen(fd,4))return 1;
#endif
 }
 while(1){
  // launchd retains the listening socket. No client means no helper process.
  struct pollfd listener={fd,POLLIN,0};
  int available=poll(&listener,1,activated?2000:-1);
  if(available==0){close(fd);return 0;}
  if(available<0){if(errno==EINTR)continue;close(fd);return 1;}
  int client=accept(fd,NULL,NULL);if(client<0){if(errno==EINTR)continue;return 1;}
  if(!trustedClient(client)){close(client);continue;}
  pid_t child=fork();
  if(child==0){close(fd);dup2(client,STDIN_FILENO);dup2(client,STDOUT_FILENO);if(client>1)close(client);char *arguments[]={"magdot","watch","-",NULL};_exit(controllerMain(3,arguments));}
  close(client);
  if(child>0){int status;while(waitpid(child,&status,0)<0 && errno==EINTR){}}
  // Worker has waited for watchdog restoration before exiting. Pending new
  // connections stay on launchd's socket and start a fresh helper instance.
  if(activated){close(fd);return child<0?1:0;}
 }
}
