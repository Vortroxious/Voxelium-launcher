#pragma once
// Compute-shader feasibility spike (docs/COMPUTE_SHADERS_RESEARCH.md): desktop
// OpenGL through Mesa's Zink on Vulkan (KosmicKrisp, or MoltenVK as the last
// resort). Compiled only into the experimental IPA
// (scripts/build-ipa-zink-experimental.sh); the shipping app never sees it.
#if VOXELIUM_ZINK_EXPERIMENT
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs headless on a background thread: a bare Vulkan probe through the
/// bundled driver, then EGL surfaceless + Zink with a 4.3+ core context, a
/// compute-shader SSBO check, a 300-frame full-screen draw and memory use.
@interface VXZinkTest : NSObject

/// Called once on the main thread with `ok` and a multi-line report.
@property (nonatomic, copy, nullable) void (^onFinish)(BOOL ok, NSString *report);

/// Lines are also appended to this file when set.
@property (nonatomic, copy, nullable) NSString *logPath;

/// Mesa's own log (MESA_LOG_FILE).
@property (nonatomic, copy, nullable) NSString *mesaLogPath;

/// Set MESA_GL_VERSION_OVERRIDE=4.6 and MESA_GLSL_VERSION_OVERRIDE=460.
/// Without it Zink on Metal reports GL 2.1 and the compute dispatch is skipped.
@property (nonatomic) BOOL versionOverride;

/// Starts the test. Zink and its Vulkan driver cannot be unloaded, so only
/// the first call in a process runs; later calls report that and finish.
- (void)start;

/// True once a Zink test has started in this process.
@property (class, nonatomic, readonly) BOOL used;

@end

/// True when Frameworks/zink holds libEGL_mesa.dylib and a Vulkan driver.
BOOL VXZinkBundled(void);

/// "KosmicKrisp" or "MoltenVK" for the driver in Frameworks/zink, nil if none.
NSString *_Nullable VXZinkVulkanDriverName(void);

NS_ASSUME_NONNULL_END
#endif
