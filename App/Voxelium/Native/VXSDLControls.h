#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Minecraft 26.3+ (SDL3 + Vulkan): puts the app's touch controls (VXTouchControls)
/// over SDL's game window once Minecraft creates it, sends their input through SDL
/// (patches/sdl3/0005), pauses rendering while the app is in the background (the
/// Vulkan loader shim's vx_vulkan_set_paused) and pauses the game when the app
/// resigns active. Call once, on the main thread, before the game starts.
void VXSDLControlsStart(NSString *sdlLibraryPath, NSString *vulkanLibraryPath);

NS_ASSUME_NONNULL_END
