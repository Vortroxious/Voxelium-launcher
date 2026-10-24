// On-screen controls and touch gestures for the game window (VXTouchControls.h),
// moved out of VXGLFW.m so that the SDL3 path (Minecraft 26.3+) uses them too.
// Input goes to an id<VXInputSink> in GLFW terms.

#import "VXTouchControls.h"

#include <mach/mach.h>
#include <os/proc.h>

#define GLFW_INCLUDE_NONE
#include "glfw/GLFW/glfw3.h"

#pragma mark - Haptics (as Amethyst: light on button press / tap, medium on long press)

static UIImpactFeedbackGenerator *vxLightHaptic(void) {
    static UIImpactFeedbackGenerator *g;
    if (!g) { g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [g prepare]; }
    return g;
}

static UIImpactFeedbackGenerator *vxMediumHaptic(void) {
    static UIImpactFeedbackGenerator *g;
    if (!g) { g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [g prepare]; }
    return g;
}

#pragma mark - On-screen controls (Amethyst/PojavLauncher default layout)

// Layout and behaviour follow Amethyst-iOS's built-in default control layout
// (Natives/customcontrols/CustomControlsUtils.m, generateAndSaveDefaultControl,
// GPL-3.0). Its positions are expressions over the screen size in pixels; they
// are evaluated here in points with button_scale = 100 and margin = 2 pt.

typedef NS_ENUM(NSInteger, VXSpecial) {
    VXSpecialNone, VXSpecialRuntimeMenu, VXSpecialHideGUI, VXSpecialKeyboard, VXSpecialVirtualMouse, VXSpecialDrawer,
};

@class VXControlsOverlay;

@interface VXControlButton : UIButton
@property (nonatomic, weak) id<VXInputSink> owner;
@property (nonatomic, weak) VXControlsOverlay *overlayRef;
@property (nonatomic) int key;          // GLFW key, or GLFW_KEY_UNKNOWN
@property (nonatomic, copy) NSArray<NSNumber *> *extraKeys;  // pressed together with key (custom layouts)
@property (nonatomic) int mouseButton;  // GLFW mouse button, or -1
@property (nonatomic) VXSpecial special;
@property (nonatomic) BOOL toggle, latched, inGame, inMenu, inDrawer;
@property (nonatomic) CGSize size;      // points
@property (nonatomic, copy) CGPoint (^origin)(CGFloat W, CGFloat H);
@end

// The app's memory as iOS counts it (phys_footprint) and how much more it may use
// before iOS kills it; footprint + available is the app's limit (3376 MB on an iPhone
// 15 Pro Max).
static void vxMemoryNow(uint64_t *footprint, uint64_t *available) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    *footprint = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS ? info.phys_footprint : 0;
    *available = os_proc_available_memory();
}

@interface VXControlsOverlay ()
- (void)special:(VXSpecial)special from:(VXControlButton *)button;
@end

@implementation VXControlButton

+ (instancetype)named:(NSString *)title size:(CGSize)size {
    VXControlButton *b = [self buttonWithType:UIButtonTypeCustom];
    b.key = GLFW_KEY_UNKNOWN;
    b.mouseButton = -1;
    b.size = size;
    b.inGame = b.inMenu = YES;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.numberOfLines = 2;
    b.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    b.titleLabel.textAlignment = NSTextAlignmentCenter;
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0x4d / 255.0];  // Amethyst bgColor 0x4d000000
    b.layer.borderColor = UIColor.whiteColor.CGColor;
    [b addTarget:b action:@selector(down) forControlEvents:UIControlEventTouchDown];
    [b addTarget:b action:@selector(up) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return b;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) / 2;  // cornerRadius 100%
}

- (void)setPressedLook:(BOOL)pressed {
    self.backgroundColor = pressed ? [UIColor colorWithWhite:1 alpha:0.35] : [UIColor colorWithWhite:0 alpha:0x4d / 255.0];
}

- (void)send:(int)action {
    if (self.key != GLFW_KEY_UNKNOWN) [self.owner vxKey:self.key action:action];
    for (NSNumber *k in self.extraKeys) [self.owner vxKey:k.intValue action:action];
    if (self.mouseButton >= 0) [self.owner vxMouseButton:self.mouseButton action:action];
}

- (void)down {
    [vxLightHaptic() impactOccurred];
    if (self.special != VXSpecialNone) {
        [self.overlayRef special:self.special from:self];
        return;
    }
    if (self.toggle) {
        self.latched = !self.latched;
        [self send:self.latched ? GLFW_PRESS : GLFW_RELEASE];
        [self setPressedLook:self.latched];
    } else {
        [self send:GLFW_PRESS];
        [self setPressedLook:YES];
    }
}

- (void)up {
    if (self.special != VXSpecialNone || self.toggle) return;
    [self send:GLFW_RELEASE];
    [self setPressedLook:NO];
}

- (void)releaseLatched {
    if (self.latched) {
        self.latched = NO;
        [self send:GLFW_RELEASE];
        [self setPressedLook:NO];
    }
}

@end

// Movement stick (Amethyst default: 204.8 pt, bottom-left, relative, no forward lock).
@interface VXJoystick : UIView
@property (nonatomic, weak) id<VXInputSink> owner;
@end

@implementation VXJoystick {
    UIView *_knob;
    int _held;  // bit 0 W, 1 S, 2 A, 3 D
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0x4d / 255.0];
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:0 alpha:0x4d / 255.0].CGColor;  // strokeColor 1291845632
        _knob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 72, 72)];
        _knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
        _knob.layer.cornerRadius = 36;
        _knob.userInteractionEnabled = NO;
        [self addSubview:_knob];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.width / 2;
    if (!_held) _knob.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
}

- (void)apply:(int)held {
    static const int keys[4] = {GLFW_KEY_W, GLFW_KEY_S, GLFW_KEY_A, GLFW_KEY_D};
    for (int i = 0; i < 4; i++) {
        BOOL was = (_held >> i) & 1, now = (held >> i) & 1;
        if (was != now) [self.owner vxKey:keys[i] action:now ? GLFW_PRESS : GLFW_RELEASE];
    }
    _held = held;
}

- (void)track:(UITouch *)t {
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGPoint p = [t locationInView:self];
    CGFloat r = self.bounds.size.width / 2;
    CGFloat dx = (p.x - c.x) / r, dy = (p.y - c.y) / r;
    CGFloat len = hypot(dx, dy);
    if (len > 1) { dx /= len; dy /= len; }
    _knob.center = CGPointMake(c.x + dx * r * 0.6, c.y + dy * r * 0.6);
    int held = 0;
    if (dy < -0.35) held |= 1;
    if (dy > 0.35) held |= 2;
    if (dx < -0.35) held |= 4;
    if (dx > 0.35) held |= 8;
    [self apply:held];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [vxLightHaptic() impactOccurred];
    [self track:touches.anyObject];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self track:touches.anyObject]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self reset]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self reset]; }

- (void)reset {
    [self apply:0];
    _knob.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
}

@end

// Hidden first responder that brings up the iOS keyboard (world names, chat,
// signs) and turns typing into GLFW char/key events.
@interface VXKeyboardProxy : UIView <UIKeyInput>
@property (nonatomic, weak) id<VXInputSink> owner;
@property (nonatomic) UITextAutocorrectionType autocorrectionType;
@property (nonatomic) UITextAutocapitalizationType autocapitalizationType;
@property (nonatomic) UITextSpellCheckingType spellCheckingType;
@property (nonatomic) UIReturnKeyType returnKeyType;
@end

@implementation VXKeyboardProxy
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.autocorrectionType = UITextAutocorrectionTypeNo;
        self.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.spellCheckingType = UITextSpellCheckingTypeNo;
        self.returnKeyType = UIReturnKeyDone;
        self.userInteractionEnabled = NO;
    }
    return self;
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (void)insertText:(NSString *)text {
    id<VXInputSink> w = self.owner;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *s, NSRange r, NSRange er, BOOL *stop) {
        if ([s isEqualToString:@"\n"]) {
            [w vxKey:GLFW_KEY_ENTER action:GLFW_PRESS];
            [w vxKey:GLFW_KEY_ENTER action:GLFW_RELEASE];
            return;
        }
        UTF32Char cp = 0;
        if ([s getBytes:&cp maxLength:sizeof(cp) usedLength:NULL encoding:NSUTF32LittleEndianStringEncoding
                options:0 range:NSMakeRange(0, s.length) remainingRange:NULL]) [w vxChar:cp];
    }];
}
- (void)deleteBackward {
    [self.owner vxKey:GLFW_KEY_BACKSPACE action:GLFW_PRESS];
    [self.owner vxKey:GLFW_KEY_BACKSPACE action:GLFW_RELEASE];
}
@end

@implementation VXControlsOverlay {
    NSMutableArray<VXControlButton *> *_buttons;
    VXJoystick *_stick;
    VXKeyboardProxy *_keyboard;
    CGSize _loggedSize;
    CGFloat _stickX, _stickY, _stickSize;  // fractions of the overlay / points; _stickY < 0 = default
    UILabel *_memoryGauge;   // "1.7 / 3.4 GB" under More: orange from 80%, red from 90% of the limit
    UILabel *_notice;        // short messages, e.g. after an iOS memory warning
    NSTimer *_memoryTimer;
    CGFloat _controlsAlpha;                // layout "opacity" (Controls tab), applied to buttons and joystick
}

// The layout from the launcher's Controls tab: JSON at $VOXELIUM_CONTROLS_PATH, written by
// MinecraftLauncher from VoxeliumCore's ControlLayout (positions are fractions of the
// landscape screen, sizes in points). Returns NO (built-in layout used) if missing or invalid.
- (BOOL)loadLayoutFile {
    const char *path = getenv("VOXELIUM_CONTROLS_PATH");
    if (!path) return NO;
    NSData *data = [NSData dataWithContentsOfFile:@(path)];
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *list = [root isKindOfClass:NSDictionary.class] ? root[@"buttons"] : nil;
    if (![list isKindOfClass:NSArray.class]) {
        NSLog(@"[VXControls] controls: could not read %s, using the built-in layout", path);
        return NO;
    }
    NSDictionary *specials = @{@"runtimeMenu": @(VXSpecialRuntimeMenu), @"hideGUI": @(VXSpecialHideGUI),
                               @"keyboard": @(VXSpecialKeyboard), @"virtualMouse": @(VXSpecialVirtualMouse),
                               @"drawer": @(VXSpecialDrawer)};
    for (NSDictionary *d in list) {
        if (![d isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [d[@"name"] isKindOfClass:NSString.class] ? d[@"name"] : @"";
        CGFloat w = [d[@"width"] doubleValue] ?: 69.6, h = [d[@"height"] doubleValue] ?: 69.6;
        CGFloat fx = [d[@"x"] doubleValue], fy = [d[@"y"] doubleValue];
        NSMutableArray<NSNumber *> *keys = [NSMutableArray array];
        if ([d[@"keys"] isKindOfClass:NSArray.class])
            for (id k in d[@"keys"]) if ([k isKindOfClass:NSNumber.class] && [k intValue] > 0 && [k intValue] <= GLFW_KEY_LAST) [keys addObject:k];
        VXControlButton *btn = [self add:name key:keys.count ? keys[0].intValue : GLFW_KEY_UNKNOWN w:w h:h
                                    game:[d[@"showInGame"] boolValue] menu:[d[@"showInMenu"] boolValue]
                                      at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(fx * W, fy * H); }];
        if (keys.count > 1) btn.extraKeys = [keys subarrayWithRange:NSMakeRange(1, keys.count - 1)];
        int mouse = d[@"mouse"] ? [d[@"mouse"] intValue] : -1;
        btn.mouseButton = mouse >= 0 && mouse <= GLFW_MOUSE_BUTTON_LAST ? mouse : -1;
        NSNumber *special = [d[@"special"] isKindOfClass:NSString.class] ? specials[d[@"special"]] : nil;
        btn.special = special ? (VXSpecial)special.integerValue : VXSpecialNone;
        btn.toggle = [d[@"toggle"] boolValue];
        btn.inDrawer = [d[@"inDrawer"] boolValue];
        if (btn.inDrawer) btn.inGame = btn.inMenu = YES;
        if (btn.special == VXSpecialDrawer) btn.layer.borderWidth = 1.5;
    }
    double opacity = root[@"opacity"] ? [root[@"opacity"] doubleValue] : 1;
    _controlsAlpha = MIN(MAX(opacity, 0.2), 1);
    NSDictionary *stick = root[@"joystick"];
    if ([stick isKindOfClass:NSDictionary.class]) {
        _stickX = [stick[@"x"] doubleValue];
        _stickY = [stick[@"y"] doubleValue];
        _stickSize = [stick[@"size"] doubleValue] ?: 204.8;
    }
    NSLog(@"[VXControls] controls: %lu buttons from %s", (unsigned long)_buttons.count, path);
    return YES;
}

// Amethyst's default layout, used when no layout file is given (e.g. the GLFW test).
// Keep in step with ControlLayout.amethystDefault in VoxeliumCore.
- (void)addBuiltInLayout {
    const CGFloat m = 2, a = 69.6, b = 104.8, d = 96, dh = 40;

    // Right-hand cluster (x/y from Amethyst's expressions, simplified).
    [self add:@"Jump" key:GLFW_KEY_SPACE w:a h:a game:YES menu:NO
           at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0.94878495 * W - a, 0.31131014 * H + a + m); }];
    [self add:@"Shift" key:GLFW_KEY_LEFT_SHIFT w:a h:a game:YES menu:YES
           at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0.94878495 * W - a, 0.31131014 * H); }].toggle = YES;
    [self add:@"Sprint" key:GLFW_KEY_LEFT_CONTROL w:a h:a game:YES menu:NO
           at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0.94878495 * W - 2 * a - m, 0.31131014 * H); }].toggle = YES;
    [self add:@"Right\nClick" mouse:GLFW_MOUSE_BUTTON_RIGHT w:a h:a
           at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0.8756154 * W - a, 0.8178498 * H - a); }];
    [self add:@"Left\nClick" mouse:GLFW_MOUSE_BUTTON_LEFT w:a h:a
           at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0.7756397 * W - a, 0.8224885 * H - a); }];
    [self add:@"Middle\nClick" mouse:GLFW_MOUSE_BUTTON_MIDDLE w:a h:a
           at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0.83548373 * W - a, 0.67798775 * H - a); }];
    // Inventory (E): Amethyst has it in the top row; moved, at the user's request, into the
    // right-hand cluster, just right of Right Click and below Jump (in reach of the right thumb).
    [self add:@"Inven-\ntory" key:GLFW_KEY_E w:a h:a game:YES menu:NO
           at:^CGPoint(CGFloat W, CGFloat H) {
               return CGPointMake(0.8756154 * W + m, MAX(0.8178498 * H - a, 0.31131014 * H + 2 * a + 2 * m));
           }];

    // Top row, packed from the right edge.
    VXControlButton *menuBtn = [self add:@"Runtime\nMenu" key:GLFW_KEY_UNKNOWN w:b h:39.2 game:YES menu:YES
           at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(W - a - b - m, 0); }];
    menuBtn.special = VXSpecialRuntimeMenu;
    VXControlButton *hide = [self add:@"Hide\nGUI" key:GLFW_KEY_UNKNOWN w:a h:40 game:YES menu:YES
           at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(W - a, 0); }];
    hide.special = VXSpecialHideGUI;
    [self add:@"Pause" key:GLFW_KEY_ESCAPE w:b h:39.2 game:YES menu:NO
           at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(W - a - 2 * b - 2 * m, 0); }];
    [self add:@"Exit\nMenu" key:GLFW_KEY_ESCAPE w:b h:39.2 game:NO menu:YES
           at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(W - a - 2 * b - 2 * m, 0); }];

    // "More" drawer (top-left) and its items.
    VXControlButton *more = [self add:@"More" key:GLFW_KEY_UNKNOWN w:d h:dh game:YES menu:YES
           at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0, 0); }];
    more.special = VXSpecialDrawer;
    more.layer.borderWidth = 1.5;
    const CGFloat dy = 0.0026855469;
    [self drawer:@"Third\nperson" key:GLFW_KEY_F5 at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(d + m, dy * H); }];
    [self drawer:@"Debug\nMenu" key:GLFW_KEY_F3 at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(3 * (d + m), dy * H); }];
    [self drawer:@"Mouse\nToggle" key:GLFW_KEY_UNKNOWN at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(2 * (d + m), dy * H + dh + m); }].special = VXSpecialVirtualMouse;
    [self drawer:@"Chat" key:GLFW_KEY_T at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0, dy * H + dh + m); }];
    [self drawer:@"Keyboard" key:GLFW_KEY_UNKNOWN at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(d + m, dy * H + dh + m); }].special = VXSpecialKeyboard;
    // Amethyst's expression puts Player List above the screen (y < 0); it is placed in the free slot at the top instead.
    [self drawer:@"Player\nList" key:GLFW_KEY_TAB at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(2 * (d + m), dy * H); }].toggle = YES;
}

- (instancetype)initWithOwner:(id<VXInputSink>)owner {
    if ((self = [super initWithFrame:CGRectZero])) {
        _owner = owner;
        _buttons = [NSMutableArray array];
        _stickX = 0.02326631;
        _stickSize = 204.8;
        _stickY = -1;  // Amethyst default: 0.9753418 * H - size
        _controlsAlpha = 1;
        if (![self loadLayoutFile]) [self addBuiltInLayout];

        _stick = [[VXJoystick alloc] initWithFrame:CGRectZero];
        _stick.owner = owner;
        [self addSubview:_stick];
        _stick.alpha = _controlsAlpha;
        for (VXControlButton *btn in _buttons) btn.alpha = _controlsAlpha;

        _keyboard = [[VXKeyboardProxy alloc] initWithFrame:CGRectZero];
        _keyboard.owner = owner;
        [self addSubview:_keyboard];

        _pointer = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"cursorarrow"]];
        _pointer.tintColor = UIColor.whiteColor;
        _pointer.layer.shadowOpacity = 0.8;
        _pointer.layer.shadowRadius = 1.5;
        _pointer.layer.shadowOffset = CGSizeZero;
        _pointer.userInteractionEnabled = NO;
        _pointer.hidden = YES;
        [self addSubview:_pointer];

        _memoryGauge = [UILabel new];
        _memoryGauge.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
        _memoryGauge.textColor = UIColor.whiteColor;
        _memoryGauge.textAlignment = NSTextAlignmentCenter;
        _memoryGauge.layer.cornerRadius = 8;
        _memoryGauge.layer.masksToBounds = YES;
        _memoryGauge.userInteractionEnabled = NO;
        _memoryGauge.accessibilityLabel = @"Memory use";
        [self addSubview:_memoryGauge];
        _notice = [UILabel new];
        _notice.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _notice.textColor = UIColor.whiteColor;
        _notice.backgroundColor = [UIColor colorWithRed:0.75 green:0.2 blue:0.15 alpha:0.9];
        _notice.numberOfLines = 0;
        _notice.textAlignment = NSTextAlignmentCenter;
        _notice.layer.cornerRadius = 10;
        _notice.layer.masksToBounds = YES;
        _notice.userInteractionEnabled = NO;
        _notice.alpha = 0;
        [self addSubview:_notice];
        __weak VXControlsOverlay *weakSelf = self;
        _memoryTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) { [weakSelf updateMemoryGauge]; }];
        [self updateMemoryGauge];
        [self refresh];
    }
    return self;
}

- (void)dealloc { [_memoryTimer invalidate]; }

- (void)updateMemoryGauge {
    uint64_t footprint = 0, available = 0;
    vxMemoryNow(&footprint, &available);
    double used = footprint / 1073741824.0, limit = (footprint + available) / 1073741824.0;
    double share = limit > 0 ? used / limit : 0;
    _memoryGauge.text = [NSString stringWithFormat:@"%.1f / %.1f GB", used, limit];
    _memoryGauge.backgroundColor = share >= 0.9 ? [UIColor colorWithRed:0.8 green:0.15 blue:0.1 alpha:0.85]
                                 : share >= 0.8 ? [UIColor colorWithRed:0.9 green:0.55 blue:0.0 alpha:0.85]
                                                : [UIColor colorWithWhite:0 alpha:0.4];
    [self setNeedsLayout];
}

- (void)showNotice:(NSString *)text {
    _notice.text = text;
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [UIView animateWithDuration:0.25 animations:^{ self->_notice.alpha = 1; }];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideNotice) object:nil];
    [self performSelector:@selector(hideNotice) withObject:nil afterDelay:6];
}

- (void)hideNotice {
    [UIView animateWithDuration:0.4 animations:^{ self->_notice.alpha = 0; }];
}

- (VXControlButton *)add:(NSString *)name key:(int)key w:(CGFloat)w h:(CGFloat)h game:(BOOL)game menu:(BOOL)menu
                      at:(CGPoint (^)(CGFloat, CGFloat))origin {
    VXControlButton *btn = [VXControlButton named:name size:CGSizeMake(w, h)];
    btn.owner = self.owner;
    btn.overlayRef = self;
    btn.key = key;
    btn.inGame = game;
    btn.inMenu = menu;
    btn.origin = origin;
    [_buttons addObject:btn];
    [self addSubview:btn];
    return btn;
}

- (VXControlButton *)add:(NSString *)name mouse:(int)mouse w:(CGFloat)w h:(CGFloat)h at:(CGPoint (^)(CGFloat, CGFloat))origin {
    VXControlButton *btn = [self add:name key:GLFW_KEY_UNKNOWN w:w h:h game:YES menu:YES at:origin];
    btn.mouseButton = mouse;
    return btn;
}

- (VXControlButton *)drawer:(NSString *)name key:(int)key at:(CGPoint (^)(CGFloat, CGFloat))origin {
    VXControlButton *btn = [self add:name key:key w:96 h:40 game:YES menu:YES at:origin];
    btn.inDrawer = YES;
    return btn;
}

- (void)refresh {
    for (VXControlButton *btn in _buttons) {
        BOOL shown = self.inGame ? btn.inGame : btn.inMenu;
        if (btn.inDrawer) shown = shown && self.drawerOpen;
        if (self.guiHidden && btn.special != VXSpecialHideGUI) shown = NO;
        btn.hidden = !shown;
    }
    _stick.hidden = !self.inGame || self.guiHidden;  // joystick: in game only
    self.pointer.hidden = !(self.virtualMouse && !self.inGame);
    _memoryGauge.hidden = self.guiHidden || self.drawerOpen;
}

- (void)setInGame:(BOOL)inGame {
    if (_inGame == inGame) return;
    _inGame = inGame;
    if (!inGame) {
        // Leaving the game (menu, inventory, chat): release movement and latched keys.
        [_stick reset];
        for (VXControlButton *btn in _buttons) if (btn.key == GLFW_KEY_LEFT_CONTROL) [btn releaseLatched];
    }
    [self refresh];
    [self logControls];
}

- (void)toggleKeyboard {
    if (_keyboard.isFirstResponder) {
        [_keyboard resignFirstResponder];
        [self.gameView becomeFirstResponder];  // keep hardware keyboard input
    } else {
        [_keyboard becomeFirstResponder];
    }
}

- (void)special:(VXSpecial)special from:(VXControlButton *)button {
    switch (special) {
        case VXSpecialHideGUI:
            self.guiHidden = !self.guiHidden;
            [self refresh];
            break;
        case VXSpecialDrawer:
            self.drawerOpen = !self.drawerOpen;
            [self refresh];
            break;
        case VXSpecialKeyboard:
            [self toggleKeyboard];
            break;
        case VXSpecialVirtualMouse:
            self.virtualMouse = !self.virtualMouse;
            [self refresh];
            break;
        case VXSpecialRuntimeMenu: {
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Voxelium" message:nil
                                                                    preferredStyle:UIAlertControllerStyleActionSheet];
            [sheet addAction:[UIAlertAction actionWithTitle:@"Show / hide keyboard" style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *x) { [self toggleKeyboard]; }]];
            [sheet addAction:[UIAlertAction actionWithTitle:self.virtualMouse ? @"Virtual mouse: on" : @"Virtual mouse: off"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *x) { [self special:VXSpecialVirtualMouse from:nil]; }]];
            [sheet addAction:[UIAlertAction actionWithTitle:@"Quit game (saves the world)" style:UIAlertActionStyleDestructive
                                                    handler:^(UIAlertAction *x) {
                [self.owner vxQuit];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            sheet.popoverPresentationController.sourceView = button;
            UIViewController *vc = self.window.rootViewController;
            [vc presentViewController:sheet animated:YES completion:nil];
            break;
        }
        case VXSpecialNone:
            break;
    }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == _keyboard || hit == _pointer) ? nil : hit;
}

// Diagnostics: where each control is and what is visible (stderr goes to jvm.log).
- (void)logControls {
    NSMutableString *row = [NSMutableString string];
    for (VXControlButton *btn in _buttons)
        if (!btn.inDrawer)
            [row appendFormat:@" [%@ %.0f,%.0f%@]", [btn.currentTitle stringByReplacingOccurrencesOfString:@"\n" withString:@" "],
                btn.frame.origin.x, btn.frame.origin.y, btn.hidden ? @" hidden" : @""];
    NSLog(@"[VXControls] controls %.0fx%.0f pt, inGame=%d:%@", self.bounds.size.width, self.bounds.size.height, self.inGame, row);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    for (VXControlButton *btn in _buttons) {
        CGPoint o = btn.origin(W, H);
        // Keep every control on screen (Amethyst clamps the same way when loading).
        o.x = MIN(MAX(o.x, 0), W - btn.size.width);
        o.y = MIN(MAX(o.y, 0), H - btn.size.height);
        btn.frame = (CGRect){o, btn.size};
    }
    if (!CGSizeEqualToSize(_loggedSize, self.bounds.size)) {
        _loggedSize = self.bounds.size;
        [self logControls];
    }
    const CGFloat stick = _stickSize;
    CGFloat sy = _stickY >= 0 ? _stickY * H : 0.9753418 * H - stick;
    _stick.frame = CGRectMake(MIN(MAX(_stickX * W, 0), W - stick), MIN(MAX(sy, 0), H - stick), stick, stick);

    // Memory gauge just under the More button (wherever a custom layout puts it).
    CGRect anchor = CGRectMake(0, 0, 100, 40);
    for (VXControlButton *btn in _buttons) if (btn.special == VXSpecialDrawer) { anchor = btn.frame; break; }
    CGSize g = [_memoryGauge sizeThatFits:CGSizeMake(200, 20)];
    CGFloat gw = g.width + 14, gh = 18;
    _memoryGauge.frame = CGRectMake(MIN(MAX(CGRectGetMidX(anchor) - gw / 2, 0), W - gw),
                                    MIN(CGRectGetMaxY(anchor) + 4, H - gh), gw, gh);
    CGFloat nw = MIN(W - 40, 420);
    CGSize n = [_notice sizeThatFits:CGSizeMake(nw - 24, 200)];
    _notice.frame = CGRectMake((W - nw) / 2, 60, nw, n.height + 16);
}

@end

#pragma mark - Touch gestures on the game view

// Touch diagnostics, logged when the window is destroyed (stderr ends up in jvm.log).
static int gTouchBegan, gTouchMoved, gTouchMovedAccepted, gTouchEnded, gTouchCancelled, gHotbarSelects;

// Gestures on the game view outside the controls (as Amethyst):
//   in game:  drag = look, tap = use/place (right click), long press = break (hold left),
//             tap on the hotbar = select that slot (keys 1-9);
//   in menus: direct touch pointer, or a trackpad-style pointer with Mouse Toggle.
static const CFTimeInterval kLongPress = 0.35;
static const CGFloat kTapSlop = 12;

@implementation VXTouchView {
    UITouch *_primary, *_secondary;
    UITouch *_hotbarTouch;    // in game: a finger on the hotbar (independent of the look finger)
    int _hotbarSlot;
    CGPoint _lastPrimary, _startPrimary;
    CFTimeInterval _startTime;
    BOOL _primaryInGame, _primaryVirtual, _moved, _holding;
    NSUInteger _gestureGeneration;
    CGPoint _virtualCursor;
}

- (void)pushCursor:(CGPoint)p {
    [self.sink vxCursorAt:p];
}

// Minecraft hotbar slot under a point (auto GUI scale), or -1.
- (int)hotbarSlotAt:(CGPoint)p {
    id<VXInputSink> w = self.sink;
    CGSize fb = w.vxFramebufferSize;
    if (!w || fb.width <= 0) return -1;
    int fbW = (int)fb.width, fbH = (int)fb.height, s = 1;
    while (s < fbW && s < fbH && fbW / (s + 1) >= 320 && fbH / (s + 1) >= 240) s++;
    CGFloat x = p.x * w.vxPixelsPerPoint, y = p.y * w.vxPixelsPerPoint;
    CGFloat left = (fbW / s / 2.0 - 91) * s, top = (fbH / s - 22.0) * s;
    if (y < top || x < left || x >= left + 182.0 * s) return -1;
    int slot = (int)((x - left) / (20.0 * s));
    return slot >= 0 && slot <= 8 ? slot : -1;
}

- (void)selectHotbarSlot:(int)slot {
    id<VXInputSink> w = self.sink;
    if (!w || slot < 0 || slot > 8) return;
    _hotbarSlot = slot;
    gHotbarSelects++;
    [vxLightHaptic() impactOccurred];
    [w vxKey:GLFW_KEY_1 + slot action:GLFW_PRESS];
    [w vxKey:GLFW_KEY_1 + slot action:GLFW_RELEASE];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    gTouchBegan += (int)touches.count;
    id<VXInputSink> w = self.sink;
    if (!w) return;
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        // In game, a touch that lands on the hotbar selects that slot right away and
        // owns the hotbar until it lifts: sliding along it changes slot, as in Amethyst.
        // It never looks, uses, breaks or drops (no hold-to-drop, at the user's request).
        int slot = -1;
        BOOL inGame = w.vxInGame;
        if (inGame && p.y > self.bounds.size.height * 0.85) {
            // Diagnostics for hotbar hits (bottom of the screen only).
            NSLog(@"[VXControls] bottom touch at %.0f,%.0f pt (fb %.0fx%.0f, scale %.2f) -> hotbar slot %d",
                  p.x, p.y, w.vxFramebufferSize.width, w.vxFramebufferSize.height, w.vxPixelsPerPoint, [self hotbarSlotAt:p]);
        }
        if (!_hotbarTouch && inGame && (slot = [self hotbarSlotAt:p]) >= 0) {
            _hotbarTouch = t;
            _hotbarSlot = -1;
            [self selectHotbarSlot:slot];
            continue;
        }
        if (!_primary) {
            _primary = t;
            _lastPrimary = _startPrimary = p;
            _startTime = CACurrentMediaTime();
            _primaryInGame = w.vxInGame;
            _primaryVirtual = !_primaryInGame && self.overlay.virtualMouse;
            _moved = NO;
            _holding = NO;
            if (_primaryInGame || _primaryVirtual) {
                // Tap vs long press is decided later; a still, held finger presses the left button.
                NSUInteger gen = ++_gestureGeneration;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLongPress * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (gen != self->_gestureGeneration || !self->_primary || self->_moved || self->_holding) return;
                    self->_holding = YES;
                    [vxMediumHaptic() impactOccurred];
                    [self.sink vxMouseButton:GLFW_MOUSE_BUTTON_LEFT action:GLFW_PRESS];
                });
            } else {
                [self pushCursor:p];
                [w vxMouseButton:GLFW_MOUSE_BUTTON_LEFT action:GLFW_PRESS];
            }
        } else if (!_secondary && !_primaryInGame && !_primaryVirtual) {
            _secondary = t;
            [w vxMouseButton:GLFW_MOUSE_BUTTON_RIGHT action:GLFW_PRESS];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    gTouchMoved++;
    id<VXInputSink> w = self.sink;
    if (w && _hotbarTouch && [touches containsObject:_hotbarTouch]) {
        int slot = [self hotbarSlotAt:[_hotbarTouch locationInView:self]];
        if (slot >= 0 && slot != _hotbarSlot) [self selectHotbarSlot:slot];
    }
    if (!w || !_primary || ![touches containsObject:_primary]) return;
    gTouchMovedAccepted++;
    CGPoint p = [_primary locationInView:self];
    CGPoint d = CGPointMake(p.x - _lastPrimary.x, p.y - _lastPrimary.y);
    if (hypot(p.x - _startPrimary.x, p.y - _startPrimary.y) > kTapSlop) _moved = YES;
    if (w.vxInGame) {
        // Captured cursor (mouse look): relative motion, encoded as a = 1 with the delta in x/y.
        // Scaled to screen pixels like Amethyst (touch point × UIScreen.scale while grabbing),
        // so Minecraft's sensitivity slider feels the same as there.
        const CGFloat k = UIScreen.mainScreen.scale;
        [w vxCursorDelta:CGPointMake(d.x * k, d.y * k)];
    } else if (_primaryVirtual) {
        CGSize s = self.bounds.size;
        _virtualCursor.x = MIN(MAX(_virtualCursor.x + d.x, 0), s.width);
        _virtualCursor.y = MIN(MAX(_virtualCursor.y + d.y, 0), s.height);
        self.overlay.pointer.frame = (CGRect){_virtualCursor, self.overlay.pointer.bounds.size};
        [self pushCursor:_virtualCursor];
    } else {
        [self pushCursor:p];
    }
    _lastPrimary = p;
}

- (void)endTouches:(NSSet<UITouch *> *)touches {
    id<VXInputSink> w = self.sink;
    if (!w) return;
    if (_hotbarTouch && [touches containsObject:_hotbarTouch]) _hotbarTouch = nil;
    if (_primary && [touches containsObject:_primary]) {
        _gestureGeneration++;
        BOOL tap = !_moved && CACurrentMediaTime() - _startTime < kLongPress;
        if (_holding) {
            [w vxMouseButton:GLFW_MOUSE_BUTTON_LEFT action:GLFW_RELEASE];
        } else if (tap && _primaryInGame) {
            [vxLightHaptic() impactOccurred];
            [w vxMouseButton:GLFW_MOUSE_BUTTON_RIGHT action:GLFW_PRESS];
            [w vxMouseButton:GLFW_MOUSE_BUTTON_RIGHT action:GLFW_RELEASE];
        } else if (tap && _primaryVirtual) {
            [vxLightHaptic() impactOccurred];
            [w vxMouseButton:GLFW_MOUSE_BUTTON_LEFT action:GLFW_PRESS];
            [w vxMouseButton:GLFW_MOUSE_BUTTON_LEFT action:GLFW_RELEASE];
        } else if (!_primaryInGame && !_primaryVirtual) {
            [w vxMouseButton:GLFW_MOUSE_BUTTON_LEFT action:GLFW_RELEASE];
        }
        _primary = nil;
        _holding = NO;
    }
    if (_secondary && [touches containsObject:_secondary]) {
        [w vxMouseButton:GLFW_MOUSE_BUTTON_RIGHT action:GLFW_RELEASE];
        _secondary = nil;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    gTouchEnded += (int)touches.count;
    [self endTouches:touches];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    gTouchCancelled += (int)touches.count;
    [self endTouches:touches];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.overlay.frame = self.bounds;
    CGSize s = self.bounds.size;
    if (CGPointEqualToPoint(_virtualCursor, CGPointZero)) _virtualCursor = CGPointMake(s.width / 2, s.height / 2);
}

@end
NSString *VXTouchStats(void) {
    return [NSString stringWithFormat:@"began=%d moved=%d movedAccepted=%d ended=%d cancelled=%d hotbarSelects=%d",
            gTouchBegan, gTouchMoved, gTouchMovedAccepted, gTouchEnded, gTouchCancelled, gHotbarSelects];
}
