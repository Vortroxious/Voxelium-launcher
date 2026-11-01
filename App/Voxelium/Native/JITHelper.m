// Starts the JIT helper extension the way LiveContainer starts LiveProcess
// (LCUtils.m, AppSceneViewController.m, AGPL-3.0; private NSExtension methods as
// declared in its FoundationPrivate.h).

#import "JITHelper.h"
#import <objc/message.h>
#include <notify.h>
#include <unistd.h>

#define VXJITHelperStageNotification "io.github.voxelium.jithelper.stage"

// Kept alive for the whole run; NSExtension drops its callbacks when released.
static id helperExtension;
static int stageToken = -1;
static void (^stageHandler)(int);

/// The helper's NSExtension, or nil with `why` set.
static id helper(NSString **why) {
    if (helperExtension) return helperExtension;
    NSURL *plugins = NSBundle.mainBundle.builtInPlugInsURL;
    NSBundle *bundle = plugins ? [NSBundle bundleWithURL:[plugins URLByAppendingPathComponent:@"VoxeliumJITHelper.appex"]] : nil;
    if (!bundle.bundleIdentifier) {
        NSArray *found = plugins ? [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugins.path error:nil] : nil;
        *why = [NSString stringWithFormat:@"VoxeliumJITHelper.appex is not in the installed app (PlugIns: %@)", found ?: @"none"];
        return nil;
    }
    Class extensionClass = NSClassFromString(@"NSExtension");
    SEL withIdentifier = NSSelectorFromString(@"extensionWithIdentifier:error:");
    if (!extensionClass || ![extensionClass respondsToSelector:withIdentifier]) {
        *why = @"the NSExtension private API is not available on this iOS";
        return nil;
    }
    NSError *error = nil;
    id ext = ((id (*)(Class, SEL, NSString *, NSError **))objc_msgSend)(extensionClass, withIdentifier, bundle.bundleIdentifier, &error);
    if (!ext) {
        *why = [NSString stringWithFormat:@"iOS doesn't know the extension %@: %@", bundle.bundleIdentifier, error.localizedDescription ?: @"no error given"];
        return nil;
    }
    helperExtension = ext;
    return ext;
}

/// Sends one request; `reply` gets the helper's reply dictionary, or nil and a reason.
static void sendRequest(NSDictionary *userInfo, void (^started)(int pid),
                        void (^reply)(NSDictionary *_Nullable info, NSString *_Nullable failure)) {
    NSString *why = nil;
    id ext = helper(&why);
    if (!ext) {
        dispatch_async(dispatch_get_main_queue(), ^{ reply(nil, why); });
        return;
    }
    __block BOOL answered = NO;
    void (^answer)(NSDictionary *, NSString *) = ^(NSDictionary *info, NSString *failure) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (answered) return;
            answered = YES;
            reply(info, failure);
        });
    };
    void (^completion)(NSUUID *, NSArray *) = ^(NSUUID *uuid, NSArray *items) {
        NSExtensionItem *item = [items.firstObject isKindOfClass:NSExtensionItem.class] ? items.firstObject : nil;
        answer(item.userInfo ?: @{}, nil);
    };
    void (^cancelled)(NSUUID *, NSError *) = ^(NSUUID *uuid, NSError *err) {
        answer(nil, [NSString stringWithFormat:@"the helper request was cancelled: %@", err.localizedDescription ?: @"no reason"]);
    };
    void (^interrupted)(NSUUID *) = ^(NSUUID *uuid) {
        answer(nil, @"the helper process ended before it answered");
    };
    ((void (*)(id, SEL, id))objc_msgSend)(ext, NSSelectorFromString(@"setRequestCompletionBlock:"), completion);
    ((void (*)(id, SEL, id))objc_msgSend)(ext, NSSelectorFromString(@"setRequestCancellationBlock:"), cancelled);
    ((void (*)(id, SEL, id))objc_msgSend)(ext, NSSelectorFromString(@"setRequestInterruptionBlock:"), interrupted);

    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = userInfo;
    void (^begun)(NSUUID *) = ^(NSUUID *requestID) {
        int pid = requestID ? ((int (*)(id, SEL, NSUUID *))objc_msgSend)(ext, NSSelectorFromString(@"pidForRequestIdentifier:"), requestID) : 0;
        dispatch_async(dispatch_get_main_queue(), ^{ started(pid); });
        if (pid <= 0) answer(nil, @"the request started but no helper process");
    };
    ((void (*)(id, SEL, NSArray *, id))objc_msgSend)(ext, NSSelectorFromString(@"beginExtensionRequestWithInputItems:completion:"), @[item], begun);
}

void VXJITHelperCheck(void (^report)(NSString *line)) {
    void (^say)(NSString *) = ^(NSString *line) {
        NSLog(@"[JITHelper] %@", line);
        report(line);
    };
    say(@"Starting the helper…");
    sendRequest(@{ @"action": @"check", @"hostPid": @(getpid()) }, ^(int pid) {
        say(pid > 0 ? [NSString stringWithFormat:@"OK: helper started, pid %d (Voxelium is pid %d)", pid, getpid()]
                    : @"FAIL: no helper process");
    }, ^(NSDictionary *u, NSString *failure) {
        if (!u) { say([@"FAIL: " stringByAppendingString:failure]); return; }
        say([NSString stringWithFormat:@"OK: helper pid %@ saw host pid %@; lockdown (62078) %@; RSD (49152) %@; TXM %@; helper get-task-allow %@",
             u[@"helperPid"], u[@"hostPid"], u[@"lockdown"], u[@"rsd"], u[@"txm"], u[@"getTaskAllow"]]);
    });
}

void VXJITHelperEnableJIT(int hostPid, NSData *pairingFile, NSData *script, BOOL forceScript,
                          void (^stage)(int stage),
                          void (^done)(BOOL ok, NSString *_Nullable error, NSArray<NSString *> *log)) {
    stageHandler = stage;
    if (stageToken == -1) {
        notify_register_dispatch(VXJITHelperStageNotification, &stageToken, dispatch_get_main_queue(), ^(int token) {
            uint64_t s = 0;
            notify_get_state(token, &s);
            if (stageHandler) stageHandler((int)s);
        });
    }
    NSDictionary *request = @{ @"action": @"enableJIT", @"hostPid": @(hostPid), @"pairingFile": pairingFile,
                               @"script": script, @"forceScript": @(forceScript) };
    sendRequest(request, ^(int pid) {
        NSLog(@"[JITHelper] helper pid %d enabling JIT for %d", pid, hostPid);
    }, ^(NSDictionary *u, NSString *failure) {
        stageHandler = nil;
        NSArray *log = [u[@"log"] isKindOfClass:NSArray.class] ? u[@"log"] : @[];
        if (!u) { done(NO, failure, log); return; }
        BOOL ok = [u[@"ok"] boolValue];
        done(ok, ok ? nil : (u[@"error"] ?: @"the helper gave no reason"), log);
    });
}

