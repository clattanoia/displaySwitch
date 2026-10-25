#import "DisplayCatalog.h"
#import <AppKit/AppKit.h>

static const uint32_t DSFlagDefault = 0x00000004;
static const uint32_t DSFlagInterlaced = 0x00000040;
static const uint32_t DSFlagStretched = 0x00000800;
static const uint32_t DSFlagNative = 0x02000000;

static NSString * const DSErrorDomain = @"app.displaySwitch.DisplaySwitch";

@interface DSMode ()
@property (nonatomic) BOOL ioNative;
- (NSString *)geometryKey;
@end

@implementation DSMode

- (BOOL)sameGeometryAs:(DSMode *)other {
    return self.width == other.width && self.height == other.height && self.pixelWidth == other.pixelWidth &&
           self.pixelHeight == other.pixelHeight;
}

- (NSString *)refreshLabel {
    if (self.refreshRate <= 0.5) {
        return @"默认刷新率";
    }
    double rounded = round(self.refreshRate);
    if (fabs(self.refreshRate - rounded) < 0.05) {
        return [NSString stringWithFormat:@"%.0f Hz", rounded];
    }
    return [NSString stringWithFormat:@"%.2f Hz", self.refreshRate];
}

- (NSString *)geometryKey {
    return [NSString stringWithFormat:@"%ld|%ld|%ld|%ld", (long)self.width, (long)self.height, (long)self.pixelWidth,
                              (long)self.pixelHeight];
}

@end

@implementation DSDisplay
@end

@implementation DSCatalog

+ (NSString *)titleForMode:(DSMode *)mode among:(NSArray<DSMode *> *)modes {
    BOOL anyHiDPI = NO;
    BOOL anyStandard = NO;
    for (DSMode *sibling in modes) {
        if (sibling.hiDPI) {
            anyHiDPI = YES;
        } else {
            anyStandard = YES;
        }
    }

    NSMutableString *title = [NSMutableString stringWithFormat:@"%ld × %ld", (long)mode.width, (long)mode.height];
    if (!mode.hiDPI && mode.nativeResolution) {
        [title appendString:@"  ·  原生"];
    } else if (mode.hiDPI && anyStandard) {
        [title appendString:@"  ·  视网膜"];
    } else if (!mode.hiDPI && anyHiDPI) {
        [title appendString:@"  ·  低分辨率"];
    }
    if (mode.defaultResolution) {
        [title appendString:@"  ·  默认"];
    }
    return title;
}

+ (BOOL)applyMode:(DSMode *)mode error:(NSError **)error {
    CGDirectDisplayID displayID = [self displayIDForKey:mode.displayKey];
    if (displayID == kCGNullDirectDisplay) {
        if (error) {
            *error = [self error:@"找不到这台显示器，它可能已经断开。"];
        }
        return NO;
    }

    CGDisplayModeRef current = CGDisplayCopyDisplayMode(displayID);
    if (current && CGDisplayModeGetWidth(current) == (size_t)mode.width &&
        CGDisplayModeGetHeight(current) == (size_t)mode.height &&
        CGDisplayModeGetPixelWidth(current) == (size_t)mode.pixelWidth &&
        CGDisplayModeGetPixelHeight(current) == (size_t)mode.pixelHeight &&
        fabs(CGDisplayModeGetRefreshRate(current) - mode.refreshRate) < 0.6) {
        CGDisplayModeRelease(current);
        return YES;
    }
    if (current) {
        CGDisplayModeRelease(current);
    }

    CGDisplayModeRef match = [self copyModeMatching:mode onDisplay:displayID];
    if (!match) {
        if (error) {
            *error = [self error:@"系统没有提供这个分辨率。"];
        }
        return NO;
    }

    CGDisplayConfigRef config = NULL;
    CGError beginError = CGBeginDisplayConfiguration(&config);
    if (beginError != kCGErrorSuccess || !config) {
        CGDisplayModeRelease(match);
        if (error) {
            *error = [self error:[NSString stringWithFormat:@"无法开始切换（错误码 %d）。", beginError]];
        }
        return NO;
    }

    CGError configureError = CGConfigureDisplayWithDisplayMode(config, displayID, match, NULL);
    CGDisplayModeRelease(match);
    if (configureError != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (error) {
            *error = [self error:[NSString stringWithFormat:@"系统拒绝了这个分辨率（错误码 %d）。", configureError]];
        }
        return NO;
    }

    // 永久写入，退出菜单栏应用后分辨率仍然保持。
    CGError completeError = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    if (completeError != kCGErrorSuccess) {
        if (error) {
            *error = [self error:[NSString stringWithFormat:@"切换没有完成（错误码 %d）。", completeError]];
        }
        return NO;
    }
    return YES;
}

+ (NSArray<DSDisplay *> *)activeDisplays {
    uint32_t count = 0;
    CGGetActiveDisplayList(0, NULL, &count);
    if (count == 0) {
        return @[];
    }

    CGDirectDisplayID *ids = calloc(count, sizeof(CGDirectDisplayID));
    if (!ids) {
        return @[];
    }
    CGGetActiveDisplayList(count, ids, &count);

    NSMutableArray<DSDisplay *> *displays = [NSMutableArray array];
    CGDirectDisplayID mainID = CGMainDisplayID();
    for (uint32_t index = 0; index < count; index++) {
        CGDirectDisplayID displayID = ids[index];
        if (displayID == kCGNullDirectDisplay) {
            continue;
        }
        if (CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay) {
            continue;
        }
        DSDisplay *display = [self displayForID:displayID mainID:mainID];
        if (display) {
            [displays addObject:display];
        }
    }
    free(ids);

    [displays sortUsingComparator:^NSComparisonResult(DSDisplay *lhs, DSDisplay *rhs) {
        if (lhs.mainDisplay != rhs.mainDisplay) {
            return lhs.mainDisplay ? NSOrderedAscending : NSOrderedDescending;
        }
        CGRect leftBounds = CGDisplayBounds(lhs.displayID);
        CGRect rightBounds = CGDisplayBounds(rhs.displayID);
        if (leftBounds.origin.x < rightBounds.origin.x) {
            return NSOrderedAscending;
        }
        if (leftBounds.origin.x > rightBounds.origin.x) {
            return NSOrderedDescending;
        }
        if (leftBounds.origin.y < rightBounds.origin.y) {
            return NSOrderedAscending;
        }
        if (leftBounds.origin.y > rightBounds.origin.y) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    return displays;
}

#pragma mark - Private

+ (NSError *)error:(NSString *)message {
    return [NSError errorWithDomain:DSErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

+ (CGDirectDisplayID)displayIDForKey:(NSString *)key {
    uint32_t count = 0;
    CGGetActiveDisplayList(0, NULL, &count);
    if (count == 0) {
        return kCGNullDirectDisplay;
    }
    CGDirectDisplayID *ids = calloc(count, sizeof(CGDirectDisplayID));
    if (!ids) {
        return kCGNullDirectDisplay;
    }
    CGGetActiveDisplayList(count, ids, &count);
    CGDirectDisplayID found = kCGNullDirectDisplay;
    for (uint32_t index = 0; index < count; index++) {
        NSString *name = [self nameForDisplay:ids[index]];
        if ([[self keyForDisplay:ids[index] name:name] isEqualToString:key]) {
            found = ids[index];
            break;
        }
    }
    free(ids);
    return found;
}

+ (NSString *)nameForDisplay:(CGDirectDisplayID)displayID {
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number.unsignedIntValue == displayID) {
            if (screen.localizedName.length > 0) {
                return screen.localizedName;
            }
            break;
        }
    }
    if (CGDisplayIsBuiltin(displayID)) {
        return @"内建显示器";
    }
    return [NSString stringWithFormat:@"显示器 %u", displayID];
}

+ (NSString *)keyForDisplay:(CGDirectDisplayID)displayID name:(NSString *)name {
    uint32_t vendor = CGDisplayVendorNumber(displayID);
    uint32_t model = CGDisplayModelNumber(displayID);
    uint32_t serial = CGDisplaySerialNumber(displayID);
    if (serial != 0) {
        return [NSString stringWithFormat:@"%u-%u-%u", vendor, model, serial];
    }
    return [NSString stringWithFormat:@"%u-%u-%@", vendor, model, name];
}

+ (DSMode *)modeFromDisplayMode:(CGDisplayModeRef)mode
                      displayID:(CGDirectDisplayID)displayID
                            key:(NSString *)key {
    size_t width = CGDisplayModeGetWidth(mode);
    size_t height = CGDisplayModeGetHeight(mode);
    if (width == 0 || height == 0) {
        return nil;
    }
    uint32_t flags = CGDisplayModeGetIOFlags(mode);
    if ((flags & DSFlagInterlaced) || (flags & DSFlagStretched) || !CGDisplayModeIsUsableForDesktopGUI(mode)) {
        return nil;
    }

    DSMode *result = [DSMode new];
    result.displayKey = key;
    result.displayID = displayID;
    result.ioModeID = CGDisplayModeGetIODisplayModeID(mode);
    result.width = (NSInteger)width;
    result.height = (NSInteger)height;
    result.pixelWidth = (NSInteger)CGDisplayModeGetPixelWidth(mode);
    result.pixelHeight = (NSInteger)CGDisplayModeGetPixelHeight(mode);
    result.refreshRate = CGDisplayModeGetRefreshRate(mode);
    result.hiDPI = result.pixelWidth >= result.width * 2 && result.pixelHeight >= result.height * 2;
    result.defaultResolution = (flags & DSFlagDefault) != 0;
    result.ioNative = (flags & DSFlagNative) != 0;
    BOOL standard = result.pixelWidth == result.width && result.pixelHeight == result.height;
    if (!result.hiDPI && !standard) {
        return nil;
    }
    return result;
}

+ (NSArray<DSMode *> *)rawModesForDisplay:(CGDirectDisplayID)displayID key:(NSString *)key {
    const void *dictKey = kCGDisplayShowDuplicateLowResolutionModes;
    const void *dictValue = kCFBooleanTrue;
    CFDictionaryRef options = CFDictionaryCreate(kCFAllocatorDefault, &dictKey, &dictValue, 1,
                                                 &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, options);
    if (options) {
        CFRelease(options);
    }
    if (!modes) {
        return @[];
    }

    NSMutableArray<DSMode *> *result = [NSMutableArray array];
    CFIndex count = CFArrayGetCount(modes);
    for (CFIndex index = 0; index < count; index++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, index);
        DSMode *wrapped = [self modeFromDisplayMode:mode displayID:displayID key:key];
        if (wrapped) {
            [result addObject:wrapped];
        }
    }
    CFRelease(modes);
    return result;
}

+ (DSMode *)currentModeForDisplay:(CGDirectDisplayID)displayID key:(NSString *)key {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
    if (!mode) {
        return nil;
    }
    DSMode *wrapped = [self modeFromDisplayMode:mode displayID:displayID key:key];
    if (!wrapped) {
        wrapped = [DSMode new];
        wrapped.displayKey = key;
        wrapped.displayID = displayID;
        wrapped.ioModeID = CGDisplayModeGetIODisplayModeID(mode);
        wrapped.width = (NSInteger)CGDisplayModeGetWidth(mode);
        wrapped.height = (NSInteger)CGDisplayModeGetHeight(mode);
        wrapped.pixelWidth = (NSInteger)CGDisplayModeGetPixelWidth(mode);
        wrapped.pixelHeight = (NSInteger)CGDisplayModeGetPixelHeight(mode);
        wrapped.refreshRate = CGDisplayModeGetRefreshRate(mode);
        wrapped.hiDPI = wrapped.pixelWidth >= wrapped.width * 2 && wrapped.pixelHeight >= wrapped.height * 2;
    }
    CGDisplayModeRelease(mode);
    return wrapped;
}

+ (DSMode *)pickModeFrom:(NSArray<DSMode *> *)group closestTo:(double)targetHz {
    DSMode *best = nil;
    for (DSMode *mode in group) {
        if (!best) {
            best = mode;
            continue;
        }
        double candidateDelta = fabs(mode.refreshRate - targetHz);
        double bestDelta = fabs(best.refreshRate - targetHz);
        if (candidateDelta < bestDelta - 0.05) {
            best = mode;
            continue;
        }
        if (fabs(candidateDelta - bestDelta) > 0.05) {
            continue;
        }
        if (mode.defaultResolution != best.defaultResolution) {
            if (mode.defaultResolution) {
                best = mode;
            }
            continue;
        }
        if (mode.ioModeID < best.ioModeID) {
            best = mode;
        }
    }
    return best;
}

+ (DSDisplay *)displayForID:(CGDirectDisplayID)displayID mainID:(CGDirectDisplayID)mainID {
    NSString *name = [self nameForDisplay:displayID];
    NSString *key = [self keyForDisplay:displayID name:name];
    NSArray<DSMode *> *raw = [self rawModesForDisplay:displayID key:key];
    DSMode *current = [self currentModeForDisplay:displayID key:key];
    if (!current || raw.count == 0) {
        return nil;
    }

    NSInteger nativePixelWidth = current.pixelWidth;
    NSInteger nativePixelHeight = current.pixelHeight;
    long long nativeArea = 0;
    long long defaultArea = 0;
    NSInteger defaultPixelWidth = 0;
    NSInteger defaultPixelHeight = 0;
    for (DSMode *mode in raw) {
        long long area = (long long)mode.pixelWidth * (long long)mode.pixelHeight;
        if (mode.ioNative && area > nativeArea) {
            nativeArea = area;
            nativePixelWidth = mode.pixelWidth;
            nativePixelHeight = mode.pixelHeight;
        }
        if (mode.defaultResolution && area > defaultArea) {
            defaultArea = area;
            defaultPixelWidth = mode.pixelWidth;
            defaultPixelHeight = mode.pixelHeight;
        }
    }
    if (nativeArea == 0 && defaultArea > 0) {
        nativePixelWidth = defaultPixelWidth;
        nativePixelHeight = defaultPixelHeight;
    }

    double nativeAspect = nativePixelHeight > 0 ? (double)nativePixelWidth / (double)nativePixelHeight : 1.6;
    for (DSMode *mode in raw) {
        mode.nativeResolution = !mode.hiDPI && mode.pixelWidth == nativePixelWidth && mode.pixelHeight == nativePixelHeight;
    }
    current.nativeResolution = !current.hiDPI && current.pixelWidth == nativePixelWidth && current.pixelHeight == nativePixelHeight;

    NSMutableDictionary<NSString *, NSMutableArray<DSMode *> *> *groups = [NSMutableDictionary dictionary];
    for (DSMode *mode in raw) {
        NSString *geometry = [mode geometryKey];
        NSMutableArray<DSMode *> *group = groups[geometry];
        if (!group) {
            group = [NSMutableArray array];
            groups[geometry] = group;
        }
        [group addObject:mode];
    }

    NSMutableArray<DSMode *> *representatives = [NSMutableArray array];
    [groups enumerateKeysAndObjectsUsingBlock:^(NSString *geometry, NSMutableArray<DSMode *> *group, BOOL *stop) {
        (void)geometry;
        (void)stop;
        DSMode *picked = [self pickModeFrom:group closestTo:current.refreshRate];
        if (!picked) {
            return;
        }
        BOOL anyDefault = NO;
        for (DSMode *mode in group) {
            if (mode.defaultResolution) {
                anyDefault = YES;
                break;
            }
        }
        picked.defaultResolution = anyDefault;
        [representatives addObject:picked];
    }];

    [representatives sortUsingComparator:^NSComparisonResult(DSMode *lhs, DSMode *rhs) {
        if (lhs.width != rhs.width) {
            return lhs.width > rhs.width ? NSOrderedAscending : NSOrderedDescending;
        }
        if (lhs.height != rhs.height) {
            return lhs.height > rhs.height ? NSOrderedAscending : NSOrderedDescending;
        }
        if (lhs.hiDPI != rhs.hiDPI) {
            return lhs.hiDPI ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    BOOL builtin = CGDisplayIsBuiltin(displayID) != 0;
    NSMutableArray<DSMode *> *recommended = [NSMutableArray array];
    for (DSMode *mode in representatives) {
        double aspect = (double)mode.width / (double)mode.height;
        BOOL aspectMatches = fabs(aspect - nativeAspect) < 0.02;
        BOOL include = NO;
        if (mode.hiDPI && aspectMatches) {
            include = YES;
        }
        // 外接显示器把面板原生分辨率放进默认列表；内建视网膜屏的 1x 原生模式会发糊，只在「全部」里出现。
        if (mode.nativeResolution && !builtin) {
            include = YES;
        }
        if ([mode sameGeometryAs:current]) {
            include = YES;
        }
        if (include) {
            [recommended addObject:mode];
        }
    }
    if (recommended.count == 0) {
        recommended = representatives;
    }

    NSMutableArray<DSMode *> *refreshModes = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seenRates = [NSMutableSet set];
    for (DSMode *mode in raw) {
        if (![mode sameGeometryAs:current]) {
            continue;
        }
        NSInteger milliHz = (NSInteger)llround(mode.refreshRate * 100.0);
        NSNumber *rateKey = @(milliHz);
        if ([seenRates containsObject:rateKey]) {
            continue;
        }
        [seenRates addObject:rateKey];
        [refreshModes addObject:mode];
    }
    [refreshModes sortUsingComparator:^NSComparisonResult(DSMode *lhs, DSMode *rhs) {
        if (lhs.refreshRate == rhs.refreshRate) {
            return NSOrderedSame;
        }
        return lhs.refreshRate > rhs.refreshRate ? NSOrderedAscending : NSOrderedDescending;
    }];

    DSDisplay *display = [DSDisplay new];
    display.displayID = displayID;
    display.key = key;
    display.name = name;
    display.builtin = builtin;
    display.mainDisplay = displayID == mainID;
    display.current = current;
    display.recommendedModes = recommended;
    display.allModes = representatives;
    display.refreshModes = refreshModes;
    return display;
}

+ (CGDisplayModeRef)copyModeMatching:(DSMode *)wanted onDisplay:(CGDirectDisplayID)displayID {
    const void *dictKey = kCGDisplayShowDuplicateLowResolutionModes;
    const void *dictValue = kCFBooleanTrue;
    CFDictionaryRef options = CFDictionaryCreate(kCFAllocatorDefault, &dictKey, &dictValue, 1,
                                                 &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, options);
    if (options) {
        CFRelease(options);
    }
    if (!modes) {
        return NULL;
    }

    CGDisplayModeRef best = NULL;
    double bestDelta = DBL_MAX;
    int32_t bestID = INT32_MAX;
    CFIndex count = CFArrayGetCount(modes);
    for (CFIndex index = 0; index < count; index++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, index);
        if (CGDisplayModeGetWidth(mode) != (size_t)wanted.width || CGDisplayModeGetHeight(mode) != (size_t)wanted.height ||
            CGDisplayModeGetPixelWidth(mode) != (size_t)wanted.pixelWidth ||
            CGDisplayModeGetPixelHeight(mode) != (size_t)wanted.pixelHeight) {
            continue;
        }
        if (!CGDisplayModeIsUsableForDesktopGUI(mode)) {
            continue;
        }
        double delta = fabs(CGDisplayModeGetRefreshRate(mode) - wanted.refreshRate);
        int32_t ioID = CGDisplayModeGetIODisplayModeID(mode);
        BOOL better = delta < bestDelta - 0.05;
        if (!better && fabs(delta - bestDelta) <= 0.05) {
            better = (ioID == wanted.ioModeID && bestID != wanted.ioModeID) || (bestID != wanted.ioModeID && ioID < bestID);
        }
        if (better || !best) {
            best = mode;
            bestDelta = delta;
            bestID = ioID;
        }
    }

    if (best) {
        CGDisplayModeRetain(best);
    }
    CFRelease(modes);
    return best;
}

@end
