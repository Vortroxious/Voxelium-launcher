#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Outcome of one in-process JVM run.
typedef NS_ENUM(NSInteger, VXJVMStatus) {
    VXJVMStatusOK = 0,              ///< main() returned without an uncaught exception
    VXJVMStatusAlreadyStarted,      ///< a JVM was already created in this process (JNI allows one)
    VXJVMStatusNoJIT,               ///< JIT preconditions not met; JVM not attempted
    VXJVMStatusLoadFailed,          ///< dlopen/dlsym of libjvm failed
    VXJVMStatusCreateFailed,        ///< JNI_CreateJavaVM returned an error
    VXJVMStatusMainNotFound,        ///< main class or method missing
    VXJVMStatusException,           ///< main() threw
};

@interface VXJVMResult : NSObject
@property (nonatomic, readonly) VXJVMStatus status;
@property (nonatomic, readonly, copy) NSString *message;
@end

@interface VXJVMBridge : NSObject

/// Runs `mainClass.main(args)` in a JVM created inside this process.
/// Blocks the calling thread until main() returns; JVM stdout/stderr are
/// appended to `logPath`. Can only succeed once per process.
+ (VXJVMResult *)runJavaHome:(NSString *)javaHome
                   classpath:(NSString *)classpath
                   mainClass:(NSString *)mainClass
                        args:(NSArray<NSString *> *)args
                  jvmOptions:(NSArray<NSString *> *)jvmOptions
                     logPath:(NSString *)logPath
    NS_SWIFT_NAME(run(javaHome:classpath:mainClass:args:jvmOptions:logPath:));

/// Human-readable JIT state, for diagnostics.
+ (NSString *)jitDescription;

@end

/// Asks the running JVM (if any) for a full garbage collection on a background thread,
/// so the heap shrinks when iOS warns about memory. No-op without a JVM, while one is
/// already running, or within 20 s of the last one. `why` is logged and must be a string literal.
FOUNDATION_EXPORT void VXJVMRequestGC(const char *_Nullable why);

NS_ASSUME_NONNULL_END
