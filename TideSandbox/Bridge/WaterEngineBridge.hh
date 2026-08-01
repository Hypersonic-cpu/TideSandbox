#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

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

typedef NS_ENUM(NSInteger, WSBoundaryType) {
    WSBoundaryTypeReflective = 0,
    WSBoundaryTypeFreeOpen,
    WSBoundaryTypeDrivenHeight,
};

typedef NS_ENUM(NSInteger, WSRequestedSimulationBackend) {
    WSRequestedSimulationBackendAutomaticAccelerated = 0,
    WSRequestedSimulationBackendMetalGPU,
    WSRequestedSimulationBackendCPUReference,
};

typedef NS_ENUM(NSInteger, WSResolvedSimulationBackend) {
    WSResolvedSimulationBackendMPSGraphAutomatic = 0,
    WSResolvedSimulationBackendMetalGPU,
    WSResolvedSimulationBackendCPUReference,
};

typedef NS_ENUM(NSInteger, WSBackendFailureInjection) {
    WSBackendFailureInjectionNone = 0,
    WSBackendFailureInjectionMPSGraphPreparation,
    WSBackendFailureInjectionMetalPreparation,
    WSBackendFailureInjectionAcceleratedExecution,
    WSBackendFailureInjectionAllAcceleratedPreparation,
};

@interface WSBackendStatus : NSObject

@property(nonatomic, readonly) WSRequestedSimulationBackend requestedBackend;
@property(nonatomic, readonly) WSResolvedSimulationBackend resolvedBackend;
@property(nonatomic, readonly, getter=isReady) BOOL ready;
@property(nonatomic, readonly) NSString *resolutionReason;
@property(nonatomic, readonly) NSString *fallbackReason;
@property(nonatomic, readonly) NSString *statePrecision;
@property(nonatomic, readonly) double graphCompileMilliseconds;
@property(nonatomic, readonly) double lastStableDtMilliseconds;
@property(nonatomic, readonly) double lastFramePhysicsMilliseconds;
@property(nonatomic, readonly) double lastSubstepMilliseconds;
@property(nonatomic, readonly) double lastReadbackMilliseconds;
@property(nonatomic, readonly) NSUInteger substepCount;
@property(nonatomic, readonly) NSUInteger stateSizedAllocationCount;

@end

@interface WSBoundarySideConfiguration : NSObject

@property(nonatomic, readonly) WSBoundaryType type;
@property(nonatomic, readonly) double meanSurfaceElevation;
@property(nonatomic, readonly) double amplitude;
@property(nonatomic, readonly) double periodSeconds;
@property(nonatomic, readonly) double phaseRadians;
@property(nonatomic, readonly) double rampSeconds;

- (instancetype)initWithType:(WSBoundaryType)type
         meanSurfaceElevation:(double)meanSurfaceElevation
                    amplitude:(double)amplitude
                periodSeconds:(double)periodSeconds
                 phaseRadians:(double)phaseRadians
                  rampSeconds:(double)rampSeconds NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface WSBoundaryConfiguration : NSObject

@property(nonatomic, readonly) WSBoundarySideConfiguration *left;
@property(nonatomic, readonly) WSBoundarySideConfiguration *right;
@property(nonatomic, readonly) WSBoundarySideConfiguration *bottom;
@property(nonatomic, readonly) WSBoundarySideConfiguration *top;

- (instancetype)initWithLeft:(WSBoundarySideConfiguration *)left
                        right:(WSBoundarySideConfiguration *)right
                       bottom:(WSBoundarySideConfiguration *)bottom
                          top:(WSBoundarySideConfiguration *)top NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

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
@property(nonatomic, readonly) NSArray<NSNumber *> *instantaneousBoundaryOutflowRate;
@property(nonatomic, readonly) NSArray<NSNumber *> *cumulativeBoundaryOutwardVolume;
@property(nonatomic, readonly) double netBoundaryOutflowRate;
@property(nonatomic, readonly) double accountedExpectedVolume;
@property(nonatomic, readonly) double accountingError;
@property(nonatomic, readonly, getter=isFinite) BOOL finite;
@property(nonatomic, readonly) WSEngineStepStatus status;

@end

@interface WSAcceleratedFieldBuffers : NSObject

@property(nonatomic, readonly) id<MTLDevice> device;
@property(nonatomic, readonly) id<MTLBuffer> bedElevation;
@property(nonatomic, readonly) id<MTLBuffer> waterDepth;
@property(nonatomic, readonly) NSUInteger width;
@property(nonatomic, readonly) NSUInteger height;
@property(nonatomic, readonly) uint64_t generation;

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
@property(nonatomic, readonly) WSBackendStatus *backendStatus;
@property(nonatomic, readonly, nullable) WSAcceleratedFieldBuffers *acceleratedFieldBuffers;

@end

@interface WSWaterEngineBridge : NSObject {
@private
    void *_implementation;
}

@property(nonatomic, getter=isRunning) BOOL running;
@property(nonatomic, readonly) WSRequestedSimulationBackend requestedBackend;
@property(nonatomic, readonly) WSResolvedSimulationBackend resolvedBackend;
@property(nonatomic, readonly) WSBackendStatus *backendStatus;
@property(nonatomic, readonly, nullable) WSAcceleratedFieldBuffers *acceleratedFieldBuffers;

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
- (BOOL)loadWidth:(NSUInteger)width
            height:(NSUInteger)height
       domainWidth:(double)domainWidth
      domainHeight:(double)domainHeight
      bedElevation:(NSData *)bedElevation
         waterDepth:(NSData *)waterDepth
         minimumBed:(double)minimumBed
     maximumSurface:(double)maximumSurface
         boundaries:(WSBoundaryConfiguration *)boundaries
    NS_SWIFT_NAME(load(width:height:domainWidth:domainHeight:bedElevation:waterDepth:minimumBed:maximumSurface:boundaries:));
- (void)reset;
- (WSEngineStepStatus)advance:(double)frameDeltaTime;
- (WSEngineStepStatus)stepOnce:(double)timeStep;
- (WSEngineSnapshot *)snapshot;
- (BOOL)setRequestedBackend:(WSRequestedSimulationBackend)backend;
- (WSBoundaryConfiguration *)boundaryConfiguration;
- (BOOL)setBoundaryConfiguration:(WSBoundaryConfiguration *)configuration;

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

// Deterministic failure injection is exposed for non-interactive backend recovery tests.
- (void)setBackendFailureInjection:(WSBackendFailureInjection)failure;

@end

NS_ASSUME_NONNULL_END
