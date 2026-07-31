#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WSEngineStepStatus) {
    WSEngineStepStatusSuccess = 0,
    WSEngineStepStatusInvalidConfiguration,
    WSEngineStepStatusInvalidTimeStep,
    WSEngineStepStatusNonFiniteState,
    WSEngineStepStatusVelocityBoundExceeded,
    WSEngineStepStatusSubstepLimitReached,
};

typedef NS_ENUM(NSInteger, WSBrushFalloff) {
    WSBrushFalloffConstant = 0,
    WSBrushFalloffLinear,
    WSBrushFalloffSmooth,
};

typedef NS_ENUM(NSInteger, WSPolygonMode) {
    WSPolygonModeAdd = 0,
    WSPolygonModeSet,
};

@interface WSEngineDiagnostics : NSObject

@property(nonatomic, readonly) double totalVolume;
@property(nonatomic, readonly) double minimumDepth;
@property(nonatomic, readonly) double maximumDepth;
@property(nonatomic, readonly) double maximumAbsVelocityX;
@property(nonatomic, readonly) double maximumAbsVelocityY;
@property(nonatomic, readonly) double maximumWaveSpeed;
@property(nonatomic, readonly) double selectedTimeStep;
@property(nonatomic, readonly) double simulatedTime;
@property(nonatomic, readonly) double correctionVolume;
@property(nonatomic, readonly) NSUInteger substepCount;
@property(nonatomic, readonly) NSUInteger wetCellCount;
@property(nonatomic, readonly) NSUInteger correctionCount;
@property(nonatomic, readonly, getter=isFinite) BOOL finite;
@property(nonatomic, readonly) WSEngineStepStatus status;

@end

@interface WSEngineSnapshot : NSObject

@property(nonatomic, readonly) NSUInteger width;
@property(nonatomic, readonly) NSUInteger height;
@property(nonatomic, readonly) double domainWidth;
@property(nonatomic, readonly) double domainHeight;
@property(nonatomic, readonly) NSData *bedElevation;
@property(nonatomic, readonly) NSData *waterDepth;
@property(nonatomic, readonly) NSData *surfaceElevation;
@property(nonatomic, readonly) NSData *surfaceDeviation;
@property(nonatomic, readonly) NSData *velocityMagnitude;
@property(nonatomic, readonly) NSData *wetMask;
@property(nonatomic, readonly) WSEngineDiagnostics *diagnostics;

@end

@interface WSWaterEngineBridge : NSObject {
@private
    void *_implementation;
}

@property(nonatomic, getter=isRunning) BOOL running;

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  domainWidth:(double)domainWidth
                 domainHeight:(double)domainHeight NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)loadWidth:(NSUInteger)width
            height:(NSUInteger)height
       domainWidth:(double)domainWidth
      domainHeight:(double)domainHeight
      bedElevation:(NSData *)bedElevation
         waterDepth:(NSData *)waterDepth
    NS_SWIFT_NAME(load(width:height:domainWidth:domainHeight:bedElevation:waterDepth:));
- (void)reset;
- (WSEngineStepStatus)advance:(double)frameDeltaTime;
- (WSEngineStepStatus)stepOnce:(double)timeStep;
- (WSEngineSnapshot *)snapshot;

- (BOOL)updateGravity:(double)gravity
        linearDamping:(double)linearDamping
             cflNumber:(double)cflNumber
       minimumWetDepth:(double)minimumWetDepth
           workerCount:(NSUInteger)workerCount
    NS_SWIFT_NAME(updateConfiguration(gravity:linearDamping:cflNumber:minimumWetDepth:workerCount:));

- (BOOL)applyBrushAtX:(double)x
                    y:(double)y
               radius:(double)radius
             strength:(double)strength
              falloff:(WSBrushFalloff)falloff
           minimumBed:(double)minimumBed
           maximumBed:(double)maximumBed
    NS_SWIFT_NAME(applyBrush(x:y:radius:strength:falloff:minimumBed:maximumBed:));

- (BOOL)applyPolygonWithXYCoordinates:(NSData *)xyCoordinates
                                  mode:(WSPolygonMode)mode
                            elevation:(double)elevation
                           minimumBed:(double)minimumBed
                            maximumBed:(double)maximumBed
    NS_SWIFT_NAME(applyPolygon(xyCoordinates:mode:elevation:minimumBed:maximumBed:));

@end

NS_ASSUME_NONNULL_END
