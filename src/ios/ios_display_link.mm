#include <Geode/Geode.hpp>

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <algorithm>
#include <cmath>
#include <cstdint>

// A separate transparent window keeps the debug panel above Geometry Dash's
// EAGL view. Returning nil from hitTest makes this window pass every touch
// through to the game window underneath.
@interface SDLModPassthroughWindow : UIWindow
@end

@implementation SDLModPassthroughWindow
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    return nil;
}
@end

// Geometry Dash ships CCDirectorCaller inside the game executable. Its
// Objective-C class is available through the runtime, but it is not exported
// as a link-time class symbol. Build a runtime subclass so this mod never
// creates an undefined _OBJC_CLASS_$_CCDirectorCaller linker reference.
//
// The overridden doCaller: calls the original implementation. On iOS that
// method restores the EAGL context and then runs Director::mainLoop(), so the
// game's existing frame path remains intact.

static Class s_displayLinkCallerClass = Nil;
static id s_sharedDisplayLinkCaller = nil;
static IMP s_originalDoCaller = nullptr;

static char s_displayLinkKey;
static char s_animationIntervalKey;

static UILabel* s_debugOverlayLabel = nil;
static SDLModPassthroughWindow* s_debugOverlayWindow = nil;
static bool s_debugOverlayEnabled = true;
static bool s_debugSceneWarningLogged = false;
static bool s_schedulerStarted = false;
static bool s_schedulerStartFailed = false;
static CFTimeInterval s_debugSampleStart = 0.0;
static CFTimeInterval s_debugLastOverlayUpdate = 0.0;
static CFTimeInterval s_lastCallbackTime = 0.0;
static uint64_t s_totalCallbacks = 0;
static uint64_t s_forwardedCallbacks = 0;
static uint64_t s_sampleCallbacks = 0;
static double s_measuredCallbackFPS = 0.0;

static double animation_interval(id self) {
    NSNumber* value = (NSNumber*)objc_getAssociatedObject(self, &s_animationIntervalKey);
    if (value == nil) {
        return 1.0 / 60.0;
    }
    const double interval = value.doubleValue;
    return std::isfinite(interval) && interval > 0.0 ? interval : 1.0 / 60.0;
}

static CADisplayLink* display_link(id self) {
    return (CADisplayLink*)objc_getAssociatedObject(self, &s_displayLinkKey);
}

static NSInteger target_frame_rate(id self) {
    NSInteger fps = static_cast<NSInteger>(std::lround(1.0 / animation_interval(self)));
    const NSInteger displayMaximum = [UIScreen mainScreen].maximumFramesPerSecond;
    if (displayMaximum > 0) {
        fps = std::min(fps, displayMaximum);
    }
    return std::max<NSInteger>(1, fps);
}

static UIWindowScene* debug_overlay_scene() {
    UIApplication* application = [UIApplication sharedApplication];
    UIWindowScene* foregroundInactiveScene = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene* scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene* windowScene = (UIWindowScene*)scene;
            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                return windowScene;
            }
            if (windowScene.activationState == UISceneActivationStateForegroundInactive) {
                foregroundInactiveScene = windowScene;
            }
        }
    }

    return foregroundInactiveScene;
}

static void destroy_debug_overlay_window() {
    [s_debugOverlayLabel removeFromSuperview];
    s_debugOverlayLabel = nil;

    if (s_debugOverlayWindow != nil) {
        s_debugOverlayWindow.hidden = YES;
        s_debugOverlayWindow.rootViewController = nil;
        [s_debugOverlayWindow release];
        s_debugOverlayWindow = nil;
    }
}

static void ensure_debug_overlay() {
    if (!s_debugOverlayEnabled) {
        return;
    }

    UIWindowScene* scene = debug_overlay_scene();
    if (scene == nil) {
        if (!s_debugSceneWarningLogged) {
            geode::log::warn("SDL iOS debug overlay: no foreground UIWindowScene is available yet");
            s_debugSceneWarningLogged = true;
        }
        return;
    }

    if (s_debugOverlayWindow != nil && s_debugOverlayWindow.windowScene != scene) {
        destroy_debug_overlay_window();
    }

    if (s_debugOverlayWindow == nil) {
        s_debugOverlayWindow = [[SDLModPassthroughWindow alloc] initWithWindowScene:scene];
        s_debugOverlayWindow.windowLevel = UIWindowLevelNormal + 1.0;
        s_debugOverlayWindow.backgroundColor = [UIColor clearColor];
        s_debugOverlayWindow.opaque = NO;

        UIViewController* controller = [[UIViewController alloc] init];
        controller.view.backgroundColor = [UIColor clearColor];
        controller.view.opaque = NO;
        controller.view.userInteractionEnabled = NO;
        s_debugOverlayWindow.rootViewController = controller;
        [controller release];

        s_debugOverlayWindow.hidden = NO;
        geode::log::info("SDL iOS debug overlay: created transparent pass-through window");
    }

    s_debugOverlayWindow.hidden = NO;
    UIView* hostView = s_debugOverlayWindow.rootViewController.view;
    if (hostView == nil) {
        return;
    }

    if (s_debugOverlayLabel != nil && s_debugOverlayLabel.superview != hostView) {
        [s_debugOverlayLabel removeFromSuperview];
        s_debugOverlayLabel = nil;
    }

    if (s_debugOverlayLabel == nil) {
        UILabel* label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.numberOfLines = 0;
        label.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [UIColor colorWithWhite:0.02 alpha:0.88];
        label.textAlignment = NSTextAlignmentLeft;
        label.userInteractionEnabled = NO;
        label.layer.cornerRadius = 8.0;
        label.layer.masksToBounds = YES;
        label.lineBreakMode = NSLineBreakByClipping;
        label.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        label.frame = CGRectMake(
            10.0,
            hostView.safeAreaInsets.top + 8.0,
            252.0,
            116.0
        );
        s_debugOverlayLabel = label;
        [hostView addSubview:label];
        [label release];
        geode::log::info("SDL iOS debug overlay: label attached to overlay window");
    }

    [hostView bringSubviewToFront:s_debugOverlayLabel];
}

static void refresh_debug_overlay(id self) {
    if (!s_debugOverlayEnabled) {
        return;
    }

    ensure_debug_overlay();
    if (s_debugOverlayLabel == nil) {
        return;
    }

    const bool hasLink = display_link(self) != nil;
    NSString* schedulerState = s_schedulerStartFailed
        ? @"FAILED"
        : (!s_schedulerStarted ? @"STOPPED"
           : (s_totalCallbacks == 0 ? @"WAITING" : @"ACTIVE"));
    const CFTimeInterval now = CACurrentMediaTime();
    const double callbackAge = s_lastCallbackTime > 0.0
        ? std::max(0.0, now - s_lastCallbackTime)
        : -1.0;
    NSString* callbackAgeText = callbackAge >= 0.0
        ? [NSString stringWithFormat:@"%.2fs ago", callbackAge]
        : @"not received";

    s_debugOverlayLabel.text = [NSString stringWithFormat:
        @"SDL iOS DEBUG\nScheduler: %@\nCADisplayLink: %@\nCallback FPS: %.1f\nTarget FPS: %ld\nCallbacks: %llu  Forwarded: %llu\nLast callback: %@",
        schedulerState,
        hasLink ? @"ATTACHED" : @"NONE",
        s_measuredCallbackFPS,
        static_cast<long>(target_frame_rate(self)),
        static_cast<unsigned long long>(s_totalCallbacks),
        static_cast<unsigned long long>(s_forwardedCallbacks),
        callbackAgeText
    ];
}

static void apply_preferred_frame_rate(id self) {
    CADisplayLink* link = display_link(self);
    if (link == nil) {
        return;
    }

    const NSInteger fps = target_frame_rate(self);

    if (@available(iOS 15.0, *)) {
        const CGFloat preferred = static_cast<CGFloat>(fps);
        const CGFloat minimum = std::max<CGFloat>(1.0, preferred * 2.0 / 3.0);
        link.preferredFrameRateRange = CAFrameRateRangeMake(minimum, preferred, preferred);
    } else {
        link.preferredFramesPerSecond = fps;
    }
}

static void ios_display_link_do_caller(id self, SEL selector, id sender) {
    if (s_originalDoCaller == nullptr) {
        return;
    }

    const CFTimeInterval now = CACurrentMediaTime();
    ++s_totalCallbacks;
    ++s_sampleCallbacks;
    s_lastCallbackTime = now;

    if (s_debugSampleStart <= 0.0) {
        s_debugSampleStart = now;
    } else {
        const CFTimeInterval elapsed = now - s_debugSampleStart;
        if (elapsed >= 1.0) {
            s_measuredCallbackFPS = static_cast<double>(s_sampleCallbacks) / elapsed;
            s_sampleCallbacks = 0;
            s_debugSampleStart = now;
        }
    }

    using OriginalDoCaller = void (*)(id, SEL, id);
    reinterpret_cast<OriginalDoCaller>(s_originalDoCaller)(self, selector, sender);
    ++s_forwardedCallbacks;

    // UIKit text is refreshed at most four times per second, not on every frame.
    if (s_debugLastOverlayUpdate <= 0.0 || now - s_debugLastOverlayUpdate >= 0.25) {
        refresh_debug_overlay(self);
        s_debugLastOverlayUpdate = now;
    }
}

static void ios_display_link_stop(id self, SEL) {
    s_schedulerStarted = false;
    CADisplayLink* link = display_link(self);
    if (link != nil) {
        [link invalidate];
        objc_setAssociatedObject(self, &s_displayLinkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    refresh_debug_overlay(self);
}

static void ios_display_link_start(id self, SEL) {
    ios_display_link_stop(self, nullptr);
    s_schedulerStartFailed = false;

    CADisplayLink* link = [CADisplayLink displayLinkWithTarget:self
                                                     selector:@selector(doCaller:)];
    if (link == nil) {
        s_schedulerStartFailed = true;
        geode::log::error("SDL iOS port: failed to create CADisplayLink");
        refresh_debug_overlay(self);
        return;
    }

    objc_setAssociatedObject(self, &s_displayLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    apply_preferred_frame_rate(self);
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    s_schedulerStarted = true;
    refresh_debug_overlay(self);

    geode::log::info(
        "SDL iOS port: native CADisplayLink scheduler started ({} FPS target)",
        static_cast<int>(target_frame_rate(self))
    );
}

static void ios_display_link_set_animation_interval(id self, SEL, double interval) {
    if (!std::isfinite(interval) || interval <= 0.0) {
        return;
    }

    objc_setAssociatedObject(
        self,
        &s_animationIntervalKey,
        [NSNumber numberWithDouble:interval],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    // Preserve Cocos2d's public interval property (measured in 1/60 s frames).
    auto setInterval = reinterpret_cast<void (*)(id, SEL, int)>(objc_msgSend);
    setInterval(self, @selector(setInterval:),
                std::max(1, static_cast<int>(std::lround(60.0 * interval))));

    apply_preferred_frame_rate(self);
}

static id c_shared_director_caller(id, SEL) {
    if (s_sharedDisplayLinkCaller == nil) {
        if (s_displayLinkCallerClass == Nil) {
            return nil;
        }
        s_sharedDisplayLinkCaller = [[s_displayLinkCallerClass alloc] init];
        s_totalCallbacks = 0;
        s_forwardedCallbacks = 0;
        s_sampleCallbacks = 0;
        s_measuredCallbackFPS = 0.0;
        s_debugSampleStart = 0.0;
        s_lastCallbackTime = 0.0;
        s_debugLastOverlayUpdate = 0.0;
        objc_setAssociatedObject(
            s_sharedDisplayLinkCaller,
            &s_animationIntervalKey,
            [NSNumber numberWithDouble:1.0 / 60.0],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
    return s_sharedDisplayLinkCaller;
}

static void c_destroy_director_caller(id, SEL) {
    if (s_sharedDisplayLinkCaller != nil) {
        ios_display_link_stop(s_sharedDisplayLinkCaller, nullptr);
        [s_sharedDisplayLinkCaller release];
        s_sharedDisplayLinkCaller = nil;
    }
    destroy_debug_overlay_window();
    s_schedulerStarted = false;
}

$execute {
    s_debugOverlayEnabled = geode::Mod::get()->getSettingValue<bool>("ios-debug-overlay");

    if (!geode::Mod::get()->getSettingValue<bool>("ios-native-display-link")) {
        geode::log::info("SDL iOS port: native display-link scheduler disabled by setting");
        return;
    }

    Class directorCallerClass = objc_getClass("CCDirectorCaller");
    if (directorCallerClass == Nil) {
        geode::log::error("SDL iOS port: CCDirectorCaller class was not found; keeping vanilla scheduler");
        return;
    }

    Method sharedMethod = class_getClassMethod(
        directorCallerClass, @selector(sharedDirectorCaller)
    );
    Method originalDoCallerMethod = class_getInstanceMethod(
        directorCallerClass, @selector(doCaller:)
    );
    if (sharedMethod == nullptr || originalDoCallerMethod == nullptr) {
        geode::log::error("SDL iOS port: required CCDirectorCaller methods were not found; keeping vanilla scheduler");
        return;
    }

    s_originalDoCaller = method_getImplementation(originalDoCallerMethod);
    if (s_originalDoCaller == nullptr) {
        geode::log::error("SDL iOS port: original CCDirectorCaller doCaller: implementation is missing");
        return;
    }

    s_displayLinkCallerClass = objc_allocateClassPair(
        directorCallerClass, "SDLModIOSDisplayLinkCaller", 0
    );
    const bool needsRegistration = s_displayLinkCallerClass != Nil;
    if (!needsRegistration) {
        // A second registration can occur during unusual loader/reload paths.
        s_displayLinkCallerClass = objc_getClass("SDLModIOSDisplayLinkCaller");
    }
    if (s_displayLinkCallerClass == Nil) {
        geode::log::error("SDL iOS port: failed to create runtime display-link subclass");
        return;
    }

    const bool doCallerAdded = class_addMethod(
        s_displayLinkCallerClass, @selector(doCaller:),
        reinterpret_cast<IMP>(&ios_display_link_do_caller), "v@:@"
    );
    const bool startAdded = class_addMethod(
        s_displayLinkCallerClass, @selector(startMainLoop),
        reinterpret_cast<IMP>(&ios_display_link_start), "v@:"
    );
    const bool stopAdded = class_addMethod(
        s_displayLinkCallerClass, @selector(stopMainLoop),
        reinterpret_cast<IMP>(&ios_display_link_stop), "v@:"
    );
    const bool intervalAdded = class_addMethod(
        s_displayLinkCallerClass, @selector(setAnimationInterval:),
        reinterpret_cast<IMP>(&ios_display_link_set_animation_interval), "v@:d"
    );

    if (needsRegistration) {
        if (!(doCallerAdded && startAdded && stopAdded && intervalAdded)) {
            geode::log::error("SDL iOS port: failed to install runtime display-link methods");
            return;
        }
        objc_registerClassPair(s_displayLinkCallerClass);
    }

    if (!(doCallerAdded && startAdded && stopAdded && intervalAdded)) {
        geode::log::error("SDL iOS port: failed to install runtime display-link methods");
        return;
    }

    auto sharedHook = geode::Mod::get()->hook(
        reinterpret_cast<void*>(method_getImplementation(sharedMethod)),
        &c_shared_director_caller,
        "iOS SDL display-link shared caller",
        tulip::hook::TulipConvention::Default
    );
    if (!sharedHook) {
        geode::log::error("SDL iOS port: failed to hook sharedDirectorCaller: {}", sharedHook.unwrapErr());
        return;
    }
    sharedHook.unwrap()->setPriority(geode::Priority::Replace);

    Method destroyMethod = class_getClassMethod(directorCallerClass, sel_registerName("destroy"));
    if (destroyMethod != nullptr) {
        auto destroyHook = geode::Mod::get()->hook(
            reinterpret_cast<void*>(method_getImplementation(destroyMethod)),
            &c_destroy_director_caller,
            "iOS SDL display-link destroy",
            tulip::hook::TulipConvention::Default
        );
        if (destroyHook) {
            destroyHook.unwrap()->setPriority(geode::Priority::Replace);
        } else {
            geode::log::warn("SDL iOS port: could not hook CCDirectorCaller destroy: {}", destroyHook.unwrapErr());
        }
    }

    geode::log::info("SDL iOS port: installed runtime display-link subclass for Geometry Dash 2.2081");
}
