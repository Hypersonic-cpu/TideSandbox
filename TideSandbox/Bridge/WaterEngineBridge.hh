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

typedef NS_ENUM(NSInteger, WSEditTarget) {
    WSEditTargetInitialState = 0,
    WSEditTargetPausedCurrentState,
};

typedef NS_ENUM(NSInteger, WSMaterialOperation) {
    WSMaterialOperationAddSand = 0,
    WSMaterialOperationRemoveSand,
    WSMaterialOperationAddWater,
    WSMaterialOperationRemoveWater,
};

@interface WSTerrainEditResult : NSObject

@property(nonatomic, readonly) BOOL succeeded;
@property(nonatomic, readonly, getter=isChanged) BOOL changed;
@property(nonatomic, readonly) NSUInteger changedCells;
@property(nonatomic, readonly) NSUInteger changedFaces;
@property(nonatomic, readonly) double sandVolumeDelta;
@property(nonatomic, readonly) double waterVolumeDelta;
@property(nonatomic, readonly, getter=isClamped) BOOL clamped;
@property(nonatomic, readonly) NSUInteger newlyWetCells;
@property(nonatomic, readonly) NSUInteger newlyDryCells;

@end

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
- (BOOL)loadWidth:(NSUInteger)width
            height:(NSUInteger)height
       domainWidth:(double)domainWidth
      domainHeight:(double)domainHeight
      bedElevation:(NSData *)bedElevation
         waterDepth:(NSData *)waterDepth
         minimumBed:(double)minimumBed
     maximumSurface:(double)maximumSurface
    NS_SWIFT_NAME(load(width:height:domainWidth:domainHeight:bedElevation:waterDepth:minimumBed:maximumSurface:));
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

- (WSTerrainEditResult *)applyMaterialBrushAtX:(double)x
                                             y:(double)y
                                        radius:(double)radius
                                     operation:(WSMaterialOperation)operation
                                        amount:(double)amount
                                       falloff:(WSBrushFalloff)falloff
                                        target:(WSEditTarget)target
    NS_SWIFT_NAME(applyMaterialBrush(x:y:radius:operation:amount:falloff:target:));

- (WSTerrainEditResult *)applyMaterialPolygonWithXYCoordinates:(NSData *)xyCoordinates
                                                      operation:(WSMaterialOperation)operation
                                                         amount:(double)amount
                                                         target:(WSEditTarget)target
    NS_SWIFT_NAME(applyMaterialPolygon(xyCoordinates:operation:amount:target:));

@end

NS_ASSUME_NONNULL_END
