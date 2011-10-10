#pragma once

#include "Transport.cuh"
#include "CudaUtilities.h"

#define KRNL_SS_BLOCK_W		32
#define KRNL_SS_BLOCK_H		8
#define KRNL_SS_BLOCK_SIZE	KRNL_SS_BLOCK_W * KRNL_SS_BLOCK_H

KERNEL void KrnlSingleScattering(CScene* pScene, int* pSeeds)
{
	const int X		= blockIdx.x * blockDim.x + threadIdx.x;
	const int Y		= blockIdx.y * blockDim.y + threadIdx.y;
	const int PID	= Y * gFilmWidth + X;

	if (X >= gFilmWidth || Y >= gFilmHeight || PID >= gFilmNoPixels)
		return;
	
	CRNG RNG(&pSeeds[2 * PID], &pSeeds[2 * PID + 1]);

	CColorXyz Lv = SPEC_BLACK, Li = SPEC_BLACK;

	CRay Re;
	
	const Vec2f UV = Vec2f(X, Y) + RNG.Get2();

 	pScene->m_Camera.GenerateRay(UV, RNG.Get2(), Re.m_O, Re.m_D);

	Re.m_MinT = 0.0f; 
	Re.m_MaxT = FLT_MAX;

	Vec3f Pe, Pl;
	
	CLight* pLight = NULL;

	if (SampleDistanceRM(Re, RNG, Pe, pScene))
	{
		if (NearestLight(pScene, CRay(Re.m_O, Re.m_D, 0.0f, (Pe - Re.m_O).Length()), Li, Pl, pLight))
		{
			float4 ColorXYZA = make_float4(Lv.c[0], Lv.c[1], Lv.c[2], 0.0f);
			surf2Dwrite(ColorXYZA, gSurfFrameEstimateXyza, X * sizeof(float4), Y);
			return;
		}
		 
		const float D = GetNormalizedIntensity(pScene, Pe);

		Lv += GetEmission(pScene, D).ToXYZ();

		switch (pScene->m_ShadingType)
		{
			case 0:
			{
				Lv += UniformSampleOneLight(pScene, D, Normalize(-Re.m_D), Pe, NormalizedGradient(pScene, Pe), RNG, true);
				break;
			}
		
			case 1:
			{
				Lv += 0.5f * UniformSampleOneLight(pScene, D, Normalize(-Re.m_D), Pe, NormalizedGradient(pScene, Pe), RNG, false);
				break;
			}

			case 2:
			{
				const float GradMag = GradientMagnitude(pScene, Pe) * gIntensityInvRange;

				const float PdfBrdf = (1.0f - __expf(-pScene->m_GradientFactor * GradMag));

				if (RNG.Get1() < PdfBrdf)
  					Lv += UniformSampleOneLight(pScene, D, Normalize(-Re.m_D), Pe, NormalizedGradient(pScene, Pe), RNG, true);
				else
 					Lv += 0.5f * UniformSampleOneLight(pScene, D, Normalize(-Re.m_D), Pe, NormalizedGradient(pScene, Pe), RNG, false);

				break;
			}
		}
	}
	else
	{
		if (NearestLight(pScene, CRay(Re.m_O, Re.m_D, 0.0f, INF_MAX), Li, Pl, pLight))
			Lv = Li;
	}
	
	__syncthreads();

	float4 ColorXYZA = make_float4(Lv.c[0], Lv.c[1], Lv.c[2], 0.0f);
	surf2Dwrite(ColorXYZA, gSurfFrameEstimateXyza, X * sizeof(float4), Y);
}

void SingleScattering(CScene* pScene, CScene* pDevScene, int* pSeeds)
{
	const dim3 KernelBlock(KRNL_SS_BLOCK_W, KRNL_SS_BLOCK_H);
	const dim3 KernelGrid((int)ceilf((float)pScene->m_Camera.m_Film.m_Resolution.GetResX() / (float)KernelBlock.x), (int)ceilf((float)pScene->m_Camera.m_Film.m_Resolution.GetResY() / (float)KernelBlock.y));
	
	KrnlSingleScattering<<<KernelGrid, KernelBlock>>>(pDevScene, pSeeds);
	HandleCudaError(cudaGetLastError());
}