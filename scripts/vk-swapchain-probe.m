// Mac runner for the Vulkan swapchain test (App/Voxelium/Native/VXVulkanSwapchain.h):
// a window with a CAMetalLayer, the test on a background thread (as Java runs it on
// the phone), then quit. Checks KosmicKrisp's Metal WSI and the loader shim
// (scripts/build-zink.sh vulkan-mac) before they go to a phone.
//   clang -fobjc-arc -IApp/Voxelium/Native -IApp/Voxelium/Native/khronos \
//     scripts/vk-swapchain-probe.m -framework AppKit -framework QuartzCore -o vk-swapchain-probe
//   ./vk-swapchain-probe <path to libvulkan.1.dylib> [seconds]
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include "VXVulkanSwapchain.h"

static void logLine(void *ctx, const char *line) {
    printf("%s\n", line);
    fflush(stdout);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <libvulkan.1.dylib> [seconds]\n", argv[0]);
            return 2;
        }
        NSString *library = @(argv[1]);
        double seconds = argc > 2 ? atof(argv[2]) : 5.0;
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 960, 540)
                                                       styleMask:NSWindowStyleMaskTitled
                                                         backing:NSBackingStoreBuffered defer:NO];
        window.title = @"Voxelium Vulkan swapchain test";
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.contentsScale = window.backingScaleFactor;
        window.contentView.wantsLayer = YES;
        window.contentView.layer = layer;
        [window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        CGSize px = CGSizeMake(960 * layer.contentsScale, 540 * layer.contentsScale);
        __block int status = 1;
        [NSThread detachNewThreadWithBlock:^{
            vxvk_logger L = {logLine, NULL};
            status = vxvk_run_swapchain_test(library.fileSystemRepresentation, (__bridge void *)layer,
                                             (uint32_t)px.width, (uint32_t)px.height, seconds, &L);
            dispatch_async(dispatch_get_main_queue(), ^{ [app stop:nil]; [app postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:YES]; });
        }];
        [app run];
        return status;
    }
}
