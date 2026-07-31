#include <metal_stdlib>

using namespace metal;

struct DiagnosticVertexOutput {
    float4 position [[position]];
    half3 color;
};

vertex DiagnosticVertexOutput diagnosticVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-0.62, -0.55),
        float2( 0.62, -0.55),
        float2( 0.00,  0.62),
    };
    constexpr half3 colors[] = {
        half3(0.15h, 0.55h, 0.95h),
        half3(0.10h, 0.85h, 0.70h),
        half3(0.95h, 0.78h, 0.25h),
    };
    return {float4(positions[vertexID], 0.0, 1.0), colors[vertexID]};
}

fragment half4 diagnosticFragment(DiagnosticVertexOutput input [[stage_in]]) {
    return half4(input.color, 1.0h);
}

struct FrameUniforms {
    float4x4 viewProjection;
    float4 cameraPosition;
    float4 domainAndCellSize;
    uint4 gridSize;
    float4 elevationRange;
    float4 lightDirection;
    float4 waterParameters;
};

struct HeightFieldVertexOutput {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
    float normalizedElevation;
};

vertex HeightFieldVertexOutput terrainVertex(
    uint vertexID [[vertex_id]],
    constant float *bedElevation [[buffer(0)]],
    constant FrameUniforms& uniforms [[buffer(1)]]) {
    const uint width = uniforms.gridSize.x;
    const uint height = uniforms.gridSize.y;
    const uint column = vertexID % width;
    const uint row = vertexID / width;
    const float verticalScale = uniforms.elevationRange.x;
    const float domainWidth = uniforms.domainAndCellSize.x;
    const float domainHeight = uniforms.domainAndCellSize.y;
    const float cellWidth = uniforms.domainAndCellSize.z;
    const float cellHeight = uniforms.domainAndCellSize.w;

    const float3 worldPosition = float3(
        (float(column) + 0.5) * cellWidth - domainWidth * 0.5,
        bedElevation[vertexID] * verticalScale,
        (float(row) + 0.5) * cellHeight - domainHeight * 0.5
    );

    const uint leftColumn = column > 0 ? column - 1 : column;
    const uint rightColumn = min(column + 1, width - 1);
    const uint lowerRow = row > 0 ? row - 1 : row;
    const uint upperRow = min(row + 1, height - 1);
    const float spanX = float(max(rightColumn - leftColumn, 1u)) * cellWidth;
    const float spanZ = float(max(upperRow - lowerRow, 1u)) * cellHeight;
    const float slopeX = verticalScale *
        (bedElevation[row * width + rightColumn] -
         bedElevation[row * width + leftColumn]) / spanX;
    const float slopeZ = verticalScale *
        (bedElevation[upperRow * width + column] -
         bedElevation[lowerRow * width + column]) / spanZ;
    const float3 normal = normalize(float3(-slopeX, 1.0, -slopeZ));

    const float range = max(
        uniforms.elevationRange.z - uniforms.elevationRange.y,
        1.0e-7
    );
    HeightFieldVertexOutput output;
    output.position = uniforms.viewProjection * float4(worldPosition, 1.0);
    output.worldPosition = worldPosition;
    output.normal = normal;
    output.normalizedElevation = saturate(
        (bedElevation[vertexID] - uniforms.elevationRange.y) / range
    );
    return output;
}

fragment half4 terrainFragment(
    HeightFieldVertexOutput input [[stage_in]],
    constant FrameUniforms& uniforms [[buffer(1)]]) {
    const float3 sand = float3(0.82, 0.72, 0.48);
    const float3 highTerrain = float3(0.43, 0.66, 0.36);
    const float3 baseColor = mix(sand, highTerrain, input.normalizedElevation);
    const float3 lightDirection = normalize(uniforms.lightDirection.xyz);
    const float diffuse = max(dot(normalize(input.normal), lightDirection), 0.0);
    const float lighting = 0.30 + 0.70 * diffuse;
    return half4(half3(baseColor * lighting), 1.0h);
}

struct WaterVertexOutput {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
    float waterDepth;
};

static inline float surfaceElevation(
    constant float *bedElevation,
    constant float *waterDepth,
    uint index) {
    return bedElevation[index] + max(waterDepth[index], 0.0);
}

vertex WaterVertexOutput waterVertex(
    uint vertexID [[vertex_id]],
    constant float *bedElevation [[buffer(0)]],
    constant FrameUniforms& uniforms [[buffer(1)]],
    constant float *waterDepth [[buffer(2)]]) {
    const uint width = uniforms.gridSize.x;
    const uint height = uniforms.gridSize.y;
    const uint column = vertexID % width;
    const uint row = vertexID / width;
    const float verticalScale = uniforms.elevationRange.x;
    const float domainWidth = uniforms.domainAndCellSize.x;
    const float domainHeight = uniforms.domainAndCellSize.y;
    const float cellWidth = uniforms.domainAndCellSize.z;
    const float cellHeight = uniforms.domainAndCellSize.w;
    const float depth = max(waterDepth[vertexID], 0.0);
    const float3 worldPosition = float3(
        (float(column) + 0.5) * cellWidth - domainWidth * 0.5,
        (bedElevation[vertexID] + depth) * verticalScale + uniforms.waterParameters.w,
        (float(row) + 0.5) * cellHeight - domainHeight * 0.5
    );

    const uint leftColumn = column > 0 ? column - 1 : column;
    const uint rightColumn = min(column + 1, width - 1);
    const uint lowerRow = row > 0 ? row - 1 : row;
    const uint upperRow = min(row + 1, height - 1);
    const uint leftIndex = row * width + leftColumn;
    const uint rightIndex = row * width + rightColumn;
    const uint lowerIndex = lowerRow * width + column;
    const uint upperIndex = upperRow * width + column;
    const float spanX = float(max(rightColumn - leftColumn, 1u)) * cellWidth;
    const float spanZ = float(max(upperRow - lowerRow, 1u)) * cellHeight;
    const float slopeX = verticalScale *
        (surfaceElevation(bedElevation, waterDepth, rightIndex) -
         surfaceElevation(bedElevation, waterDepth, leftIndex)) / spanX;
    const float slopeZ = verticalScale *
        (surfaceElevation(bedElevation, waterDepth, upperIndex) -
         surfaceElevation(bedElevation, waterDepth, lowerIndex)) / spanZ;

    WaterVertexOutput output;
    output.position = uniforms.viewProjection * float4(worldPosition, 1.0);
    output.worldPosition = worldPosition;
    output.normal = normalize(float3(-slopeX, 1.0, -slopeZ));
    output.waterDepth = depth;
    return output;
}

fragment half4 waterFragment(
    WaterVertexOutput input [[stage_in]],
    constant FrameUniforms& uniforms [[buffer(1)]]) {
    const float minimumWetDepth = uniforms.waterParameters.x;
    const float depth = max(input.waterDepth, 0.0);
    if (!(depth > minimumWetDepth)) {
        discard_fragment();
    }

    const float shorelineWidth = max(
        minimumWetDepth * max(uniforms.waterParameters.y, 1.0),
        1.0e-5
    );
    const float shorelineAlpha = smoothstep(
        minimumWetDepth,
        minimumWetDepth + shorelineWidth,
        depth
    );
    const float normalizedDepth = saturate(
        depth / max(uniforms.elevationRange.w, 1.0e-6)
    );
    const float3 shallowWater = float3(0.18, 0.66, 0.88);
    const float3 deepWater = float3(0.025, 0.16, 0.42);
    const float3 baseColor = mix(shallowWater, deepWater, sqrt(normalizedDepth));
    const float3 normal = normalize(input.normal);
    const float3 lightDirection = normalize(uniforms.lightDirection.xyz);
    const float3 viewDirection = normalize(
        uniforms.cameraPosition.xyz - input.worldPosition
    );
    const float3 halfDirection = normalize(lightDirection + viewDirection);
    const float diffuse = max(dot(normal, lightDirection), 0.0);
    const float specular = pow(max(dot(normal, halfDirection), 0.0), 48.0) * 0.30;
    const float fresnel = pow(1.0 - max(dot(normal, viewDirection), 0.0), 3.0);
    const float3 litColor = saturate(
        baseColor * (0.38 + 0.62 * diffuse) + specular + fresnel * 0.18
    );
    const float opacity = saturate(
        uniforms.waterParameters.z * (0.78 + fresnel * 0.22) * shorelineAlpha
    );
    return half4(half3(litColor * opacity), half(opacity));
}
