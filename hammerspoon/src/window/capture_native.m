// Screenshot work stays off Lua's thread. Lua only enqueues IDs and drains results.
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

typedef struct lua_State lua_State;
typedef long long lua_Integer;
typedef int (*lua_CFunction)(lua_State *);
extern double luaL_checknumber(lua_State *, int);
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
static NSPanel *glassPanel;
static void pump(void);

// Stage Manager can leave a small window surface inside a large transparent
// image. Crop the actual alpha footprint before resizing, not after detail is lost.
static CGImageRef trimWindowImage(CGImageRef image) {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGBitmapByteOrder32Big | (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return CGImageRetain(image);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    unsigned char *pixels = CGBitmapContextGetData(context);
    size_t left = width, top = height, right = 0, bottom = 0;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            if (pixels[(y * width + x) * 4 + 3] >= 32) {
                left = MIN(left, x); right = MAX(right, x);
                top = MIN(top, y); bottom = MAX(bottom, y);
            }
        }
    }
    if (left == width) { CGContextRelease(context); return NULL; }
    CGImageRef result = NULL;
    if (left < right && top < bottom && (right-left+1 < width*0.95 || bottom-top+1 < height*0.95)) {
        // Crop the normalized bitmap so alpha scan and crop use the same row order.
        CGImageRef normalized = CGBitmapContextCreateImage(context);
        left = left > 2 ? left-2 : 0; top = top > 2 ? top-2 : 0;
        right = MIN(width-1, right+2); bottom = MIN(height-1, bottom+2);
        result = CGImageCreateWithImageInRect(normalized, CGRectMake(left, top, right-left+1, bottom-top+1));
        CGImageRelease(normalized);
    }
    CGContextRelease(context);
    return result ?: CGImageRetain(image);
}

static int positionGlass(lua_State *L) {
    CGFloat x = luaL_checknumber(L, 1), y = luaL_checknumber(L, 2);
    CGFloat width = luaL_checknumber(L, 3), height = luaL_checknumber(L, 4);
    if (!glassPanel) {
        glassPanel = [[NSPanel alloc] initWithContentRect:NSZeroRect
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        glassPanel.releasedWhenClosed = NO;
        glassPanel.opaque = NO;
        glassPanel.backgroundColor = NSColor.clearColor;
        glassPanel.ignoresMouseEvents = YES;
        glassPanel.hidesOnDeactivate = NO;
        glassPanel.hasShadow = YES;
        // Let the material provide translucency; window alpha blends sharp content back in.
        glassPanel.alphaValue = 1;
        glassPanel.level = CGWindowLevelForKey(kCGOverlayWindowLevelKey) - 1;
        glassPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
        NSVisualEffectView *effect = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        effect.material = NSVisualEffectMaterialHUDWindow;
        effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        effect.state = NSVisualEffectStateActive;
        effect.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
        // Mask the material itself without clipping its backdrop-rendering layer.
        NSImage *mask = [NSImage imageWithSize:NSMakeSize(29, 29) flipped:NO drawingHandler:^BOOL(NSRect rect) {
            [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:14 yRadius:14] fill];
            return YES;
        }];
        mask.capInsets = NSEdgeInsetsMake(14, 14, 14, 14);
        effect.maskImage = mask;
        glassPanel.contentView = effect;
    }
    CGFloat screenTop = NSMaxY(NSScreen.screens.firstObject.frame);
    [glassPanel setFrame:NSMakeRect(x, screenTop-y-height, width, height) display:NO];
    return 0;
}
static int showGlass(lua_State *L) { [glassPanel orderFrontRegardless]; return 0; }
static int hideGlass(lua_State *L) { [glassPanel orderOut:nil]; return 0; }

static void finish(NSDictionary *job, CGImageRef image, NSString *error) {
    @autoreleasepool {
        NSString *url;
        CGImageRef cropped = image ? CGImageRetain(image) : NULL;
        if (cropped) {
            image = cropped;
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
            CGImageRelease(image);
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
        // Tahoe's fullSize capture may be transparent or clip the Stage Manager surface.
        uint32_t options = (1 << 11) | (1 << 8) | (1 << 19);
        if (@available(macOS 26.0, *)) options &= ~(1 << 19);
        CFArrayRef frames = captureWindows(connection(), &wid, 1, options);
        if (frames) {
            if (CFArrayGetCount(frames)) image = CGImageRetain((CGImageRef)CFArrayGetValueAtIndex(frames, 0));
            CFRelease(frames);
        }
    }
    if (image) {
        CGImageRef content = trimWindowImage(image);
        CGImageRelease(image); image = content;
    }
    if (!image) {
        CGImageRef (*snapshot)(CGRect, CFArrayRef, CGWindowImageOption) = dlsym(RTLD_DEFAULT, "CGWindowListCreateImageFromArray");
        const void *value = (void *)(uintptr_t)wid;
        CFArrayRef ids = CFArrayCreate(NULL, &value, 1, NULL);
        if (snapshot) image = snapshot(CGRectNull, ids, kCGWindowImageBoundsIgnoreFraming);
        CFRelease(ids);
        if (image) {
            CGImageRef content = trimWindowImage(image);
            CGImageRelease(image); image = content;
        }
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
    [glassPanel close]; glassPanel = nil;
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
    lua_createtable(L, 0, 6);
    lua_pushcclosure(L, request, 0); lua_setfield(L, -2, "request");
    lua_pushcclosure(L, poll, 0); lua_setfield(L, -2, "poll");
    lua_pushcclosure(L, reset, 0); lua_setfield(L, -2, "reset");
    lua_pushcclosure(L, positionGlass, 0); lua_setfield(L, -2, "positionGlass");
    lua_pushcclosure(L, showGlass, 0); lua_setfield(L, -2, "showGlass");
    lua_pushcclosure(L, hideGlass, 0); lua_setfield(L, -2, "hideGlass");
    return 1;
}
