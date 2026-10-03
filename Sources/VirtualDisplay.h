// Adapted from TargetBridge, Copyright (c) 2026 Marco Caciotti, MIT.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) uint32_t maxPixelsWide;
@property(nonatomic) uint32_t maxPixelsHigh;
@property(nonatomic) NSPoint whitePoint;
@property(nonatomic) NSPoint redPrimary;
@property(nonatomic) NSPoint greenPrimary;
@property(nonatomic) NSPoint bluePrimary;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) uint32_t vendorID;
@property(nonatomic) uint32_t productID;
@property(nonatomic) uint32_t serialNum;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) BOOL hiDPI;
@property(nonatomic, copy) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end
