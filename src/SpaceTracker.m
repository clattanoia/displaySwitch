#import "SpaceTracker.h"
#import <dlfcn.h>

typedef int CGSConnectionID;
typedef CGSConnectionID (*DSConnectionFunc)(void);
typedef CFArrayRef (*DSCopySpacesFunc)(CGSConnectionID);
typedef CFUUIDRef (*DSDisplayUUIDFunc)(CGDirectDisplayID);

@implementation DSSpaceInfo
@end

@implementation DSSpaceTracker

+ (BOOL)isAvailable {
    DSConnectionFunc connection = NULL;
    DSCopySpacesFunc copySpaces = NULL;
    [self loadConnection:&connection copySpaces:&copySpaces];
    return connection != NULL && copySpaces != NULL;
}

+ (DSSpaceInfo *)activeSpaceForDisplay:(CGDirectDisplayID)displayID {
    NSString *displayUUID = [self uuidForDisplay:displayID];
    if (displayUUID.length == 0) {
        return nil;
    }
    for (DSSpaceInfo *space in [self allSpaces]) {
        if (space.active && [space.displayUUID caseInsensitiveCompare:displayUUID] == NSOrderedSame) {
            return space;
        }
    }
    return nil;
}

#pragma mark - Private

+ (void)loadConnection:(DSConnectionFunc *)connection copySpaces:(DSCopySpacesFunc *)copySpaces {
    static DSConnectionFunc connectionFunc = NULL;
    static DSCopySpacesFunc copyFunc = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (!skylight) {
            return;
        }
        connectionFunc = (DSConnectionFunc)dlsym(skylight, "CGSMainConnectionID");
        copyFunc = (DSCopySpacesFunc)dlsym(skylight, "CGSCopyManagedDisplaySpaces");
    });
    if (connection) {
        *connection = connectionFunc;
    }
    if (copySpaces) {
        *copySpaces = copyFunc;
    }
}

+ (NSString *)nameForDesktopNumber:(NSInteger)number {
    static NSString *format = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        format = [self desktopNameFormat];
    });
    return [NSString stringWithFormat:format, @(number)];
}

+ (NSString *)desktopNameFormat {
    NSString *root = @"/System/Library/CoreServices/Dock.app/Contents/Resources";
    for (NSString *language in [NSLocale preferredLanguages]) {
        NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithObjects:
            [language stringByReplacingOccurrencesOfString:@"-" withString:@"_"],
            language,
            [language componentsSeparatedByString:@"-"].firstObject ?: language,
            nil];
        if ([language hasPrefix:@"zh-Hans"]) {
            [candidates addObject:@"zh_CN"];
        } else if ([language hasPrefix:@"zh-Hant"]) {
            [candidates addObject:@"zh_TW"];
            [candidates addObject:@"zh_HK"];
        }
        for (NSString *name in candidates) {
            NSString *path = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.lproj/Localizable.strings", name]];
            NSDictionary *table = [NSDictionary dictionaryWithContentsOfFile:path];
            NSString *value = table[@"DesktopNum"];
            if ([value isKindOfClass:NSString.class] && value.length > 0) {
                return value;
            }
        }
    }
    return @"Desktop %@";
}

+ (NSString *)uuidForDisplay:(CGDirectDisplayID)displayID {
    static DSDisplayUUIDFunc createUUID = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createUUID = (DSDisplayUUIDFunc)dlsym(RTLD_DEFAULT, "CGDisplayCreateUUIDFromDisplayID");
    });
    if (!createUUID) {
        return nil;
    }
    CFUUIDRef uuid = createUUID(displayID);
    if (!uuid) {
        return nil;
    }
    NSString *string = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return string;
}

+ (NSArray<DSSpaceInfo *> *)allSpaces {
    DSConnectionFunc connection = NULL;
    DSCopySpacesFunc copySpaces = NULL;
    [self loadConnection:&connection copySpaces:&copySpaces];
    if (!connection || !copySpaces) {
        return @[];
    }

    CFArrayRef raw = copySpaces(connection());
    if (!raw) {
        return @[];
    }
    NSArray *displays = (__bridge_transfer NSArray *)raw;
    NSMutableArray<DSSpaceInfo *> *result = [NSMutableArray array];
    NSInteger desktopNumber = 0;
    for (NSDictionary *displayInfo in displays) {
        if (![displayInfo isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *displayUUID = displayInfo[@"Display Identifier"];
        NSArray *spaces = displayInfo[@"Spaces"];
        NSDictionary *current = displayInfo[@"Current Space"];
        NSString *currentUUID = [current isKindOfClass:NSDictionary.class] ? current[@"uuid"] : nil;
        if (![displayUUID isKindOfClass:NSString.class] || ![spaces isKindOfClass:NSArray.class]) {
            continue;
        }

        for (NSDictionary *space in spaces) {
            if (![space isKindOfClass:NSDictionary.class]) {
                continue;
            }
            NSString *uuid = space[@"uuid"];
            if (![uuid isKindOfClass:NSString.class]) {
                continue;
            }
            NSInteger type = [space[@"type"] integerValue];
            if (type == 0) {
                desktopNumber += 1;
            }
            DSSpaceInfo *info = [DSSpaceInfo new];
            info.uuid = uuid;
            info.displayUUID = displayUUID;
            info.type = type;
            info.number = type == 0 ? desktopNumber : 0;
            info.displayName = info.number > 0 ? [self nameForDesktopNumber:info.number] : @"";
            info.active = [uuid isEqualToString:currentUUID];
            [result addObject:info];
        }
    }
    return result;
}

@end
