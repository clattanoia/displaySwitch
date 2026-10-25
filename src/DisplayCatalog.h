#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个可切换的显示模式。几何尺寸相同即视为同一个分辨率，刷新率单独切换。
@interface DSMode : NSObject
@property (nonatomic, copy) NSString *displayKey;
@property (nonatomic) CGDirectDisplayID displayID;
@property (nonatomic) int32_t ioModeID;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) NSInteger pixelWidth;
@property (nonatomic) NSInteger pixelHeight;
@property (nonatomic) double refreshRate;
/// 点尺寸的 2 倍帧缓冲，对应系统设置里的视网膜缩放。
@property (nonatomic) BOOL hiDPI;
/// 1x 面板原生像素，例如 3840×2160 或 3024×1964。
@property (nonatomic) BOOL nativeResolution;
/// 系统标记的默认分辨率。
@property (nonatomic) BOOL defaultResolution;
- (BOOL)sameGeometryAs:(DSMode *)other;
- (NSString *)refreshLabel;
@end

@interface DSDisplay : NSObject
@property (nonatomic) CGDirectDisplayID displayID;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL builtin;
@property (nonatomic) BOOL mainDisplay;
@property (nonatomic, strong) DSMode *current;
/// 和系统设置默认列表接近：原生比例的视网膜模式，外接屏再加原生分辨率。
@property (nonatomic, copy) NSArray<DSMode *> *recommendedModes;
/// 全部桌面可用模式，每种尺寸只保留最接近当前刷新率的一条。
@property (nonatomic, copy) NSArray<DSMode *> *allModes;
/// 当前分辨率下可选的刷新率。
@property (nonatomic, copy) NSArray<DSMode *> *refreshModes;
@end

@interface DSCatalog : NSObject
+ (NSArray<DSDisplay *> *)activeDisplays;
+ (NSString *)titleForMode:(DSMode *)mode among:(NSArray<DSMode *> *)modes;
+ (BOOL)applyMode:(DSMode *)mode error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
