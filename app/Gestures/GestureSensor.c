// SPDX-License-Identifier: GPL-3.0-only
#include "GestureSensor.h"
#include <IOKit/hidsystem/IOHIDLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>

// Undocumented IOKit event API. Only the accelerometer is matched.
typedef const void *Client;
typedef const void *Service;
typedef const void *Event;
extern Client IOHIDEventSystemClientCreate(CFAllocatorRef);
extern void IOHIDEventSystemClientSetMatching(Client, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(Client);
extern CFTypeRef IOHIDServiceClientCopyProperty(Service, CFStringRef);
extern Boolean IOHIDServiceClientSetProperty(Service, CFStringRef, CFTypeRef);
typedef void (*EventCallback)(void *, void *, void *, Event);
extern void IOHIDEventSystemClientRegisterEventCallback(Client, EventCallback, void *, void *);
extern void IOHIDEventSystemClientUnregisterEventCallback(Client, EventCallback, void *, void *);
extern void IOHIDEventSystemClientScheduleWithRunLoop(Client, CFRunLoopRef, CFStringRef);
extern void IOHIDEventSystemClientUnscheduleWithRunLoop(Client, CFRunLoopRef, CFStringRef);
extern int IOHIDEventGetType(Event);
extern double IOHIDEventGetFloatValue(Event, int);
extern uint64_t IOHIDEventGetTimeStamp(Event);
static Client client;
static Service service;
static CFTypeRef previous;
static TapSample deliver;
static mach_timebase_info_data_t timebase;
static void receive(void *a, void *b, void *c, Event event) {
    if (!deliver || IOHIDEventGetType(event) != 13) return;
    double seconds = (double)IOHIDEventGetTimeStamp(event) * timebase.numer / timebase.denom / 1e9;
    deliver(seconds, IOHIDEventGetFloatValue(event, 13<<16),
            IOHIDEventGetFloatValue(event, (13<<16)+1), IOHIDEventGetFloatValue(event, (13<<16)+2));
}
void magdot_sensor_stop(void) {
    deliver = 0;
    if (!client) return;
    IOHIDEventSystemClientUnscheduleWithRunLoop(client, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOHIDEventSystemClientUnregisterEventCallback(client, receive, 0, 0);
    if (service) {
        CFTypeRef current = IOHIDServiceClientCopyProperty(service, CFSTR("ReportInterval"));
        int64_t value = 0;
        if (current && CFGetTypeID(current) == CFNumberGetTypeID())
            CFNumberGetValue(current, kCFNumberSInt64Type, &value);
        if (value == 1250 && previous)
            IOHIDServiceClientSetProperty(service, CFSTR("ReportInterval"), previous);
        if (current) CFRelease(current);
        CFRelease(service); service = 0;
    }
    if (previous) { CFRelease(previous); previous = 0; }
    CFRelease(client); client = 0;
}
int magdot_sensor_start(TapSample callback) {
    magdot_sensor_stop(); mach_timebase_info(&timebase);
    client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return 1;
    int page = 0xff00, usage = 3;
    CFNumberRef p = CFNumberCreate(0, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(0, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {p,u};
    CFDictionaryRef match = CFDictionaryCreate(0, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match); CFRelease(p); CFRelease(u);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services || CFArrayGetCount(services) == 0) {
        if (services) CFRelease(services); magdot_sensor_stop(); return 2;
    }
    service = CFRetain(CFArrayGetValueAtIndex(services, 0)); CFRelease(services);
    previous = IOHIDServiceClientCopyProperty(service, CFSTR("ReportInterval"));
    int64_t interval = 1250;
    CFNumberRef n = CFNumberCreate(0, kCFNumberSInt64Type, &interval);
    Boolean ok = IOHIDServiceClientSetProperty(service, CFSTR("ReportInterval"), n);
    CFRelease(n);
    if (!ok) { magdot_sensor_stop(); return 3; }
    deliver = callback;
    IOHIDEventSystemClientRegisterEventCallback(client, receive, 0, 0);
    IOHIDEventSystemClientScheduleWithRunLoop(client, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    return 0;
}

int magdot_sensor_access(void) { return (int)IOHIDCheckAccess(kIOHIDRequestTypeListenEvent); }
int magdot_sensor_request(void) { return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent); }

// Contact presence only: never inspect or retain touch coordinates/content.
// Private framework is dynamically capability-tested and never required to link.
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdbool.h>
static void *mtLibrary;
static CFArrayRef mtDevices;
static _Atomic bool mtEnabled;
static _Atomic uint64_t mtMask,mtLast;
static int mtAvailable;
static mach_timebase_info_data_t mtTimebase;
typedef void (*MTCallback)(void *,const void *,size_t,double,size_t);
static void (*mtRegister)(void *,MTCallback),(*mtUnregister)(void *,MTCallback);
static void (*mtStart)(void *,int);
static int (*mtStop)(void *);
static bool (*mtRunning)(void *);
static _Atomic uint64_t mtFrames;
typedef struct { int frame; double time; int identifier; int state; unsigned char unused[72]; } ContactPresence;
_Static_assert(sizeof(ContactPresence)==96,"Unexpected contact frame ABI");
static bool any_contact(const void *contacts,size_t count){
    if (!count) return false;
    if (!contacts || count>16) return true;
    const ContactPresence *rows=contacts;
    for(size_t n=0;n<count;n++)if(rows[n].state>0 && rows[n].state<7)return true;
    return false;
}
int magdot_touch_decoder_selftest(void){ContactPresence row={0};if(any_contact(&row,1))return 0;row.state=4;if(!any_contact(&row,1))return 0;row.state=7;if(any_contact(&row,1)||any_contact(&row,0))return 0;return 1;}
static void contact_frame(void *device,const void *contacts,size_t count,double time,size_t frame){
    (void)time;(void)frame;
    if (!atomic_load(&mtEnabled) || !mtDevices) return;
    atomic_fetch_add(&mtFrames,1);
    bool touching=any_contact(contacts,count);
    for (CFIndex i=0;i<CFArrayGetCount(mtDevices) && i<63;i++) {
        if (CFArrayGetCount(mtDevices)>1 && CFArrayGetValueAtIndex(mtDevices,i)!=device) continue;
        uint64_t bit=1ULL<<i;
        if (touching){atomic_fetch_or(&mtMask,bit);atomic_store(&mtLast,mach_absolute_time());}
        else{bool previous=(atomic_fetch_and(&mtMask,~bit)&bit)!=0;if(previous || count>0)atomic_store(&mtLast,mach_absolute_time());}
        break;
    }
}
void magdot_touch_stop(void){
    if (!atomic_exchange(&mtEnabled,false)) return;
    for (CFIndex i=0;i<CFArrayGetCount(mtDevices);i++) {
        void *device=(void *)CFArrayGetValueAtIndex(mtDevices,i);
        mtUnregister(device,contact_frame);mtStop(device);
    }
    atomic_store(&mtMask,0);mtAvailable=0;
    // Retain opaque device objects until process exit to avoid callback races.
}
int magdot_touch_start(void){
    if (atomic_load(&mtEnabled)) return mtAvailable;
    mach_timebase_info(&mtTimebase);
    if (!mtLibrary) mtLibrary=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_NOW|RTLD_LOCAL);
    if (!mtLibrary) return 0;
    CFArrayRef (*createList)(void)=dlsym(mtLibrary,"MTDeviceCreateList");
    mtRegister=dlsym(mtLibrary,"MTRegisterContactFrameCallback");mtUnregister=dlsym(mtLibrary,"MTUnregisterContactFrameCallback");mtStart=dlsym(mtLibrary,"MTDeviceStart");mtStop=dlsym(mtLibrary,"MTDeviceStop");mtRunning=dlsym(mtLibrary,"MTDeviceIsRunning");
    if (!createList || !mtRegister || !mtUnregister || !mtStart || !mtStop) return 0;
    if (!mtDevices) mtDevices=createList();
    if (!mtDevices || CFArrayGetCount(mtDevices)==0) return 0;
    atomic_store(&mtEnabled,true);mtAvailable=0;
    for (CFIndex i=0;i<CFArrayGetCount(mtDevices) && i<63;i++) {
        void *device=(void *)CFArrayGetValueAtIndex(mtDevices,i);
        mtRegister(device,contact_frame);mtStart(device,0);if(!mtRunning || mtRunning(device))mtAvailable++;
    }
    if (!mtAvailable) magdot_touch_stop();
    return mtAvailable;
}
double magdot_touch_age(void){
    if (atomic_load(&mtMask)) return 0;
    uint64_t last=atomic_load(&mtLast);
    if (!last) return 1e12;
    return (double)(mach_absolute_time()-last)*mtTimebase.numer/mtTimebase.denom/1e9;
}
int magdot_touch_available(void){return mtAvailable;}

uint64_t magdot_touch_frames(void){return atomic_load(&mtFrames);}
