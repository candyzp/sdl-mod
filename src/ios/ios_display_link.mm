#include <Geode/Geode.hpp>

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include <cmath>

@interface IOSDisplayLinkCaller : NSObject {
    CADisplayLink* m_displayLink;
    double m_animationInterval;
}

+ (id)sharedDirectorCaller;
- (void)setAnimationInterval:(double)interval;
- (void)startMainLoop;
- (void)end;
- (void)onDisplayLink:(CADisplayLink*)displayLink;

@end

@implementation IOSDisplayLinkCaller

+ (id)sharedDirectorCaller {
    static IOSDisplayLinkCaller* caller = nil;
    if (caller == nil) {
        caller = [[IOSDisplayLinkCaller alloc] init];
    }
    return caller;
}

- (id)init {
    self = [super init];
    if (self) {
        m_displayLink = nil;
        m_animationInterval = 1.0 / 60.0;
    }
    return self;
}

- (void)setAnimationInterval:(double)interval {
    if (std::isfinite(interval) && interval > 0.0) {
        m_animationInterval = interval;
    }

    if (m_displayLink != nil) {
        [self applyPreferredFrameRate];
    }
}

- (void)applyPreferredFrameRate {
    if (m_displayLink == nil) {
        return;
    }

    NSInteger fps = static_cast<NSInteger>(std::lround(1.0 / m_animationInterval));
    const NSInteger displayMaximum = [UIScreen mainScreen].maximumFramesPerSecond;

    if (displayMaximum > 0) {
        fps = std::min(fps, displayMaximum);
    }

    fps = std::max<NSInteger>(1, fps);

    if (@available(iOS 15.0, *)) {
        const CGFloat preferred = static_cast<CGFloat>(fps);
        const CGFloat minimum = std::max<CGFloat>(1.0, preferred * 2.0 / 3.0);
        m_displayLink.preferredFrameRateRange = CAFrameRateRangeMake(
            minimum,
            preferred,
            preferred
        );
    } else {
        m_displayLink.preferredFramesPerSecond = static_cast<NSInteger>(fps);
    }
}

- (void)startMainLoop {
    if (m_displayLink != nil) {
        return;
    }

    m_displayLink = [[CADisplayLink displayLinkWithTarget:self
                                                selector:@selector(onDisplayLink:)] retain];
    if (m_displayLink == nil) {
        geode::log::error("SDL iOS port: failed to create CADisplayLink");
        return;
    }

    [self applyPreferredFrameRate];
    [m_displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                       forMode:NSRunLoopCommonModes];

    geode::log::info(
        "SDL iOS port: native CADisplayLink scheduler started ({} FPS target)",
        static_cast<int>(std::lround(1.0 / m_animationInterval))
    );
}

- (void)onDisplayLink:(CADisplayLink*)displayLink {
    auto* director = cocos2d::CCDirector::sharedDirector();
    if (director == nullptr) {
        return;
    }

    static_cast<cocos2d::CCDisplayLinkDirector*>(director)->mainLoop();
}

- (void)end {
    if (m_displayLink != nil) {
        [m_displayLink invalidate];
        [m_displayLink release];
        m_displayLink = nil;
    }
}

- (void)dealloc {
    [self end];
    [super dealloc];
}

@end

static IOSDisplayLinkCaller* c_sharedDirectorCaller() {
    return [IOSDisplayLinkCaller sharedDirectorCaller];
}

$execute {
    if (!geode::Mod::get()->getSettingValue<bool>("ios-native-display-link")) {
        geode::log::info("SDL iOS port: native display-link scheduler disabled by setting");
        return;
    }

    auto directorCallerClass = objc_getClass("CCDirectorCaller");
    if (directorCallerClass == Nil) {
        geode::log::error("SDL iOS port: CCDirectorCaller class was not found; keeping vanilla scheduler");
        return;
    }

    auto method = class_getClassMethod(directorCallerClass, @selector(sharedDirectorCaller));
    if (method == nullptr) {
        geode::log::error("SDL iOS port: +[CCDirectorCaller sharedDirectorCaller] was not found; keeping vanilla scheduler");
        return;
    }

    auto hook = geode::Mod::get()->hook(
        reinterpret_cast<void*>(method_getImplementation(method)),
        &c_sharedDirectorCaller,
        "iOS SDL display-link scheduler",
        tulip::hook::TulipConvention::Default
    );

    if (!hook) {
        geode::log::error("SDL iOS port: failed to hook CCDirectorCaller: {}", hook.unwrapErr());
        return;
    }

    hook.unwrap()->setPriority(geode::Priority::Replace);
    geode::log::info("SDL iOS port: installed native display-link scheduler for Geometry Dash 2.2081");
}
