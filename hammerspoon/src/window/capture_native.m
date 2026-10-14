// Screenshot work stays off Lua's thread. Lua only enqueues IDs and drains results.
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

typedef struct lua_State lua_State;
typedef long long lua_Integer;
typedef int (*lua_CFunction)(lua_State *);
extern lua_Integer luaL_checkinteger(lua_State *, int);
extern void lua_createtable(lua_State *, int, int);
extern void lua_pushinteger(lua_State *, lua_Integer);
extern void lua_pushboolean(lua_State *, int);
extern const char *lua_pushstring(lua_State *, const char *);
extern void lua_pushcclosure(lua_State *, lua_CFunction, int);
extern void lua_setfield(lua_State *, int, const char *);
extern void lua_rawseti(lua_State *, int, lua_Integer);
extern int lua_toboolean(lua_State *, int);

static NSObject *lock;
static NSMutableArray<NSDictionary *> *pending, *completed;
static NSDictionary *inFlight;
static NSUInteger generation;
static dispatch_queue_t worker;
static void pump(void);

static void finish(NSDictionary *job, CGImageRef image, NSString *error) {
    @autoreleasepool {
        NSString *url;
        if (image) {
            // Bound cache and Lua decoding cost even on the legacy capture path.
            CGFloat ratio = MIN(1, MIN(768.0 / CGImageGetWidth(image), 480.0 / CGImageGetHeight(image)));
            size_t width = MAX(1, (size_t)(CGImageGetWidth(image) * ratio));
            size_t height = MAX(1, (size_t)(CGImageGetHeight(image) * ratio));
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
            CGColorSpaceRelease(space);
            if (context) {
                CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
                CGImageRef scaled = CGBitmapContextCreateImage(context);
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:scaled];
                NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                if (png) url = [@"data:image/png;base64," stringByAppendingString:[png base64EncodedStringWithOptions:0]];
                CGImageRelease(scaled);
                CGContextRelease(context);
            }
        }
        @synchronized(lock) {
            if ([job[@"generation"] unsignedIntegerValue] == generation) {
                NSMutableDictionary *result = [job mutableCopy];
                if (url) result[@"image"] = url;
                else result[@"error"] = error ?: @"No screenshot available";
                if (completed.count == 128) [completed removeObjectAtIndex:0];
                [completed addObject:result];
            }
            inFlight = nil;
        }
    }
    pump();
}

static void capture(NSDictionary *job) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    if ([session[@"CGSSessionScreenIsLocked"] boolValue]) {
        finish(job, NULL, @"Screen is locked");
        return;
    }
    if (!CGPreflightScreenCaptureAccess()) {
        finish(job, NULL, @"Screen Recording permission is unavailable");
        return;
    }
    CGWindowID wid = [job[@"id"] unsignedIntValue];
    // AltTab's offscreen/minimized-window capture path. Resolve symbols rather
    // than linking private APIs; retain the public API as a visible-window fallback.
    static void *skyLight;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    });
    uint32_t (*connection)(void) = skyLight ? dlsym(skyLight, "CGSMainConnectionID") : NULL;
    CFArrayRef (*captureWindows)(uint32_t, CGWindowID *, uint32_t, uint32_t) =
        skyLight ? dlsym(skyLight, "CGSHWCaptureWindowList") : NULL;
    CGImageRef image = NULL;
    if (connection && captureWindows) {
        // ignoreGlobalClipShape | bestResolution | fullSize (Stage Manager).
        CFArrayRef frames = captureWindows(connection(), &wid, 1, (1 << 11) | (1 << 8) | (1 << 19));
        if (frames) {
            if (CFArrayGetCount(frames)) image = CGImageRetain((CGImageRef)CFArrayGetValueAtIndex(frames, 0));
            CFRelease(frames);
        }
    }
    if (!image) {
        CGImageRef (*snapshot)(CGRect, CFArrayRef, CGWindowImageOption) = dlsym(RTLD_DEFAULT, "CGWindowListCreateImageFromArray");
        const void *value = (void *)(uintptr_t)wid;
        CFArrayRef ids = CFArrayCreate(NULL, &value, 1, NULL);
        if (snapshot) image = snapshot(CGRectNull, ids, kCGWindowImageBoundsIgnoreFraming);
        CFRelease(ids);
    }
    finish(job, image, nil);
    if (image) CGImageRelease(image);
}

static void pump(void) {
    NSDictionary *job;
    @synchronized(lock) {
        if (inFlight || pending.count == 0) return;
        job = pending.firstObject;
        [pending removeObjectAtIndex:0];
        inFlight = job;
    }
    dispatch_async(worker, ^{
        @autoreleasepool { capture(job); }
    });
}

static int request(lua_State *L) {
    NSNumber *wid = @(luaL_checkinteger(L, 1)), *token = @(luaL_checkinteger(L, 2));
    BOOL priority = lua_toboolean(L, 3);
    @synchronized(lock) {
        if ([inFlight[@"id"] isEqual:wid] && [inFlight[@"token"] isEqual:token] &&
            [inFlight[@"generation"] unsignedIntegerValue] == generation) { lua_pushboolean(L, YES); return 1; }
        for (NSUInteger i = 0; i < pending.count; i++) {
            if ([pending[i][@"id"] isEqual:wid]) { [pending removeObjectAtIndex:i]; break; }
        }
        if (pending.count >= 128) {
            if (!priority) { lua_pushboolean(L, NO); return 1; }
            [pending removeLastObject];
        }
        NSDictionary *job = @{@"id":wid, @"token":token, @"generation":@(generation)};
        if (priority) [pending insertObject:job atIndex:0]; else [pending addObject:job];
    }
    pump();
    lua_pushboolean(L, YES);
    return 1;
}

static int poll(lua_State *L) {
    NSArray *batch;
    @synchronized(lock) {
        NSUInteger count = MIN(4, completed.count);
        batch = [completed subarrayWithRange:NSMakeRange(0, count)];
        [completed removeObjectsInRange:NSMakeRange(0, count)];
    }
    lua_createtable(L, (int)batch.count, 0);
    int index = 0;
    for (NSDictionary *result in batch) {
        lua_createtable(L, 0, 4);
        for (NSString *key in @[@"id", @"token"]) {
            lua_pushinteger(L, [result[key] longLongValue]); lua_setfield(L, -2, key.UTF8String);
        }
        for (NSString *key in @[@"image", @"error"]) {
            if (result[key]) { lua_pushstring(L, [result[key] UTF8String]); lua_setfield(L, -2, key.UTF8String); }
        }
        lua_rawseti(L, -2, ++index);
    }
    return 1;
}

static int reset(lua_State *L) {
    @synchronized(lock) { generation++; [pending removeAllObjects]; [completed removeAllObjects]; }
    // An in-flight OS request may finish, but its generation cannot enter the new cache.
    return 0;
}

int luaopen_window_capture(lua_State *L) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Lua may close its loadlib handle during a configuration reload while an
        // OS capture is still in flight. Keep the code mapped; no worker touches Lua.
        Dl_info info;
        if (dladdr((void *)luaopen_window_capture, &info) && info.dli_fname)
            dlopen(info.dli_fname, RTLD_LAZY | RTLD_NODELETE);
        lock = [NSObject new]; pending = [NSMutableArray new]; completed = [NSMutableArray new];
        worker = dispatch_queue_create("hammerspoon.window-capture", DISPATCH_QUEUE_SERIAL);
    });
    reset(L);
    lua_createtable(L, 0, 3);
    lua_pushcclosure(L, request, 0); lua_setfield(L, -2, "request");
    lua_pushcclosure(L, poll, 0); lua_setfield(L, -2, "poll");
    lua_pushcclosure(L, reset, 0); lua_setfield(L, -2, "reset");
    return 1;
}
