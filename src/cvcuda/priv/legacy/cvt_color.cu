/* Copyright (c) 2021-2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 *
 * SPDX-FileCopyrightText: NVIDIA CORPORATION & AFFILIATES
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.
 * Copyright (C) 2000-2008, Intel Corporation, all rights reserved.
 * Copyright (C) 2009-2010, Willow Garage Inc., all rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "CvCudaLegacy.h"
#include "CvCudaLegacyHelpers.hpp"

#include "CvCudaUtils.cuh"

#include <cfloat>

static constexpr float B2YF = 0.114f;
static constexpr float G2YF = 0.587f;
static constexpr float R2YF = 0.299f;

static constexpr int gray_shift = 15;
static constexpr int yuv_shift  = 14;
static constexpr int RY15       = 9798;  // == R2YF*32768 + 0.5
static constexpr int GY15       = 19235; // == G2YF*32768 + 0.5
static constexpr int BY15       = 3735;  // == B2YF*32768 + 0.5

static constexpr int R2Y  = 4899;  // == R2YF*16384
static constexpr int G2Y  = 9617;  // == G2YF*16384
static constexpr int B2Y  = 1868;  // == B2YF*16384
static constexpr int R2VI = 14369; // == R2VF*16384
static constexpr int B2UI = 8061;  // == B2UF*16384

static constexpr float B2UF = 0.492f;
static constexpr float R2VF = 0.877f;

static constexpr int U2BI = 33292;
static constexpr int U2GI = -6472;
static constexpr int V2GI = -9519;
static constexpr int V2RI = 18678;

static constexpr float U2BF = 2.032f;
static constexpr float U2GF = -0.395f;
static constexpr float V2GF = -0.581f;
static constexpr float V2RF = 1.140f;

// Coefficients for YUV420sp to RGB conversion
static constexpr int ITUR_BT_601_CY    = 1220542;
static constexpr int ITUR_BT_601_CUB   = 2116026;
static constexpr int ITUR_BT_601_CUG   = -409993;
static constexpr int ITUR_BT_601_CVG   = -852492;
static constexpr int ITUR_BT_601_CVR   = 1673527;
static constexpr int ITUR_BT_601_SHIFT = 20;
// Coefficients for RGB to YUV420p conversion
static constexpr int ITUR_BT_601_CRY = 269484;
static constexpr int ITUR_BT_601_CGY = 528482;
static constexpr int ITUR_BT_601_CBY = 102760;
static constexpr int ITUR_BT_601_CRU = -155188;
static constexpr int ITUR_BT_601_CGU = -305135;
static constexpr int ITUR_BT_601_CBU = 460324;
static constexpr int ITUR_BT_601_CGV = -385875;
static constexpr int ITUR_BT_601_CBV = -74448;

#define CV_DESCALE(x, n) (((x) + (1 << ((n)-1))) >> (n))

#define BLOCK 32

namespace nvcv::legacy::cuda_op {

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void rgb_to_bgr_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int sch, int dch, int bidx)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();

    T b = *src.ptr(batch_idx, dst_y, dst_x, bidx);
    T g = *src.ptr(batch_idx, dst_y, dst_x, 1);
    T r = *src.ptr(batch_idx, dst_y, dst_x, bidx ^ 2);

    *dst.ptr(batch_idx, dst_y, dst_x, 0) = b;
    *dst.ptr(batch_idx, dst_y, dst_x, 1) = g;
    *dst.ptr(batch_idx, dst_y, dst_x, 2) = r;

    if (dch == 4)
    {
        T al = sch == 4 ? *src.ptr(batch_idx, dst_y, dst_x, 3) : cuda::TypeTraits<T>::max;
        *dst.ptr(batch_idx, dst_y, dst_x, 3) = al;
    }
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void gray_to_bgr_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int dch)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();

    T g = *src.ptr(batch_idx, dst_y, dst_x, 0);

    *dst.ptr(batch_idx, dst_y, dst_x, 0) = g;
    *dst.ptr(batch_idx, dst_y, dst_x, 1) = g;
    *dst.ptr(batch_idx, dst_y, dst_x, 2) = g;
    if (dch == 4)
    {
        *dst.ptr(batch_idx, dst_y, dst_x, 3) = g;
    }
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void bgr_to_gray_char_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int bidx)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();
    int       b         = *src.ptr(batch_idx, dst_y, dst_x, bidx);
    int       g         = *src.ptr(batch_idx, dst_y, dst_x, 1);
    int       r         = *src.ptr(batch_idx, dst_y, dst_x, bidx ^ 2);

    T gray                               = (T)CV_DESCALE(b * BY15 + g * GY15 + r * RY15, gray_shift);
    *dst.ptr(batch_idx, dst_y, dst_x, 0) = gray;
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void bgr_to_gray_float_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int bidx)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();
    T         b         = *src.ptr(batch_idx, dst_y, dst_x, bidx);
    T         g         = *src.ptr(batch_idx, dst_y, dst_x, 1);
    T         r         = *src.ptr(batch_idx, dst_y, dst_x, bidx ^ 2);

    T gray                               = (T)(b * B2YF + g * G2YF + r * R2YF);
    *dst.ptr(batch_idx, dst_y, dst_x, 0) = gray;
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void bgr_to_yuv_char_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int bidx)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();
    int       B         = *src.ptr(batch_idx, dst_y, dst_x, bidx);
    int       G         = *src.ptr(batch_idx, dst_y, dst_x, 1);
    int       R         = *src.ptr(batch_idx, dst_y, dst_x, bidx ^ 2);

    int C0 = R2Y, C1 = G2Y, C2 = B2Y, C3 = R2VI, C4 = B2UI;
    int delta = ((T)(cuda::TypeTraits<T>::max / 2 + 1)) * (1 << yuv_shift);
    int Y     = CV_DESCALE(R * C0 + G * C1 + B * C2, yuv_shift);
    int Cr    = CV_DESCALE((R - Y) * C3 + delta, yuv_shift);
    int Cb    = CV_DESCALE((B - Y) * C4 + delta, yuv_shift);

    *dst.ptr(batch_idx, dst_y, dst_x, 0) = cuda::SaturateCast<T>(Y);
    *dst.ptr(batch_idx, dst_y, dst_x, 1) = cuda::SaturateCast<T>(Cb);
    *dst.ptr(batch_idx, dst_y, dst_x, 2) = cuda::SaturateCast<T>(Cr);
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void bgr_to_yuv_float_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int bidx)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();
    T         B         = *src.ptr(batch_idx, dst_y, dst_x, bidx);
    T         G         = *src.ptr(batch_idx, dst_y, dst_x, 1);
    T         R         = *src.ptr(batch_idx, dst_y, dst_x, bidx ^ 2);

    T C0 = R2YF, C1 = G2YF, C2 = B2YF, C3 = R2VF, C4 = B2UF;
    T delta                              = 0.5f;
    T Y                                  = R * C0 + G * C1 + B * C2;
    T Cr                                 = (R - Y) * C3 + delta;
    T Cb                                 = (B - Y) * C4 + delta;
    *dst.ptr(batch_idx, dst_y, dst_x, 0) = Y;
    *dst.ptr(batch_idx, dst_y, dst_x, 1) = Cb;
    *dst.ptr(batch_idx, dst_y, dst_x, 2) = Cr;
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void yuv_to_bgr_char_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int bidx)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();
    T         Y         = *src.ptr(batch_idx, dst_y, dst_x, 0);
    T         Cb        = *src.ptr(batch_idx, dst_y, dst_x, 1);
    T         Cr        = *src.ptr(batch_idx, dst_y, dst_x, 2);

    int C0 = V2RI, C1 = V2GI, C2 = U2GI, C3 = U2BI;
    int delta = ((T)(cuda::TypeTraits<T>::max / 2 + 1));
    int b     = Y + CV_DESCALE((Cb - delta) * C3, yuv_shift);
    int g     = Y + CV_DESCALE((Cb - delta) * C2 + (Cr - delta) * C1, yuv_shift);
    int r     = Y + CV_DESCALE((Cr - delta) * C0, yuv_shift);

    *dst.ptr(batch_idx, dst_y, dst_x, bidx)     = cuda::SaturateCast<T>(b);
    *dst.ptr(batch_idx, dst_y, dst_x, 1)        = cuda::SaturateCast<T>(g);
    *dst.ptr(batch_idx, dst_y, dst_x, bidx ^ 2) = cuda::SaturateCast<T>(r);
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void yuv_to_bgr_float_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int bidx)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();
    T         Y         = *src.ptr(batch_idx, dst_y, dst_x, 0);
    T         Cb        = *src.ptr(batch_idx, dst_y, dst_x, 1);
    T         Cr        = *src.ptr(batch_idx, dst_y, dst_x, 2);

    T C0 = V2RF, C1 = V2GF, C2 = U2GF, C3 = U2BF;
    T delta = 0.5f;
    T b     = Y + (Cb - delta) * C3;
    T g     = Y + (Cb - delta) * C2 + (Cr - delta) * C1;
    T r     = Y + (Cr - delta) * C0;

    *dst.ptr(batch_idx, dst_y, dst_x, bidx)     = b;
    *dst.ptr(batch_idx, dst_y, dst_x, 1)        = g;
    *dst.ptr(batch_idx, dst_y, dst_x, bidx ^ 2) = r;
}

template<class SrcWrapper, class DstWrapper>
__global__ void bgr_to_hsv_char_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int bidx, bool isFullRange)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();

    int       b         = *src.ptr(batch_idx, dst_y, dst_x, bidx);
    int       g         = *src.ptr(batch_idx, dst_y, dst_x, 1);
    int       r         = *src.ptr(batch_idx, dst_y, dst_x, bidx ^ 2);
    int       hrange    = isFullRange ? 256 : 180;
    int       hr        = hrange;
    const int hsv_shift = 12;
    int       h, s, v = b;
    int       vmin = b;
    int       vr, vg;

    v    = cuda::max(v, g);
    v    = cuda::max(v, r);
    vmin = cuda::min(vmin, g);
    vmin = cuda::min(vmin, r);

    unsigned char diff = cuda::SaturateCast<unsigned char>(v - vmin);
    vr                 = v == r ? -1 : 0;
    vg                 = v == g ? -1 : 0;

    int hdiv_table = diff == 0 ? 0 : cuda::SaturateCast<int>((hrange << hsv_shift) / (6. * diff));
    int sdiv_table = v == 0 ? 0 : cuda::SaturateCast<int>((255 << hsv_shift) / (1. * v));
    s              = (diff * sdiv_table + (1 << (hsv_shift - 1))) >> hsv_shift;
    h              = (vr & (g - b)) + (~vr & ((vg & (b - r + 2 * diff)) + ((~vg) & (r - g + 4 * diff))));
    h              = (h * hdiv_table + (1 << (hsv_shift - 1))) >> hsv_shift;
    h += h < 0 ? hr : 0;

    *dst.ptr(batch_idx, dst_y, dst_x, 0) = cuda::SaturateCast<unsigned char>(h);
    *dst.ptr(batch_idx, dst_y, dst_x, 1) = (unsigned char)s;
    *dst.ptr(batch_idx, dst_y, dst_x, 2) = (unsigned char)v;
}

template<class SrcWrapper, class DstWrapper>
__global__ void bgr_to_hsv_float_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int bidx)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();

    float b = *src.ptr(batch_idx, dst_y, dst_x, bidx);
    float g = *src.ptr(batch_idx, dst_y, dst_x, 1);
    float r = *src.ptr(batch_idx, dst_y, dst_x, bidx ^ 2);
    float h, s, v;
    float hrange = 360.0;
    float hscale = hrange * (1.f / 360.f);

    float vmin, diff;

    v = vmin = r;
    if (v < g)
        v = g;
    if (v < b)
        v = b;
    if (vmin > g)
        vmin = g;
    if (vmin > b)
        vmin = b;

    diff = v - vmin;
    s    = diff / (float)(fabs(v) + FLT_EPSILON);
    diff = (float)(60. / (diff + FLT_EPSILON));
    if (v == r)
        h = (g - b) * diff;
    else if (v == g)
        h = (b - r) * diff + 120.f;
    else
        h = (r - g) * diff + 240.f;

    if (h < 0)
        h += 360.f;

    *dst.ptr(batch_idx, dst_y, dst_x, 0) = h * hscale;
    *dst.ptr(batch_idx, dst_y, dst_x, 1) = s;
    *dst.ptr(batch_idx, dst_y, dst_x, 2) = v;
}

__device__ inline void HSV2RGB_native(float h, float s, float v, float &b, float &g, float &r, const float hscale)
{
    if (s == 0)
        b = g = r = v;
    else
    {
        static const int sector_data[][3] = {
            {1, 3, 0},
            {1, 0, 2},
            {3, 0, 1},
            {0, 2, 1},
            {0, 1, 3},
            {2, 1, 0}
        };
        float tab[4];
        int   sector;
        h *= hscale;
        h      = fmod(h, 6.f);
        sector = (int)floor(h);
        h -= sector;
        if ((unsigned)sector >= 6u)
        {
            sector = 0;
            h      = 0.f;
        }

        tab[0] = v;
        tab[1] = v * (1.f - s);
        tab[2] = v * (1.f - s * h);
        tab[3] = v * (1.f - s * (1.f - h));

        b = tab[sector_data[sector][0]];
        g = tab[sector_data[sector][1]];
        r = tab[sector_data[sector][2]];
    }
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void hsv_to_bgr_char_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int bidx, int dcn, bool isFullRange)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();

    float h = *src.ptr(batch_idx, dst_y, dst_x, 0);
    float s = *src.ptr(batch_idx, dst_y, dst_x, 1) * (1.0f / 255.0f);
    float v = *src.ptr(batch_idx, dst_y, dst_x, 2) * (1.0f / 255.0f);

    float         hrange = isFullRange ? 255 : 180;
    unsigned char alpha  = cuda::TypeTraits<T>::max;
    float         hs     = 6.f / hrange;

    float b, g, r;
    HSV2RGB_native(h, s, v, b, g, r, hs);

    *dst.ptr(batch_idx, dst_y, dst_x, bidx)     = cuda::SaturateCast<uchar>(b * 255.0f);
    *dst.ptr(batch_idx, dst_y, dst_x, 1)        = cuda::SaturateCast<uchar>(g * 255.0f);
    *dst.ptr(batch_idx, dst_y, dst_x, bidx ^ 2) = cuda::SaturateCast<uchar>(r * 255.0f);
    if (dcn == 4)
        *dst.ptr(batch_idx, dst_y, dst_x, 3) = alpha;
}

template<class SrcWrapper, class DstWrapper>
__global__ void hsv_to_bgr_float_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int bidx, int dcn)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();

    float h = *src.ptr(batch_idx, dst_y, dst_x, 0);
    float s = *src.ptr(batch_idx, dst_y, dst_x, 1);
    float v = *src.ptr(batch_idx, dst_y, dst_x, 2);

    float hrange = 360.0;
    float alpha  = 1.f;
    float hs     = 6.f / hrange;

    float b, g, r;
    HSV2RGB_native(h, s, v, b, g, r, hs);

    *dst.ptr(batch_idx, dst_y, dst_x, bidx)     = b;
    *dst.ptr(batch_idx, dst_y, dst_x, 1)        = g;
    *dst.ptr(batch_idx, dst_y, dst_x, bidx ^ 2) = r;
    if (dcn == 4)
        *dst.ptr(batch_idx, dst_y, dst_x, 3) = alpha;
}

__device__ __forceinline__ void yuv42xxp_to_bgr_kernel(const int &Y, const int &U, const int &V, uchar &r, uchar &g,
                                                       uchar &b)
{
    //R = 1.164(Y - 16) + 1.596(V - 128)
    //G = 1.164(Y - 16) - 0.813(V - 128) - 0.391(U - 128)
    //B = 1.164(Y - 16)                  + 2.018(U - 128)

    //R = (1220542(Y - 16) + 1673527(V - 128)                  + (1 << 19)) >> 20
    //G = (1220542(Y - 16) - 852492(V - 128) - 409993(U - 128) + (1 << 19)) >> 20
    //B = (1220542(Y - 16)                  + 2116026(U - 128) + (1 << 19)) >> 20
    const int C0 = ITUR_BT_601_CY, C1 = ITUR_BT_601_CVR, C2 = ITUR_BT_601_CVG, C3 = ITUR_BT_601_CUG,
              C4           = ITUR_BT_601_CUB;
    const int yuv4xx_shift = ITUR_BT_601_SHIFT;

    int yy = cuda::max(0, Y - 16) * C0;
    int uu = U - 128;
    int vv = V - 128;

    r = cuda::SaturateCast<uchar>(CV_DESCALE((yy + C1 * vv), yuv4xx_shift));
    g = cuda::SaturateCast<uchar>(CV_DESCALE((yy + C2 * vv + C3 * uu), yuv4xx_shift));
    b = cuda::SaturateCast<uchar>(CV_DESCALE((yy + C4 * uu), yuv4xx_shift));
}

__device__ __forceinline__ void bgr_to_yuv42xxp_kernel(const uchar &r, const uchar &g, const uchar &b, uchar &Y,
                                                       uchar &U, uchar &V)
{
    const int shifted16 = (16 << ITUR_BT_601_SHIFT);
    const int halfShift = (1 << (ITUR_BT_601_SHIFT - 1));
    int       yy        = ITUR_BT_601_CRY * r + ITUR_BT_601_CGY * g + ITUR_BT_601_CBY * b + halfShift + shifted16;

    Y = cuda::SaturateCast<uchar>(yy >> ITUR_BT_601_SHIFT);

    const int shifted128 = (128 << ITUR_BT_601_SHIFT);
    int       uu         = ITUR_BT_601_CRU * r + ITUR_BT_601_CGU * g + ITUR_BT_601_CBU * b + halfShift + shifted128;
    int       vv         = ITUR_BT_601_CBU * r + ITUR_BT_601_CGV * g + ITUR_BT_601_CBV * b + halfShift + shifted128;

    U = cuda::SaturateCast<uchar>(uu >> ITUR_BT_601_SHIFT);
    V = cuda::SaturateCast<uchar>(vv >> ITUR_BT_601_SHIFT);
}

template<class SrcWrapper, class DstWrapper>
__global__ void bgr_to_yuv420p_char_nhwc(SrcWrapper src, DstWrapper dst, int2 srcSize, int scn, int bidx, int uidx)
{
    int src_x = blockIdx.x * blockDim.x + threadIdx.x;
    int src_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (src_x >= srcSize.x || src_y >= srcSize.y)
        return;
    const int batch_idx     = get_batch_idx();
    int       plane_y_step  = srcSize.y * srcSize.x;
    int       plane_uv_step = plane_y_step / 4;
    int       uv_x          = (src_y % 4 < 2) ? src_x / 2 : (src_x / 2 + srcSize.x / 2);

    uchar b = static_cast<uchar>(*src.ptr(batch_idx, src_y, src_x, bidx));
    uchar g = static_cast<uchar>(*src.ptr(batch_idx, src_y, src_x, 1));
    uchar r = static_cast<uchar>(*src.ptr(batch_idx, src_y, src_x, bidx ^ 2));
    // Ignore gray channel if input is RGBA

    uchar Y{0}, U{0}, V{0};
    bgr_to_yuv42xxp_kernel(r, g, b, Y, U, V);

    *dst.ptr(batch_idx, src_y, src_x, 0) = Y;
    if (src_y % 2 == 0 && src_x % 2 == 0)
    {
        *dst.ptr(batch_idx, srcSize.y + src_y / 4, uv_x + plane_uv_step * uidx)       = U;
        *dst.ptr(batch_idx, srcSize.y + src_y / 4, uv_x + plane_uv_step * (1 - uidx)) = V;
    }
}

template<class SrcWrapper, class DstWrapper>
__global__ void bgr_to_yuv420sp_char_nhwc(SrcWrapper src, DstWrapper dst, int2 srcSize, int scn, int bidx, int uidx)
{
    int src_x = blockIdx.x * blockDim.x + threadIdx.x;
    int src_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (src_x >= srcSize.x || src_y >= srcSize.y)
        return;
    const int batch_idx = get_batch_idx();
    int       uv_x      = (src_x % 2 == 0) ? src_x : (src_x - 1);

    uchar b = static_cast<uchar>(*src.ptr(batch_idx, src_y, src_x, bidx));
    uchar g = static_cast<uchar>(*src.ptr(batch_idx, src_y, src_x, 1));
    uchar r = static_cast<uchar>(*src.ptr(batch_idx, src_y, src_x, bidx ^ 2));
    // Ignore gray channel if input is RGBA

    uchar Y{0}, U{0}, V{0};
    bgr_to_yuv42xxp_kernel(r, g, b, Y, U, V);

    *dst.ptr(batch_idx, src_y, src_x, 0) = Y;
    if (src_y % 2 == 0 && src_x % 2 == 0)
    {
        *dst.ptr(batch_idx, srcSize.y + src_y / 2, uv_x + uidx)       = U;
        *dst.ptr(batch_idx, srcSize.y + src_y / 2, uv_x + (1 - uidx)) = V;
    }
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void yuv420sp_to_bgr_char_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int dcn, int bidx, int uidx)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();
    int       uv_x      = (dst_x % 2 == 0) ? dst_x : (dst_x - 1);

    T Y = *src.ptr(batch_idx, dst_y, dst_x, 0);
    T U = *src.ptr(batch_idx, dstSize.y + dst_y / 2, uv_x + uidx);
    T V = *src.ptr(batch_idx, dstSize.y + dst_y / 2, uv_x + 1 - uidx);

    uchar r{0}, g{0}, b{0}, a{0xff};
    yuv42xxp_to_bgr_kernel(int(Y), int(U), int(V), r, g, b);

    *dst.ptr(batch_idx, dst_y, dst_x, bidx)     = b;
    *dst.ptr(batch_idx, dst_y, dst_x, 1)        = g;
    *dst.ptr(batch_idx, dst_y, dst_x, bidx ^ 2) = r;
    if (dcn == 4)
    {
        *dst.ptr(batch_idx, dst_y, dst_x, 3) = a;
    }
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void yuv420p_to_bgr_char_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int dcn, int bidx, int uidx)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;

    const int batch_idx     = get_batch_idx();
    int       plane_y_step  = dstSize.y * dstSize.x;
    int       plane_uv_step = plane_y_step / 4;
    int       uv_x          = (dst_y % 4 < 2) ? dst_x / 2 : (dst_x / 2 + dstSize.x / 2);

    T Y = *src.ptr(batch_idx, dst_y, dst_x, 0);
    T U = *src.ptr(batch_idx, dstSize.y + dst_y / 4, uv_x + plane_uv_step * uidx);
    T V = *src.ptr(batch_idx, dstSize.y + dst_y / 4, uv_x + plane_uv_step * (1 - uidx));

    uchar r{0}, g{0}, b{0}, a{0xff};
    yuv42xxp_to_bgr_kernel(int(Y), int(U), int(V), r, g, b);

    *dst.ptr(batch_idx, dst_y, dst_x, bidx)     = b;
    *dst.ptr(batch_idx, dst_y, dst_x, 1)        = g;
    *dst.ptr(batch_idx, dst_y, dst_x, bidx ^ 2) = r;
    if (dcn == 4)
    {
        *dst.ptr(batch_idx, dst_y, dst_x, 3) = a;
    }
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void yuv422_to_bgr_char_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int dcn, int bidx, int yidx,
                                        int uidx)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx = get_batch_idx();
    int       uv_x      = (dst_x % 2 == 0) ? dst_x : dst_x - 1;

    T Y = *src.ptr(batch_idx, dst_y, dst_x, yidx);
    T U = *src.ptr(batch_idx, dst_y, uv_x, (1 - yidx) + uidx);
    T V = *src.ptr(batch_idx, dst_y, uv_x, (1 - yidx) + uidx ^ 2);

    uchar r{0}, g{0}, b{0}, a{0xff};
    yuv42xxp_to_bgr_kernel(int(Y), int(U), int(V), r, g, b);

    *dst.ptr(batch_idx, dst_y, dst_x, bidx)     = b;
    *dst.ptr(batch_idx, dst_y, dst_x, 1)        = g;
    *dst.ptr(batch_idx, dst_y, dst_x, bidx ^ 2) = r;
    if (dcn == 4)
    {
        *dst.ptr(batch_idx, dst_y, dst_x, 3) = a;
    }
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void yuv420_to_gray_char_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx                  = get_batch_idx();
    T         Y                          = *src.ptr(batch_idx, dst_y, dst_x, 0);
    *dst.ptr(batch_idx, dst_y, dst_x, 0) = Y;
}

template<class SrcWrapper, class DstWrapper, typename T = typename DstWrapper::ValueType>
__global__ void yuv422_to_gray_char_nhwc(SrcWrapper src, DstWrapper dst, int2 dstSize, int yidx)
{
    int dst_x = blockIdx.x * blockDim.x + threadIdx.x;
    int dst_y = blockIdx.y * blockDim.y + threadIdx.y;
    if (dst_x >= dstSize.x || dst_y >= dstSize.y)
        return;
    const int batch_idx                  = get_batch_idx();
    T         Y                          = *src.ptr(batch_idx, dst_y, dst_x, yidx);
    *dst.ptr(batch_idx, dst_y, dst_x, 0) = Y;
}

inline ErrorCode BGR_to_RGB(const ITensorDataStridedCuda &inData, const ITensorDataStridedCuda &outData,
                            NVCVColorConversionCode code, cudaStream_t stream)
{
    int sch  = (code == NVCV_COLOR_BGRA2BGR || code == NVCV_COLOR_RGBA2BGR || code == NVCV_COLOR_BGRA2RGBA) ? 4 : 3;
    int dch  = (code == NVCV_COLOR_BGR2BGRA || code == NVCV_COLOR_BGR2RGBA || code == NVCV_COLOR_BGRA2RGBA) ? 4 : 3;
    int bidx = (code == NVCV_COLOR_BGR2RGB || code == NVCV_COLOR_RGBA2BGR || code == NVCV_COLOR_BGRA2RGBA
                || code == NVCV_COLOR_BGR2RGBA)
                 ? 2
                 : 0;

    auto inAccess = TensorDataAccessStridedImagePlanar::Create(inData);
    NVCV_ASSERT(inAccess);

    cuda_op::DataType  inDataType = helpers::GetLegacyDataType(inData.dtype());
    cuda_op::DataShape inputShape = helpers::GetLegacyDataShape(inAccess->infoShape());

    auto outAccess = TensorDataAccessStridedImagePlanar::Create(outData);
    NVCV_ASSERT(outAccess);

    cuda_op::DataType  outDataType = helpers::GetLegacyDataType(outData.dtype());
    cuda_op::DataShape outputShape = helpers::GetLegacyDataShape(outAccess->infoShape());

    if (inputShape.C != sch)
    {
        LOG_ERROR("Invalid input channel number " << inputShape.C << " expecting: " << sch);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (outDataType != inDataType)
    {
        LOG_ERROR("Unsupported input/output DataType " << inDataType << "/" << outDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    if (outputShape.H != inputShape.H || outputShape.W != inputShape.W || outputShape.N != inputShape.N
        || outputShape.C != dch)
    {
        LOG_ERROR("Invalid output shape " << outputShape);
        return ErrorCode::INVALID_DATA_SHAPE;
    }

    dim3 blockSize(BLOCK, BLOCK / 4, 1);
    dim3 gridSize(divUp(inputShape.W, blockSize.x), divUp(inputShape.H, blockSize.y), inputShape.N);

    int2 dstSize{outputShape.W, outputShape.H};

    switch (inDataType)
    {
    case kCV_8U:
    case kCV_8S:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<uint8_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<uint8_t>(outData);
        rgb_to_bgr_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, sch, dch, bidx);
        checkKernelErrors();
    }
    break;
    case kCV_16U:
    case kCV_16F:
    case kCV_16S:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<uint16_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<uint16_t>(outData);
        rgb_to_bgr_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, sch, dch, bidx);
        checkKernelErrors();
    }
    break;
    case kCV_32S:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<int32_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<int32_t>(outData);
        rgb_to_bgr_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, sch, dch, bidx);
        checkKernelErrors();
    }
    break;
    case kCV_32F:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<float>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<float>(outData);
        rgb_to_bgr_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, sch, dch, bidx);
        checkKernelErrors();
    }
    break;
    case kCV_64F:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<double>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<double>(outData);
        rgb_to_bgr_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, sch, dch, bidx);
        checkKernelErrors();
    }
    break;
    }
    return ErrorCode::SUCCESS;
}

inline ErrorCode GRAY_to_BGR(const ITensorDataStridedCuda &inData, const ITensorDataStridedCuda &outData,
                             NVCVColorConversionCode code, cudaStream_t stream)
{
    int dch = (code == NVCV_COLOR_GRAY2BGRA) ? 4 : 3;

    auto inAccess = TensorDataAccessStridedImagePlanar::Create(inData);
    NVCV_ASSERT(inAccess);

    cuda_op::DataType  inDataType = helpers::GetLegacyDataType(inData.dtype());
    cuda_op::DataShape inputShape = helpers::GetLegacyDataShape(inAccess->infoShape());

    auto outAccess = TensorDataAccessStridedImagePlanar::Create(outData);
    NVCV_ASSERT(outAccess);

    cuda_op::DataType  outDataType = helpers::GetLegacyDataType(outData.dtype());
    cuda_op::DataShape outputShape = helpers::GetLegacyDataShape(outAccess->infoShape());

    if (inputShape.C != 1)
    {
        LOG_ERROR("Invalid input channel number " << inputShape.C);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (outDataType != inDataType)
    {
        LOG_ERROR("Unsupported input/output DataType " << inDataType << "/" << outDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    if (outputShape.H != inputShape.H || outputShape.W != inputShape.W || outputShape.N != inputShape.N
        || outputShape.C != dch)
    {
        LOG_ERROR("Invalid output shape " << outputShape);
        return ErrorCode::INVALID_DATA_SHAPE;
    }

    dim3 blockSize(BLOCK, BLOCK / 4, 1);
    dim3 gridSize(divUp(inputShape.W, blockSize.x), divUp(inputShape.H, blockSize.y), inputShape.N);

    int2 dstSize{outputShape.W, outputShape.H};

    switch (inDataType)
    {
    case kCV_8U:
    case kCV_8S:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<uint8_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<uint8_t>(outData);
        gray_to_bgr_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, dch);
        checkKernelErrors();
    }
    break;
    case kCV_16U:
    case kCV_16F:
    case kCV_16S:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<uint16_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<uint16_t>(outData);
        gray_to_bgr_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, dch);
        checkKernelErrors();
    }
    break;
    case kCV_32S:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<int32_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<int32_t>(outData);
        gray_to_bgr_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, dch);
        checkKernelErrors();
    }
    break;
    case kCV_32F:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<float>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<float>(outData);
        gray_to_bgr_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, dch);
        checkKernelErrors();
    }
    break;
    case kCV_64F:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<double>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<double>(outData);
        gray_to_bgr_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, dch);
        checkKernelErrors();
    }
    break;
    }
    return ErrorCode::SUCCESS;
}

inline ErrorCode BGR_to_GRAY(const ITensorDataStridedCuda &inData, const ITensorDataStridedCuda &outData,
                             NVCVColorConversionCode code, cudaStream_t stream)
{
    int bidx = (code == NVCV_COLOR_RGBA2GRAY || code == NVCV_COLOR_RGB2GRAY) ? 2 : 0;
    int sch  = (code == NVCV_COLOR_RGBA2GRAY || code == NVCV_COLOR_BGRA2GRAY) ? 4 : 3;

    auto inAccess = TensorDataAccessStridedImagePlanar::Create(inData);
    NVCV_ASSERT(inAccess);

    cuda_op::DataType  inDataType = helpers::GetLegacyDataType(inData.dtype());
    cuda_op::DataShape inputShape = helpers::GetLegacyDataShape(inAccess->infoShape());

    auto outAccess = TensorDataAccessStridedImagePlanar::Create(outData);
    NVCV_ASSERT(outAccess);

    cuda_op::DataType  outDataType = helpers::GetLegacyDataType(outData.dtype());
    cuda_op::DataShape outputShape = helpers::GetLegacyDataShape(outAccess->infoShape());

    if (inputShape.C != sch)
    {
        LOG_ERROR("Invalid input channel number " << inputShape.C << " expecting: " << sch);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (outDataType != inDataType)
    {
        LOG_ERROR("Unsupported input/output DataType " << inDataType << "/" << outDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    if (outputShape.H != inputShape.H || outputShape.W != inputShape.W || outputShape.N != inputShape.N
        || outputShape.C != 1)
    {
        LOG_ERROR("Invalid output shape " << outputShape);
        return ErrorCode::INVALID_DATA_SHAPE;
    }

    dim3 blockSize(BLOCK, BLOCK / 4, 1);
    dim3 gridSize(divUp(inputShape.W, blockSize.x), divUp(inputShape.H, blockSize.y), inputShape.N);

    int2 dstSize{outputShape.W, outputShape.H};

    switch (inDataType)
    {
    case kCV_8U:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<uint8_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<uint8_t>(outData);
        bgr_to_gray_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx);
        checkKernelErrors();
    }
    break;
    case kCV_16U:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<uint16_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<uint16_t>(outData);
        bgr_to_gray_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx);
        checkKernelErrors();
    }
    break;
    case kCV_32F:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<float>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<float>(outData);
        bgr_to_gray_float_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx);
        checkKernelErrors();
    }
    break;
    default:
        LOG_ERROR("Unsupported DataType " << inDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    return ErrorCode::SUCCESS;
}

inline ErrorCode BGR_to_YUV(const ITensorDataStridedCuda &inData, const ITensorDataStridedCuda &outData,
                            NVCVColorConversionCode code, cudaStream_t stream)
{
    int bidx = code == NVCV_COLOR_BGR2YUV ? 0 : 2;

    auto inAccess = TensorDataAccessStridedImagePlanar::Create(inData);
    NVCV_ASSERT(inAccess);

    cuda_op::DataType  inDataType = helpers::GetLegacyDataType(inData.dtype());
    cuda_op::DataShape inputShape = helpers::GetLegacyDataShape(inAccess->infoShape());

    auto outAccess = TensorDataAccessStridedImagePlanar::Create(outData);
    NVCV_ASSERT(outAccess);

    cuda_op::DataType  outDataType = helpers::GetLegacyDataType(outData.dtype());
    cuda_op::DataShape outputShape = helpers::GetLegacyDataShape(outAccess->infoShape());

    if (inputShape.C != 3)
    {
        LOG_ERROR("Invalid input channel number " << inputShape.C);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (outDataType != inDataType)
    {
        LOG_ERROR("Unsupported input/output DataType " << inDataType << "/" << outDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    if (outputShape != inputShape)
    {
        LOG_ERROR("Invalid input shape " << inputShape << " different than output shape " << outputShape);
        return ErrorCode::INVALID_DATA_SHAPE;
    }

    dim3 blockSize(BLOCK, BLOCK / 4, 1);
    dim3 gridSize(divUp(inputShape.W, blockSize.x), divUp(inputShape.H, blockSize.y), inputShape.N);

    int2 dstSize{outputShape.W, outputShape.H};

    switch (inDataType)
    {
    case kCV_8U:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<uint8_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<uint8_t>(outData);
        bgr_to_yuv_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx);
        checkKernelErrors();
    }
    break;
    case kCV_16U:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<uint16_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<uint16_t>(outData);
        bgr_to_yuv_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx);
        checkKernelErrors();
    }
    break;
    case kCV_32F:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<float>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<float>(outData);
        bgr_to_yuv_float_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx);
        checkKernelErrors();
    }
    break;
    default:
        LOG_ERROR("Unsupported DataType " << inDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    return ErrorCode::SUCCESS;
}

inline ErrorCode YUV_to_BGR(const ITensorDataStridedCuda &inData, const ITensorDataStridedCuda &outData,
                            NVCVColorConversionCode code, cudaStream_t stream)
{
    int bidx = code == NVCV_COLOR_YUV2BGR ? 0 : 2;

    auto inAccess = TensorDataAccessStridedImagePlanar::Create(inData);
    NVCV_ASSERT(inAccess);

    cuda_op::DataType  inDataType = helpers::GetLegacyDataType(inData.dtype());
    cuda_op::DataShape inputShape = helpers::GetLegacyDataShape(inAccess->infoShape());

    auto outAccess = TensorDataAccessStridedImagePlanar::Create(outData);
    NVCV_ASSERT(outAccess);

    cuda_op::DataType  outDataType = helpers::GetLegacyDataType(outData.dtype());
    cuda_op::DataShape outputShape = helpers::GetLegacyDataShape(outAccess->infoShape());

    if (inputShape.C != 3)
    {
        LOG_ERROR("Invalid input channel number " << inputShape.C);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (outDataType != inDataType)
    {
        LOG_ERROR("Unsupported input/output DataType " << inDataType << "/" << outDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    if (outputShape != inputShape)
    {
        LOG_ERROR("Invalid input shape " << inputShape << " different than output shape " << outputShape);
        return ErrorCode::INVALID_DATA_SHAPE;
    }

    dim3 blockSize(BLOCK, BLOCK / 4, 1);
    dim3 gridSize(divUp(inputShape.W, blockSize.x), divUp(inputShape.H, blockSize.y), inputShape.N);

    int2 dstSize{outputShape.W, outputShape.H};

    switch (inDataType)
    {
    case kCV_8U:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<uint8_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<uint8_t>(outData);
        yuv_to_bgr_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx);
        checkKernelErrors();
    }
    break;
    case kCV_16U:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<uint16_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<uint16_t>(outData);
        yuv_to_bgr_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx);
        checkKernelErrors();
    }
    break;
    case kCV_32F:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<float>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<float>(outData);
        yuv_to_bgr_float_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx);
        checkKernelErrors();
    }
    break;
    default:
        LOG_ERROR("Unsupported DataType " << inDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    return ErrorCode::SUCCESS;
}

inline ErrorCode BGR_to_HSV(const ITensorDataStridedCuda &inData, const ITensorDataStridedCuda &outData,
                            NVCVColorConversionCode code, cudaStream_t stream)
{
    bool isFullRange = (code == NVCV_COLOR_BGR2HSV_FULL || code == NVCV_COLOR_RGB2HSV_FULL);
    int  bidx        = (code == NVCV_COLOR_BGR2HSV || code == NVCV_COLOR_BGR2HSV_FULL) ? 0 : 2;

    auto inAccess = TensorDataAccessStridedImagePlanar::Create(inData);
    NVCV_ASSERT(inAccess);

    cuda_op::DataType  inDataType = helpers::GetLegacyDataType(inData.dtype());
    cuda_op::DataShape inputShape = helpers::GetLegacyDataShape(inAccess->infoShape());

    auto outAccess = TensorDataAccessStridedImagePlanar::Create(outData);
    NVCV_ASSERT(outAccess);

    cuda_op::DataType  outDataType = helpers::GetLegacyDataType(outData.dtype());
    cuda_op::DataShape outputShape = helpers::GetLegacyDataShape(outAccess->infoShape());

    if (inputShape.C != 3)
    {
        LOG_ERROR("Invalid input channel number " << inputShape.C);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (outDataType != inDataType)
    {
        LOG_ERROR("Unsupported input/output DataType " << inDataType << "/" << outDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    if (outputShape != inputShape)
    {
        LOG_ERROR("Invalid input shape " << inputShape << " different than output shape " << outputShape);
        return ErrorCode::INVALID_DATA_SHAPE;
    }

    dim3 blockSize(BLOCK, BLOCK / 4, 1);
    dim3 gridSize(divUp(inputShape.W, blockSize.x), divUp(inputShape.H, blockSize.y), inputShape.N);

    int2 dstSize{outputShape.W, outputShape.H};

    switch (inDataType)
    {
    case kCV_8U:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<uint8_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<uint8_t>(outData);
        bgr_to_hsv_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx, isFullRange);
        checkKernelErrors();
    }
    break;
    case kCV_32F:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<float>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<float>(outData);
        bgr_to_hsv_float_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx);
        checkKernelErrors();
    }
    break;
    default:
        LOG_ERROR("Unsupported DataType " << inDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    return ErrorCode::SUCCESS;
}

inline ErrorCode HSV_to_BGR(const ITensorDataStridedCuda &inData, const ITensorDataStridedCuda &outData,
                            NVCVColorConversionCode code, cudaStream_t stream)
{
    bool isFullRange = (code == NVCV_COLOR_HSV2BGR_FULL || code == NVCV_COLOR_HSV2RGB_FULL);
    int  bidx        = (code == NVCV_COLOR_HSV2BGR || code == NVCV_COLOR_HSV2BGR_FULL) ? 0 : 2;

    auto inAccess = TensorDataAccessStridedImagePlanar::Create(inData);
    NVCV_ASSERT(inAccess);

    cuda_op::DataType  inDataType = helpers::GetLegacyDataType(inData.dtype());
    cuda_op::DataShape inputShape = helpers::GetLegacyDataShape(inAccess->infoShape());

    auto outAccess = TensorDataAccessStridedImagePlanar::Create(outData);
    NVCV_ASSERT(outAccess);

    cuda_op::DataType  outDataType = helpers::GetLegacyDataType(outData.dtype());
    cuda_op::DataShape outputShape = helpers::GetLegacyDataShape(outAccess->infoShape());

    if (outputShape.C != 3 && outputShape.C != 4)
    {
        LOG_ERROR("Invalid output channel number " << outputShape.C);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (inputShape.C != 3)
    {
        LOG_ERROR("Invalid input channel number " << inputShape.C);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (outDataType != inDataType)
    {
        LOG_ERROR("Unsupported input/output DataType " << inDataType << "/" << outDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    if (outputShape.H != inputShape.H || outputShape.W != inputShape.W || outputShape.N != inputShape.N)
    {
        LOG_ERROR("Invalid output shape " << outputShape);
        return ErrorCode::INVALID_DATA_SHAPE;
    }

    dim3 blockSize(BLOCK, BLOCK / 4, 1);
    dim3 gridSize(divUp(inputShape.W, blockSize.x), divUp(inputShape.H, blockSize.y), inputShape.N);

    int2 dstSize{outputShape.W, outputShape.H};
    int  dcn = outputShape.C;

    switch (inDataType)
    {
    case kCV_8U:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<uint8_t>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<uint8_t>(outData);
        hsv_to_bgr_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx, dcn, isFullRange);
        checkKernelErrors();
    }
    break;
    case kCV_32F:
    {
        auto srcWrap = cuda::CreateTensorWrapNHWC<float>(inData);
        auto dstWrap = cuda::CreateTensorWrapNHWC<float>(outData);
        hsv_to_bgr_float_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, bidx, dcn);
        checkKernelErrors();
    }
    break;
    default:
        LOG_ERROR("Unsupported DataType " << inDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    return ErrorCode::SUCCESS;
}

inline ErrorCode YUV420xp_to_BGR(const ITensorDataStridedCuda &inData, const ITensorDataStridedCuda &outData,
                                 NVCVColorConversionCode code, cudaStream_t stream)
{
    int bidx
        = (code == NVCV_COLOR_YUV2BGR_NV12 || code == NVCV_COLOR_YUV2BGRA_NV12 || code == NVCV_COLOR_YUV2BGR_NV21
           || code == NVCV_COLOR_YUV2BGRA_NV21 || code == NVCV_COLOR_YUV2BGR_YV12 || code == NVCV_COLOR_YUV2BGRA_YV12
           || code == NVCV_COLOR_YUV2BGR_IYUV || code == NVCV_COLOR_YUV2BGRA_IYUV)
            ? 0
            : 2;

    int uidx
        = (code == NVCV_COLOR_YUV2BGR_NV12 || code == NVCV_COLOR_YUV2BGRA_NV12 || code == NVCV_COLOR_YUV2RGB_NV12
           || code == NVCV_COLOR_YUV2RGBA_NV12 || code == NVCV_COLOR_YUV2BGR_IYUV || code == NVCV_COLOR_YUV2BGRA_IYUV
           || code == NVCV_COLOR_YUV2RGB_IYUV || code == NVCV_COLOR_YUV2RGBA_IYUV)
            ? 0
            : 1;

    auto inAccess = TensorDataAccessStridedImagePlanar::Create(inData);
    NVCV_ASSERT(inAccess);

    cuda_op::DataType  inDataType = helpers::GetLegacyDataType(inData.dtype());
    cuda_op::DataShape inputShape = helpers::GetLegacyDataShape(inAccess->infoShape());

    auto outAccess = TensorDataAccessStridedImagePlanar::Create(outData);
    NVCV_ASSERT(outAccess);

    cuda_op::DataType  outDataType = helpers::GetLegacyDataType(outData.dtype());
    cuda_op::DataShape outputShape = helpers::GetLegacyDataShape(outAccess->infoShape());

    if (outputShape.C != 3 && outputShape.C != 4)
    {
        LOG_ERROR("Invalid output channel number " << outputShape.C);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (inputShape.C != 1)
    {
        LOG_ERROR("Invalid input channel number " << inputShape.C);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (inputShape.H % 3 != 0 || inputShape.W % 2 != 0)
    {
        LOG_ERROR("Invalid input shape " << inputShape);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (inDataType != kCV_8U || outDataType != kCV_8U)
    {
        LOG_ERROR("Unsupported input/output DataType " << inDataType << "/" << outDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }

    int rgb_width  = inputShape.W;
    int rgb_height = inputShape.H * 2 / 3;

    if (outputShape.H != rgb_height || outputShape.W != rgb_width || outputShape.N != inputShape.N)
    {
        LOG_ERROR("Invalid output shape " << outputShape);
        return ErrorCode::INVALID_DATA_SHAPE;
    }

    dim3 blockSize(BLOCK, BLOCK / 1, 1);
    dim3 gridSize(divUp(rgb_width, blockSize.x), divUp(rgb_height, blockSize.y), inputShape.N);

    int2 dstSize{outputShape.W, outputShape.H};
    int  dcn = outputShape.C;

    auto srcWrap = cuda::CreateTensorWrapNHWC<uint8_t>(inData);
    auto dstWrap = cuda::CreateTensorWrapNHWC<uint8_t>(outData);

    switch (code)
    {
    case NVCV_COLOR_YUV2GRAY_420:
    {
        /* Method 1 */
        // yuv420_to_gray_char_nhwc<unsigned char><<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize);
        // checkKernelErrors();

        /* Method 2 (Better performance, but only works with fixed input shapes) */
        int dpitch     = static_cast<int>(outAccess->sampleStride());
        int spitch     = static_cast<int>(inAccess->sampleStride());
        int cpy_width  = static_cast<int>(outAccess->sampleStride());
        int cpy_height = inputShape.N;

        checkCudaErrors(cudaMemcpy2DAsync(outData.basePtr(), dpitch, inData.basePtr(), spitch, cpy_width, cpy_height,
                                          cudaMemcpyDeviceToDevice, stream));
    }
    break;
    case NVCV_COLOR_YUV2BGR_NV12:
    case NVCV_COLOR_YUV2BGR_NV21:
    case NVCV_COLOR_YUV2BGRA_NV12:
    case NVCV_COLOR_YUV2BGRA_NV21:
    case NVCV_COLOR_YUV2RGB_NV12:
    case NVCV_COLOR_YUV2RGB_NV21:
    case NVCV_COLOR_YUV2RGBA_NV12:
    case NVCV_COLOR_YUV2RGBA_NV21:
    {
        yuv420sp_to_bgr_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, dcn, bidx, uidx);
        checkKernelErrors();
    }
    break;
    case NVCV_COLOR_YUV2BGR_YV12:
    case NVCV_COLOR_YUV2BGR_IYUV:
    case NVCV_COLOR_YUV2BGRA_YV12:
    case NVCV_COLOR_YUV2BGRA_IYUV:
    case NVCV_COLOR_YUV2RGB_YV12:
    case NVCV_COLOR_YUV2RGB_IYUV:
    case NVCV_COLOR_YUV2RGBA_YV12:
    case NVCV_COLOR_YUV2RGBA_IYUV:
    {
        yuv420p_to_bgr_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, dcn, bidx, uidx);
        checkKernelErrors();
    }
    break;
    default:
        LOG_ERROR("Unsupported conversion code " << code);
        return ErrorCode::INVALID_PARAMETER;
    }
    return ErrorCode::SUCCESS;
}

inline ErrorCode YUV422_to_BGR(const ITensorDataStridedCuda &inData, const ITensorDataStridedCuda &outData,
                               NVCVColorConversionCode code, cudaStream_t stream)
{
    int bidx
        = (code == NVCV_COLOR_YUV2BGR_YUY2 || code == NVCV_COLOR_YUV2BGRA_YUY2 || code == NVCV_COLOR_YUV2BGR_YVYU
           || code == NVCV_COLOR_YUV2BGRA_YVYU || code == NVCV_COLOR_YUV2BGR_UYVY || code == NVCV_COLOR_YUV2BGRA_UYVY)
            ? 0
            : 2;

    int yidx
        = (code == NVCV_COLOR_YUV2BGR_YUY2 || code == NVCV_COLOR_YUV2BGRA_YUY2 || code == NVCV_COLOR_YUV2RGB_YUY2
           || code == NVCV_COLOR_YUV2RGBA_YUY2 || code == NVCV_COLOR_YUV2BGR_YVYU || code == NVCV_COLOR_YUV2BGRA_YVYU
           || code == NVCV_COLOR_YUV2RGB_YVYU || code == NVCV_COLOR_YUV2RGBA_YVYU || code == NVCV_COLOR_YUV2GRAY_YUY2)
            ? 0
            : 1;

    int uidx
        = (code == NVCV_COLOR_YUV2BGR_YUY2 || code == NVCV_COLOR_YUV2BGRA_YUY2 || code == NVCV_COLOR_YUV2RGB_YUY2
           || code == NVCV_COLOR_YUV2RGBA_YUY2 || code == NVCV_COLOR_YUV2BGR_UYVY || code == NVCV_COLOR_YUV2BGRA_UYVY
           || code == NVCV_COLOR_YUV2RGB_UYVY || code == NVCV_COLOR_YUV2RGBA_UYVY)
            ? 0
            : 2;

    auto inAccess = TensorDataAccessStridedImagePlanar::Create(inData);
    NVCV_ASSERT(inAccess);

    cuda_op::DataType  inDataType = helpers::GetLegacyDataType(inData.dtype());
    cuda_op::DataShape inputShape = helpers::GetLegacyDataShape(inAccess->infoShape());

    auto outAccess = TensorDataAccessStridedImagePlanar::Create(outData);
    NVCV_ASSERT(outAccess);

    cuda_op::DataType  outDataType = helpers::GetLegacyDataType(outData.dtype());
    cuda_op::DataShape outputShape = helpers::GetLegacyDataShape(outAccess->infoShape());

    if (outputShape.C != 3 && outputShape.C != 4)
    {
        LOG_ERROR("Invalid output channel number " << outputShape.C);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (inputShape.C != 2)
    {
        LOG_ERROR("Invalid input channel number " << inputShape.C);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (inDataType != kCV_8U || outDataType != kCV_8U)
    {
        LOG_ERROR("Unsupported input/output DataType " << inDataType << "/" << outDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }
    if (outputShape.H != inputShape.H || outputShape.W != inputShape.W || outputShape.N != inputShape.N)
    {
        LOG_ERROR("Invalid output shape " << outputShape);
        return ErrorCode::INVALID_DATA_SHAPE;
    }

    dim3 blockSize(BLOCK, BLOCK / 4, 1);
    dim3 gridSize(divUp(inputShape.W, blockSize.x), divUp(inputShape.H, blockSize.y), inputShape.N);

    int2 dstSize{outputShape.W, outputShape.H};
    int  dcn = outputShape.C;

    auto srcWrap = cuda::CreateTensorWrapNHWC<uint8_t>(inData);
    auto dstWrap = cuda::CreateTensorWrapNHWC<uint8_t>(outData);

    switch (code)
    {
    case NVCV_COLOR_YUV2GRAY_YUY2:
    case NVCV_COLOR_YUV2GRAY_UYVY:
    {
        yuv422_to_gray_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, yidx);
        checkKernelErrors();
    }
    break;
    case NVCV_COLOR_YUV2BGR_YUY2:
    case NVCV_COLOR_YUV2BGR_YVYU:
    case NVCV_COLOR_YUV2BGRA_YUY2:
    case NVCV_COLOR_YUV2BGRA_YVYU:
    case NVCV_COLOR_YUV2RGB_YUY2:
    case NVCV_COLOR_YUV2RGB_YVYU:
    case NVCV_COLOR_YUV2RGBA_YUY2:
    case NVCV_COLOR_YUV2RGBA_YVYU:
    case NVCV_COLOR_YUV2RGB_UYVY:
    case NVCV_COLOR_YUV2BGR_UYVY:
    case NVCV_COLOR_YUV2RGBA_UYVY:
    case NVCV_COLOR_YUV2BGRA_UYVY:
    {
        yuv422_to_bgr_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, dstSize, dcn, bidx, yidx, uidx);
        checkKernelErrors();
    }
    break;
    default:
        LOG_ERROR("Unsupported conversion code " << code);
        return ErrorCode::INVALID_PARAMETER;
    }
    return ErrorCode::SUCCESS;
}

template<class SrcWrapper, class DstWrapper>
inline static void bgr_to_yuv420p_launcher(SrcWrapper srcWrap, DstWrapper dstWrap, DataShape inputShape, int bidx,
                                           int uidx, cudaStream_t stream)
{
    int2 srcSize{inputShape.W, inputShape.H};
    // method 1
    dim3 blockSize(BLOCK, BLOCK / 1, 1);
    dim3 gridSize(divUp(inputShape.W, blockSize.x), divUp(inputShape.H, blockSize.y), inputShape.N);
    bgr_to_yuv420p_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, srcSize, inputShape.C, bidx, uidx);
    checkKernelErrors();

    // method 2 (TODO)
    // NPP
}

template<class SrcWrapper, class DstWrapper>
inline static void bgr_to_yuv420sp_launcher(SrcWrapper srcWrap, DstWrapper dstWrap, DataShape inputShape, int bidx,
                                            int uidx, cudaStream_t stream)
{
    int2 srcSize{inputShape.W, inputShape.H};
    // method 1
    dim3 blockSize(BLOCK, BLOCK / 1, 1);
    dim3 gridSize(divUp(inputShape.W, blockSize.x), divUp(inputShape.H, blockSize.y), inputShape.N);
    bgr_to_yuv420sp_char_nhwc<<<gridSize, blockSize, 0, stream>>>(srcWrap, dstWrap, srcSize, inputShape.C, bidx, uidx);
    checkKernelErrors();

    // method 2 (TODO)
    // NPP
}

inline ErrorCode BGR_to_YUV420xp(const ITensorDataStridedCuda &inData, const ITensorDataStridedCuda &outData,
                                 NVCVColorConversionCode code, cudaStream_t stream)
{
    int bidx
        = (code == NVCV_COLOR_BGR2YUV_NV12 || code == NVCV_COLOR_BGRA2YUV_NV12 || code == NVCV_COLOR_BGR2YUV_NV21
           || code == NVCV_COLOR_BGRA2YUV_NV21 || code == NVCV_COLOR_BGR2YUV_YV12 || code == NVCV_COLOR_BGRA2YUV_YV12
           || code == NVCV_COLOR_BGR2YUV_IYUV || code == NVCV_COLOR_BGRA2YUV_IYUV)
            ? 0
            : 2;

    int uidx
        = (code == NVCV_COLOR_BGR2YUV_NV12 || code == NVCV_COLOR_BGRA2YUV_NV12 || code == NVCV_COLOR_RGB2YUV_NV12
           || code == NVCV_COLOR_RGBA2YUV_NV12 || code == NVCV_COLOR_BGR2YUV_IYUV || code == NVCV_COLOR_BGRA2YUV_IYUV
           || code == NVCV_COLOR_RGB2YUV_IYUV || code == NVCV_COLOR_RGBA2YUV_IYUV)
            ? 0
            : 1;

    auto inAccess = TensorDataAccessStridedImagePlanar::Create(inData);
    NVCV_ASSERT(inAccess);

    cuda_op::DataType  inDataType = helpers::GetLegacyDataType(inData.dtype());
    cuda_op::DataShape inputShape = helpers::GetLegacyDataShape(inAccess->infoShape());

    auto outAccess = TensorDataAccessStridedImagePlanar::Create(outData);
    NVCV_ASSERT(outAccess);

    cuda_op::DataType  outDataType = helpers::GetLegacyDataType(outData.dtype());
    cuda_op::DataShape outputShape = helpers::GetLegacyDataShape(outAccess->infoShape());

    if (inputShape.C != 3 && inputShape.C != 4)
    {
        LOG_ERROR("Invalid input channel number " << inputShape.C);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (inputShape.H % 2 != 0 || inputShape.W % 2 != 0)
    {
        LOG_ERROR("Invalid input shape " << inputShape);
        return ErrorCode::INVALID_DATA_SHAPE;
    }
    if (inDataType != kCV_8U || outDataType != kCV_8U)
    {
        LOG_ERROR("Unsupported input/output DataType " << inDataType << "/" << outDataType);
        return ErrorCode::INVALID_DATA_TYPE;
    }

    int yuv420_width  = inputShape.W;
    int yuv420_height = inputShape.H / 2 * 3;

    if (outputShape.H != yuv420_height || outputShape.W != yuv420_width || outputShape.N != inputShape.N)
    {
        LOG_ERROR("Invalid output shape " << outputShape);
        return ErrorCode::INVALID_DATA_SHAPE;
    }

    // BGR input
    auto srcWrap = cuda::CreateTensorWrapNHWC<uint8_t>(inData);
    // YUV420 output
    auto dstWrap = cuda::CreateTensorWrapNHWC<uint8_t>(outData);

    switch (code)
    {
    case NVCV_COLOR_BGR2YUV_NV12:
    case NVCV_COLOR_BGR2YUV_NV21:
    case NVCV_COLOR_BGRA2YUV_NV12:
    case NVCV_COLOR_BGRA2YUV_NV21:
    case NVCV_COLOR_RGB2YUV_NV12:
    case NVCV_COLOR_RGB2YUV_NV21:
    case NVCV_COLOR_RGBA2YUV_NV12:
    case NVCV_COLOR_RGBA2YUV_NV21:
    {
        bgr_to_yuv420sp_launcher(srcWrap, dstWrap, inputShape, bidx, uidx, stream);
        checkKernelErrors();
    }
    break;
    case NVCV_COLOR_BGR2YUV_YV12:
    case NVCV_COLOR_BGR2YUV_IYUV:
    case NVCV_COLOR_BGRA2YUV_YV12:
    case NVCV_COLOR_BGRA2YUV_IYUV:
    case NVCV_COLOR_RGB2YUV_YV12:
    case NVCV_COLOR_RGB2YUV_IYUV:
    case NVCV_COLOR_RGBA2YUV_YV12:
    case NVCV_COLOR_RGBA2YUV_IYUV:
    {
        bgr_to_yuv420p_launcher(srcWrap, dstWrap, inputShape, bidx, uidx, stream);
        checkKernelErrors();
    }
    break;
    default:
        LOG_ERROR("Unsupported conversion code " << code);
        return ErrorCode::INVALID_PARAMETER;
    }
    return ErrorCode::SUCCESS;
}

size_t CvtColor::calBufferSize(DataShape max_input_shape, DataShape max_output_shape, DataType max_data_type)
{
    return 0;
}

ErrorCode CvtColor::infer(const ITensorDataStridedCuda &inData, const ITensorDataStridedCuda &outData,
                          NVCVColorConversionCode code, cudaStream_t stream)
{
    DataFormat input_format  = helpers::GetLegacyDataFormat(inData.layout());
    DataFormat output_format = helpers::GetLegacyDataFormat(outData.layout());

    if (input_format != output_format)
    {
        LOG_ERROR("Invalid DataFormat between input (" << input_format << ") and output (" << output_format << ")");
        return ErrorCode::INVALID_DATA_FORMAT;
    }

    DataFormat format = input_format;

    if (!(format == kNHWC || format == kHWC))
    {
        LOG_ERROR("Invalid DataFormat " << format);
        return ErrorCode::INVALID_DATA_FORMAT;
    }

    typedef ErrorCode (*func_t)(const ITensorDataStridedCuda &inData, const ITensorDataStridedCuda &outData,
                                NVCVColorConversionCode code, cudaStream_t stream);

    static const func_t funcs[] = {
        BGR_to_RGB, // CV_BGR2BGRA    =0
        BGR_to_RGB, // CV_BGRA2BGR    =1
        BGR_to_RGB, // CV_BGR2RGBA    =2
        BGR_to_RGB, // CV_RGBA2BGR    =3
        BGR_to_RGB, // CV_BGR2RGB     =4
        BGR_to_RGB, // CV_BGRA2RGBA   =5

        BGR_to_GRAY, // CV_BGR2GRAY    =6
        BGR_to_GRAY, // CV_RGB2GRAY    =7
        GRAY_to_BGR, // CV_GRAY2BGR    =8
        0,           //GRAY_to_BGRA,           // CV_GRAY2BGRA   =9
        0,           //BGRA_to_GRAY,           // CV_BGRA2GRAY   =10
        0,           //RGBA_to_GRAY,           // CV_RGBA2GRAY   =11

        0, //BGR_to_BGR565,          // CV_BGR2BGR565  =12
        0, //RGB_to_BGR565,          // CV_RGB2BGR565  =13
        0, //BGR565_to_BGR,          // CV_BGR5652BGR  =14
        0, //BGR565_to_RGB,          // CV_BGR5652RGB  =15
        0, //BGRA_to_BGR565,         // CV_BGRA2BGR565 =16
        0, //RGBA_to_BGR565,         // CV_RGBA2BGR565 =17
        0, //BGR565_to_BGRA,         // CV_BGR5652BGRA =18
        0, //BGR565_to_RGBA,         // CV_BGR5652RGBA =19

        0, //GRAY_to_BGR565,         // CV_GRAY2BGR565 =20
        0, //BGR565_to_GRAY,         // CV_BGR5652GRAY =21

        0, //BGR_to_BGR555,          // CV_BGR2BGR555  =22
        0, //RGB_to_BGR555,          // CV_RGB2BGR555  =23
        0, //BGR555_to_BGR,          // CV_BGR5552BGR  =24
        0, //BGR555_to_RGB,          // CV_BGR5552RGB  =25
        0, //BGRA_to_BGR555,         // CV_BGRA2BGR555 =26
        0, //RGBA_to_BGR555,         // CV_RGBA2BGR555 =27
        0, //BGR555_to_BGRA,         // CV_BGR5552BGRA =28
        0, //BGR555_to_RGBA,         // CV_BGR5552RGBA =29

        0, //GRAY_to_BGR555,         // CV_GRAY2BGR555 =30
        0, //BGR555_to_GRAY,         // CV_BGR5552GRAY =31

        0, //BGR_to_XYZ,             // CV_BGR2XYZ     =32
        0, //RGB_to_XYZ,             // CV_RGB2XYZ     =33
        0, //XYZ_to_BGR,             // CV_XYZ2BGR     =34
        0, //XYZ_to_RGB,             // CV_XYZ2RGB     =35

        0, //BGR_to_YCrCb,           // CV_BGR2YCrCb   =36
        0, //RGB_to_YCrCb,           // CV_RGB2YCrCb   =37
        0, //YCrCb_to_BGR,           // CV_YCrCb2BGR   =38
        0, //YCrCb_to_RGB,           // CV_YCrCb2RGB   =39

        BGR_to_HSV, //BGR_to_HSV,             // CV_BGR2HSV     =40
        BGR_to_HSV, //RGB_to_HSV,             // CV_RGB2HSV     =41

        0, //                =42
        0, //                =43

        0, //BGR_to_Lab,             // CV_BGR2Lab     =44
        0, //RGB_to_Lab,             // CV_RGB2Lab     =45

        0, //bayerBG_to_BGR,         // CV_BayerBG2BGR =46
        0, //bayeRGB_to_BGR,         // CV_BayeRGB2BGR =47
        0, //bayerRG_to_BGR,         // CV_BayerRG2BGR =48
        0, //bayerGR_to_BGR,         // CV_BayerGR2BGR =49

        0, //BGR_to_Luv,             // CV_BGR2Luv     =50
        0, //RGB_to_Luv,             // CV_RGB2Luv     =51

        0, //BGR_to_HLS,             // CV_BGR2HLS     =52
        0, //RGB_to_HLS,             // CV_RGB2HLS     =53

        HSV_to_BGR, // CV_HSV2BGR     =54
        HSV_to_BGR, // CV_HSV2RGB     =55

        0, //Lab_to_BGR,             // CV_Lab2BGR     =56
        0, //Lab_to_RGB,             // CV_Lab2RGB     =57
        0, //Luv_to_BGR,             // CV_Luv2BGR     =58
        0, //Luv_to_RGB,             // CV_Luv2RGB     =59

        0, //HLS_to_BGR,             // CV_HLS2BGR     =60
        0, //HLS_to_RGB,             // CV_HLS2RGB     =61

        0, // CV_BayerBG2BGR_VNG =62
        0, // CV_BayeRGB2BGR_VNG =63
        0, // CV_BayerRG2BGR_VNG =64
        0, // CV_BayerGR2BGR_VNG =65

        BGR_to_HSV, //BGR_to_HSV_FULL,        // CV_BGR2HSV_FULL = 66
        BGR_to_HSV, //RGB_to_HSV_FULL,        // CV_RGB2HSV_FULL = 67
        0,          //BGR_to_HLS_FULL,        // CV_BGR2HLS_FULL = 68
        0,          //RGB_to_HLS_FULL,        // CV_RGB2HLS_FULL = 69

        HSV_to_BGR, // CV_HSV2BGR_FULL = 70
        HSV_to_BGR, // CV_HSV2RGB_FULL = 71
        0,          //HLS_to_BGR_FULL,        // CV_HLS2BGR_FULL = 72
        0,          //HLS_to_RGB_FULL,        // CV_HLS2RGB_FULL = 73

        0, //LBGR_to_Lab,            // CV_LBGR2Lab     = 74
        0, //LRGB_to_Lab,            // CV_LRGB2Lab     = 75
        0, //LBGR_to_Luv,            // CV_LBGR2Luv     = 76
        0, //LRGB_to_Luv,            // CV_LRGB2Luv     = 77

        0, //Lab_to_LBGR,            // CV_Lab2LBGR     = 78
        0, //Lab_to_LRGB,            // CV_Lab2LRGB     = 79
        0, //Luv_to_LBGR,            // CV_Luv2LBGR     = 80
        0, //Luv_to_LRGB,            // CV_Luv2LRGB     = 81

        BGR_to_YUV, // CV_BGR2YUV      = 82
        BGR_to_YUV, // CV_RGB2YUV      = 83
        YUV_to_BGR, // CV_YUV2BGR      = 84
        YUV_to_BGR, // CV_YUV2RGB      = 85

        0, //bayerBG_to_gray,        // CV_BayerBG2GRAY = 86
        0, //bayeRGB_to_GRAY,        // CV_BayeRGB2GRAY = 87
        0, //bayerRG_to_gray,        // CV_BayerRG2GRAY = 88
        0, //bayerGR_to_gray,        // CV_BayerGR2GRAY = 89

        //! YUV 4:2:0 family to RGB
        YUV420xp_to_BGR, // CV_YUV2RGB_NV12 = 90,
        YUV420xp_to_BGR, // CV_YUV2BGR_NV12 = 91,
        YUV420xp_to_BGR, // CV_YUV2RGB_NV21 = 92, CV_YUV420sp2RGB
        YUV420xp_to_BGR, // CV_YUV2BGR_NV21 = 93, CV_YUV420sp2BGR

        YUV420xp_to_BGR, // CV_YUV2RGBA_NV12 = 94,
        YUV420xp_to_BGR, // CV_YUV2BGRA_NV12 = 95,
        YUV420xp_to_BGR, // CV_YUV2RGBA_NV21 = 96, CV_YUV420sp2RGBA
        YUV420xp_to_BGR, // CV_YUV2BGRA_NV21 = 97, CV_YUV420sp2BGRA

        YUV420xp_to_BGR, // CV_YUV2RGB_YV12 = 98, CV_YUV420p2RGB
        YUV420xp_to_BGR, // CV_YUV2BGR_YV12 = 99, CV_YUV420p2BGR
        YUV420xp_to_BGR, // CV_YUV2RGB_IYUV = 100, CV_YUV2RGB_I420
        YUV420xp_to_BGR, // CV_YUV2BGR_IYUV = 101, CV_YUV2BGR_I420

        YUV420xp_to_BGR, // CV_YUV2RGBA_YV12 = 102, CV_YUV420p2RGBA
        YUV420xp_to_BGR, // CV_YUV2BGRA_YV12 = 103, CV_YUV420p2BGRA
        YUV420xp_to_BGR, // CV_YUV2RGBA_IYUV = 104, CV_YUV2RGBA_I420
        YUV420xp_to_BGR, // CV_YUV2BGRA_IYUV = 105, CV_YUV2BGRA_I420

        YUV420xp_to_BGR, // CV_YUV2GRAY_420 = 106,
        // CV_YUV2GRAY_NV21,
        // CV_YUV2GRAY_NV12,
        // CV_YUV2GRAY_YV12,
        // CV_YUV2GRAY_IYUV,
        // CV_YUV2GRAY_I420,
        // CV_YUV420sp2GRAY,
        // CV_YUV420p2GRAY ,

        //! YUV 4:2:2 family to RGB
        YUV422_to_BGR, // CV_YUV2RGB_UYVY = 107, CV_YUV2RGB_Y422, CV_YUV2RGB_UYNV
        YUV422_to_BGR, // CV_YUV2BGR_UYVY = 108, CV_YUV2BGR_Y422, CV_YUV2BGR_UYNV
        0,             // CV_YUV2RGB_VYUY = 109,
        0,             // CV_YUV2BGR_VYUY = 110,

        YUV422_to_BGR, // CV_YUV2RGBA_UYVY = 111, CV_YUV2RGBA_Y422, CV_YUV2RGBA_UYNV
        YUV422_to_BGR, // CV_YUV2BGRA_UYVY = 112, CV_YUV2BGRA_Y422, CV_YUV2BGRA_UYNV
        0,             // CV_YUV2RGBA_VYUY = 113,
        0,             // CV_YUV2BGRA_VYUY = 114,

        YUV422_to_BGR, // CV_YUV2RGB_YUY2 = 115, CV_YUV2RGB_YUYV, CV_YUV2RGB_YUNV
        YUV422_to_BGR, // CV_YUV2BGR_YUY2 = 116, CV_YUV2BGR_YUYV, CV_YUV2BGR_YUNV
        YUV422_to_BGR, // CV_YUV2RGB_YVYU = 117,
        YUV422_to_BGR, // CV_YUV2BGR_YVYU = 118,

        YUV422_to_BGR, // CV_YUV2RGBA_YUY2 = 119, CV_YUV2RGBA_YUYV, CV_YUV2RGBA_YUNV
        YUV422_to_BGR, // CV_YUV2BGRA_YUY2 = 120, CV_YUV2BGRA_YUYV, CV_YUV2BGRA_YUNV
        YUV422_to_BGR, // CV_YUV2RGBA_YVYU = 121,
        YUV422_to_BGR, // CV_YUV2BGRA_YVYU = 122,

        YUV422_to_BGR, // CV_YUV2GRAY_UYVY = 123, CV_YUV2GRAY_Y422, CV_YUV2GRAY_UYNV
        YUV422_to_BGR, // CV_YUV2GRAY_YUY2 = 124, CV_YUV2GRAY_YVYU, CV_YUV2GRAY_YUYV, CV_YUV2GRAY_YUNV

        //! alpha premultiplication
        0, //RGBA_to_mBGRA,         // CV_RGBA2mRGBA = 125,
        0, // CV_mRGBA2RGBA = 126,

        //! RGB to YUV 4:2:0 family (three plane YUV)
        BGR_to_YUV420xp, // CV_RGB2YUV_I420  = 127, CV_RGB2YUV_IYUV
        BGR_to_YUV420xp, // CV_BGR2YUV_I420  = 128, CV_BGR2YUV_IYUV

        BGR_to_YUV420xp, // CV_RGBA2YUV_I420 = 129, CV_RGBA2YUV_IYUV
        BGR_to_YUV420xp, // CV_BGRA2YUV_I420 = 130, CV_BGRA2YUV_IYUV
        BGR_to_YUV420xp, // CV_RGB2YUV_YV12  = 131,
        BGR_to_YUV420xp, // CV_BGR2YUV_YV12  = 132,
        BGR_to_YUV420xp, // CV_RGBA2YUV_YV12 = 133,
        BGR_to_YUV420xp, // CV_BGRA2YUV_YV12 = 134,

        //! Edge-Aware Demosaicing
        0, // CV_BayerBG2BGR_EA  = 135,
        0, // CV_BayerGB2BGR_EA  = 136,
        0, // CV_BayerRG2BGR_EA  = 137,
        0, // CV_BayerGR2BGR_EA  = 138,

        0, // OpenCV COLORCVT_MAX = 139

        //! RGB to YUV 4:2:0 family (two plane YUV, not in OpenCV)
        BGR_to_YUV420xp, // CV_RGB2YUV_NV12 = 140,
        BGR_to_YUV420xp, // CV_BGR2YUV_NV12 = 141,
        BGR_to_YUV420xp, // CV_RGB2YUV_NV21 = 142, CV_RGB2YUV420sp
        BGR_to_YUV420xp, // CV_BGR2YUV_NV21 = 143, CV_BGR2YUV420sp

        BGR_to_YUV420xp, // CV_RGBA2YUV_NV12 = 144,
        BGR_to_YUV420xp, // CV_BGRA2YUV_NV12 = 145,
        BGR_to_YUV420xp, // CV_RGBA2YUV_NV21 = 146, CV_RGBA2YUV420sp
        BGR_to_YUV420xp, // CV_BGRA2YUV_NV21 = 147, CV_BGRA2YUV420sp

        0, // CV_COLORCVT_MAX  = 148
    };

    func_t func = funcs[code];

    if (func == 0)
    {
        LOG_ERROR("Invalid convert color code: " << code);
        return ErrorCode::INVALID_PARAMETER;
    }

    return func(inData, outData, code, stream);
}

} // namespace nvcv::legacy::cuda_op
