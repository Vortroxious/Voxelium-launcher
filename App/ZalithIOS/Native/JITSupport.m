// JIT detection and the StikDebug "JIT26" breakpoint protocol.
//
// Adapted from Amethyst-iOS (GPL-3.0), Natives/utils.m
// (https://github.com/AngelAuraMC/Amethyst-iOS, fetched 2026-10-15):
// DeviceGetJITFlags, DeviceCanCreateRXMap, DeviceHasTXMReal and the
// JIT26* breakpoint helpers. The command numbers must match the
// UniversalJIT26.js script run by StikDebug (x16 = command, brk #0xf00d).

#import <Foundation/Foundation.h>
#include <dirent.h>
#include <dlfcn.h>
#include <limits.h>
#include <sys/mman.h>
#include <unistd.h>
#include "JITSupport.h"

#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

bool ZLJITDebuggerAttached(void) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return false;
    return (flags & CS_DEBUGGED) != 0;
}

bool ZLJITDebuggerStillAttached(void) {
    // getppid() is launchd (1) unless a debugger is attached right now.
    return getppid() != 1;
}

// Before JIT is granted this fails on every device; it is only meaningful
// once the process is being debugged.
static bool canCreateRXMap(void) {
    size_t page = (size_t)getpagesize();
    uint32_t *map = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_SHARED, -1, 0);
    if (map == MAP_FAILED) return false;
    *map = 0xFFFFFFFF;
    int ret = mprotect(map, page, PROT_READ | PROT_EXEC);
    munmap(map, page);
    return ret == 0;
}

static bool hasTXM(void) {
    DIR *d = opendir("/private/preboot");
    if (!d) {
        // Not readable on recent iOS; fall back to the chip list Amethyst uses.
        uint64_t (*MGGetSInt64Answer)(CFStringRef) = dlsym(RTLD_DEFAULT, "MGGetSInt64Answer");
        uint64_t chip = MGGetSInt64Answer ? MGGetSInt64Answer(CFSTR("ChipID")) : 0;
        switch (chip) {
            case 0x8020: case 0x8027: return false;                                  // A12, A12X/Z
            case 0x8030: case 0x8101: case 0x8103:                                   // A13, A14, M1
                if (@available(iOS 27.0, *)) return true;
                return false;
            default:
                if (@available(iOS 19.0, *)) return true;
                return false;
        }
    }
    char path[PATH_MAX] = {0};
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strlen(e->d_name) == 96) {
            snprintf(path, sizeof(path), "/private/preboot/%s/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", e->d_name);
            break;
        }
    }
    closedir(d);
    return path[0] && access(path, F_OK) == 0;
}

// Not cached: the RX-map probe gives a different answer before and after a
// debugger attaches, so callers re-check right before starting the JVM.
unsigned int ZLJITGetFlags(void) {
    const char *s = getenv("JIT_FLAGS");
    if (s) return (unsigned int)strtoul(s, NULL, 0);
    unsigned int flags = 0;
    if (@available(iOS 26.0, *)) {
        flags |= ZLJITFlagIOS26;
        if (!canCreateRXMap()) flags |= ZLJITFlagForceMirrored;
    }
    if (hasTXM()) flags |= ZLJITFlagHasTXM;
    return flags;
}

// Matches the bundled libjvm: with -XX:+MirrorMappedCodeCache on iOS 19+ it
// asks the debugger for its code cache whenever DeviceHasTXM() is true
// (see get_debug_jit_mapping in libjvm), regardless of the mirrored flag.
bool ZLJITNeedsScript(void) {
    return (ZLJITGetFlags() & ZLJITFlagHasTXM) != 0;
}

// Looked up by libjvm with dlsym(RTLD_DEFAULT, "DeviceHasTXM"). Must stay an
// exported, unmangled symbol of the app executable.
__attribute__((visibility("default"), used))
bool DeviceHasTXM(void) {
    return ZLJITNeedsScript();
}

__attribute__((noinline, optnone, naked))
void *ZLJIT26PrepareRegion(void *addr, size_t len) {
    asm("mov x16, #1 \n"
        "brk #0xf00d \n"
        "ret");
}

__attribute__((noinline, optnone, naked))
void *ZLJIT26CreateRegionLegacy(size_t len) {
    asm("brk #0x69 \n"
        "ret");
}

__attribute__((noinline, optnone, naked))
void ZLJIT26SendScript(const char *script, size_t len) {
    asm("mov x16, #2 \n"
        "brk #0xf00d \n"
        "ret");
}

// Only handled after UniversalJIT26Extension.js was sent.
__attribute__((noinline, optnone, naked))
void ZLJIT26SetDetachAfterFirstBr(bool value) {
    asm("mov x16, #3 \n"
        "brk #0xf00d \n"
        "ret");
}
