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
    float4 cameraTarget;
    uint4 debugFlags;
};

struct HeightFieldVertexOutput {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
    float normalizedElevation;
    float waterDepth;
};

vertex HeightFieldVertexOutput terrainVertex(
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
    output.waterDepth = max(waterDepth[vertexID], 0.0);
    return output;
}

fragment half4 terrainFragment(
    HeightFieldVertexOutput input [[stage_in]],
    constant FrameUniforms& uniforms [[buffer(1)]]) {
    if (uniforms.debugFlags.x != 0u) {
        const bool wet = input.waterDepth > uniforms.waterParameters.x;
        const half3 maskColor = wet
            ? half3(0.05h, 0.72h, 0.92h)
            : half3(0.92h, 0.42h, 0.16h);
        return half4(maskColor, 1.0h);
    }
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
    if (uniforms.debugFlags.x != 0u) {
        discard_fragment();
    }
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

struct DebugLineVertexOutput {
    float4 position [[position]];
    half3 color;
};

vertex DebugLineVertexOutput debugLineVertex(
    uint vertexID [[vertex_id]],
    constant float *bedElevation [[buffer(0)]],
    constant FrameUniforms& uniforms [[buffer(1)]],
    constant float *waterDepth [[buffer(2)]],
    constant uint& mode [[buffer(3)]]) {
    const uint width = uniforms.gridSize.x;
    const uint height = uniforms.gridSize.y;
    const float domainWidth = uniforms.domainAndCellSize.x;
    const float domainHeight = uniforms.domainAndCellSize.y;
    const float cellWidth = uniforms.domainAndCellSize.z;
    const float cellHeight = uniforms.domainAndCellSize.w;
    const float verticalScale = uniforms.elevationRange.x;
    float3 worldPosition = float3(0.0);
    half3 color = half3(1.0h);

    if (mode == 0u) {
        constexpr uint2 edges[] = {
            uint2(0, 1), uint2(1, 3), uint2(3, 2), uint2(2, 0),
            uint2(4, 5), uint2(5, 7), uint2(7, 6), uint2(6, 4),
            uint2(0, 4), uint2(1, 5), uint2(2, 6), uint2(3, 7),
        };
        const uint edge = vertexID / 2u;
        const uint corner = vertexID % 2u == 0u ? edges[edge].x : edges[edge].y;
        const float x = (corner & 1u) == 0u ? -domainWidth * 0.5 : domainWidth * 0.5;
        const float z = (corner & 2u) == 0u ? -domainHeight * 0.5 : domainHeight * 0.5;
        const float minimumY = uniforms.elevationRange.y * verticalScale;
        const float maximumY = (uniforms.elevationRange.z +
            uniforms.elevationRange.w) * verticalScale + uniforms.waterParameters.w;
        const float y = (corner & 4u) == 0u ? minimumY : maximumY;
        worldPosition = float3(x, y, z);
        color = half3(1.0h, 0.78h, 0.12h);
    } else if (mode == 1u) {
        const uint sampleColumns = min(width, 16u);
        const uint sampleRows = min(height, 16u);
        const uint sample = vertexID / 2u;
        const uint sampleColumn = sample % sampleColumns;
        const uint sampleRow = min(sample / sampleColumns, sampleRows - 1u);
        const uint column = uint(round(
            float(sampleColumn) * float(width - 1u) / float(max(sampleColumns - 1u, 1u))
        ));
        const uint row = uint(round(
            float(sampleRow) * float(height - 1u) / float(max(sampleRows - 1u, 1u))
        ));
        const uint index = row * width + column;
        const uint leftColumn = column > 0u ? column - 1u : column;
        const uint rightColumn = min(column + 1u, width - 1u);
        const uint lowerRow = row > 0u ? row - 1u : row;
        const uint upperRow = min(row + 1u, height - 1u);
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
        const float3 normal = normalize(float3(-slopeX, 1.0, -slopeZ));
        const float elevation = surfaceElevation(bedElevation, waterDepth, index);
        const float3 origin = float3(
            (float(column) + 0.5) * cellWidth - domainWidth * 0.5,
            elevation * verticalScale + uniforms.waterParameters.w,
            (float(row) + 0.5) * cellHeight - domainHeight * 0.5
        );
        const float normalLength = max(
            min(domainWidth, domainHeight) * 0.025,
            max(cellWidth, cellHeight) * 1.5
        );
        worldPosition = vertexID % 2u == 0u
            ? origin
            : origin + normal * normalLength;
        color = half3(0.95h, 0.18h, 0.92h);
    } else {
        const uint axis = min(vertexID / 2u, 2u);
        float3 direction = float3(0.0);
        direction[axis] = 1.0;
        const float markerRadius = max(min(domainWidth, domainHeight) * 0.035, 0.05);
        const float sign = vertexID % 2u == 0u ? -1.0 : 1.0;
        worldPosition = uniforms.cameraTarget.xyz + direction * markerRadius * sign;
        constexpr half3 axisColors[] = {
            half3(1.0h, 0.2h, 0.2h),
            half3(0.2h, 1.0h, 0.3h),
            half3(0.2h, 0.5h, 1.0h),
        };
        color = axisColors[axis];
    }

    return {
        uniforms.viewProjection * float4(worldPosition, 1.0),
        color,
    };
}

fragment half4 debugLineFragment(DebugLineVertexOutput input [[stage_in]]) {
    return half4(input.color, 1.0h);
}
