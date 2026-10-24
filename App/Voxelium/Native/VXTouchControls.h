#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// On-screen controls and touch gestures for the game window, shared by the app's
// GLFW (VXGLFW.m, Minecraft up to 26.1.2) and the SDL3 path (VXSDLControls.m,
// Minecraft 26.3+). They speak GLFW: key codes, mouse buttons and actions
// (GLFW_PRESS/GLFW_RELEASE), as in the control layouts from the Controls tab.

/// Where the controls send input, and what they need to know about the game.
@protocol VXInputSink <NSObject>
- (void)vxKey:(int)key action:(int)action;
- (void)vxMouseButton:(int)button action:(int)action;
- (void)vxChar:(UInt32)codepoint;
/// Pointer position in menus, in points.
- (void)vxCursorAt:(CGPoint)point;
/// Mouse look while the game has captured the cursor: a delta in screen pixels.
- (void)vxCursorDelta:(CGPoint)delta;
/// Quit the game (it saves the world).
- (void)vxQuit;
/// Whether the game has captured the cursor (in the world, not in a menu).
@property (nonatomic, readonly) BOOL vxInGame;
/// The game's framebuffer in pixels, and pixels per point (render scale included).
@property (nonatomic, readonly) CGSize vxFramebufferSize;
@property (nonatomic, readonly) CGFloat vxPixelsPerPoint;
@end

/// Buttons, joystick, keyboard proxy, memory gauge and notices (Amethyst's layout or the user's).
@interface VXControlsOverlay : UIView
@property (nonatomic, weak, nullable) id<VXInputSink> owner;
/// The view that takes hardware-keyboard input again when the on-screen keyboard closes.
@property (nonatomic, weak, nullable) UIView *gameView;
@property (nonatomic) BOOL inGame, guiHidden, drawerOpen, virtualMouse;
@property (nonatomic, strong) UIImageView *pointer;
- (instancetype)initWithOwner:(id<VXInputSink>)owner;
- (void)toggleKeyboard;
- (void)refresh;
- (void)showNotice:(NSString *)text;
@end

/// Gestures on the game outside the controls: look, use, break, hotbar, menu pointer.
/// Holds the overlay as a subview.
@interface VXTouchView : UIView
@property (nonatomic, weak, nullable) id<VXInputSink> sink;
@property (nonatomic, strong, nullable) VXControlsOverlay *overlay;
@end

/// Touch counters for the log ("touches: began=… moved=…").
NSString *VXTouchStats(void);

NS_ASSUME_NONNULL_END
