#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The built-in JIT helper (docs/JIT_INTEGRATION_PLAN.md, Phase 2): the extension
/// VoxeliumJITHelper.appex, with StikJIT inside, started with the private NSExtension API.
/// It needs iOS 17.4 (StikJIT's minimum). Callbacks run on the main queue.

/// Starts the helper with a "check" request and reports each step and its reply.
void VXJITHelperCheck(void (^report)(NSString *line));

/// Asks the helper to turn on JIT for `hostPid` with StikJIT. `stage` gets the helper's
/// progress (1 checking connection … 6 device ready, 7 attaching, 8 finished). `done` runs
/// when the helper's request ends: on TXM devices only after the JIT script detached,
/// which is after the JVM got its code cache. `log` holds StikJIT's lines.
void VXJITHelperEnableJIT(int hostPid, NSData *pairingFile, NSData *script, BOOL forceScript,
                          void (^stage)(int stage),
                          void (^done)(BOOL ok, NSString *_Nullable error, NSArray<NSString *> *log));

NS_ASSUME_NONNULL_END
