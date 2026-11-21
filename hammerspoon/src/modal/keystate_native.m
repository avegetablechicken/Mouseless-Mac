// Input state read and input handled without waiting on Lua. A key-up can be
// lost before it reaches the session event stream, which leaves the session
// state reporting the key as held; only the HID system state reflects the
// actual release. The event taps here run on background threads: unlike
// hs.eventtap's taps, they never make input wait for Lua.
// Lua symbols are supplied by Hammerspoon; its LuaSkin headers are used.
#import <CoreGraphics/CoreGraphics.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#import <Foundation/Foundation.h>
#include "lua.h"
#include "lauxlib.h"

static int keyDown(lua_State *L) {
    CGKeyCode keycode = (CGKeyCode)luaL_checkinteger(L, 1);
    lua_pushboolean(L, CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, keycode));
    return 1;
}

static void *runTap(void *tap) {
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    CFRunLoopRun();
    return NULL;
}

// Taps live for the process: the library stays loaded across reloads.
static bool runOnThread(CFMachPortRef tap) {
    pthread_attr_t attr;
    pthread_t thread;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    bool started = pthread_create(&thread, &attr, runTap, tap) == 0;
    pthread_attr_destroy(&attr);
    return started;
}

static atomic_llong mouseDowns;
static CFMachPortRef mouseTap;

static CGEventRef countMouseDown(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(mouseTap, true);
    } else {
        atomic_fetch_add(&mouseDowns, 1);
    }
    return event;
}

static void startMouseTap(void) {
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown)
        | CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventOtherMouseDown);
    mouseTap = CGEventTapCreate(kCGSessionEventTap, kCGTailAppendEventTap,
        kCGEventTapOptionListenOnly, mask, countMouseDown, NULL);
    if (mouseTap && !runOnThread(mouseTap)) { CFRelease(mouseTap); mouseTap = NULL; }
}

// Mouse-button presses so far; nothing when the listen-only tap is unavailable.
static int mouseDownCount(lua_State *L) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, startMouseTap);
    if (!mouseTap) return 0;
    lua_pushinteger(L, (lua_Integer)atomic_load(&mouseDowns));
    return 1;
}

// One background tap handles Hyper and the keyboard watchers below. Whether
// to consume a key is decided here without Lua wherever possible; Lua is
// called afterwards on the main thread.
static CFMachPortRef keyTap;
static lua_State *callbackState;  // main thread only
static atomic_bool suspended;
static atomic_bool fnHeld;
static atomic_llong keyDowns;     // key-downs delivered to applications

// Bit set of command, option, shift, control and fn; Hyper keys use the
// first four, as in hyper.lua.
static int modifierSet(CGEventFlags flags) {
    return ((flags & kCGEventFlagMaskCommand) ? 1 : 0) | ((flags & kCGEventFlagMaskAlternate) ? 2 : 0)
        | ((flags & kCGEventFlagMaskShift) ? 4 : 0) | ((flags & kCGEventFlagMaskControl) ? 8 : 0)
        | ((flags & kCGEventFlagMaskSecondaryFn) ? 16 : 0);
}

// Call a Lua function from the registry on the main thread with the given
// arguments pushed by `push`; returns its first result as a boolean.
static bool callLua(int ref, int nargs, void (^push)(lua_State *)) {
    lua_State *L = callbackState;
    if (L == NULL || ref == LUA_NOREF) return false;
    int top = lua_gettop(L);
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
    push(L);
    bool result = lua_pcall(L, nargs, 1, 0) == LUA_OK && lua_toboolean(L, -1);
    lua_settop(L, top);
    return result;
}

// Hyper and the keys bound under it, consumed from Hyper's HID state.
enum { HYPER_DOWN = 1, HYPER_UP, KEY_PRESSED, KEY_RELEASED, KEY_REPEATED };
#define KEYS 256
#define HYPER_SETS 16
static atomic_int hyperKey = -1;
static atomic_int bindings[KEYS][HYPER_SETS];  // bindings per key and modifiers
static atomic_bool consumed[KEYS];
static int hyperRef = LUA_NOREF;

static void postHyper(int kind, int code, int modifiers, CGEventTimestamp time) {
    int ref = hyperRef;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (ref != hyperRef) return;  // the configuration was reloaded
        callLua(ref, 4, ^(lua_State *L) {
            lua_pushinteger(L, kind);
            lua_pushinteger(L, code);
            lua_pushinteger(L, modifiers);
            lua_pushinteger(L, (lua_Integer)time);
        });
    });
}

// Returns true when Hyper consumed the event.
static bool handleHyper(CGEventType type, CGEventRef event, int code, int modifiers) {
    int hyper = atomic_load(&hyperKey);
    if (hyper < 0 || code < 0 || code >= KEYS) return false;
    bool down = type == kCGEventKeyDown;
    bool repeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
    CGEventTimestamp time = CGEventGetTimestamp(event);
    modifiers &= HYPER_SETS - 1;
    if (code == hyper) {
        // While suspended, Hyper belongs to the focused remote desktop or VM.
        if (atomic_load(&suspended)) return false;
        if (!repeat) postHyper(down ? HYPER_DOWN : HYPER_UP, code, modifiers, time);
        return true;
    }
    if (!down) {
        if (!atomic_exchange(&consumed[code], false)) return false;
        postHyper(KEY_RELEASED, code, modifiers, time);
        return true;
    }
    if (repeat && atomic_load(&consumed[code])) {
        postHyper(KEY_REPEATED, code, modifiers, time);
        return true;
    }
    // A fresh press of a key still marked as consumed means its key-up was
    // lost: decide again from Hyper's current state.
    atomic_store(&consumed[code], false);
    if (atomic_load(&suspended) || atomic_load(&bindings[code][modifiers]) <= 0
        || !CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, (CGKeyCode)hyper)) {
        return false;
    }
    atomic_store(&consumed[code], true);
    postHyper(KEY_PRESSED, code, modifiers, time);
    return true;
}

// Keyboard watchers: replacements for hs.eventtap taps that would make every
// key wait for Lua. A watcher sees the event types in `listen` after they are
// delivered; only events of `decide` types that match one of its rules, or
// that arrive while fn is held when `whileFn` is set, wait for its callback,
// which returns whether to consume them.
#define WATCHERS 64
#define RULES 8
#define DECIDE_TIMEOUT 0.5  // seconds a key waits for Lua before passing through
typedef struct { int code, modifiers; } Rule;
typedef struct {
    bool used, enabled, whileFn, listenHyper;
    CGEventMask listen, decide;
    int ruleCount;
    Rule rules[RULES];
    int ref;
    long long serial;  // tells a reused slot from the watcher it replaced
} Watcher;
static Watcher watchers[WATCHERS];
static long long watcherSerial;
static pthread_mutex_t watchersLock = PTHREAD_MUTEX_INITIALIZER;

static bool matchesRules(const Watcher *w, int code, int modifiers) {
    if (w->whileFn && atomic_load(&fnHeld)) return true;
    for (int i = 0; i < w->ruleCount; i++) {
        if (w->rules[i].code == code && w->rules[i].modifiers == modifiers) return true;
    }
    return false;
}

// Event data drops the event source's user data, which marks events that
// Hammerspoon posts itself, so it is passed alongside.
static void pushEvent(lua_State *L, NSData *data, int64_t userData, long long sequence) {
    lua_pushlstring(L, data.bytes, data.length);
    lua_pushinteger(L, sequence);
    lua_pushinteger(L, userData);
}

static void notifyWatcher(Watcher w, NSData *data, int64_t userData, long long sequence) {
    dispatch_async(dispatch_get_main_queue(), ^{
        int slot = (int)(w.serial % WATCHERS);
        if (!watchers[slot].used || watchers[slot].serial != w.serial) return;
        callLua(w.ref, 3, ^(lua_State *L) { pushEvent(L, data, userData, sequence); });
    });
}

// Asks a watcher on the main thread; a key never waits longer than
// DECIDE_TIMEOUT, after which it passes through.
static bool askWatcher(Watcher w, NSData *data, int64_t userData, long long sequence) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block atomic_bool abandoned = false;
    __block bool consume = false;
    dispatch_async(dispatch_get_main_queue(), ^{
        int slot = (int)(w.serial % WATCHERS);
        if (watchers[slot].used && watchers[slot].serial == w.serial) {
            bool result = callLua(w.ref, 3, ^(lua_State *L) {
                pushEvent(L, data, userData, sequence);
            });
            if (!atomic_load(&abandoned)) consume = result;
        }
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(DECIDE_TIMEOUT * NSEC_PER_SEC))) != 0) {
        atomic_store(&abandoned, true);
        return false;
    }
    return consume;
}

static CGEventRef handleKey(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(keyTap, true);
        return event;
    }
    int code = (int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    int modifiers = modifierSet(CGEventGetFlags(event));
    if (type == kCGEventFlagsChanged) {
        atomic_store(&fnHeld, (modifiers & 16) != 0);
    } else if (handleHyper(type, event, code, modifiers)) {
        // The Hyper double-tap watcher also needs intervening consumed chord keys.
        if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) return NULL;
        pthread_mutex_lock(&watchersLock);
        for (int i = WATCHERS - 1; i >= 0; i--) {
            Watcher *w = &watchers[i];
            if (w->used && w->enabled && w->listenHyper && (w->listen & CGEventMaskBit(type))) {
                NSData *data = CFBridgingRelease(CGEventCreateData(NULL, event));
                notifyWatcher(*w, data, CGEventGetIntegerValueField(event, kCGEventSourceUserData),
                              atomic_load(&keyDowns));
            }
        }
        pthread_mutex_unlock(&watchersLock);
        return NULL;
    }
    long long sequence = atomic_load(&keyDowns);
    Watcher matched[WATCHERS];
    int count = 0;
    pthread_mutex_lock(&watchersLock);
    for (int i = WATCHERS - 1; i >= 0; i--) {
        Watcher *w = &watchers[i];
        if (w->used && w->enabled && ((w->listen | w->decide) & CGEventMaskBit(type))) {
            matched[count++] = *w;
        }
    }
    pthread_mutex_unlock(&watchersLock);
    if (count == 0) {
        if (type == kCGEventKeyDown) atomic_fetch_add(&keyDowns, 1);
        return event;
    }
    NSData *data = CFBridgingRelease(CGEventCreateData(NULL, event));
    int64_t userData = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    // Later watchers first, as with hs.eventtap.
    for (int i = 0; i < count; i++) {
        Watcher w = matched[i];
        if ((w.decide & CGEventMaskBit(type)) && matchesRules(&w, code, modifiers)) {
            if (askWatcher(w, data, userData, sequence)) return NULL;
        } else if (w.listen & CGEventMaskBit(type)) {
            notifyWatcher(w, data, userData, sequence + (type == kCGEventKeyDown ? 1 : 0));
        }
    }
    if (type == kCGEventKeyDown) atomic_fetch_add(&keyDowns, 1);
    return event;
}

static void startKeyTapOnce(void) {
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp)
        | CGEventMaskBit(kCGEventFlagsChanged);
    keyTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, mask, handleKey, NULL);
    if (keyTap && !runOnThread(keyTap)) { CFRelease(keyTap); keyTap = NULL; }
}

static bool ensureKeyTap(lua_State *L) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, startKeyTapOnce);
    if (!keyTap) return false;
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
    callbackState = lua_tothread(L, -1);
    lua_pop(L, 1);
    return true;
}

static void resetHyper(void) {
    atomic_store(&hyperKey, -1);
    hyperRef = LUA_NOREF;
    for (int code = 0; code < KEYS; code++) {
        atomic_store(&consumed[code], false);
        for (int set = 0; set < HYPER_SETS; set++) atomic_store(&bindings[code][set], 0);
    }
}

// The configuration that started the Hyper tap is gone: pass its keys through.
static int stopHyper(lua_State *L) {
    resetHyper();
    return 0;
}

// startKeyTap(hyperKeyCode, callback(kind, keyCode, modifiers, timestamp)):
// returns a handle that stops handling Hyper when collected, or nothing when
// the tap is unavailable.
static int startKeyTap(lua_State *L) {
    int hyper = (int)luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    if (!ensureKeyTap(L) || hyper < 0 || hyper >= KEYS) return 0;
    resetHyper();
    lua_pushvalue(L, 2);
    hyperRef = luaL_ref(L, LUA_REGISTRYINDEX);
    atomic_store(&hyperKey, hyper);
    lua_newuserdata(L, 1);
    if (luaL_newmetatable(L, "keystate.hyper")) {
        lua_pushcfunction(L, stopHyper);
        lua_setfield(L, -2, "__gc");
    }
    lua_setmetatable(L, -2);
    return 1;
}

// bindKey(keyCode, modifiers, delta): count a binding the tap should consume.
static int bindKey(lua_State *L) {
    lua_Integer code = luaL_checkinteger(L, 1), set = luaL_checkinteger(L, 2);
    if (code >= 0 && code < KEYS && set >= 0 && set < HYPER_SETS) {
        atomic_fetch_add(&bindings[code][set], (int)luaL_checkinteger(L, 3));
    }
    return 0;
}

static int setSuspended(lua_State *L) {
    atomic_store(&suspended, lua_toboolean(L, 1));
    return 0;
}

static Watcher *checkWatcher(lua_State *L) {
    long long serial = *(long long *)luaL_checkudata(L, 1, "keystate.watcher");
    Watcher *w = &watchers[serial % WATCHERS];
    return w->used && w->serial == serial ? w : NULL;
}

static int setWatcherEnabled(lua_State *L, bool enabled) {
    Watcher *w = checkWatcher(L);
    pthread_mutex_lock(&watchersLock);
    if (w) w->enabled = enabled;
    pthread_mutex_unlock(&watchersLock);
    lua_settop(L, 1);
    return 1;
}
static int startWatcher(lua_State *L) { return setWatcherEnabled(L, true); }
static int stopWatcher(lua_State *L) { return setWatcherEnabled(L, false); }

static int watcherIsEnabled(lua_State *L) {
    Watcher *w = checkWatcher(L);
    lua_pushboolean(L, w && w->enabled);
    return 1;
}

static int deleteWatcher(lua_State *L) {
    Watcher *w = checkWatcher(L);
    if (!w) return 0;
    pthread_mutex_lock(&watchersLock);
    w->used = w->enabled = false;
    pthread_mutex_unlock(&watchersLock);
    luaL_unref(L, LUA_REGISTRYINDEX, w->ref);
    w->ref = LUA_NOREF;
    return 0;
}

// watch(listenMask, decideMask, rules, whileFn,
//       callback(eventData, keyDowns, eventSourceUserData), listenHyper):
// rules is a list of {keyCode, modifiers}. Returns a stopped watcher with
// start, stop and isEnabled, or nothing when the tap is unavailable.
static int watch(lua_State *L) {
    CGEventMask listen = (CGEventMask)luaL_checkinteger(L, 1);
    CGEventMask decide = (CGEventMask)luaL_checkinteger(L, 2);
    luaL_checktype(L, 3, LUA_TTABLE);
    bool whileFn = lua_toboolean(L, 4);
    luaL_checktype(L, 5, LUA_TFUNCTION);
    lua_Integer ruleCount = luaL_len(L, 3);
    luaL_argcheck(L, ruleCount <= RULES, 3, "too many rules");
    if (!ensureKeyTap(L)) return 0;
    int slot = -1;
    for (int i = 0; i < WATCHERS; i++) {
        long long serial = watcherSerial + 1 + i;
        if (!watchers[serial % WATCHERS].used) { slot = (int)(serial % WATCHERS); watcherSerial = serial; break; }
    }
    if (slot < 0) return 0;
    Watcher w = { .used = true, .whileFn = whileFn, .listen = listen, .decide = decide,
                  .ruleCount = (int)ruleCount, .serial = watcherSerial, .listenHyper = lua_toboolean(L, 6) };
    for (int i = 0; i < ruleCount; i++) {
        lua_rawgeti(L, 3, i + 1);
        lua_rawgeti(L, -1, 1); w.rules[i].code = (int)lua_tointeger(L, -1);
        lua_rawgeti(L, -2, 2); w.rules[i].modifiers = (int)lua_tointeger(L, -1);
        lua_pop(L, 3);
    }
    lua_pushvalue(L, 5);
    w.ref = luaL_ref(L, LUA_REGISTRYINDEX);
    pthread_mutex_lock(&watchersLock);
    watchers[slot] = w;
    pthread_mutex_unlock(&watchersLock);
    *(long long *)lua_newuserdata(L, sizeof(long long)) = w.serial;
    if (luaL_newmetatable(L, "keystate.watcher")) {
        lua_pushvalue(L, -1); lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, deleteWatcher); lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, startWatcher); lua_setfield(L, -2, "start");
        lua_pushcfunction(L, stopWatcher); lua_setfield(L, -2, "stop");
        lua_pushcfunction(L, watcherIsEnabled); lua_setfield(L, -2, "isEnabled");
    }
    lua_setmetatable(L, -2);
    return 1;
}

// Key-downs delivered so far; a watcher's event is stale when this has moved
// past the count it was reported with.
static int keyDownCount(lua_State *L) {
    lua_pushinteger(L, (lua_Integer)atomic_load(&keyDowns));
    return 1;
}

int luaopen_keystate_native(lua_State *L) {
    lua_createtable(L, 0, 8);
    lua_pushcfunction(L, keyDown); lua_setfield(L, -2, "keyDown");
    lua_pushcfunction(L, mouseDownCount); lua_setfield(L, -2, "mouseDownCount");
    lua_pushcfunction(L, startKeyTap); lua_setfield(L, -2, "startKeyTap");
    lua_pushcfunction(L, bindKey); lua_setfield(L, -2, "bindKey");
    lua_pushcfunction(L, setSuspended); lua_setfield(L, -2, "setSuspended");
    lua_pushcfunction(L, watch); lua_setfield(L, -2, "watch");
    lua_pushcfunction(L, keyDownCount); lua_setfield(L, -2, "keyDownCount");
    return 1;
}
