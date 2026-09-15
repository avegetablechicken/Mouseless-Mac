// Small native bridge for menu bar windows and session-level mouse events.
// Lua resolves the selected item and clicks without changing its layout.
// Lua symbols are supplied by Hammerspoon; no separate Lua install is required.
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
typedef struct lua_State lua_State;
typedef long long lua_Integer;
typedef int (*lua_CFunction)(lua_State *);
extern double luaL_checknumber(lua_State *, int);
extern lua_Integer luaL_checkinteger(lua_State *, int);
extern int luaL_error(lua_State *, const char *, ...);
extern void lua_createtable(lua_State *, int, int);
extern void lua_pushnumber(lua_State *, double);
extern void lua_pushboolean(lua_State *, int);
extern void lua_pushcclosure(lua_State *, lua_CFunction, int);
extern void lua_setfield(lua_State *, int, const char *);
extern void lua_rawseti(lua_State *, int, lua_Integer);
#define lua_newtable(L) lua_createtable(L, 0, 0)
#define lua_pushcfunction(L,f) lua_pushcclosure(L, f, 0)
// Deliver one targeted event through the session event stream.
// A tagged null event first synchronizes with the source application's queue.
typedef struct {
    CGEventRef event;
    CFMachPortRef ownerTap, sessionTap;
    pid_t pid;
    int64_t tag;
    bool received;
} Delivery;
static CGEventRef ownerCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    Delivery *d = context;
    if(type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(d->ownerTap, true);
        return event;
    }
    if(CGEventGetIntegerValueField(event, kCGEventSourceUserData) != d->tag) return event;
    CGEventTapEnable(d->ownerTap, false);
    CGEventPost(kCGSessionEventTap, d->event);
    return NULL;
}
static CGEventRef sessionCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    Delivery *d = context;
    if(type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(d->sessionTap, true);
        return event;
    }
    if(CGEventGetIntegerValueField(event, kCGEventSourceUserData) != d->tag) return event;
    CGEventTapEnable(d->sessionTap, false);
    // Let the targeted session event reach the source app exactly once.
    // Posting it to the PID again can toggle a newly opened menu closed.
    d->received = true;
    return event;
}
static bool deliver(CGEventRef event, pid_t pid) {
    Delivery d = { .event = event, .pid = pid, .tag = (int64_t)(uintptr_t)event };
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, d.tag);
    d.ownerTap = CGEventTapCreateForPid(pid, kCGTailAppendEventTap, kCGEventTapOptionDefault,
        CGEventMaskBit(kCGEventNull), ownerCallback, &d);
    d.sessionTap = CGEventTapCreate(kCGSessionEventTap, kCGTailAppendEventTap,
        kCGEventTapOptionListenOnly, CGEventMaskBit(CGEventGetType(event)), sessionCallback, &d);
    if(!d.ownerTap || !d.sessionTap) {
        if(d.ownerTap) CFRelease(d.ownerTap);
        if(d.sessionTap) CFRelease(d.sessionTap);
        return false;
    }
    CFRunLoopRef loop = CFRunLoopGetCurrent();
    CFStringRef mode = CFSTR("HammerspoonMenuBarDelivery");
    CFRunLoopSourceRef ownerSource = CFMachPortCreateRunLoopSource(NULL, d.ownerTap, 0);
    CFRunLoopSourceRef sessionSource = CFMachPortCreateRunLoopSource(NULL, d.sessionTap, 0);
    CFRunLoopAddSource(loop, ownerSource, mode);
    CFRunLoopAddSource(loop, sessionSource, mode);
    CGEventRef wake = CGEventCreate(NULL);
    CGEventSetIntegerValueField(wake, kCGEventSourceUserData, d.tag);
    CGEventPostToPid(pid, wake);
    CFRelease(wake);
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.25;
    while(!d.received && CFAbsoluteTimeGetCurrent() < deadline) {
        CFRunLoopRunInMode(mode, 0.01, true);
    }
    CGEventTapEnable(d.ownerTap, false);
    CGEventTapEnable(d.sessionTap, false);
    CFRunLoopRemoveSource(loop, ownerSource, mode);
    CFRunLoopRemoveSource(loop, sessionSource, mode);
    CFMachPortInvalidate(d.ownerTap);
    CFMachPortInvalidate(d.sessionTap);
    CFRelease(ownerSource); CFRelease(sessionSource);
    CFRelease(d.ownerTap); CFRelease(d.sessionTap);
    return d.received;
}
static int sendEvent(lua_State *L) {
    CGEventType type = (CGEventType)luaL_checkinteger(L, 1);
    if(type != kCGEventLeftMouseDown && type != kCGEventLeftMouseUp) return luaL_error(L, "Invalid menu bar event type");
    CGPoint point = CGPointMake(luaL_checknumber(L, 2), luaL_checknumber(L, 3));
    int64_t wid = luaL_checkinteger(L, 4);
    pid_t pid = (pid_t)luaL_checkinteger(L, 5);
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if(!source) return luaL_error(L, "Cannot create event source");
    CGEventRef event = CGEventCreateMouseEvent(source, type, point, kCGMouseButtonLeft);
    if(!event) { CFRelease(source); return luaL_error(L, "Cannot create mouse event"); }
    CGEventSetFlags(event, 0);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventSetIntegerValueField(event, 51, wid);
    CGEventSetIntegerValueField(event, 91, wid);
    CGEventSetIntegerValueField(event, 92, wid);
    CGEventSetIntegerValueField(event, kCGEventTargetUnixProcessID, pid);
    bool received = deliver(event, pid);
    CFRelease(event); CFRelease(source);
    lua_pushboolean(L, received);
    return 1;
}
static int list(lua_State *L) {
    static void *lib;
    if(!lib) lib=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY);
    if(!lib) return luaL_error(L,"SkyLight unavailable");
    uint32_t (*mainID)(void)=dlsym(lib,"CGSMainConnectionID");
    int (*countFn)(uint32_t,uint32_t,int*)=dlsym(lib,"CGSGetWindowCount");
    int (*listFn)(uint32_t,uint32_t,int,uint32_t*,int*)=dlsym(lib,"CGSGetProcessMenuBarWindowList");
    if(!mainID || !countFn || !listFn) return luaL_error(L,"Menu bar window API unavailable");
    int count=0,actual=0; uint32_t connection=mainID();
    if(countFn(connection,0,&count)!=0 || count<1) return luaL_error(L,"Cannot count windows");
    uint32_t *ids=calloc(count,sizeof(uint32_t));
    int status=listFn(connection,0,count,ids,&actual);
    if(status!=0 || actual<0 || actual>count) { free(ids); return luaL_error(L,"Cannot list menu bar windows"); }
    const void **values=calloc(actual,sizeof(void*));
    for(int i=0;i<actual;i++) values[i]=(const void*)(uintptr_t)ids[i];
    CFArrayRef array=CFArrayCreate(NULL,values,actual,NULL);
    NSArray *windows=CFBridgingRelease(CGWindowListCreateDescriptionFromArray(array));
    CFRelease(array); free(values); free(ids);
    lua_newtable(L); int idx=0;
    for(NSDictionary *w in windows) {
        if([w[(id)kCGWindowLayer] intValue]!=25) continue;
        NSDictionary *b=w[(id)kCGWindowBounds];
        lua_newtable(L);
        NSDictionary *record=@{@"id":w[(id)kCGWindowNumber],@"pid":w[(id)kCGWindowOwnerPID],@"x":b[@"X"],@"y":b[@"Y"],@"w":b[@"Width"],@"h":b[@"Height"]};
        for(NSString *key in record) { lua_pushnumber(L,[record[key] doubleValue]); lua_setfield(L,-2,key.UTF8String); }
        lua_pushboolean(L,[w[(id)kCGWindowIsOnscreen] boolValue]); lua_setfield(L,-2,"visible");
        lua_rawseti(L,-2,++idx);
    }
    return 1;
}
int luaopen_menubar_native(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L,sendEvent); lua_setfield(L,-2,"send");
    lua_pushcfunction(L,list); lua_setfield(L,-2,"list");
    return 1;
}
