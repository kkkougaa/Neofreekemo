//
//  GlassStyle.x
//  NeoFreeBird
//
//  7.3.169: one Liquid Glass look for the whole app (kemo_glass_clear). The
//  user: iOS's own "Clear / Tinted" switch does not reach the app's glass, so
//  the app gets its own: off = regular glass (as X and this tweak make it),
//  on = clear glass everywhere.
//
//  Every glass in the app is a UIVisualEffectView whose effect is a
//  UIGlassEffect (X's XDSGlassContainer, the bars, this tweak's own pills and
//  sheets). Where such an effect is put on a view (-initWithEffect:,
//  -setEffect:), a regular one is swapped for a clear one made with
//  +[UIGlassEffect effectWithStyle:] (style 1 = clear, 0 = regular; the call
//  AccountBubbles.x already makes), keeping its tint colour and whether it
//  is interactive. The view keeps the effect it was given, so turning the
//  switch off puts X's own back. Only with Liquid Glass on (liquid_glass).
//  Glass that SwiftUI draws without a UIVisualEffectView is not reached; the
//  shake dump counts what was.
//

#import "HookHelpers.h"

static NSString* const kGlassClearKey = @"kemo_glass_clear";
static BOOL gGlassClear = NO;
static BOOL gGlassSwapping = NO;  // inside our own setEffect:
static NSHashTable<UIVisualEffectView*>* gGlassViews;
static const void* kGlassOriginalKey = &kGlassOriginalKey;  // the effect the view was given
static const void* kGlassMadeKey = &kGlassMadeKey;          // on an effect: made here
static NSUInteger gGlassSwapped = 0;
static NSUInteger gGlassSeen = 0;
static NSString* gGlassNote = @"-";

static Class GlassClass(void) {
    static Class glass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        glass = NSClassFromString(@"UIGlassEffect");
    });
    return glass;
}

static BOOL IsGlass(UIVisualEffect* effect) {
    Class glass = GlassClass();
    return glass && effect && [effect isKindOfClass:glass];
}

// A clear copy of `effect`, or nil when this iOS cannot make one.
static UIVisualEffect* ClearCopy(UIVisualEffect* effect) {
    Class glass = GlassClass();
    SEL styled = NSSelectorFromString(@"effectWithStyle:");
    if (!glass || ![glass respondsToSelector:styled]) {
        gGlassNote = @"UIGlassEffect has no effectWithStyle:";
        return nil;
    }
    UIVisualEffect* clear = nil;
    @try {
        clear = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glass, styled, 1);
    } @catch (__unused NSException* exception) {
        clear = nil;
    }
    if (![clear isKindOfClass:glass]) return nil;
    SEL getTint = NSSelectorFromString(@"tintColor");
    SEL setTint = NSSelectorFromString(@"setTintColor:");
    if ([effect respondsToSelector:getTint] && [clear respondsToSelector:setTint]) {
        id tint = ((id (*)(id, SEL))objc_msgSend)(effect, getTint);
        if (tint) ((void (*)(id, SEL, id))objc_msgSend)(clear, setTint, tint);
    }
    SEL getInteractive = NSSelectorFromString(@"isInteractive");
    SEL setInteractive = NSSelectorFromString(@"setInteractive:");
    if ([effect respondsToSelector:getInteractive] && [clear respondsToSelector:setInteractive]) {
        BOOL interactive = ((BOOL (*)(id, SEL))objc_msgSend)(effect, getInteractive);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(clear, setInteractive, interactive);
    }
    objc_setAssociatedObject(clear, kGlassMadeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return clear;
}

static BOOL WantClear(void) {
    return gGlassClear && NFBLiquidGlassEnabled();
}

// What the view should show for the effect it was given.
static UIVisualEffect* EffectFor(UIVisualEffectView* view, UIVisualEffect* given) {
    if (!IsGlass(given) || objc_getAssociatedObject(given, kGlassMadeKey)) return given;
    gGlassSeen++;
    objc_setAssociatedObject(view, kGlassOriginalKey, given, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gGlassViews) gGlassViews = [NSHashTable weakObjectsHashTable];
    [gGlassViews addObject:view];
    if (!WantClear()) return given;
    UIVisualEffect* clear = ClearCopy(given);
    if (!clear) return given;
    gGlassSwapped++;
    return clear;
}

// The switch changed: every glass seen so far shows the new look.
static void ApplyEverywhere(void) {
    for (UIVisualEffectView* view in [gGlassViews allObjects]) {
        UIVisualEffect* original = objc_getAssociatedObject(view, kGlassOriginalKey);
        if (!original) continue;
        UIVisualEffect* wanted = WantClear() ? (ClearCopy(original) ?: original) : original;
        gGlassSwapping = YES;
        view.effect = wanted;
        gGlassSwapping = NO;
    }
}

NSString* NFBGlassStyleDebugText(void) {
    return [NSString stringWithFormat:@"glass: clear=%d liquid=%d seen=%lu swapped=%lu views=%lu note=%@", gGlassClear,
                                      NFBLiquidGlassEnabled(), (unsigned long)gGlassSeen, (unsigned long)gGlassSwapped,
                                      (unsigned long)gGlassViews.count, gGlassNote];
}

%hook UIVisualEffectView

- (instancetype)initWithEffect:(UIVisualEffect*)effect {
    if (!IsGlass(effect) || ![NSThread isMainThread] || objc_getAssociatedObject(effect, kGlassMadeKey)) return %orig;
    UIVisualEffect* original = effect;
    UIVisualEffect* clear = WantClear() ? ClearCopy(effect) : nil;
    UIVisualEffectView* view = %orig(clear ?: effect);
    if (view) {
        objc_setAssociatedObject(view, kGlassOriginalKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gGlassViews) gGlassViews = [NSHashTable weakObjectsHashTable];
        [gGlassViews addObject:view];
        gGlassSeen++;
        if (clear) gGlassSwapped++;
    }
    return view;
}

- (void)setEffect:(UIVisualEffect*)effect {
    if (gGlassSwapping || ![NSThread isMainThread]) {
        %orig;
        return;
    }
    if (!IsGlass(effect)) {
        if (objc_getAssociatedObject(self, kGlassOriginalKey)) {
            objc_setAssociatedObject(self, kGlassOriginalKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        %orig;
        return;
    }
    %orig(EffectFor(self, effect));
}

%end

%ctor {
    gGlassClear = [[NSUserDefaults standardUserDefaults] boolForKey:kGlassClearKey];
    // queue:nil, then main (a main-queue observer stalls the launch, see CLAUDE.md).
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(__unused NSNotification* note) {
                                                      BOOL on = [[NSUserDefaults standardUserDefaults] boolForKey:kGlassClearKey];
                                                      if (on == gGlassClear) return;
                                                      dispatch_async(dispatch_get_main_queue(), ^{
                                                          BOOL now = [[NSUserDefaults standardUserDefaults] boolForKey:kGlassClearKey];
                                                          if (now == gGlassClear) return;
                                                          gGlassClear = now;
                                                          ApplyEverywhere();
                                                      });
                                                  }];
}
