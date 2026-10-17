#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Path LWJGL should load as its GLFW library (-Dorg.lwjgl.glfw.libname):
/// this app's executable, which exports the GLFW 3.4 API implemented in
/// VXGLFW.m.
NSString *VXGLFWLibraryPath(void);

/// Checks that the executable can be dlopen()ed and exposes glfw* symbols.
NSString *VXGLFWSelfCheck(void);

NS_ASSUME_NONNULL_END
