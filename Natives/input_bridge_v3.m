/*
 * V3 input bridge implementation.
 *
 * Status:
 * - Active development
 * - Works with some bugs:
 *  + Modded versions gives broken stuff..
 */

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "SurfaceViewController.h"

#include <assert.h>
#include <dlfcn.h>
#include <libgen.h>
#include <stdlib.h>
#include <stdatomic.h>

#include "jni.h"
#include "glfw_keycodes.h"
#include "ios_uikit_bridge.h"
#include "utils.h"

#include "JavaLauncher.h"

// SDL3 event injection via dlsym — used when GLFW callbacks are NULL (MC 26.3)
// Only SDL_PushEvent and SDL_GetWindowID are exported from libSDL3.dylib.
// Internal functions like SDL_SendMouseMotion are NOT exported, so we construct
// SDL_Event structs and push them directly.
//
// We cannot #include <SDL3/SDL_events.h> from the Natives build, so we define
// the minimal constants and structs we need inline.

// SDL3 event type constants (from SDL_events.h)
#define SDL3_EVENT_KEY_DOWN        0x300
#define SDL3_EVENT_KEY_UP          0x301
#define SDL3_EVENT_MOUSE_MOTION    0x400
#define SDL3_EVENT_MOUSE_BUTTON_DOWN 0x401
#define SDL3_EVENT_MOUSE_BUTTON_UP   0x402
#define SDL3_EVENT_MOUSE_WHEEL     0x403

typedef uint32_t SDL3_WindowID;
typedef uint32_t SDL3_MouseID;
typedef uint16_t SDL3_Keymod;
typedef int      SDL3_Scancode;
typedef uint32_t SDL3_Keycode;

// SDL3 MouseMotionEvent layout (must match SDL3 ABI exactly)
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    SDL3_MouseID which;
    uint32_t state;
    float x, y;
    float xrel, yrel;
} SDL3_MouseMotionEvent;

// SDL3 MouseButtonEvent layout
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    SDL3_MouseID which;
    uint8_t button;
    bool down;
    uint8_t clicks;
    uint8_t padding;
    float x, y;
} SDL3_MouseButtonEvent;

// SDL3 MouseWheelEvent layout
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    SDL3_MouseID which;
    float x, y;
    uint32_t direction;
    float mouse_x, mouse_y;
    int32_t integer_x, integer_y;
} SDL3_MouseWheelEvent;

// SDL3 KeyboardEvent layout
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    uint32_t which;
    SDL3_Scancode scancode;
    SDL3_Keycode key;
    SDL3_Keymod mod;
    uint16_t raw;
    bool down;
    bool repeat;
} SDL3_KeyboardEvent;

// Union large enough to hold any SDL3 event
typedef union {
    uint32_t type;
    char _padding[128];
} SDL3_Event;

typedef bool SDL_PushEvent_func(void *event);
typedef uint32_t SDL_GetWindowID_func(void *window);
typedef bool SDL_HideCursor_func(void);
typedef bool SDL_ShowCursor_func(void);

static SDL_PushEvent_func     *pSDL_PushEvent     = NULL;
static SDL_GetWindowID_func   *pSDL_GetWindowID   = NULL;
static void *g_sdlWindow = NULL;  // The real SDL3 window pointer

static void initSDLEventFuncs(void) {
    static BOOL inited = NO;
    if (inited) return;
    inited = YES;
    pSDL_PushEvent   = dlsym(RTLD_DEFAULT, "SDL_PushEvent");
    pSDL_GetWindowID = dlsym(RTLD_DEFAULT, "SDL_GetWindowID");
    NSLog(@"[InputDiag] initSDLEventFuncs: PushEvent=%p GetWindowID=%p g_sdlWindow=%p",
        (void*)pSDL_PushEvent, (void*)pSDL_GetWindowID, g_sdlWindow);
}

// Called from UIKit_CreateWindow to register the real SDL window
void Amethyst_SetSDLWindow(void *window) {
    g_sdlWindow = window;
    // Re-init in case libSDL3.dylib wasn't loaded at JNI_OnLoad time
    initSDLEventFuncs();
    NSLog(@"[InputDiag] Amethyst_SetSDLWindow: %p PushEvent=%p", window, (void*)pSDL_PushEvent);
}

static SDL3_WindowID getSDLWindowID(void) {
    if (g_sdlWindow && pSDL_GetWindowID) {
        return pSDL_GetWindowID(g_sdlWindow);
    }
    return 0;
}

// Push a mouse motion event into SDL's event queue
static void pushSDLMouseMotion(float x, float y, float xrel, float yrel) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;
    SDL3_MouseMotionEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = SDL3_EVENT_MOUSE_MOTION;
    ev.windowID = getSDLWindowID();
    ev.which = 0;
    ev.state = 0;
    ev.x = x;
    ev.y = y;
    ev.xrel = xrel;
    ev.yrel = yrel;
    pSDL_PushEvent((void*)&ev);
}

// Push a mouse button event into SDL's event queue
// sdlButton: 1=left, 2=middle, 3=right (SDL convention)
static void pushSDLMouseButton(uint8_t sdlButton, bool down, float x, float y) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;
    SDL3_MouseButtonEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = down ? SDL3_EVENT_MOUSE_BUTTON_DOWN : SDL3_EVENT_MOUSE_BUTTON_UP;
    ev.windowID = getSDLWindowID();
    ev.which = 0;
    ev.button = sdlButton;
    ev.down = down;
    ev.clicks = 1;
    ev.x = x;
    ev.y = y;
    pSDL_PushEvent((void*)&ev);
}

// Push a keyboard event into SDL's event queue
static void pushSDLKeyboardEvent(SDL3_Scancode scancode, bool down) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;
    SDL3_KeyboardEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = down ? SDL3_EVENT_KEY_DOWN : SDL3_EVENT_KEY_UP;
    ev.windowID = getSDLWindowID();
    ev.which = 0;
    ev.scancode = scancode;
    ev.key = 0;
    ev.mod = 0;
    ev.down = down;
    ev.repeat = false;
    pSDL_PushEvent((void*)&ev);
}

// Push a mouse wheel event into SDL's event queue
static void pushSDLMouseWheel(float x, float y) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;
    SDL3_MouseWheelEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = SDL3_EVENT_MOUSE_WHEEL;
    ev.windowID = getSDLWindowID();
    ev.which = 0;
    ev.x = x;
    ev.y = y;
    ev.direction = 0;
    ev.mouse_x = cursorX;
    ev.mouse_y = cursorY;
    ev.integer_x = (int32_t)x;
    ev.integer_y = (int32_t)y;
    pSDL_PushEvent((void*)&ev);
}

// GLFW keycode → SDL_Scancode conversion
static int glfwKeyToSDLScancode(int glfwKey) {
    // Printable keys: ASCII-based, same as USB HID usage
    if (glfwKey >= GLFW_KEY_A && glfwKey <= GLFW_KEY_Z) return 4 + (glfwKey - GLFW_KEY_A);   // SDL_SCANCODE_A=4
    if (glfwKey >= GLFW_KEY_0 && glfwKey <= GLFW_KEY_9) return 39 + (glfwKey - GLFW_KEY_0);   // SDL_SCANCODE_0=39
    if (glfwKey >= GLFW_KEY_F1 && glfwKey <= GLFW_KEY_F25) return 58 + (glfwKey - GLFW_KEY_F1); // SDL_SCANCODE_F1=58
    if (glfwKey >= GLFW_KEY_NUMPAD_0 && glfwKey <= GLFW_KEY_NUMPAD_9) return 98 + (glfwKey - GLFW_KEY_NUMPAD_0);
    switch (glfwKey) {
        case GLFW_KEY_SPACE:           return 44;
        case GLFW_KEY_APOSTROPHE:      return 52;
        case GLFW_KEY_COMMA:           return 54;
        case GLFW_KEY_MINUS:           return 45;
        case GLFW_KEY_PERIOD:          return 55;
        case GLFW_KEY_SLASH:           return 56;
        case GLFW_KEY_SEMICOLON:       return 51;
        case GLFW_KEY_EQUAL:           return 46;
        case GLFW_KEY_LEFT_BRACKET:    return 47;
        case GLFW_KEY_BACKSLASH:       return 49;
        case GLFW_KEY_RIGHT_BRACKET:   return 48;
        case GLFW_KEY_GRAVE_ACCENT:    return 53;
        case GLFW_KEY_ESCAPE:          return 41;
        case GLFW_KEY_ENTER:           return 40;
        case GLFW_KEY_TAB:             return 43;
        case GLFW_KEY_BACKSPACE:       return 42;
        case GLFW_KEY_INSERT:          return 73;
        case GLFW_KEY_DELETE:          return 76;
        case GLFW_KEY_DPAD_RIGHT:      return 79;
        case GLFW_KEY_DPAD_LEFT:       return 80;
        case GLFW_KEY_DPAD_DOWN:       return 81;
        case GLFW_KEY_DPAD_UP:         return 82;
        case GLFW_KEY_PAGE_UP:         return 75;
        case GLFW_KEY_PAGE_DOWN:       return 78;
        case GLFW_KEY_HOME:            return 74;
        case GLFW_KEY_END:             return 77;
        case GLFW_KEY_CAPS_LOCK:       return 57;
        case GLFW_KEY_SCROLL_LOCK:     return 71;
        case GLFW_KEY_NUM_LOCK:        return 83;
        case GLFW_KEY_PRINT_SCREEN:    return 70;
        case GLFW_KEY_PAUSE:           return 72;
        case GLFW_KEY_LEFT_SHIFT:      return 225;
        case GLFW_KEY_LEFT_CONTROL:    return 224;
        case GLFW_KEY_LEFT_ALT:        return 226;
        case GLFW_KEY_LEFT_SUPER:      return 227;
        case GLFW_KEY_RIGHT_SHIFT:     return 229;
        case GLFW_KEY_RIGHT_CONTROL:   return 228;
        case GLFW_KEY_RIGHT_ALT:       return 230;
        case GLFW_KEY_RIGHT_SUPER:     return 231;
        case GLFW_KEY_MENU:            return 101;
        case GLFW_KEY_NUMPAD_ADD:      return 87;
        case GLFW_KEY_NUMPAD_SUBTRACT: return 86;
        case GLFW_KEY_NUMPAD_MULTIPLY: return 85;
        case GLFW_KEY_NUMPAD_DIVIDE:   return 84;
        case GLFW_KEY_NUMPAD_DECIMAL:  return 220;
        case GLFW_KEY_NUMPAD_ENTER:    return 88;
        case GLFW_KEY_NUMPAD_EQUAL:    return 103;
        default:                       return 0; // SDL_SCANCODE_UNKNOWN
    }
}

// SDL button ID mapping: GLFW uses 0-based, SDL uses 1-based
static uint8_t glfwButtonToSDLButton(int glfwButton) {
    switch (glfwButton) {
        case GLFW_MOUSE_BUTTON_LEFT:   return 1; // SDL_BUTTON_LEFT
        case GLFW_MOUSE_BUTTON_RIGHT:  return 3; // SDL_BUTTON_RIGHT
        case GLFW_MOUSE_BUTTON_MIDDLE: return 2; // SDL_BUTTON_MIDDLE
        default:                       return (uint8_t)(glfwButton + 1);
    }
}

jint (*orig_ProcessImpl_forkAndExec)(JNIEnv *env, jobject process, jint mode, jbyteArray helperpath, jbyteArray prog, jbyteArray argBlock, jint argc, jbyteArray envBlock, jint envc, jbyteArray dir, jintArray std_fds, jboolean redirectErrorStream);
jlong (*orig_ProcessHandleImpl_isAlive0)(JNIEnv *env, jclass clazz, jlong jpid);

NSString* processPath(NSString* path) {
    if ([path hasPrefix:@"file:"]) {
        path = [path substringFromIndex:5].stringByRemovingPercentEncoding;
    }
    path = path.stringByResolvingSymlinksInPath;

    NSString *prefix = @"file";
    if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"shareddocuments://"]] &&
      ![path hasPrefix:@"/var/mobile/Documents"]) {
        // Prefer opening in Files if containerized
        prefix = @"shareddocuments";
    } else if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"filza://"]]) {
        // Open in Filza if installed
        prefix = @"filza";
    } else if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"santander://"]]) {
        // Open in Santander if installed
        prefix = @"santander";
    }

    return [NSString stringWithFormat:@"%@://%@", prefix, path];
}

void openURLGlobal(NSString *path) {
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([path hasPrefix:@"http"]) {
            openLink(UIWindow.mainWindow.rootViewController, [NSURL URLWithString:path]);
            dispatch_group_leave(group);
            return;
        }
        NSString *realPath = processPath(path);
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:realPath] options:@{} completionHandler:^(BOOL success) {
            if (success) {
                NSLog(@"Opened \"%@\"", realPath);
            } else {
                NSLog(@"Failed to open \"%@\"", realPath);
            }
            dispatch_group_leave(group);
        }];
    });

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}

/**
 * Hooked version of java.lang.UNIXProcess.forkAndExec()
 * which is used to handle the "open" command.
 */
jint
hooked_ProcessImpl_forkAndExec(JNIEnv *env, jobject process, jint mode, jbyteArray helperpath, jbyteArray prog, jbyteArray argBlock, jint argc, jbyteArray envBlock, jint envc, jbyteArray dir, jintArray std_fds, jboolean redirectErrorStream) {
    char *pProg = (char *)((*env)->GetByteArrayElements(env, prog, NULL));

    // Here we only handle the "open" command
    if (strcmp(basename(pProg), "open")) {
        (*env)->ReleaseByteArrayElements(env, prog, (jbyte *)pProg, 0);
        return orig_ProcessImpl_forkAndExec(env, process, mode, helperpath, prog, argBlock, argc, envBlock, envc, dir, std_fds, redirectErrorStream);
    }

    char *path = (char *)((*env)->GetByteArrayElements(env, argBlock, NULL));
    openURLGlobal(@(path));

    (*env)->ReleaseByteArrayElements(env, prog, (jbyte *)pProg, 0);
    (*env)->ReleaseByteArrayElements(env, argBlock, (jbyte *)path, 0);
    return 0;
}

/**
 * Hooked version of java.lang.ProcessHandleImpl.isAlive0()
 * which is used to ignore "Operation not permitted"
 */
jlong hooked_ProcessHandleImpl_isAlive0(JNIEnv *env, jclass clazz, jlong jpid) {
    jlong result = orig_ProcessHandleImpl_isAlive0(env, clazz, jpid);
    if ((*env)->ExceptionOccurred(env)) {
        (*env)->ExceptionClear(env);
    }
    return result;
}

// Part of awt_bridge
void CTCClipboard_nQuerySystemClipboard(JNIEnv *env, jclass clazz) {
    if(method_SystemClipboardDataReceived == NULL) {
        class_CTCClipboard = (*env)->NewGlobalRef(env, clazz);
        method_SystemClipboardDataReceived = (*env)->GetStaticMethodID(env, clazz, "systemClipboardDataReceived", "(Ljava/lang/String;Ljava/lang/String;)V");
    }
    // From Java_net_kdt_pojavlaunch_AWTInputBridge_nativeClipboardReceived
    // Note: we cannot use main_queue here as it will cause deadlock
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        JNIEnv *env;
        (*runtimeJavaVMPtr)->AttachCurrentThread(runtimeJavaVMPtr, &env, NULL);
        const char* mimeChars = "text/plain";
        (*env)->CallStaticVoidMethod(env, class_CTCClipboard, method_SystemClipboardDataReceived,
            UIKit_accessClipboard(env, CLIPBOARD_PASTE, NULL),
            (*env)->NewStringUTF(env, mimeChars));
        (*runtimeJavaVMPtr)->DetachCurrentThread(runtimeJavaVMPtr);
    });
}

void CTCClipboard_nPutClipboardData(JNIEnv* env, jclass clazz, jstring clipboardData, jstring clipboardDataMime) {
    // TODO: handle non-text data(?)
    UIKit_accessClipboard(env, CLIPBOARD_COPY, clipboardData);
}

void CTCDesktopPeer_openGlobal(JNIEnv *env, jclass clazz, jstring path) {
    const char* stringChars = (*env)->GetStringUTFChars(env, path, NULL);
    openURLGlobal(@(stringChars));
    (*env)->ReleaseStringUTFChars(env, path, stringChars);
}

void hackFix18LWJGL(void *addr) {
    addr = (void *)((uintptr_t)addr & ~PAGE_MASK);
    if(DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED)) return;
    if(!mprotect(addr, PAGE_SIZE, PROT_READ | PROT_EXEC)) return;
    // FIXME: For some reason the one page in liblwjgl.dylib is mapped as r-x/rwx (COW), and recent builds on iOS 18 switches it to r--/rw- causing codesign failure. Here we hack it to map anon page to get r-x back
    char tempPage[PAGE_SIZE];
    memcpy(tempPage, addr, PAGE_SIZE);
    void *result = mmap(addr, PAGE_SIZE, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
    if (result == MAP_FAILED) {
        NSLog(@"hackFix18LWJGL: mmap failed: %s", strerror(errno));
        return;
    }
    memcpy(addr, tempPage, PAGE_SIZE);
    mprotect(addr, PAGE_SIZE, PROT_READ | PROT_EXEC);
}

void registerOpenHandler(JNIEnv *env) {
    jclass cls;

    // Hook forkAndExec
    orig_ProcessImpl_forkAndExec = dlsym(RTLD_DEFAULT, "Java_java_lang_UNIXProcess_forkAndExec");
    if (!orig_ProcessImpl_forkAndExec) {
        orig_ProcessImpl_forkAndExec = dlsym(RTLD_DEFAULT, "Java_java_lang_ProcessImpl_forkAndExec");
        cls = (*env)->FindClass(env, "java/lang/ProcessImpl");
    } else {
        cls = (*env)->FindClass(env, "java/lang/UNIXProcess");
    }
    JNINativeMethod forkAndExecMethod[] = {
        {"forkAndExec", "(I[B[B[BI[BI[B[IZ)I", (void *)&hooked_ProcessImpl_forkAndExec}
    };
    (*env)->RegisterNatives(env, cls, forkAndExecMethod, 1);

    // (Java 17 only) Hook isAlive0
    cls = (*env)->FindClass(env, "java/lang/ProcessHandleImpl");
    if ((*env)->ExceptionOccurred(env)) {
        // Java 8
        (*env)->ExceptionClear(env);
    } else {
        orig_ProcessHandleImpl_isAlive0 = dlsym(RTLD_DEFAULT, "Java_java_lang_ProcessHandleImpl_isAlive0");
        JNINativeMethod isAlive0Method[] = {
            {"isAlive0", "(J)J", (void *)&hooked_ProcessHandleImpl_isAlive0}
        };
        (*env)->RegisterNatives(env, cls, isAlive0Method, 1);
    }

    // Register CTCClipboard natives
    cls = (*env)->FindClass(env, "net/java/openjdk/cacio/ctc/CTCClipboard");
    if ((*env)->ExceptionOccurred(env)) {
        // Java 17
        (*env)->ExceptionClear(env);
        cls = (*env)->FindClass(env, "com/github/caciocavallosilano/cacio/ctc/CTCClipboard");
    }
    JNINativeMethod clipboardMethods[] = {
        {"nQuerySystemClipboard", "()V", (void *)&CTCClipboard_nQuerySystemClipboard},
        {"nPutClipboardData", "(Ljava/lang/String;Ljava/lang/String;)V", (void *)&CTCClipboard_nPutClipboardData}
    };
    (*env)->RegisterNatives(env, cls, clipboardMethods, 2);

    // Register CTCDesktopPeer natives
    cls = (*env)->FindClass(env, "net/java/openjdk/cacio/ctc/CTCDesktopPeer");
    if ((*env)->ExceptionOccurred(env)) {
        // Java 17, not available
        //(*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return;
    }
    JNINativeMethod peerOpenMethods[] = {
        {"openFile", "(Ljava/lang/String;)V", (void *)&CTCDesktopPeer_openGlobal},
        {"openUri", "(Ljava/lang/String;)V", (void *)&CTCDesktopPeer_openGlobal}
    };
    (*env)->RegisterNatives(env, cls, peerOpenMethods, 2);
}

// JNI_OnLoad
void JNI_OnLoadGLFW() {
    if (runtimeJNIEnvPtr == NULL) {
        NSLog(@"[JNI] JNI_OnLoadGLFW: runtimeJNIEnvPtr is NULL, skipping");
        return;
    }
    jclass clazz = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "org/lwjgl/glfw/GLFW");
    if (clazz == NULL) {
        if ((*runtimeJNIEnvPtr)->ExceptionOccurred(runtimeJNIEnvPtr)) {
            (*runtimeJNIEnvPtr)->ExceptionDescribe(runtimeJNIEnvPtr);
            (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        }
        NSLog(@"[JNI] JNI_OnLoadGLFW: FindClass(org/lwjgl/glfw/GLFW) returned NULL, skipping registration");
        return;
    }
    vmGlfwClass = (*runtimeJNIEnvPtr)->NewGlobalRef(runtimeJNIEnvPtr, clazz);
    method_internalWindowSizeChanged = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, vmGlfwClass, "internalWindowSizeChanged", "(JII)V");
    if ((*runtimeJNIEnvPtr)->ExceptionOccurred(runtimeJNIEnvPtr)) {
        (*runtimeJNIEnvPtr)->ExceptionDescribe(runtimeJNIEnvPtr);
        (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        method_internalWindowSizeChanged = NULL;
    }
    jfieldID field_keyDownBuffer = (*runtimeJNIEnvPtr)->GetStaticFieldID(runtimeJNIEnvPtr, vmGlfwClass, "keyDownBuffer", "Ljava/nio/ByteBuffer;");
    if ((*runtimeJNIEnvPtr)->ExceptionOccurred(runtimeJNIEnvPtr)) {
        (*runtimeJNIEnvPtr)->ExceptionDescribe(runtimeJNIEnvPtr);
        (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        field_keyDownBuffer = NULL;
    }
    if (field_keyDownBuffer != NULL) {
        jobject keyDownBufferJ = (*runtimeJNIEnvPtr)->GetStaticObjectField(runtimeJNIEnvPtr, vmGlfwClass, field_keyDownBuffer);
        if (keyDownBufferJ != NULL) {
            keyDownBuffer = (*runtimeJNIEnvPtr)->GetDirectBufferAddress(runtimeJNIEnvPtr, keyDownBufferJ);
        }
    }
    NSLog(@"[JNI] JNI_OnLoadGLFW registered, class=%p, method=%p, keyDownBuffer=%p", (void *)vmGlfwClass, (void *)method_internalWindowSizeChanged, (void *)keyDownBuffer);
}

jint JNI_OnLoad(JavaVM* vm, void* reserved) {
    runtimeJavaVMPtr = vm;

    // Initialize SDL3 event function pointers for MC 26.3+ input
    initSDLEventFuncs();

    JNIEnv *env;
    (*runtimeJavaVMPtr)->GetEnv(runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    registerOpenHandler(env);
    if (!getenv("POJAV_SKIP_JNI_GLFW")) {
        runtimeJNIEnvPtr = env;
        JNI_OnLoadGLFW();
    }

    return JNI_VERSION_1_4;
}

// Should be?
void JNI_OnUnload(JavaVM* vm, void* reserved) {
    runtimeJNIEnvPtr = NULL;
}

#define ADD_CALLBACK_WWIN(NAME) \
JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSet##NAME##Callback(JNIEnv * env, jclass cls, jlong window, jlong callbackptr) { \
    void** oldCallback = (void**) &GLFW_invoke_##NAME; \
    GLFW_invoke_##NAME = (GLFW_invoke_##NAME##_func*) (uintptr_t) callbackptr; \
    return (jlong) (uintptr_t) *oldCallback; \
}

ADD_CALLBACK_WWIN(Char)
ADD_CALLBACK_WWIN(CharMods)
ADD_CALLBACK_WWIN(CursorEnter)
ADD_CALLBACK_WWIN(CursorPos)
ADD_CALLBACK_WWIN(FramebufferSize)
ADD_CALLBACK_WWIN(Key)
ADD_CALLBACK_WWIN(MouseButton)
ADD_CALLBACK_WWIN(Scroll)
ADD_CALLBACK_WWIN(WindowPos)
ADD_CALLBACK_WWIN(WindowSize)

#undef ADD_CALLBACK_WWIN

void handleFramebufferSizeJava(void* window, int w, int h) {
    if(GLFW_invoke_CursorEnter)GLFW_invoke_CursorEnter(window, 1);
    if(GLFW_invoke_WindowPos)GLFW_invoke_WindowPos(window, 0, 0);
    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(runtimeJNIEnvPtr, vmGlfwClass, method_internalWindowSizeChanged, (long)window, w, h);
}

void pojavPumpEvents(void* window) {
    static BOOL setInputReady = NO;
    static int pumpCount = 0;
    if(!setInputReady) {
        setInputReady = YES;
        CallbackBridge_nativeSetInputReady(YES);
        NSLog(@"[InputDiag] pojavPumpEvents: isInputReady set to YES, showingWindow=%p", (void*)showingWindow);
    }
    pumpCount++;
    if (pumpCount <= 5 || pumpCount % 300 == 0) {
        NSLog(@"[InputDiag] pojavPumpEvents #%d: window=%p GLFW_invoke_Key=%p GLFW_invoke_CursorPos=%p GLFW_invoke_Char=%p isGrabbing=%d isUseStackQueue=%d eventCounter=%d",
            pumpCount, window,
            (void*)GLFW_invoke_Key, (void*)GLFW_invoke_CursorPos, (void*)GLFW_invoke_Char,
            isGrabbing, isUseStackQueueCall,
            (int)atomic_load_explicit(&eventCounter, memory_order_relaxed));
    }
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);
    if((cLastX != cursorX || cLastY != cursorY) && GLFW_invoke_CursorPos) {
        cLastX = cursorX;
        cLastY = cursorY;
        if (isUseStackQueueCall)
            GLFW_invoke_CursorPos(window, cursorX, cursorY);
    }
    for(size_t i = 0; i < counter; i++) {
        GLFWInputEvent event = events[i];
        switch(event.type) {
            case EVENT_TYPE_CHAR:
                // NSLog(@"[KeyboardDebug] Queue: Processing EVENT_TYPE_CHAR for character %d", event.i1);
                if(GLFW_invoke_Char) GLFW_invoke_Char(window, event.i1);
                break;
            case EVENT_TYPE_CHAR_MODS:
                // NSLog(@"[KeyboardDebug] Queue: Processing EVENT_TYPE_CHAR_MODS for character %d", event.i1);
                if(GLFW_invoke_CharMods) {
                    GLFW_invoke_CharMods(window, event.i1, event.i2);
                } else if (GLFW_invoke_Char) {
                    //NSLog(@"[KeyboardDebug] Queue: Fallback to GLFW_invoke_Char for character %d", event.i1);
                    GLFW_invoke_Char(window, event.i1);
                }
                break;
            case EVENT_TYPE_KEY:
                if(GLFW_invoke_Key) GLFW_invoke_Key(window, event.i1, event.i2, event.i3, event.i4);
                break;
            case EVENT_TYPE_MOUSE_BUTTON:
                if(GLFW_invoke_MouseButton) GLFW_invoke_MouseButton(window, event.i1, event.i2, event.i3);
                break;
            case EVENT_TYPE_SCROLL:
                if(GLFW_invoke_Scroll) GLFW_invoke_Scroll(window, event.f1, event.f2);
                break;
            case EVENT_TYPE_FRAMEBUFFER_SIZE:
                handleFramebufferSizeJava(window, event.i1, event.i2);
                if(GLFW_invoke_FramebufferSize) GLFW_invoke_FramebufferSize(window, event.i1, event.i2);
                break;
            case EVENT_TYPE_WINDOW_SIZE:
                handleFramebufferSizeJava(window, event.i1, event.i2);
                if(GLFW_invoke_WindowSize) GLFW_invoke_WindowSize(window, event.i1, event.i2);
                break;
        }
    }
    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}
void pojavRewindEvents() {
    atomic_store_explicit(&eventCounter, 0, memory_order_release);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPos(JNIEnv *env, jclass clazz, jlong window, jobject xpos,
                                          jobject ypos) {
    *(double*)(*env)->GetDirectBufferAddress(env, xpos) = cursorX;
    *(double*)(*env)->GetDirectBufferAddress(env, ypos) = cursorY;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPosA(JNIEnv *env, jclass clazz, jlong window,
                                            jdoubleArray xpos, jdoubleArray ypos) {
    (*env)->SetDoubleArrayRegion(env, xpos, 0,1, &cursorX);
    (*env)->SetDoubleArrayRegion(env, ypos, 0,1, &cursorY);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_glfwSetCursorPos(JNIEnv *env, jclass clazz, jlong window, jdouble xpos,
                                          jdouble ypos) {
    cLastX = cursorX = xpos;
    cLastY = cursorY = ypos;
}

void sendData(short type, int i1, int i2, short i3, short i4) {
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);
    if (counter < 7999) {
        GLFWInputEvent *event = &events[counter++];
        event->type = type;
        event->i1 = i1;
        event->i2 = i2;
        event->i3 = i3;
        event->i4 = i4;
    }
    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}

void sendDataFloat(short type, float i1, float i2, short i3, short i4) {
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);
    if (counter < 7999) {
        GLFWInputEvent *event = &events[counter++];
        event->type = type;
        event->f1 = i1;
        event->f2 = i2;
        event->i3 = i3;
        event->i4 = i4;
    }
    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}

void closeGLFWWindow() {
    NSLog(@"Closing GLFW window");

    /*
    jclass glfwClazz = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "org/lwjgl/glfw/GLFW");
    assert(glfwClazz != NULL);
    jmethodID glfwMethod = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, glfwMethod, "glfwSetWindowShouldClose", "(JZ)V");
    assert(glfwMethod != NULL);
    
    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(
        runtimeJNIEnvPtr,
        glfwClazz, glfwMethod,
        (jlong) showingWindow, JNI_TRUE
    );
    */
    exit(-1);
}

const int hotbarKeys[9] = {
    GLFW_KEY_1, GLFW_KEY_2, GLFW_KEY_3,
    GLFW_KEY_4, GLFW_KEY_5, GLFW_KEY_6,
    GLFW_KEY_7, GLFW_KEY_8, GLFW_KEY_9
};
int guiScale = 1;
int mcscale(CGFloat input) {
    return (int)((guiScale * input)/resolutionScale);
}
int callback_SurfaceViewController_touchHotbar(CGFloat x, CGFloat y) {
    if (isGrabbing == JNI_FALSE) {
        return -1;
    }

    int barHeight = mcscale(20);
    int barY = physicalHeight - barHeight;
    if (y < barY) return -1;

    int barWidth = mcscale(180);
    int barX = (physicalWidth / 2) - (barWidth / 2);
    if (x < barX || x >= barX + barWidth) return -1;

    return hotbarKeys[(int) MathUtils_map(x, barX, barX + barWidth, 0, 9)];
}

JNIEXPORT void JNICALL Java_net_kdt_pojavlaunch_uikit_UIKit_updateMCGuiScale(JNIEnv* env, jclass clazz, jint scale) {
    guiScale = scale;
}

JNIEXPORT jstring JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard(JNIEnv* env, jclass clazz, jint action, jstring copySrc) {
    NSDebugLog(@"Debug: Clipboard access is going on\n");
    return UIKit_accessClipboard(env, action, copySrc);
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(JNIEnv* env, jclass clazz, jboolean grabbing, jfloat xset, jfloat yset) {
    isGrabbing = grabbing;

    // Manage SDL cursor visibility: hide when grabbing (in-game), show when not (menu)
    static SDL_HideCursor_func *pSDL_HideCursor = NULL;
    static SDL_ShowCursor_func *pSDL_ShowCursor = NULL;
    static BOOL cursorFuncsResolved = NO;
    if (!cursorFuncsResolved) {
        pSDL_HideCursor = dlsym(RTLD_DEFAULT, "SDL_HideCursor");
        pSDL_ShowCursor = dlsym(RTLD_DEFAULT, "SDL_ShowCursor");
        cursorFuncsResolved = YES;
    }
    if (pSDL_HideCursor && pSDL_ShowCursor) {
        if (grabbing) {
            pSDL_HideCursor();
            NSLog(@"[InputDiag] nativeSetGrabbing: SDL_HideCursor called");
        } else {
            pSDL_ShowCursor();
            NSLog(@"[InputDiag] nativeSetGrabbing: SDL_ShowCursor called");
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        SurfaceViewController *vc = ((SurfaceViewController *)UIWindow.mainWindow.rootViewController);
        [vc updateGrabState];
    });
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeIsGrabbing(JNIEnv* env, jclass clazz) {
    return isGrabbing;
}

void CallbackBridge_nativeSetInputReady(BOOL inputReady) {
    isInputReady = inputReady;
    if (inputReady) {
        if (GLFW_invoke_FramebufferSize) {
            hackFix18LWJGL(GLFW_invoke_FramebufferSize);
            GLFW_invoke_FramebufferSize((void*) showingWindow, windowWidth, windowHeight);
        }
        if (GLFW_invoke_WindowSize) {
            GLFW_invoke_FramebufferSize((void*) showingWindow, windowWidth, windowHeight);
        }
    }
}

BOOL CallbackBridge_nativeSendChar(jchar codepoint /* jint codepoint */) {
    if (GLFW_invoke_Char && isInputReady) {
        if (isUseStackQueueCall) {
            sendData(EVENT_TYPE_CHAR, codepoint, 0, 0, 0);
        } else {
            GLFW_invoke_Char((void*) showingWindow, (unsigned int) codepoint);
            // return lwjgl2_triggerCharEvent(codepoint);
        }
        return YES;
    }
    return NO;
}

BOOL CallbackBridge_nativeSendCharMods(jchar codepoint, int mods) {
    // NSLog(@"[KeyboardDebug] Bridge: Got character code=%d, modifiers=%d", codepoint, mods);
    // NSLog(@"[KeyboardDebug] Bridge: Game status: GLFW_invoke_CharMods=%p, GLFW_invoke_Char=%p, isInputReady=%d", 
    //      GLFW_invoke_CharMods, GLFW_invoke_Char, isInputReady);

    if ((GLFW_invoke_CharMods || GLFW_invoke_Char) && isInputReady) {
        if (isUseStackQueueCall) {
            // NSLog(@"[KeyboardDebug] Bridge: Sending character %d to stack-queue (isUseStackQueueCall)", codepoint);
            sendData(EVENT_TYPE_CHAR_MODS, (unsigned int) codepoint, mods, 0, 0);
        } else {
            if (GLFW_invoke_CharMods) {
                // NSLog(@"[KeyboardDebug] Bridge: Direct call to GLFW_invoke_CharMods for character %d", codepoint);
                GLFW_invoke_CharMods((void*) showingWindow, codepoint, mods);
            } else {
                // NSLog(@"[KeyboardDebug] Bridge: Fallback! Direct call to GLFW_invoke_Char for character %d", codepoint);
                GLFW_invoke_Char((void*) showingWindow, (unsigned int) codepoint);
            }
        }
        return YES;
    }
    
    // NSLog(@"[KeyboardDebug] Bridge CRITICAL ERROR: Character %d DISCARDED! Reason: No handlers or game not ready.", codepoint);
    return NO;
}
/*
JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSendCursorEnter(JNIEnv* env, jclass clazz, jint entered) {
    if (GLFW_invoke_CursorEnter && isInputReady) {
        GLFW_invoke_CursorEnter(showingWindow, entered);
    }
}
*/
void CallbackBridge_nativeSendCursorPos(char event, CGFloat x, CGFloat y) {
    static int cursorSendCount = 0;
    cursorSendCount++;
    if (cursorSendCount <= 10 || cursorSendCount % 50 == 0) {
        NSLog(@"[InputDiag] sendCursorPos #%d: event=%d x=%.1f y=%.1f GLFW_invoke_CursorPos=%p isInputReady=%d g_sdlWindow=%p",
            cursorSendCount, event, x, y,
            (void*)GLFW_invoke_CursorPos, isInputReady, g_sdlWindow);
    }

    // Update cursor position tracking regardless
    switch (event) {
        case ACTION_DOWN:
        case ACTION_UP:
            if (!isGrabbing) {
                cursorX = x;
                cursorY = y;
            }
            break;

        case ACTION_MOVE:
            if (isGrabbing) {
                cursorX += x - cLastX;
                cursorY += y - cLastY;
            } else {
                cursorX = x;
                cursorY = y;
            }
            break;

        case ACTION_MOVE_MOTION:
            cursorX += x;
            cursorY += y;
            break;
    }

    // Path A: GLFW callbacks (older MC versions)
    if (GLFW_invoke_CursorPos && isInputReady) {
        if (!isUseStackQueueCall) {
            GLFW_invoke_CursorPos((void*) showingWindow, (double) cursorX, (double) cursorY);
        }
    }

    // Path B: SDL3 events (MC 26.3+)
    // When GLFW callbacks are NULL, we inject SDL mouse events directly.
    // ACTION_DOWN/UP need mouse button events; ACTION_MOVE needs motion events.
    // ACTION_MOVE_MOTION carries deltas for camera rotation (xrel/yrel).
    if (!GLFW_invoke_CursorPos && g_sdlWindow) {
        if (event == ACTION_MOVE_MOTION) {
            // x, y are deltas (from SurfaceViewController's isGrabbing path)
            // Send as relative motion so MC rotates camera
            pushSDLMouseMotion((float)cursorX, (float)cursorY, (float)x, (float)y);
        } else {
            pushSDLMouseMotion((float)cursorX, (float)cursorY, 0, 0);
            if (event == ACTION_DOWN) {
                pushSDLMouseButton(1, true, (float)cursorX, (float)cursorY);
            } else if (event == ACTION_UP) {
                pushSDLMouseButton(1, false, (float)cursorX, (float)cursorY);
            }
        }
    }
}

char getKeyModifiers(int key, int action) {
    static char currMods;
    char mod;
    switch (key) {
        case GLFW_KEY_LEFT_SHIFT:
            mod = GLFW_MOD_SHIFT;
            break;
        case GLFW_KEY_LEFT_CONTROL:
            mod = GLFW_MOD_CONTROL;
            break;
        case GLFW_KEY_LEFT_ALT:
            mod = GLFW_MOD_ALT;
            break;
        case GLFW_KEY_CAPS_LOCK:
            mod = GLFW_MOD_CAPS_LOCK;
            break;
        case GLFW_KEY_NUM_LOCK:
            mod = GLFW_MOD_NUM_LOCK;
            break;
        default:
            return currMods;
    }
    if (action) {
        currMods |= mod;
    } else {
        currMods &= ~mod;
    }
    return currMods;
}

void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods) {
    static int keySendCount = 0;
    keySendCount++;
    if (keySendCount <= 10 || keySendCount % 50 == 0) {
        NSLog(@"[InputDiag] sendKey #%d: key=%d scancode=%d action=%d mods=%d GLFW_invoke_Key=%p isInputReady=%d g_sdlWindow=%p",
            keySendCount, key, scancode, action, mods,
            (void*)GLFW_invoke_Key, isInputReady, g_sdlWindow);
    }

    // Path A: GLFW callbacks (older MC versions)
    if (GLFW_invoke_Key && isInputReady) {
        keyDownBuffer[MAX(0, key-31)]=(jbyte)action;
        if (mods == 0) {
            mods = getKeyModifiers(key, action);
        }

        if (isUseStackQueueCall) {
            sendData(EVENT_TYPE_KEY, key, scancode, action, mods);
        } else {
            GLFW_invoke_Key((void*) showingWindow, key, scancode, action, mods);
        }
    }

    // Path B: SDL3 events (MC 26.3+)
    if (!GLFW_invoke_Key && g_sdlWindow) {
        int sdlScancode = glfwKeyToSDLScancode(key);
        if (sdlScancode != 0) {
            pushSDLKeyboardEvent(sdlScancode, action != 0);
        }
    }

    // On macOS, Minecraft expects the Command key
    if (key == GLFW_KEY_LEFT_CONTROL) {
        CallbackBridge_nativeSendKey(GLFW_KEY_LEFT_SUPER, 0, action, mods);
    } else if (key == GLFW_KEY_RIGHT_CONTROL) {
        CallbackBridge_nativeSendKey(GLFW_KEY_RIGHT_SUPER, 0, action, mods);
    }
}

void CallbackBridge_nativeSendMouseButton(int button, int action, int mods) {
    // Path A: GLFW callbacks (older MC versions)
    if (isInputReady) {
        if (button == -1) {
        } else if (GLFW_invoke_MouseButton) {
            if (mods == 0) {
                mods = getKeyModifiers(0, action);
            }

            if (isUseStackQueueCall) {
                sendData(EVENT_TYPE_MOUSE_BUTTON, button, action, mods, 0);
            } else {
                GLFW_invoke_MouseButton((void*) showingWindow, button, action, mods);
            }
        }
    }

    // Path B: SDL3 events (MC 26.3+)
    if (!GLFW_invoke_MouseButton && g_sdlWindow && button >= 0) {
        pushSDLMouseButton(glfwButtonToSDLButton(button), action != 0, (float)cursorX, (float)cursorY);
    }
}

void CallbackBridge_nativeSendScreenSize(int width, int height) {
    windowWidth = width;
    windowHeight = height;
    
    if (isInputReady) {
        if (GLFW_invoke_FramebufferSize) {
            if (isUseStackQueueCall) {
                sendData(EVENT_TYPE_FRAMEBUFFER_SIZE, width, height, 0, 0);
            } else {
                GLFW_invoke_FramebufferSize((void*) showingWindow, width, height);
            }
        }
        if (GLFW_invoke_WindowSize) {
            if (isUseStackQueueCall) {
                sendData(EVENT_TYPE_WINDOW_SIZE, width, height, 0, 0);
            } else {
                GLFW_invoke_WindowSize((void*) showingWindow, width, height);
            }
        }
    }
    
    // return (isInputReady && (GLFW_invoke_FramebufferSize || GLFW_invoke_WindowSize));
}

void CallbackBridge_nativeSendScroll(CGFloat xoffset, CGFloat yoffset) {
    // Path A: GLFW callbacks
    if (GLFW_invoke_Scroll && isInputReady) {
        if (isUseStackQueueCall) {
            sendDataFloat(EVENT_TYPE_SCROLL, xoffset, yoffset, 0, 0);
        } else {
            GLFW_invoke_Scroll((void*) showingWindow, (double) xoffset, (double) yoffset);
        }
    }

    // Path B: SDL3 events (MC 26.3+)
    if (!GLFW_invoke_Scroll && g_sdlWindow) {
        pushSDLMouseWheel((float)xoffset, (float)yoffset);
    }
}
JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetShowingWindow(JNIEnv* env, jclass clazz, jlong window) {
    showingWindow = (long) window;
}

void CallbackBridge_pauseGameIfNeed() {
    if (isGrabbing) {
        CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 1, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 0, 0);
    }
}
