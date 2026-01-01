
// ----
struct IAVertex
{
    float3 position : POSITION;
    float2 uv : TEXCOORD0;
};

struct PSVertex
{
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
}

float4x4 Transform;
Texture2D<float4> Texture;
SamplerState TrilinearSampler;
uniform uint SampleIdx;
uniform float SamplesCount;


// ---- Random (implementation from "Hash Functions for GPU Rendering")
uint3 pcg3d(uint3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v = v ^ (v >> 16u);
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    return v;
}

float3 getUniformRandom(float3 elem)
{
    uint3 v = asuint(elem);
    uint3 random = pcg3d(v);
    random &= 0x007FFFFFU; // Extract mantisa part.
    random |= 0x3F800000U; // Set exponent to 127, this will result in float [1;2).
    return asfloat(random) - 1.0f;
}


// ---- FIS
float4 sampleStochasticTrilinear<let useMips : bool>(Texture2D<float4> tex, float2 uv, float3 random)
{
    uint width = 0;
    uint height = 0;
    uint mipCount = 0;
    tex.GetDimensions(0, width, height, mipCount);

    // Calculate mipmap level
#define MANUAL_MIP_LEVEL_CALCULATIONS
#ifdef MANUAL_MIP_LEVEL_CALCULATIONS
    float2 uvdx = ddx(uv) * float2(width, height);
    float2 uvdy = ddy(uv) * float2(width, height);
    float maxPd = max(dot(uvdx, uvdx), dot(uvdy, uvdy));
    float mipLevel = max(log2(maxPd) * 0.5f, 0); // #NOTE: same as max(log2(sqrt(maxPd)), 0).
#else
    float mipLevel = Texture.CalculateLevelOfDetail(TrilinearSampler, uv);
#endif

// #define IMPROVED_TRILINEAR
#ifdef IMPROVED_TRILINEAR
    // Continuous radius change which gives continuous results but differs from HW filter.
    float sampleRadius = pow(2, max(mipLevel, 0));
#else
    // Trilinear filter similar to how HW handles it.
    // In some cases there's visible change in mipmaps both for HW and FIS approaches.

    // Randomly pick mip level based on the mip level's fraction part.
    uint sampleMipLevel = (uint)mipLevel;
    if (random.z < frac(mipLevel))
        ++sampleMipLevel;
    sampleMipLevel = min(mipCount - 1, sampleMipLevel);
    float sampleRadius = 1;

    // When useMip is set to false, we sample only first mip level with increased radius size to get the correct behavior of mip maps.
    // Otherwise, stochastically sample one of the mip layer, randomly chosen, using stochastic bilinear filter.
    if (!useMips)
    {
        sampleRadius = pow(2, max(sampleMipLevel, 0));
        sampleMipLevel = 0;
    }
    else
    {
        // Override width and height with the target mip value.
        tex.GetDimensions(sampleMipLevel, width, height, mipCount);
    }
#endif

    float2 sampleOffset = (float2(random.x, random.y) - 0.5) * sampleRadius;
    float2 textureCoords = uv * float2(width, height);
    textureCoords += sampleOffset;

    // Hardcoded clamp_to_edge
    textureCoords = clamp(textureCoords, 0, uint2(width, height) - 1);

    return Texture.Load(int3((int2)textureCoords, sampleMipLevel));
}


[shader("vertex")]
PSVertex vsMain(IAVertex vertex)
{
    PSVertex result = (PSVertex)0;

    result.position = mul(Transform, float4(vertex.position, 1));
    result.uv = vertex.uv;

    return result;
}


[shader("fragment")]
float4 psMain(PSVertex vertex) : SV_Target
{
    float2 pixelPos = vertex.position.xy;
    float2 quadUV = vertex.uv;
#if HW_FILTER
    float3 color = Texture.Sample(TrilinearSampler, quadUV).rgb;
#else
    float3 random = getUniformRandom(float3(pixelPos, SampleIdx));
    #if USE_MIP
        float3 color = sampleStochasticTrilinear<true>(Texture, quadUV, random).rgb / SamplesCount;
    #else
        float3 color = sampleStochasticTrilinear<false>(Texture, quadUV, random).rgb / SamplesCount;
    #endif
#endif

    return float4(color, 1);
}
