#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Milestone 6 step 1: draws a triangle with OpenGL ES 3 through ANGLE's
/// Metal backend (loaded from the app's Frameworks folder at runtime),
/// verifies pixels with glReadPixels, and reports the outcome.
@interface VXGLTestViewController : UIViewController

/// Called once on the main thread with `ok` and a multi-line report.
@property (nonatomic, copy, nullable) void (^onFinish)(BOOL ok, NSString *report);

/// Lines are also appended to this file when set.
@property (nonatomic, copy, nullable) NSString *logPath;

/// Milestone 6 step 3b: route every GL call through MobileGlues (desktop GL
/// on top of ANGLE's GLES) with `#version 330 core` shaders.
@property (nonatomic) BOOL useMobileGlues;

/// MobileGlues config/log directory (MG_DIR_PATH).
@property (nonatomic, copy, nullable) NSString *mobileGluesDir;

@end

/// True when ANGLE's libEGL is present in the app bundle.
BOOL VXGLTestRuntimeBundled(void);

/// True when libmobileglues.dylib is present in the app bundle.
BOOL VXMobileGluesBundled(void);

NS_ASSUME_NONNULL_END
