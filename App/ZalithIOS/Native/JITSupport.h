#pragma once
#include <stdbool.h>
#include <stddef.h>

/// Bits describing how JIT has to be obtained on this device.
typedef enum : unsigned int {
    ZLJITFlagIOS26 = 1u << 0,          ///< iOS 26 or newer
    ZLJITFlagForceMirrored = 1u << 1,  ///< an RX mapping of RW memory is refused, so mirrored mapping is needed
    ZLJITFlagHasTXM = 1u << 2,         ///< device has the Trusted Execution Monitor
} ZLJITFlags;

/// Detects ZLJITFlags. `JIT_FLAGS` in the environment overrides detection.
unsigned int ZLJITGetFlags(void);

/// True on TXM devices: the JVM will request its code cache from the attached
/// StikDebug JIT script (brk #0x69), so the script must be attached.
bool ZLJITNeedsScript(void);

/// Exported for libjvm (dlsym). Same value as ZLJITNeedsScript().
bool DeviceHasTXM(void);

/// CS_DEBUGGED is set: some debugger attached at least once (JIT prerequisite).
bool ZLJITDebuggerAttached(void);

/// A debugger is attached right now (getppid() is not launchd).
bool ZLJITDebuggerStillAttached(void);

// StikDebug JIT26 breakpoint calls. Each one traps (crashes the app) unless a
// debugger running UniversalJIT26.js is attached right now.

/// Asks the script to prepare `len` bytes at `addr` (new region if NULL).
void *ZLJIT26PrepareRegion(void *addr, size_t len);

/// Legacy `brk #0x69` request, the one this HotSpot build uses for its code
/// cache. With the bare universal script it returns ZLJIT26UniversalProbeReply.
void *ZLJIT26CreateRegionLegacy(size_t len);
#define ZLJIT26UniversalProbeReply 0x690000E0u

/// Evaluates `script` inside the attached universal script.
void ZLJIT26SendScript(const char *script, size_t len);

/// Extension command: detach the debugger after the next legacy request.
void ZLJIT26SetDetachAfterFirstBr(bool value);
