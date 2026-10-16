#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Outcome of one in-process JVM run.
typedef NS_ENUM(NSInteger, ZLJVMStatus) {
    ZLJVMStatusOK = 0,              ///< main() returned without an uncaught exception
    ZLJVMStatusAlreadyStarted,      ///< a JVM was already created in this process (JNI allows one)
    ZLJVMStatusNoJIT,               ///< JIT preconditions not met; JVM not attempted
    ZLJVMStatusLoadFailed,          ///< dlopen/dlsym of libjvm failed
    ZLJVMStatusCreateFailed,        ///< JNI_CreateJavaVM returned an error
    ZLJVMStatusMainNotFound,        ///< main class or method missing
    ZLJVMStatusException,           ///< main() threw
};

@interface ZLJVMResult : NSObject
@property (nonatomic, readonly) ZLJVMStatus status;
@property (nonatomic, readonly, copy) NSString *message;
@end

@interface ZLJVMBridge : NSObject

/// Runs `mainClass.main(args)` in a JVM created inside this process.
/// Blocks the calling thread until main() returns; JVM stdout/stderr are
/// appended to `logPath`. Can only succeed once per process.
+ (ZLJVMResult *)runJavaHome:(NSString *)javaHome
                   classpath:(NSString *)classpath
                   mainClass:(NSString *)mainClass
                        args:(NSArray<NSString *> *)args
                  jvmOptions:(NSArray<NSString *> *)jvmOptions
                     logPath:(NSString *)logPath
    NS_SWIFT_NAME(run(javaHome:classpath:mainClass:args:jvmOptions:logPath:));

/// Human-readable JIT state, for diagnostics.
+ (NSString *)jitDescription;

@end

NS_ASSUME_NONNULL_END
