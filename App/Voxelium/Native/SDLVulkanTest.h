#pragma once
// Minecraft 26.3 feasibility (Stage 1b): SDL3's UIKit window driven from a
// background thread, as Minecraft's render thread drives it through LWJGL,
// with a Vulkan swapchain on SDL_Vulkan_CreateSurface. Compiled only into the
// experimental IPA (scripts/build-ipa-zink-experimental.sh), which bundles
// libSDL3.dylib (scripts/build-sdl3.sh) in Frameworks/sdl3.
#if VOXELIUM_ZINK_EXPERIMENT
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs on its own thread: SDL_Init(VIDEO), the Vulkan library through
/// SDL_Vulkan_LoadLibrary, SDL_CreateWindow, a swapchain cleared in cycling
/// colours for 5 s (at most 2 frames in flight), then a clean teardown. Every
/// SDL event is logged. Without a usable Vulkan library, the window is cleared
/// by SDL's Metal renderer instead, so SDL's window and touches can be checked
/// on their own.
@interface VXSDLVulkanTest : NSObject

/// Called once on the main thread with `ok` and a multi-line report.
@property (nonatomic, copy, nullable) void (^onFinish)(BOOL ok, NSString *report);

/// Called for each line, on the test's thread (the launcher log).
@property (nonatomic, copy, nullable) void (^onLog)(NSString *line);

/// Lines are also appended to this file when set.
@property (nonatomic, copy, nullable) NSString *logPath;

/// Skip Vulkan even when a library is bundled (SDL window + touches only).
@property (nonatomic) BOOL sdlOnly;

- (void)start;

/// True once a test in this process has loaded the Vulkan library. Like the
/// Zink test's, the driver is not set up twice in a process.
@property (class, nonatomic, readonly) BOOL vulkanUsed;

@end

/// True when Frameworks/sdl3/libSDL3.dylib is bundled and the test is compiled in.
BOOL VXSDLBundled(void);

/// The Vulkan library the test would hand to SDL_Vulkan_LoadLibrary: the
/// loader shim (libvulkan.1.dylib) if bundled, else KosmicKrisp's ICD. Nil if none.
NSString *_Nullable VXSDLVulkanLibraryPath(void);

NS_ASSUME_NONNULL_END
#endif
