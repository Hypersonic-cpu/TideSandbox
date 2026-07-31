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
