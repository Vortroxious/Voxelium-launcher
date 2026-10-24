// In-process JVM launcher for the Milestone 5 smoke test.
//
// Unlike Amethyst (which calls JLI_Launch and lets the launcher exit the
// process), this uses the JNI invocation API so the app survives the run.
// JIT preconditions and exception-port handling follow Amethyst-iOS
// Natives/JavaLauncher.m (GPL-3.0).

#import "JVMBridge.h"
#import "JITSupport.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <unistd.h>
#include "jni/jni.h"

typedef jint (*CreateJavaVM_t)(JavaVM **, void **, void *);

// Called by the JVM instead of exit() (the JNI invocation API's "exit" hook), e.g. when
// Minecraft calls System.exit(0) after "Stopping!". exit() alone ended the app on the
// spot, which looked like a crash. Like Amethyst (main_hook.m, hooked_exit, GPL-3.0),
// first send the app to the Home Screen with UIKit's suspend animation, then exit.
static void vxJVMExitHook(jint code) {
    printf("[JVMBridge] Java called exit(%d): closing the app to the Home Screen\n", (int)code);
    fflush(stdout);
    fflush(stderr);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;
        SEL suspend = NSSelectorFromString(@"suspend");
        if ([app respondsToSelector:suspend]) ((void (*)(id, SEL))objc_msgSend)(app, suspend);
    });
    usleep(400 * 1000);   // let the close animation start
    exit(code);
}

// The running VM, for VXJVMRequestGC (one VM per process).
static _Atomic(JavaVM *) gRunningVM;

void VXJVMRequestGC(const char *why) {
    JavaVM *vm = atomic_load(&gRunningVM);
    if (!vm) return;
    // iOS repeats memory warnings every ~0.5 s while the app stays near its limit, and
    // each full GC paused the game for 300-800 ms (build 0331): at most one per 20 s.
    static atomic_bool busy;
    static _Atomic uint64_t lastStart;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - atomic_load(&lastStart) < 20ull * NSEC_PER_SEC) return;
    if (atomic_exchange(&busy, true)) return;
    atomic_store(&lastStart, now);
    const char *reason = why ? why : "request";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        JNIEnv *env = NULL;
        if ((*vm)->AttachCurrentThreadAsDaemon(vm, (void **)&env, NULL) == JNI_OK && env) {
            uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            jclass system = (*env)->FindClass(env, "java/lang/System");
            jmethodID gc = system ? (*env)->GetStaticMethodID(env, system, "gc", "()V") : NULL;
            if (gc) (*env)->CallStaticVoidMethod(env, system, gc);
            if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
            printf("[VXMEM] System.gc() for %s took %llu ms\n", reason,
                   (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1000000);
            fflush(stdout);
            (*vm)->DetachCurrentThread(vm);
        }
        atomic_store(&busy, false);
    });
}

@implementation VXJVMResult
- (instancetype)initWithStatus:(VXJVMStatus)status message:(NSString *)message {
    if ((self = [super init])) {
        _status = status;
        _message = [message copy];
    }
    return self;
}
@end

static VXJVMResult *result(VXJVMStatus s, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static VXJVMResult *result(VXJVMStatus s, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[JVMBridge] %@", msg);
    return [[VXJVMResult alloc] initWithStatus:s message:msg];
}

typedef struct {
    const char *libjvm;
    char **options;
    int optionCount;
    const char *mainClass;   // slash-separated
    char **args;
    int argCount;
    dispatch_semaphore_t done;
    VXJVMStatus status;
    char message[1024];
} JVMRun;

static void *jvmThread(void *p) {
    JVMRun *run = p;
    void *lib = dlopen(run->libjvm, RTLD_NOW | RTLD_GLOBAL);
    if (!lib) {
        run->status = VXJVMStatusLoadFailed;
        snprintf(run->message, sizeof(run->message), "dlopen(libjvm) failed: %s", dlerror());
        dispatch_semaphore_signal(run->done);
        return NULL;
    }
    CreateJavaVM_t create = (CreateJavaVM_t)dlsym(lib, "JNI_CreateJavaVM");
    if (!create) {
        run->status = VXJVMStatusLoadFailed;
        snprintf(run->message, sizeof(run->message), "JNI_CreateJavaVM not found: %s", dlerror());
        dispatch_semaphore_signal(run->done);
        return NULL;
    }

    JavaVMOption *opts = calloc((size_t)run->optionCount + 1, sizeof(JavaVMOption));
    for (int i = 0; i < run->optionCount; i++) opts[i].optionString = run->options[i];
    opts[run->optionCount].optionString = "exit";
    opts[run->optionCount].extraInfo = (void *)vxJVMExitHook;
    JavaVMInitArgs vmArgs = {
        .version = JNI_VERSION_1_8,
        .nOptions = run->optionCount + 1,
        .options = opts,
        .ignoreUnrecognized = JNI_FALSE,
    };

    printf("[JVMBridge] JNI_CreateJavaVM with %d options\n", run->optionCount);
    for (int i = 0; i < run->optionCount; i++) printf("[JVMBridge]   %s\n", run->options[i]);
    fflush(stdout);

    JavaVM *vm = NULL;
    JNIEnv *env = NULL;
    jint rc = create(&vm, (void **)&env, &vmArgs);
    free(opts);
    if (rc != JNI_OK) {
        run->status = VXJVMStatusCreateFailed;
        snprintf(run->message, sizeof(run->message), "JNI_CreateJavaVM returned %d", rc);
        dispatch_semaphore_signal(run->done);
        return NULL;
    }

    atomic_store(&gRunningVM, vm);
    jclass cls = (*env)->FindClass(env, run->mainClass);
    jmethodID main = cls ? (*env)->GetStaticMethodID(env, cls, "main", "([Ljava/lang/String;)V") : NULL;
    if (!main) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionDescribe(env);
        run->status = VXJVMStatusMainNotFound;
        snprintf(run->message, sizeof(run->message), "main not found in %s", run->mainClass);
        dispatch_semaphore_signal(run->done);
        return NULL;
    }
    jclass stringClass = (*env)->FindClass(env, "java/lang/String");
    jobjectArray jargs = (*env)->NewObjectArray(env, run->argCount, stringClass, NULL);
    for (int i = 0; i < run->argCount; i++) {
        jstring s = (*env)->NewStringUTF(env, run->args[i]);
        (*env)->SetObjectArrayElement(env, jargs, i, s);
        (*env)->DeleteLocalRef(env, s);
    }

    (*env)->CallStaticVoidMethod(env, cls, main, jargs);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        run->status = VXJVMStatusException;
        snprintf(run->message, sizeof(run->message), "%s.main threw an exception (see log)", run->mainClass);
    } else {
        run->status = VXJVMStatusOK;
        snprintf(run->message, sizeof(run->message), "%s.main returned normally", run->mainClass);
    }
    fflush(stdout);
    fflush(stderr);
    dispatch_semaphore_signal(run->done);

    // Let the VM finish like the java launcher does. JNI allows only one VM
    // per process, so this thread just ends afterwards.
    (*vm)->DestroyJavaVM(vm);
    return NULL;
}

typedef struct {
    bool trapped;
    void *value;
} VXJITProbeResult;

static volatile sig_atomic_t probeTrapped;

// Runs only if no debugger consumed the breakpoint: skip the brk and return NULL.
static void probeTrapHandler(int sig, siginfo_t *info, void *ctx) {
    ucontext_t *uc = ctx;
    uc->uc_mcontext->__ss.__pc += 4;
    uc->uc_mcontext->__ss.__x[0] = 0;
    probeTrapped = 1;
}

static VXJITProbeResult VXJITProbeLegacy(void) {
    struct sigaction sa = {0}, old = {0};
    sa.sa_sigaction = probeTrapHandler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    probeTrapped = 0;
    sigaction(SIGTRAP, &sa, &old);
    void *value = VXJIT26CreateRegionLegacy((size_t)getpagesize());
    sigaction(SIGTRAP, &old, NULL);
    return (VXJITProbeResult){ .trapped = probeTrapped != 0, .value = value };
}

static char *dupString(NSString *s) { return strdup(s.UTF8String); }

@implementation VXJVMBridge

+ (NSString *)jitDescription {
    unsigned int f = VXJITGetFlags();
    return [NSString stringWithFormat:@"flags=0x%X (iOS26=%d mirrored=%d TXM=%d) CS_DEBUGGED=%d debuggerNow=%d needsScript=%d",
            f, !!(f & VXJITFlagIOS26), !!(f & VXJITFlagForceMirrored), !!(f & VXJITFlagHasTXM),
            VXJITDebuggerAttached(), VXJITDebuggerStillAttached(), VXJITNeedsScript()];
}

+ (VXJVMResult *)runJavaHome:(NSString *)javaHome
                   classpath:(NSString *)classpath
                   mainClass:(NSString *)mainClass
                        args:(NSArray<NSString *> *)args
                  jvmOptions:(NSArray<NSString *> *)jvmOptions
                     logPath:(NSString *)logPath {
    static atomic_bool started = false;
    if (atomic_exchange(&started, true)) {
        return result(VXJVMStatusAlreadyStarted, @"A JVM was already started in this process; restart the app to run again.");
    }

    NSString *jit = [self jitDescription];
    NSLog(@"[JVMBridge] %@", jit);
    // HotSpot generates its interpreter at startup, so even "hello world"
    // needs executable memory: without CS_DEBUGGED it would crash.
    if (!VXJITDebuggerAttached()) {
        atomic_store(&started, false);
        return result(VXJVMStatusNoJIT, @"JIT is not enabled (no debugger attached). Launch this app from StikDebug, then try again. %@", jit);
    }

    NSString *libjvm = [javaHome stringByAppendingPathComponent:@"lib/server/libjvm.dylib"];
    if (![NSFileManager.defaultManager fileExistsAtPath:libjvm]) {
        atomic_store(&started, false);
        return result(VXJVMStatusLoadFailed, @"Missing %@", libjvm);
    }

    // Send our and the JVM's stdout/stderr to the log for the rest of the run.
    fflush(stdout);
    fflush(stderr);
    int savedOut = dup(STDOUT_FILENO), savedErr = dup(STDERR_FILENO);
    int logFd = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (logFd >= 0) {
        dup2(logFd, STDOUT_FILENO);
        dup2(logFd, STDERR_FILENO);
        close(logFd);
        setvbuf(stdout, NULL, _IOLBF, 0);
    }
    void (^restoreOutput)(void) = ^{
        fflush(stdout);
        fflush(stderr);
        dup2(savedOut, STDOUT_FILENO);
        dup2(savedErr, STDERR_FILENO);
        close(savedOut);
        close(savedErr);
    };
    printf("[JVMBridge] %s\n", jit.UTF8String);

    if (VXJITNeedsScript()) {
        // TXM device: libjvm will ask for its code cache with `brk #0x69`
        // (get_debug_jit_mapping). Same sequence as Amethyst's launchJVM().
        // 1. probe. The bare universal script answers 0x69 with a fixed value;
        //    no debugger at all would normally kill the app, so the probe runs
        //    under a temporary SIGTRAP handler that turns that into an error.
        VXJITProbeResult probe = VXJITProbeLegacy();
        printf("[JVMBridge] JIT26 probe: %s (x0=%p)\n", probe.trapped ? "no debugger caught the breakpoint" : "debugger replied", probe.value);
        if (probe.trapped) {
            restoreOutput();
            atomic_store(&started, false);
            return result(VXJVMStatusNoJIT, @"StikDebug is not attached any more (the JIT breakpoint was not handled). Make sure UniversalJIT26.js is assigned to this app in StikDebug, launch it from StikDebug, and run the test again. %@", jit);
        }
        if ((uint32_t)(uintptr_t)probe.value != VXJIT26UniversalProbeReply) {
            if (probe.value) munmap(probe.value, (size_t)getpagesize());
            restoreOutput();
            atomic_store(&started, false);
            return result(VXJVMStatusNoJIT, @"StikDebug is running a different JIT script for this app (probe returned %p). Assign UniversalJIT26.js from this app's Documents and launch again.", probe.value);
        }
        // 2. teach the script to really allocate on 0x69, and detach after it.
        NSString *extPath = [NSBundle.mainBundle pathForResource:@"UniversalJIT26Extension" ofType:@"js"];
        NSString *ext = extPath ? [NSString stringWithContentsOfFile:extPath encoding:NSUTF8StringEncoding error:nil] : nil;
        if (!ext) {
            restoreOutput();
            atomic_store(&started, false);
            return result(VXJVMStatusNoJIT, @"UniversalJIT26Extension.js missing from the app bundle");
        }
        VXJIT26SendScript(ext.UTF8String, strlen(ext.UTF8String));
        VXJIT26SetDetachAfterFirstBr(true);
        printf("[JVMBridge] JIT26 extension sent; debugger will detach after the JVM's mapping request\n");
        // libjvm falls back to this when it cannot find DeviceHasTXM().
        setenv("XNU_HAS_TXM", "1", 1);
        // 3. bad accesses must reach HotSpot's signal handlers, not a debugger
        //    that is about to go away.
        task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, MACH_PORT_NULL,
                                 EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
    }
    signal(SIGSEGV, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    setenv("JAVA_HOME", javaHome.UTF8String, 1);

    NSMutableArray<NSString *> *options = [jvmOptions mutableCopy];
    [options addObject:[@"-Djava.class.path=" stringByAppendingString:classpath]];

    JVMRun *run = calloc(1, sizeof(JVMRun));
    run->libjvm = dupString(libjvm);
    run->optionCount = (int)options.count;
    run->options = calloc(options.count, sizeof(char *));
    for (NSUInteger i = 0; i < options.count; i++) run->options[i] = dupString(options[i]);
    run->mainClass = dupString([mainClass stringByReplacingOccurrencesOfString:@"." withString:@"/"]);
    run->argCount = (int)args.count;
    run->args = calloc(args.count ?: 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) run->args[i] = dupString(args[i]);
    run->done = dispatch_semaphore_create(0);

    // HotSpot wants a large stack on the thread that creates the VM.
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 16 << 20);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    int err = pthread_create(&thread, &attr, jvmThread, run);
    pthread_attr_destroy(&attr);

    VXJVMResult *out;
    if (err != 0) {
        out = result(VXJVMStatusLoadFailed, @"pthread_create failed: %d", err);
    } else {
        dispatch_semaphore_wait(run->done, DISPATCH_TIME_FOREVER);
        out = result(run->status, @"%s", run->message);
    }

    restoreOutput();
    // `run` is intentionally leaked: the JVM thread may still use it.
    return out;
}

@end
