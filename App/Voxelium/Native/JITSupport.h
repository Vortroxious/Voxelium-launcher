#pragma once
#include <stdbool.h>
#include <stddef.h>

/// Bits describing how JIT has to be obtained on this device.
typedef enum : unsigned int {
    VXJITFlagIOS26 = 1u << 0,          ///< iOS 26 or newer
    VXJITFlagForceMirrored = 1u << 1,  ///< an RX mapping of RW memory is refused, so mirrored mapping is needed
    VXJITFlagHasTXM = 1u << 2,         ///< device has the Trusted Execution Monitor
} VXJITFlags;

/// Detects VXJITFlags. `JIT_FLAGS` in the environment overrides detection.
unsigned int VXJITGetFlags(void);

/// True on TXM devices: the JVM will request its code cache from the attached
/// StikDebug JIT script (brk #0x69), so the script must be attached.
bool VXJITNeedsScript(void);

/// Exported for libjvm (dlsym). Same value as VXJITNeedsScript().
bool DeviceHasTXM(void);

/// CS_DEBUGGED is set: some debugger attached at least once (JIT prerequisite).
bool VXJITDebuggerAttached(void);

/// A debugger is attached right now (getppid() is not launchd).
bool VXJITDebuggerStillAttached(void);

/// The app's own `get-task-allow` entitlement: 1 = true, 0 = missing or false,
/// -1 = could not be read. Without it no debugger can attach, so no JIT.
/// Uses Security framework SPI (SecTaskCopyValueForEntitlement), looked up at run time.
int VXJITGetTaskAllow(void);

/// Result of the JIT26 probe: one legacy `brk #0x69` request run under a temporary
/// SIGTRAP handler, so it returns instead of crashing when no debugger is attached.
typedef struct {
    bool trapped;  ///< no debugger handled the breakpoint
    void *value;   ///< x0 after the breakpoint (the script's reply)
} VXJITProbeResult;

/// Asks the attached JIT script to answer a probe. The bare universal script replies
/// VXJIT26UniversalProbeReply and allocates nothing. Not thread-safe: one probe at a time.
VXJITProbeResult VXJIT26Probe(void);

// StikDebug JIT26 breakpoint calls. Each one traps (crashes the app) unless a
// debugger running UniversalJIT26.js is attached right now.

/// Asks the script to prepare `len` bytes at `addr` (new region if NULL).
void *VXJIT26PrepareRegion(void *addr, size_t len);

/// Legacy `brk #0x69` request, the one this HotSpot build uses for its code
/// cache. With the bare universal script it returns VXJIT26UniversalProbeReply.
void *VXJIT26CreateRegionLegacy(size_t len);
#define VXJIT26UniversalProbeReply 0x690000E0u

/// Evaluates `script` inside the attached universal script.
void VXJIT26SendScript(const char *script, size_t len);

/// Extension command: detach the debugger after the next legacy request.
void VXJIT26SetDetachAfterFirstBr(bool value);
