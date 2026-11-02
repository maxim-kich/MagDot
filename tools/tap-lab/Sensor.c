#include "Sensor.h"
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
void sensor_stop(void) {
    deliver = 0;
    if (!client) return;
    IOHIDEventSystemClientUnscheduleWithRunLoop(client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
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
int sensor_start(TapSample callback) {
    sensor_stop(); mach_timebase_info(&timebase);
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
        if (services) CFRelease(services); sensor_stop(); return 2;
    }
    service = CFRetain(CFArrayGetValueAtIndex(services, 0)); CFRelease(services);
    previous = IOHIDServiceClientCopyProperty(service, CFSTR("ReportInterval"));
    int64_t interval = 1250;
    CFNumberRef n = CFNumberCreate(0, kCFNumberSInt64Type, &interval);
    Boolean ok = IOHIDServiceClientSetProperty(service, CFSTR("ReportInterval"), n);
    CFRelease(n);
    if (!ok) { sensor_stop(); return 3; }
    deliver = callback;
    IOHIDEventSystemClientRegisterEventCallback(client, receive, 0, 0);
    IOHIDEventSystemClientScheduleWithRunLoop(client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    return 0;
}
