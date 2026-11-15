#include <Geode/Geode.hpp>

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <algorithm>
#include <cmath>

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

static void apply_preferred_frame_rate(id self) {
    CADisplayLink* link = display_link(self);
    if (link == nil) {
        return;
    }

    NSInteger fps = static_cast<NSInteger>(std::lround(1.0 / animation_interval(self)));
    const NSInteger displayMaximum = [UIScreen mainScreen].maximumFramesPerSecond;
    if (displayMaximum > 0) {
        fps = std::min(fps, displayMaximum);
    }
    fps = std::max<NSInteger>(1, fps);

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

    using OriginalDoCaller = void (*)(id, SEL, id);
    reinterpret_cast<OriginalDoCaller>(s_originalDoCaller)(self, selector, sender);
}

static void ios_display_link_stop(id self, SEL) {
    CADisplayLink* link = display_link(self);
    if (link != nil) {
        [link invalidate];
        objc_setAssociatedObject(self, &s_displayLinkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ios_display_link_start(id self, SEL) {
    ios_display_link_stop(self, nullptr);

    CADisplayLink* link = [CADisplayLink displayLinkWithTarget:self
                                                     selector:@selector(doCaller:)];
    if (link == nil) {
        geode::log::error("SDL iOS port: failed to create CADisplayLink");
        return;
    }

    objc_setAssociatedObject(self, &s_displayLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    apply_preferred_frame_rate(self);
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    geode::log::info(
        "SDL iOS port: native CADisplayLink scheduler started ({} FPS target)",
        static_cast<int>(std::lround(1.0 / animation_interval(self)))
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

static id c_shared_director_caller() {
    if (s_sharedDisplayLinkCaller == nil) {
        if (s_displayLinkCallerClass == Nil) {
            return nil;
        }
        s_sharedDisplayLinkCaller = [[s_displayLinkCallerClass alloc] init];
        objc_setAssociatedObject(
            s_sharedDisplayLinkCaller,
            &s_animationIntervalKey,
            [NSNumber numberWithDouble:1.0 / 60.0],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
    return s_sharedDisplayLinkCaller;
}

static void c_destroy_director_caller() {
    if (s_sharedDisplayLinkCaller != nil) {
        ios_display_link_stop(s_sharedDisplayLinkCaller, nullptr);
        [s_sharedDisplayLinkCaller release];
        s_sharedDisplayLinkCaller = nil;
    }
}

$execute {
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
    if (s_displayLinkCallerClass == Nil) {
        // A second registration can occur during unusual loader/reload paths.
        s_displayLinkCallerClass = objc_getClass("SDLModIOSDisplayLinkCaller");
    }
    if (s_displayLinkCallerClass == Nil) {
        geode::log::error("SDL iOS port: failed to create runtime display-link subclass");
        return;
    }

    const bool methodsAdded =
        class_addMethod(s_displayLinkCallerClass, @selector(doCaller:),
                        reinterpret_cast<IMP>(&ios_display_link_do_caller), "v@:@") &&
        class_addMethod(s_displayLinkCallerClass, @selector(startMainLoop),
                        reinterpret_cast<IMP>(&ios_display_link_start), "v@:") &&
        class_addMethod(s_displayLinkCallerClass, @selector(stopMainLoop),
                        reinterpret_cast<IMP>(&ios_display_link_stop), "v@:") &&
        class_addMethod(s_displayLinkCallerClass, @selector(setAnimationInterval:),
                        reinterpret_cast<IMP>(&ios_display_link_set_animation_interval), "v@:d");

    if (!class_isMetaClass(object_getClass(s_displayLinkCallerClass))) {
        objc_registerClassPair(s_displayLinkCallerClass);
    }

    if (!methodsAdded) {
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
