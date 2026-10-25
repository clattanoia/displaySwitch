#import "DisplayCatalog.h"
#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>

static NSString * const DSShowAllKey = @"showAllResolutions";
static NSString * const DSShowMenuBarResolutionKey = @"showResolutionInMenuBar";
static NSString * const DSFavoritesKey = @"favorites";
static NSString * const DSDidWelcomeKey = @"didShowWelcome";

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *menu;
- (void)refreshStatusItem;
@end

static AppDelegate *sharedDelegate = nil;

static void DisplayReconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo) {
    (void)display;
    (void)userInfo;
    if (flags & kCGDisplayBeginConfigurationFlag) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [sharedDelegate refreshStatusItem];
    });
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    sharedDelegate = self;
    [self enforceSingleInstance];

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.autosaveName = @"DisplaySwitch";
    [self applyStatusImage];

    self.menu = [[NSMenu alloc] initWithTitle:@"DisplaySwitch"];
    self.menu.delegate = self;
    self.statusItem.menu = self.menu;

    CGDisplayRegisterReconfigurationCallback(DisplayReconfigured, NULL);
    [self refreshStatusItem];
    [self showWelcomeIfNeeded];
}

- (void)enforceSingleInstance {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (bundleID.length == 0) {
        return;
    }
    for (NSRunningApplication *running in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
        if (running.processIdentifier != getpid()) {
            [NSApp terminate:nil];
            return;
        }
    }
}

- (void)applyStatusImage {
    NSImage *image = [NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:@"切换分辨率"];
    if (image) {
        NSImageSymbolConfiguration *configuration =
            [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular];
        image = [image imageWithSymbolConfiguration:configuration] ?: image;
        image.template = YES;
    } else {
        image = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
        [image lockFocus];
        [[NSColor blackColor] setStroke];
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 4, 16, 11) xRadius:1.5 yRadius:1.5];
        path.lineWidth = 1.4;
        [path stroke];
        [image unlockFocus];
        image.template = YES;
    }
    self.statusItem.button.image = image;
    self.statusItem.button.imagePosition = NSImageLeading;
    self.statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
}

- (void)refreshStatusItem {
    NSArray<DSDisplay *> *displays = [DSCatalog activeDisplays];
    DSDisplay *mainDisplay = displays.firstObject;
    BOOL showText = [NSUserDefaults.standardUserDefaults boolForKey:DSShowMenuBarResolutionKey];
    if (showText && mainDisplay.current) {
        self.statusItem.button.title =
            [NSString stringWithFormat:@"%ld×%ld", (long)mainDisplay.current.width, (long)mainDisplay.current.height];
    } else {
        self.statusItem.button.title = @"";
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (DSDisplay *display in displays) {
        if (!display.current) {
            continue;
        }
        [parts addObject:[NSString stringWithFormat:@"%@  %ld×%ld · %@", display.name, (long)display.current.width,
                                                    (long)display.current.height, display.current.refreshLabel]];
    }
    self.statusItem.button.toolTip = parts.count > 0 ? [NSString stringWithFormat:@"切换分辨率\n%@", [parts componentsJoinedByString:@"\n"]]
                                                      : @"切换分辨率";
}

- (void)showWelcomeIfNeeded {
    if ([NSUserDefaults.standardUserDefaults boolForKey:DSDidWelcomeKey]) {
        return;
    }
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:DSDidWelcomeKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"DisplaySwitch 已在菜单栏";
        alert.informativeText = @"点击右上角的显示器图标，选择分辨率即可切换，不用再打开系统设置。\n\n按住 Option 再点某一项，可以把它固定成常用分辨率。";
        [alert addButtonWithTitle:@"好"];
        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
    });
}

#pragma mark - Menu

- (void)menuWillOpen:(NSMenu *)menu {
    [menu removeAllItems];
    NSArray<DSDisplay *> *displays = [DSCatalog activeDisplays];
    if (displays.count == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"没有检测到显示器" action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [menu addItem:empty];
    }

    BOOL showAll = [NSUserDefaults.standardUserDefaults boolForKey:DSShowAllKey];
    for (DSDisplay *display in displays) {
        NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:display.name action:nil keyEquivalent:@""];
        header.enabled = NO;
        [menu addItem:header];

        NSArray<DSMode *> *source = showAll ? display.allModes : display.recommendedModes;
        NSArray<NSDictionary *> *favoriteDicts = [self favoriteDictsForKey:display.key];
        NSMutableArray<DSMode *> *favorites = [NSMutableArray array];
        NSMutableArray<DSMode *> *rest = [NSMutableArray array];
        for (DSMode *mode in source) {
            if ([self favoriteDicts:favoriteDicts containMode:mode]) {
                [favorites addObject:mode];
            } else {
                [rest addObject:mode];
            }
        }
        // 常用里也可能有「全部模式」才看得到的分辨率，默认列表里要单独补上。
        if (!showAll) {
            for (NSDictionary *dict in favoriteDicts) {
                DSMode *match = [self modeMatchingFavorite:dict inDisplay:display];
                if (!match) {
                    continue;
                }
                BOOL already = NO;
                for (DSMode *existing in favorites) {
                    if ([existing sameGeometryAs:match]) {
                        already = YES;
                        break;
                    }
                }
                if (!already) {
                    [favorites addObject:match];
                }
            }
        }

        for (DSMode *mode in favorites) {
            [self addModeItem:mode toMenu:menu among:source markedFavorite:YES display:display];
        }
        if (favorites.count > 0 && rest.count > 0) {
            [menu addItem:[NSMenuItem separatorItem]];
        }
        for (DSMode *mode in rest) {
            [self addModeItem:mode toMenu:menu among:source markedFavorite:NO display:display];
        }

        NSArray<DSMode *> *visibleRates = [self refreshModesForDisplay:display showAll:showAll];
        if (visibleRates.count > 1) {
            NSMenuItem *rateItem = [[NSMenuItem alloc]
                initWithTitle:[NSString stringWithFormat:@"刷新率  ·  %@", display.current.refreshLabel]
                        action:nil
                 keyEquivalent:@""];
            NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"刷新率"];
            for (DSMode *rate in visibleRates) {
                NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:rate.refreshLabel
                                                                action:@selector(selectMode:)
                                                         keyEquivalent:@""];
                item.target = self;
                item.representedObject = rate;
                NSInteger lhs = (NSInteger)llround(rate.refreshRate * 100.0);
                NSInteger rhs = (NSInteger)llround(display.current.refreshRate * 100.0);
                item.state = lhs == rhs ? NSControlStateValueOn : NSControlStateValueOff;
                [submenu addItem:item];
            }
            rateItem.submenu = submenu;
            [menu addItem:rateItem];
        }
        [menu addItem:[NSMenuItem separatorItem]];
    }

    NSMenuItem *showAllItem = [[NSMenuItem alloc] initWithTitle:@"显示全部分辨率" action:@selector(toggleShowAll:) keyEquivalent:@""];
    showAllItem.target = self;
    showAllItem.state = showAll ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:showAllItem];

    NSMenuItem *options = [[NSMenuItem alloc] initWithTitle:@"选项" action:nil keyEquivalent:@""];
    NSMenu *optionsMenu = [[NSMenu alloc] initWithTitle:@"选项"];
    NSMenuItem *menuBarItem = [[NSMenuItem alloc] initWithTitle:@"在菜单栏显示当前分辨率"
                                                          action:@selector(toggleMenuBarResolution:)
                                                   keyEquivalent:@""];
    menuBarItem.target = self;
    menuBarItem.state = [NSUserDefaults.standardUserDefaults boolForKey:DSShowMenuBarResolutionKey] ? NSControlStateValueOn
                                                                                                    : NSControlStateValueOff;
    [optionsMenu addItem:menuBarItem];

    NSMenuItem *loginItem = [[NSMenuItem alloc] initWithTitle:@"登录时启动" action:@selector(toggleLoginItem:) keyEquivalent:@""];
    loginItem.target = self;
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    loginItem.state = status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (status == SMAppServiceStatusRequiresApproval) {
        loginItem.title = @"登录时启动（需要在系统设置中允许）";
    }
    [optionsMenu addItem:loginItem];

    NSMenuItem *hint = [[NSMenuItem alloc] initWithTitle:@"按住 Option 点击分辨率可加入常用" action:nil keyEquivalent:@""];
    hint.enabled = NO;
    [optionsMenu addItem:[NSMenuItem separatorItem]];
    [optionsMenu addItem:hint];
    options.submenu = optionsMenu;
    [menu addItem:options];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出 DisplaySwitch" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
}

- (NSArray<DSMode *> *)refreshModesForDisplay:(DSDisplay *)display showAll:(BOOL)showAll {
    if (showAll) {
        return display.refreshModes;
    }
    NSMutableArray<DSMode *> *rates = [NSMutableArray array];
    for (DSMode *mode in display.refreshModes) {
        if (mode.refreshRate + 0.05 >= 48.0 || fabs(mode.refreshRate - display.current.refreshRate) < 0.6) {
            [rates addObject:mode];
        }
    }
    return rates;
}

- (void)addModeItem:(DSMode *)mode
             toMenu:(NSMenu *)menu
              among:(NSArray<DSMode *> *)siblings
     markedFavorite:(BOOL)markedFavorite
            display:(DSDisplay *)display {
    NSString *base = [DSCatalog titleForMode:mode among:siblings];
    if (fabs(mode.refreshRate - display.current.refreshRate) > 1.0) {
        base = [base stringByAppendingFormat:@"  ·  %@", mode.refreshLabel];
    }
    NSString *title = markedFavorite ? [NSString stringWithFormat:@"★  %@", base] : base;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectMode:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = mode;
    item.keyEquivalentModifierMask = 0;
    item.state = [mode sameGeometryAs:display.current] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:item];

    BOOL favorite = markedFavorite || [self favoriteDicts:[self favoriteDictsForKey:display.key] containMode:mode];
    NSString *alternateTitle = favorite ? [NSString stringWithFormat:@"从常用中移除  %@", base]
                                         : [NSString stringWithFormat:@"加入常用  %@", base];
    NSMenuItem *alternate = [[NSMenuItem alloc] initWithTitle:alternateTitle action:@selector(toggleFavorite:) keyEquivalent:@""];
    alternate.target = self;
    alternate.representedObject = mode;
    alternate.alternate = YES;
    alternate.keyEquivalentModifierMask = NSEventModifierFlagOption;
    [menu addItem:alternate];
}

- (void)selectMode:(NSMenuItem *)sender {
    DSMode *mode = sender.representedObject;
    if (![mode isKindOfClass:DSMode.class]) {
        return;
    }
    NSError *error = nil;
    if (![DSCatalog applyMode:mode error:&error]) {
        [self presentFailure:error.localizedDescription ?: @"切换分辨率失败。"];
        return;
    }
    [self refreshStatusItem];
}

- (void)toggleFavorite:(NSMenuItem *)sender {
    DSMode *mode = sender.representedObject;
    if (![mode isKindOfClass:DSMode.class]) {
        return;
    }
    NSMutableArray<NSDictionary *> *favorites = [[self favoriteDictsForKey:mode.displayKey] mutableCopy];
    NSUInteger existing = [favorites indexOfObjectPassingTest:^BOOL(NSDictionary *dict, NSUInteger index, BOOL *stop) {
        (void)index;
        (void)stop;
        return [self favoriteDict:dict matchesMode:mode];
    }];
    if (existing == NSNotFound) {
        [favorites addObject:@{
            @"w": @(mode.width),
            @"h": @(mode.height),
            @"pw": @(mode.pixelWidth),
            @"ph": @(mode.pixelHeight),
        }];
    } else {
        [favorites removeObjectAtIndex:existing];
    }
    [self setFavoriteDicts:favorites forKey:mode.displayKey];
}

- (void)toggleShowAll:(NSMenuItem *)sender {
    (void)sender;
    BOOL showAll = ![NSUserDefaults.standardUserDefaults boolForKey:DSShowAllKey];
    [NSUserDefaults.standardUserDefaults setBool:showAll forKey:DSShowAllKey];
}

- (void)toggleMenuBarResolution:(NSMenuItem *)sender {
    (void)sender;
    BOOL show = ![NSUserDefaults.standardUserDefaults boolForKey:DSShowMenuBarResolutionKey];
    [NSUserDefaults.standardUserDefaults setBool:show forKey:DSShowMenuBarResolutionKey];
    [self refreshStatusItem];
}

- (void)toggleLoginItem:(NSMenuItem *)sender {
    (void)sender;
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    if (service.status == SMAppServiceStatusEnabled) {
        [service unregisterAndReturnError:&error];
    } else {
        [service registerAndReturnError:&error];
    }
    if (error) {
        [self presentFailure:error.localizedDescription];
        return;
    }
    if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
    }
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)presentFailure:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"无法切换分辨率";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"好"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

#pragma mark - Favorites

- (NSArray<NSDictionary *> *)favoriteDictsForKey:(NSString *)key {
    NSDictionary *all = [NSUserDefaults.standardUserDefaults dictionaryForKey:DSFavoritesKey];
    id value = all[key];
    if (![value isKindOfClass:NSArray.class]) {
        return @[];
    }
    return value;
}

- (void)setFavoriteDicts:(NSArray<NSDictionary *> *)favorites forKey:(NSString *)key {
    NSMutableDictionary *all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:DSFavoritesKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (favorites.count == 0) {
        [all removeObjectForKey:key];
    } else {
        all[key] = favorites;
    }
    [NSUserDefaults.standardUserDefaults setObject:all forKey:DSFavoritesKey];
}

- (BOOL)favoriteDict:(NSDictionary *)dict matchesMode:(DSMode *)mode {
    return [dict[@"w"] integerValue] == mode.width && [dict[@"h"] integerValue] == mode.height &&
           [dict[@"pw"] integerValue] == mode.pixelWidth && [dict[@"ph"] integerValue] == mode.pixelHeight;
}

- (BOOL)favoriteDicts:(NSArray<NSDictionary *> *)dicts containMode:(DSMode *)mode {
    for (NSDictionary *dict in dicts) {
        if ([self favoriteDict:dict matchesMode:mode]) {
            return YES;
        }
    }
    return NO;
}

- (DSMode *)modeMatchingFavorite:(NSDictionary *)dict inDisplay:(DSDisplay *)display {
    for (DSMode *mode in display.allModes) {
        if ([self favoriteDict:dict matchesMode:mode]) {
            return mode;
        }
    }
    return nil;
}

@end

static void ListModes(void) {
    for (DSDisplay *display in [DSCatalog activeDisplays]) {
        printf("== %s  current %ld x %ld pix %ld x %ld %s\n", display.name.UTF8String, (long)display.current.width,
               (long)display.current.height, (long)display.current.pixelWidth, (long)display.current.pixelHeight,
               display.current.refreshLabel.UTF8String);
        printf("  recommended (%lu)\n", (unsigned long)display.recommendedModes.count);
        for (DSMode *mode in display.recommendedModes) {
            printf("    %s   pix %ld x %ld  %s%s\n", [DSCatalog titleForMode:mode among:display.recommendedModes].UTF8String,
                   (long)mode.pixelWidth, (long)mode.pixelHeight, mode.refreshLabel.UTF8String,
                   [mode sameGeometryAs:display.current] ? "  [current]" : "");
        }
        printf("  all (%lu)\n", (unsigned long)display.allModes.count);
        printf("  refresh");
        for (DSMode *mode in display.refreshModes) {
            printf(" %s", mode.refreshLabel.UTF8String);
        }
        printf("\n");
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int index = 1; index < argc; index++) {
            if (strcmp(argv[index], "--list-modes") == 0) {
                ListModes();
                return 0;
            }
        }

        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
