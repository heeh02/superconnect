//
//  CGVirtualDisplayPrivate.h
//  Reverse-engineered declarations for Apple's PRIVATE CoreGraphics virtual
//  display API (backed by the com.apple.VirtualDisplay XPC service / SkyLight).
//
//  These classes are NOT in the public SDK. The interface below mirrors the
//  long-standing reverse-engineered headers used by DeskPad / BetterDisplay /
//  VirtualDisplayKit. The symbols resolve at runtime against CoreGraphics.
//
//  Using these means: no Mac App Store distribution, and behavior may change
//  across macOS releases — which is exactly why superconnect-probe validates
//  them empirically on the target OS.
//
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, assign) unsigned int maxPixelsWide;
@property(nonatomic, assign) unsigned int maxPixelsHigh;
@property(nonatomic, assign) CGSize sizeInMillimeters;
@property(nonatomic, assign) unsigned int productID;
@property(nonatomic, assign) unsigned int vendorID;
@property(nonatomic, assign) unsigned int serialNum;
// Color chromaticities (CIE xy). Setting wide-gamut (BT.2020) primaries is part of
// making the virtual display HDR-capable so macOS composites with EDR headroom.
@property(nonatomic, assign) CGPoint redPrimary;
@property(nonatomic, assign) CGPoint greenPrimary;
@property(nonatomic, assign) CGPoint bluePrimary;
@property(nonatomic, assign) CGPoint whitePoint;
@property(nonatomic, copy, nullable) void (^terminationHandler)(id _Nullable arg, CGVirtualDisplay *_Nullable display);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@property(nonatomic, readonly) unsigned int width;
@property(nonatomic, readonly) unsigned int height;
@property(nonatomic, readonly) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic, assign) unsigned int hiDPI;
// Reference (HDR) display mode — advertises EDR headroom so macOS treats it as HDR.
@property(nonatomic, assign) BOOL isReference;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@property(nonatomic, readonly) unsigned int vendorID;
@property(nonatomic, readonly) unsigned int productID;
@property(nonatomic, readonly) unsigned int serialNum;
@property(nonatomic, readonly) CGSize sizeInMillimeters;
@property(nonatomic, readonly) unsigned int maxPixelsWide;
@property(nonatomic, readonly) unsigned int maxPixelsHigh;
@property(nonatomic, readonly) unsigned int hiDPI;
@property(nonatomic, readonly) NSArray<CGVirtualDisplayMode *> *modes;
@end

NS_ASSUME_NONNULL_END
