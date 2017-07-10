/**
 * Copyright (c) 2017-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#include "cuda_decl.h"
#include "gbuffer.h"
#include "gpu_camera.h"
#include "gpu_context.h"
#include "kernel_constants.h"
#include "prim_tests.h"
#include "resolve.h"
#include "shading.h"
#include "tile_data.h"
#include "warp_ops.h"

#define PROFILE_RESOLVE 0
#define ENABLE_RESOLVE_STATS 0

namespace hvvr {

extern cudaTextureObject_t* gDeviceTextureArray;

struct ResolveStats {
    uint32_t invocations;  // number of pixels shaded, including helpers
    uint32_t shadeSamples; // number samples shaded (invocations * shade count per pixel)
};

struct ResolveSMem {
    ResolveSMem() {}

    union {
        TileData tile;
        TileDataDoF tileDoF;
    };
};

template <uint32_t MSAARate, uint32_t BlockSize, bool EnableDoF>
CUDA_DEVICE vector4 BruteForceShade(ResolveSMem& sMem,
                                    const RaycasterGBufferSubsample* CUDA_RESTRICT gBufferWarp,
                                    int laneIndex,
                                    UnpackedDirectionalSample sample3D,
                                    vector3 lensCenterToFocalCenter,
                                    vector2 frameJitter,
                                    const vector2* CUDA_RESTRICT tileSubsampleLensPos,
                                    vector3 cameraPos,
                                    vector3 cameraLookVector,
                                    const PrecomputedTriangleIntersect* CUDA_RESTRICT trianglesIntersect,
                                    const PrecomputedTriangleShade* CUDA_RESTRICT trianglesShade,
                                    const ShadingVertex* CUDA_RESTRICT verts,
                                    const SimpleMaterial* CUDA_RESTRICT materials,
                                    cudaTextureObject_t* textures,
                                    const LightingEnvironment& env,
                                    uint32_t sampleOffset,
                                    const SampleInfo& sampleInfo,
                                    ResolveStats* resolveStats) {
    enum : uint32_t { badTriIndex = ~uint32_t(0) };
    float derivativeMultiplier = rsqrtf(float(MSAARate));

    vector4 result = vector4(0.0f, 0.0f, 0.0f, 0.0f);
    uint32_t combinedSampleMask = 0;
    for (int compGbufferSlot = 0; compGbufferSlot < MSAARate; compGbufferSlot++) {
        if (combinedSampleMask == (1 << MSAARate) - 1) {
            // all samples accounted for, nothing left to shade
            break;
        }

        // GBuffer texels are organized so that each subsample is a warp stride away from
        // the previous subsample for a single sample, so that warps can coalesce memory reads
        uint32_t triIndex = gBufferWarp[compGbufferSlot * WARP_SIZE + laneIndex].triIndex;
        if (triIndex == badTriIndex)
            break; // if we have samples which don't hit a triangle, they will be grouped together as the last entry

        uint32_t sampleMask = gBufferWarp[compGbufferSlot * WARP_SIZE + laneIndex].sampleMask;
        combinedSampleMask |= sampleMask;

        const PrecomputedTriangleIntersect& triIntersect = trianglesIntersect[triIndex];
        const PrecomputedTriangleShade& triShade = trianglesShade[triIndex];

        IntersectTriangleTileDoF triTileDoF;
        triTileDoF.setup(triIntersect, sMem.tileDoF.lensCenter, sMem.tileDoF.lensU, sMem.tileDoF.lensV);
        IntersectTriangleThreadDoF triThreadDoF(triTileDoF, lensCenterToFocalCenter);

        IntersectTriangleTile triTile;
        triTile.setup(triIntersect, sMem.tile.rayOrigin, sMem.tile.majorDirDiff, sMem.tile.minorDirDiff);
        IntersectTriangleThread triThread(triTile, sample3D.centerDir);

        while (sampleMask) {
            int subsampleIndex = __ffs(sampleMask) - 1;
            sampleMask &= ~(1 << subsampleIndex);

#if ENABLE_RESOLVE_STATS
            atomicAdd(&resolveStats->shadeSamples, 1);
#endif

            float b[3];
            float bOffX[3];
            float bOffY[3];
            if (EnableDoF) {
                vector2 lensUV;
                vector2 dirUV;
                GetSampleUVsDoF<MSAARate, BlockSize>(tileSubsampleLensPos, frameJitter, sMem.tileDoF.focalToLensScale,
                                                     subsampleIndex, lensUV, dirUV);

                vector3 uvw;
                triThreadDoF.calcUVW(triTileDoF, lensCenterToFocalCenter, sMem.tileDoF.lensU, sMem.tileDoF.lensV,
                                     lensUV, dirUV, uvw);
                b[0] = uvw.x;
                b[1] = uvw.y;
                b[2] = uvw.z;

                // we don't have proper derivatives for the DoF path, yet
                vector2 dirUV_dX = dirUV + vector2(sMem.tileDoF.focalToLensScale.x, 0.0f) * derivativeMultiplier;
                triThreadDoF.calcUVW(triTileDoF, lensCenterToFocalCenter, sMem.tileDoF.lensU, sMem.tileDoF.lensV,
                                     lensUV, dirUV_dX, uvw);
                bOffX[0] = uvw.x;
                bOffX[1] = uvw.y;
                bOffX[2] = uvw.z;

                vector2 dirUV_dY = dirUV + vector2(0.0f, sMem.tileDoF.focalToLensScale.y) * derivativeMultiplier;
                triThreadDoF.calcUVW(triTileDoF, lensCenterToFocalCenter, sMem.tileDoF.lensU, sMem.tileDoF.lensV,
                                     lensUV, dirUV_dY, uvw);
                bOffY[0] = uvw.x;
                bOffY[1] = uvw.y;
                bOffY[2] = uvw.z;
            } else {
                vector2 alpha = getSubsampleUnitOffset<MSAARate>(frameJitter, subsampleIndex);

                vector3 uvw;
                triThread.calcUVW(triTile, alpha, uvw);
                b[0] = uvw.x;
                b[1] = uvw.y;
                b[2] = uvw.z;

                vector2 alpha_dX = alpha + vector2(1.0f, 0.0f) * derivativeMultiplier;
                triThread.calcUVW(triTile, alpha_dX, uvw);
                bOffX[0] = uvw.x;
                bOffX[1] = uvw.y;
                bOffX[2] = uvw.z;

                vector2 alpha_dY = alpha + vector2(0.0f, 1.0f) * derivativeMultiplier;
                triThread.calcUVW(triTile, alpha_dY, uvw);
                bOffY[0] = uvw.x;
                bOffY[1] = uvw.y;
                bOffY[2] = uvw.z;
            }

#if COLOR_SHADING_MODE == SM_BARYCENTRIC
            result += BarycentricShade(b, triIndex, triShade, cameraPos, cameraLookVector, verts, materials, textures);
#elif COLOR_SHADING_MODE == SM_TRI_ID
            result += hashedColor(triIndex);
#elif COLOR_SHADING_MODE == SM_UV
            result += UVShade(b, triIndex, triShade, cameraPos, cameraLookVector, verts, materials, textures);
#elif COLOR_SHADING_MODE == SM_WS_NORMAL
            result += WSNormalShade(b, triIndex, triShade, cameraPos, cameraLookVector, verts, materials, textures);
#elif COLOR_SHADING_MODE == SM_NO_MATERIAL_BRDF
            result +=
                NoMaterialBRDFShade(b, triIndex, triShade, cameraPos, cameraLookVector, verts, materials, textures);
#elif COLOR_SHADING_MODE == SM_LAMBERTIAN_TEXTURE
            result +=
                LambertianTextureShade(b, triIndex, triShade, cameraPos, cameraLookVector, verts, materials, textures);
#elif COLOR_SHADING_MODE == SM_FULL_BRDF
            result += FullGGXShade(b, bOffX, bOffY, triIndex, triShade, cameraPos, cameraLookVector, verts, materials,
                                   textures, env);
#elif COLOR_SHADING_MODE == SM_MATERIAL_ID
            result += hashedColor(triShade.material);
#else
#error "NYI"
#endif
        }
    }

    result *= (1.0f / MSAARate);
    result.w = 1.0f;
    return result;
}

template <uint32_t MSAARate, uint32_t BlockSize, bool EnableDoF>
CUDA_DEVICE vector4 TrueMSAAShade(ResolveSMem& sMem,
                                  const RaycasterGBufferSubsample* CUDA_RESTRICT gBufferWarp,
                                  int laneIndex,
                                  UnpackedDirectionalSample sample3D,
                                  vector3 lensCenterToFocalCenter,
                                  vector2 frameJitter,
                                  const vector2* CUDA_RESTRICT tileSubsampleLensPos,
                                  vector3 cameraPos,
                                  vector3 cameraLookVector,
                                  const PrecomputedTriangleIntersect* CUDA_RESTRICT trianglesIntersect,
                                  const PrecomputedTriangleShade* CUDA_RESTRICT trianglesShade,
                                  const ShadingVertex* CUDA_RESTRICT verts,
                                  const SimpleMaterial* CUDA_RESTRICT materials,
                                  cudaTextureObject_t* textures,
                                  const LightingEnvironment& env,
                                  uint32_t sampleOffset,
                                  const SampleInfo& sampleInfo,
                                  ResolveStats* resolveStats) {
    enum : uint32_t { badTriIndex = ~uint32_t(0) };

    vector4 result = vector4(0.0f, 0.0f, 0.0f, 0.0f);
    uint32_t combinedSampleMask = 0;
    for (int compGbufferSlot = 0; compGbufferSlot < MSAARate; compGbufferSlot++) {
        if (combinedSampleMask == (1 << MSAARate) - 1) {
            // all samples accounted for, nothing left to shade
            break;
        }

        // GBuffer texels are organized so that each subsample is a warp stride away from
        // the previous subsample for a single sample, so that warps can coalesce memory reads
        uint32_t triIndex = gBufferWarp[compGbufferSlot * WARP_SIZE + laneIndex].triIndex;
        if (triIndex == badTriIndex)
            break; // if we have samples which don't hit a triangle, they will be grouped together as the last entry

        uint32_t sampleMask = gBufferWarp[compGbufferSlot * WARP_SIZE + laneIndex].sampleMask;
        combinedSampleMask |= sampleMask;

#if ENABLE_RESOLVE_STATS
        atomicAdd(&resolveStats->shadeSamples, 1);
#endif

        float sampleCountInv = 1.0f / __popc(sampleMask);
        // TODO(anankervis): should we always shade from the lens center and center dir (UVs = 0)?
        vector2 centroidLensUV = vector2(0.0f, 0.0f);
        vector2 centroidDirUV = vector2(0.0f, 0.0f);
        // Is it correct that we're generating the centroid by averaging all sample positions?
        // Typically, you'd want the centroid to be the sample (not subsample) center, and only fall back to
        // something else (clamp to tri edge?) if the sample center falls outside the triangle.
        // Now that we've got DoF samples which vary their distribution from pixel to pixel, it's even
        // more important that we pick a consistent sampling location, to avoid wavy artifacts.
        vector2 centroidAlpha = vector2(0.0f, 0.0f);
        for (uint32_t centroidMask = sampleMask; centroidMask != 0;) {
            int subsampleIndex = __ffs(centroidMask) - 1;
            centroidMask &= ~(1 << subsampleIndex);
            centroidAlpha += getSubsampleUnitOffset<MSAARate>(frameJitter, subsampleIndex) * sampleCountInv;

            vector2 lensUV;
            vector2 dirUV;
            GetSampleUVsDoF<MSAARate, BlockSize>(tileSubsampleLensPos, frameJitter, sMem.tileDoF.focalToLensScale,
                                                 subsampleIndex, lensUV, dirUV);
            centroidLensUV += lensUV * sampleCountInv;
            centroidDirUV += dirUV * sampleCountInv;
        }

        const PrecomputedTriangleIntersect& triIntersect = trianglesIntersect[triIndex];
        const PrecomputedTriangleShade& triShade = trianglesShade[triIndex];

        IntersectTriangleTileDoF triTileDoF;
        triTileDoF.setup(triIntersect, sMem.tileDoF.lensCenter, sMem.tileDoF.lensU, sMem.tileDoF.lensV);
        IntersectTriangleThreadDoF triThreadDoF(triTileDoF, lensCenterToFocalCenter);

        IntersectTriangleTile triTile;
        triTile.setup(triIntersect, sMem.tile.rayOrigin, sMem.tile.majorDirDiff, sMem.tile.minorDirDiff);
        IntersectTriangleThread triThread(triTile, sample3D.centerDir);

        float b[3];
        float bOffX[3];
        float bOffY[3];
        if (EnableDoF) {
            vector3 uvw;
            triThreadDoF.calcUVW(triTileDoF, lensCenterToFocalCenter, sMem.tileDoF.lensU, sMem.tileDoF.lensV,
                                 centroidLensUV, centroidDirUV, uvw);
            b[0] = uvw.x;
            b[1] = uvw.y;
            b[2] = uvw.z;

            // TODO(anankervis): we don't have proper derivatives for the DoF path, yet
            // but this seems to work well when the lens radius is relatively small and the focal plane is close
            // if the focal plane is too far, the derivatives become too small and you get aliasing
            // if the lens is too big, the derivatives are too large and things are always blurry
            // There's implicit scaling due to lensCenterToFocalCenter (focalDist) and lensU/lensV (lensRadius) -
            // see calcUVW and TileDataDoF::load.
            // Biasing mipmap selection will never be as good of quality as SSAA (due to bilinear square-shaped filter),
            // but it just needs to be reasonably close because we're not trying to simulate very wide filters
            // in the general case. It only needs to be convincing for relatively small filters.
            vector2 derivScale = vector2(1.0f, 1.0f);

            vector2 dirUV_dX = centroidDirUV + vector2(derivScale.x, 0.0f);
            triThreadDoF.calcUVW(triTileDoF, lensCenterToFocalCenter, sMem.tileDoF.lensU, sMem.tileDoF.lensV,
                                 centroidLensUV, dirUV_dX, uvw);
            bOffX[0] = uvw.x;
            bOffX[1] = uvw.y;
            bOffX[2] = uvw.z;

            vector2 dirUV_dY = centroidDirUV + vector2(0.0f, derivScale.y);
            triThreadDoF.calcUVW(triTileDoF, lensCenterToFocalCenter, sMem.tileDoF.lensU, sMem.tileDoF.lensV,
                                 centroidLensUV, dirUV_dY, uvw);
            bOffY[0] = uvw.x;
            bOffY[1] = uvw.y;
            bOffY[2] = uvw.z;
        } else {
            vector3 uvw;
            triThread.calcUVW(triTile, centroidAlpha, uvw);
            b[0] = uvw.x;
            b[1] = uvw.y;
            b[2] = uvw.z;

            vector2 alpha_dX = centroidAlpha + vector2(1.0f, 0.0f);
            triThread.calcUVW(triTile, alpha_dX, uvw);
            bOffX[0] = uvw.x;
            bOffX[1] = uvw.y;
            bOffX[2] = uvw.z;

            vector2 alpha_dY = centroidAlpha + vector2(0.0f, 1.0f);
            triThread.calcUVW(triTile, alpha_dY, uvw);
            bOffY[0] = uvw.x;
            bOffY[1] = uvw.y;
            bOffY[2] = uvw.z;
        }

        vector2 uv(0.0f);
        vector3 position(0.0f);
        vector3 normal(0.0f);
        vector2 ddx(0.0f);
        vector2 ddy(0.0f);
        for (int j = 0; j < 3; ++j) {
            ShadingVertex vert = verts[triShade.indices[j]];
            position += vert.pos * b[j];
            normal += vector3(vert.normal) * b[j];
            uv += vert.uv * b[j];
            ddx += vert.uv * bOffX[j];
            ddy += vert.uv * bOffY[j];
        }
        ddx -= uv;
        ddy -= uv;

        vector4 shadedColor =
            FullGGXShadeAfterInterpolation(triShade.material, uv, ddx, ddy, position, normalize(normal), cameraPos,
                                           cameraLookVector, verts, materials, textures, env);
        result += shadedColor * __popc(sampleMask);
    }
    result *= 1.0f / MSAARate;
    result.w = 1.0f;
    return result;
}

template <uint32_t MSAARate, uint32_t BlockSize, bool EnableDoF>
CUDA_DEVICE vector4 Resolve(ResolveSMem& sMem,
                            const RaycasterGBufferSubsample* CUDA_RESTRICT gBufferBlock,
                            int laneIndex,
                            uint32_t sampleOffset,
                            SampleInfo sampleInfo,
                            UnpackedDirectionalSample sample3D,
                            vector3 lensCenterToFocalCenter,
                            const vector2* CUDA_RESTRICT tileSubsampleLensPos,
                            vector3 cameraPos,
                            vector3 cameraLookVector,
                            const PrecomputedTriangleIntersect* CUDA_RESTRICT trianglesIntersect,
                            const PrecomputedTriangleShade* CUDA_RESTRICT trianglesShade,
                            const ShadingVertex* CUDA_RESTRICT verts,
                            const SimpleMaterial* CUDA_RESTRICT materials,
                            cudaTextureObject_t* textures,
                            LightingEnvironment env,
                            ResolveStats* resolveStats) {
#if ENABLE_RESOLVE_STATS
    atomicAdd(&resolveStats->invocations, 1);
#endif

    vector4 result =
#if SUPERSHADING_MODE == SSAA_SHADE
        BruteForceShade<MSAARate, BlockSize, EnableDoF>(
            sMem, gBufferBlock, laneIndex, sample3D, lensCenterToFocalCenter, sampleInfo.frameJitter,
            tileSubsampleLensPos, cameraPos, cameraLookVector, trianglesIntersect, trianglesShade, verts, materials,
            textures, env, sampleOffset, sampleInfo, resolveStats);
#else
        TrueMSAAShade<MSAARate, BlockSize, EnableDoF>(sMem, gBufferBlock, laneIndex, sample3D, lensCenterToFocalCenter,
                                                      sampleInfo.frameJitter, tileSubsampleLensPos, cameraPos,
                                                      cameraLookVector, trianglesIntersect, trianglesShade, verts,
                                                      materials, textures, env, sampleOffset, sampleInfo, resolveStats);
#endif

    return result;
}

template <uint32_t MSAARate, uint32_t BlockSize, bool TMaxBuffer, bool EnableDoF>
CUDA_KERNEL void ResolveKernel(uint32_t* sampleResults,
                               float* tMaxBuffer,
                               const RaycasterGBufferSubsample* CUDA_RESTRICT gBuffer,
                               SampleInfo sampleInfo,
                               matrix4x4 sampleToWorld,
                               matrix3x3 sampleToCamera,
                               matrix4x4 cameraToWorld,
                               const vector2* CUDA_RESTRICT tileSubsampleLensPos,
                               const unsigned* CUDA_RESTRICT tileIndexRemapOccupied,
                               vector3 cameraPos,
                               vector3 cameraLookVector,
                               const PrecomputedTriangleIntersect* CUDA_RESTRICT trianglesIntersect,
                               const PrecomputedTriangleShade* CUDA_RESTRICT trianglesShade,
                               const ShadingVertex* CUDA_RESTRICT verts,
                               const SimpleMaterial* CUDA_RESTRICT materials,
                               cudaTextureObject_t* textures,
                               LightingEnvironment env,
                               ResolveStats* resolveStats) {
    static_assert(TILE_SIZE == BlockSize, "ResolveKernel assumes TILE_SIZE == BlockSize");

    int laneIndex = laneGetIndex();

    uint32_t rayInTileIndex = threadIdx.x;
    uint32_t compactedTileIndex = blockIdx.x;
    uint32_t tileIndex = tileIndexRemapOccupied[compactedTileIndex];
    uint32_t sampleOffset = tileIndex * TILE_SIZE + rayInTileIndex;

    // GBuffer texels are organized so that each subsample is a warp stride away from
    // the previous subsample for a single sample, so that warps can coalesce memory reads
    uint32_t warpIndex = sampleOffset / WARP_SIZE;
    uint32_t warpOffset = warpIndex * WARP_SIZE * MSAARate;

    UnpackedDirectionalSample sample3D =
        GetDirectionalSample3D(sampleOffset, sampleInfo, sampleToWorld, sampleToCamera, cameraToWorld);

    UnpackedSample sample2D = GetFullSample(sampleOffset, sampleInfo);
    matrix3x3 sampleToWorldRotation = matrix3x3(sampleToWorld);
    vector3 lensCenterToFocalCenter =
        sampleInfo.lens.focalDistance * (sampleToWorldRotation * vector3(sample2D.center.x, sample2D.center.y, 1.0f));

    // TODO(anankervis): precompute this with more accurate values, and load from a per-tile buffer
    // (but watch out for the foveated path)
    __shared__ ResolveSMem sMem;
    if (threadIdx.x == BlockSize / 2) {
        if (EnableDoF) {
            sMem.tileDoF.load(sampleInfo, sampleToWorld, sampleOffset);
        } else {
            sMem.tile.load(sampleToWorld, sample3D);
        }
    }
    __syncthreads();

    vector4 result = Resolve<MSAARate, BlockSize, EnableDoF>(
        sMem, gBuffer + warpOffset, laneGetIndex(), sampleOffset, sampleInfo, sample3D, lensCenterToFocalCenter,
        tileSubsampleLensPos, cameraPos, cameraLookVector, trianglesIntersect, trianglesShade, verts, materials,
        textures, env, resolveStats);

    result = ACESFilm(result);
    sampleResults[sampleOffset] = ToColor4Unorm8SRgb(result);

    if (TMaxBuffer) {
        enum { tMaxSubsampleIndex = 0 };
        vector2 alpha = getSubsampleUnitOffset<MSAARate>(sampleInfo.frameJitter, tMaxSubsampleIndex);

        // scan through the compressed gbuffer until we find the subsample we care about
        enum : uint32_t { badTriIndex = ~uint32_t(0) };
        float tMaxValue = CUDA_INF;
        uint32_t combinedSampleMask = 0;
        for (int compGbufferSlot = 0; compGbufferSlot < MSAARate; compGbufferSlot++) {
            if (combinedSampleMask == (1 << MSAARate) - 1) {
                // all samples accounted for, nothing left to shade
                break;
            }

            // GBuffer texels are organized so that each subsample is a warp stride away from
            // the previous subsample for a single sample, so that warps can coalesce memory reads
            uint32_t triIndex = gBuffer[warpOffset + compGbufferSlot * WARP_SIZE + laneIndex].triIndex;
            if (triIndex == badTriIndex)
                break; // if we have samples which don't hit a triangle, they will be grouped together as the last entry

            uint32_t sampleMask = gBuffer[warpOffset + compGbufferSlot * WARP_SIZE + laneIndex].sampleMask;
            combinedSampleMask |= sampleMask;

            if ((sampleMask & (1 << tMaxSubsampleIndex)) != 0) {
                PrecomputedTriangleIntersect triIntersect = trianglesIntersect[triIndex];

                if (EnableDoF) {
                    IntersectTriangleTileDoF triTileDoF;
                    triTileDoF.setup(triIntersect, sMem.tileDoF.lensCenter, sMem.tileDoF.lensU, sMem.tileDoF.lensV);
                    IntersectTriangleThreadDoF triThreadDoF(triTileDoF, lensCenterToFocalCenter);

                    // should lensUV be forced to zero (centered)?
                    vector2 lensUV;
                    vector2 dirUV;
                    GetSampleUVsDoF<MSAARate, BlockSize>(tileSubsampleLensPos, sampleInfo.frameJitter,
                                                         sMem.tileDoF.focalToLensScale, tMaxSubsampleIndex, lensUV,
                                                         dirUV);

                    vector3 uvw;
                    triThreadDoF.calcUVW(triTileDoF, lensCenterToFocalCenter, sMem.tileDoF.lensU, sMem.tileDoF.lensV,
                                         lensUV, dirUV, uvw);

                    vector3 v0 = triIntersect.v0;
                    vector3 v1 = triIntersect.v0 + triIntersect.edge0;
                    vector3 v2 = triIntersect.v0 + triIntersect.edge1;

                    vector3 pos = uvw.x * v0 + uvw.y * v1 + uvw.z * v2;

                    vector3 posDelta = pos - cameraPos;
                    tMaxValue = dot(posDelta, cameraLookVector);
                } else {
                    IntersectTriangleTile triTile;
                    triTile.setup(triIntersect, sMem.tile.rayOrigin, sMem.tile.majorDirDiff, sMem.tile.minorDirDiff);
                    IntersectTriangleThread triThread(triTile, sample3D.centerDir);

                    vector3 uvw;
                    triThread.calcUVW(triTile, alpha, uvw);

                    vector3 v0 = triIntersect.v0;
                    vector3 v1 = triIntersect.v0 + triIntersect.edge0;
                    vector3 v2 = triIntersect.v0 + triIntersect.edge1;

                    vector3 pos = uvw.x * v0 + uvw.y * v1 + uvw.z * v2;

                    vector3 posDelta = pos - cameraPos;
                    tMaxValue = dot(posDelta, cameraLookVector);
                }
                break;
            }
        }
        tMaxBuffer[sampleOffset] = tMaxValue;
    }
}

void DeferredMSAAResolve(GPUCamera& camera,
                         uint32_t* d_sampleResults,
                         SampleInfo sampleInfo,
                         const matrix3x3& sampleToCamera,
                         const matrix4x4& cameraToWorld) {
    Camera_StreamedData& streamed = camera.streamed[camera.streamedIndexGPU];
    Camera_LocalData& local = camera.local;

    uint32_t occupiedTileCount = streamed.tileCountOccupied;

    PrecomputedTriangleIntersect* trianglesIntersect = gGPUContext->sceneState.trianglesIntersect;
    PrecomputedTriangleShade* trianglesShade = gGPUContext->sceneState.trianglesShade;

    ShadingVertex* vertices = gGPUContext->sceneState.worldSpaceVertices;

    SimpleMaterial* d_materials = gGPUContext->sceneState.materials;

    LightingEnvironment env = gGPUContext->sceneState.lightingEnvironment;

    static_assert(TILE_SIZE % WARP_SIZE == 0, "Tile size must be a multiple of warp size in the current architecture. "
                                              "The 'GBuffer' is interleaved in a way that would break otherwise.");

    float* d_tMaxBuffer = (camera.d_tMaxBuffer.size() > 0) ? camera.d_tMaxBuffer.data() : nullptr;

    ResolveStats* resolveStatsPtr = nullptr;
#if ENABLE_RESOLVE_STATS
    static GPUBuffer<ResolveStats> resolveStatsBuffer(1);
    resolveStatsBuffer.memsetAsync(0, camera.stream);
    resolveStatsPtr = resolveStatsBuffer.data();
#endif

#if PROFILE_RESOLVE
    static uint64_t frameIndex = 0;
    enum { profileFrameSkip = 64 };
    static cudaEvent_t start = nullptr;
    static cudaEvent_t stop = nullptr;
    static float minTimeMs = FLT_MAX;
    if (!start) {
        cudaEventCreate(&start);
        cudaEventCreate(&stop);
    }
    if (frameIndex % profileFrameSkip == 0) {
        cudaEventRecord(start, camera.stream);
    }
#endif

#define RESOLVE_LAUNCH(MSAARate, BlockSize, TMaxBuffer, EnableDoF, dim, stream)                                        \
    ResolveKernel<MSAARate, BlockSize, TMaxBuffer, EnableDoF><<<dim.grid, dim.block, 0, stream>>>(                     \
        d_sampleResults, d_tMaxBuffer, camera.d_gBuffer, sampleInfo, cameraToWorld * matrix4x4(sampleToCamera),        \
        sampleToCamera, cameraToWorld, camera.d_tileSubsampleLensPos, local.tileIndexRemapOccupied.data(),             \
        camera.position, camera.lookVector, trianglesIntersect, trianglesShade, vertices, d_materials,                 \
        gDeviceTextureArray, env, resolveStatsPtr)

    KernelDim dimResolve(occupiedTileCount * TILE_SIZE, TILE_SIZE);
    if (d_tMaxBuffer) {
        // output a tMax depth buffer for reprojection
        if (sampleInfo.lens.radius > 0.0f) {
            // Enable depth of field
            RESOLVE_LAUNCH(COLOR_MODE_MSAA_RATE, TILE_SIZE, true, true, dimResolve, camera.stream);
        } else {
            // No depth of field, assume all rays have the same origin
            RESOLVE_LAUNCH(COLOR_MODE_MSAA_RATE, TILE_SIZE, true, false, dimResolve, camera.stream);
        }
    } else {
        if (sampleInfo.lens.radius > 0.0f) {
            // Enable depth of field
            RESOLVE_LAUNCH(COLOR_MODE_MSAA_RATE, TILE_SIZE, false, true, dimResolve, camera.stream);
        } else {
            // No depth of field, assume all rays have the same origin
            RESOLVE_LAUNCH(COLOR_MODE_MSAA_RATE, TILE_SIZE, false, false, dimResolve, camera.stream);
        }
    }
#undef RESOLVE_LAUNCH

#if PROFILE_RESOLVE
    if (frameIndex % profileFrameSkip == 0) {
        cudaEventRecord(stop, camera.stream);
        cudaEventSynchronize(stop);
        float timeMs = 0.0f;
        cudaEventElapsedTime(&timeMs, start, stop);
        minTimeMs = min(minTimeMs, timeMs);
        printf("resolve min: %.2fms\n", minTimeMs);
    }
    frameIndex++;
#endif

#if ENABLE_RESOLVE_STATS
    ResolveStats resolveStats = {};
    resolveStatsBuffer.readback(&resolveStats);
    printf("resolve stats: %u invocations, %u shade samples\n", resolveStats.invocations, resolveStats.shadeSamples);
#endif
}

template <bool TMaxBuffer>
CUDA_KERNEL void ClearEmptyTilesKernel(uint32_t* sampleResults,
                                       float* tMaxBuffer,
                                       const uint32_t* CUDA_RESTRICT tileIndexRemapEmpty,
                                       uint32_t emptyTileCount) {
    uint32_t index = blockIdx.x * blockDim.x + threadIdx.x;
    uint32_t compactedTileIndex = index / TILE_SIZE;
    uint32_t threadIndex = index - compactedTileIndex * TILE_SIZE;
    if (compactedTileIndex < emptyTileCount) {
        uint32_t tileIndex = tileIndexRemapEmpty[compactedTileIndex];
        uint32_t sampleOffset = tileIndex * TILE_SIZE + threadIndex;
        sampleResults[sampleOffset] = 0xFF000000;
        if (TMaxBuffer) {
            tMaxBuffer[sampleOffset] = CUDA_INF;
        }
    }
}

void ClearEmptyTiles(GPUCamera& camera, uint32_t* d_sampleResults, cudaStream_t stream) {
    Camera_StreamedData& streamed = camera.streamed[camera.streamedIndexGPU];
    Camera_LocalData& local = camera.local;

    uint32_t tileCount = streamed.tileCountEmpty;
    uint32_t blockCount = (tileCount * TILE_SIZE + CUDA_BLOCK_SIZE - 1) / CUDA_BLOCK_SIZE;
    dim3 dimGrid((uint32_t)blockCount, 1, 1);
    dim3 dimBlock(CUDA_BLOCK_SIZE, 1, 1);
    uint32_t* d_emptyTileIndexRemap = local.tileIndexRemapEmpty.data();
    float* d_tMaxBuffer = (camera.d_tMaxBuffer.size() > 0) ? camera.d_tMaxBuffer.data() : nullptr;

    if (d_tMaxBuffer) {
        ClearEmptyTilesKernel<true>
            <<<dimGrid, dimBlock, 0, stream>>>(d_sampleResults, d_tMaxBuffer, d_emptyTileIndexRemap, tileCount);
    } else {
        ClearEmptyTilesKernel<false>
            <<<dimGrid, dimBlock, 0, stream>>>(d_sampleResults, d_tMaxBuffer, d_emptyTileIndexRemap, tileCount);
    }
}

} // namespace hvvr
