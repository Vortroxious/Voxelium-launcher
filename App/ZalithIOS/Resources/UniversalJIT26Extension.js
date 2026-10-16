// Copied unmodified (below this header) from Amethyst-iOS, Natives/resources/UniversalJIT26Extension.js
// https://github.com/AngelAuraMC/Amethyst-iOS (GPL-3.0), fetched 2026-10-15.
// Sent by the app to StikDebug at runtime; you do not need to assign it.
logLevel = LOG_INFO;
let detachAfterFirstBr = false;

// brk 0x69: to work without introducing breaking change
legacyCommands[0x69] = function(brkResponse) {
    // char* BreakGetJITMapping(size_t bytes) { JIT26PrepareRegion(NULL, bytes); }
    x1 = x0;
    x0 = 0;
    JIT26PrepareRegion(brkResponse);
    if (detachAfterFirstBr) {
        JIT26Detach();
    }
};

// JIT26SetDetachAfterFirstBr(BOOL)
commands[3] = function(brkResponse) {
    detachAfterFirstBr = x0 != 0;
    log(`JIT26SetDetachAfterFirstBr(${detachAfterFirstBr}) called`);
};

// JIT26PrepareRegionForPatching(void *addr, size_t len)
commands[4] = function(brkResponse) {
    let x0str = x0.toString(16);
    let x1str = x1.toString(16);
    let bytes = send_command(`m${x0str},${x1str}`);
    send_command(`M${x0str},${x1str}:${bytes}`);
};
