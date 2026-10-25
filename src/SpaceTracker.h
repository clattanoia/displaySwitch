#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一块屏幕上的一个桌面。macOS 没有公开接口，这里通过系统私有接口读取。
@interface DSSpaceInfo : NSObject
@property (nonatomic, copy) NSString *uuid;
@property (nonatomic, copy) NSString *displayUUID;
/// 与调度中心相同的全局序号。一块屏幕是 Desktop 1、Desktop 2 时，另一块从 Desktop 3 接着编。全屏空间为 0。
@property (nonatomic) NSInteger number;
/// 系统显示的名称，例如 Desktop 3。
@property (nonatomic, copy) NSString *displayName;
/// 0 是普通桌面，其他值是全屏应用等系统空间。
@property (nonatomic) NSInteger type;
@property (nonatomic) BOOL active;
@end

@interface DSSpaceTracker : NSObject
+ (BOOL)isAvailable;
+ (NSArray<DSSpaceInfo *> *)allSpaces;
+ (nullable DSSpaceInfo *)activeSpaceForDisplay:(CGDirectDisplayID)displayID;
@end

NS_ASSUME_NONNULL_END
