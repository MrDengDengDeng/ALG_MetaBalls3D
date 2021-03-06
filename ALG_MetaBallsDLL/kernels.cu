#include <stdio.h>
#include <string.h>

#include <cuda_runtime_api.h>

#include <thrust/device_vector.h>
#include <thrust/scan.h>
#include <device_launch_parameters.h>

#include <helper_cuda.h>
#include <helper_math.h>

#include "tables.h"

// compute values of each corner point
// 
//__device__ float computeValue(float3* samplePts, float3 testP, uint sampleLength)
//{
//    float result = 0.0f;
//    float Dx, Dy, Dz;
//
//    for (int j = 0; j < sampleLength; j++)
//    {
//        Dx = testP.x - samplePts[j].x;
//        Dy = testP.y - samplePts[j].y;
//        Dz = testP.z - samplePts[j].z;
//
//        //result += 1.0f / (abs(Dx)+abs(Dy)+abs(Dz));
//        result += 1.0f / (Dx * Dx + Dy * Dy + Dz * Dz);
//    }
//    return result;
//}
//__device__ float computeValue(float3* samplePts, float3 testP, uint sampleLength, float radius)
//{
//    float result = 0.0f;
//    float Dx, Dy, Dz;
//
//    for (int j = 0; j < sampleLength; j++)
//    {
//        Dx = testP.x - samplePts[j].x;
//        Dy = testP.y - samplePts[j].y;
//        Dz = testP.z - samplePts[j].z;
//
//        float di = Dx * Dx + Dy * Dy + Dz * Dz;
//        if (di < radius)
//        {
//            float a = di / radius;
//            result += (1.0 - a * a) * (1.0 - a * a);
//        }
//    }
//    return result;
//}
// Field Function for Soft Object
__device__ float computeValue(float3* samplePts, float3 testP, uint sampleLength, float radius)
{
    float result = 0.0f;
    float Dx, Dy, Dz;

    for (int j = 0; j < sampleLength; j++)
    {
        Dx = testP.x - samplePts[j].x;
        Dy = testP.y - samplePts[j].y;
        Dz = testP.z - samplePts[j].z;

        float di = Dx * Dx + Dy * Dy + Dz * Dz;
        if (di <= radius)
        {
            float a = di / radius;
            result += (1.0f - (a * a * a * a * a * a * 4.0f / 9.0f) + (a * a * a * a * 17.0f / 9.0f) - (a * a * 22.0f / 9.0f));
        }
    }
    return result;
}
// compute 3d index in the grid from 1d index
__device__ uint3 calcGridPos(uint i, uint3 gridSize)
{
    uint3 gridPos;

    gridPos.z = i / (gridSize.x * gridSize.y);
    gridPos.y = i % (gridSize.x * gridSize.y) / gridSize.x;
    gridPos.x = i % (gridSize.x * gridSize.y) % gridSize.x;
    return gridPos;
}
__device__ float calcOffsetValue(float Value1, float Value2, float ValueDesired)
{
    if ((Value2 - Value1) == 0.0f)
        return 0.5f;

    return (ValueDesired - Value1) / (Value2 - Value1);
}

// classify voxel
__global__ void classifyVoxel(uint* voxelVerts, uint* voxelOccupied, uint3 gridSize,
    uint numVoxels, float3 basePoint, float3 voxelSize,
    float isoValue, float3* samplePts, uint sampleLength,float fusion)
{
    uint blockId = blockIdx.y * gridDim.x + blockIdx.x;
    uint i = blockId * blockDim.x + threadIdx.x;

    uint3 gridPos = calcGridPos(i, gridSize);

    float3 p;
    p.x = basePoint.x + gridPos.x * voxelSize.x;
    p.y = basePoint.y + gridPos.y * voxelSize.y;
    p.z = basePoint.z + gridPos.z * voxelSize.z;

     float distance = voxelSize.x * voxelSize.x + voxelSize.y * voxelSize.y + voxelSize.z * voxelSize.z;
     float radius = distance * fusion;

    float field0 = computeValue(samplePts, p, sampleLength, radius);
    float field1 = computeValue(samplePts, make_float3(voxelSize.x + p.x, 0.0f + p.y, 0.0f + p.z), sampleLength, radius);
    float field2 = computeValue(samplePts, make_float3(voxelSize.x + p.x, voxelSize.y + p.y, 0.0f + p.z), sampleLength, radius);
    float field3 = computeValue(samplePts, make_float3(0.0f + p.x, voxelSize.y + p.y, 0.0f + p.z), sampleLength, radius);
    float field4 = computeValue(samplePts, make_float3(0.0f + p.x, 0.0f + p.y, voxelSize.z + p.z), sampleLength, radius);
    float field5 = computeValue(samplePts, make_float3(voxelSize.x + p.x, 0.0f + p.y, voxelSize.z + p.z), sampleLength, radius);
    float field6 = computeValue(samplePts, make_float3(voxelSize.x + p.x, voxelSize.y + p.y, voxelSize.z + p.z), sampleLength, radius);
    float field7 = computeValue(samplePts, make_float3(0.0f + p.x, voxelSize.y + p.y, voxelSize.z + p.z), sampleLength, radius);

    // calculate flag indicating if each vertex is inside or outside isosurface
    uint cubeindex;
    cubeindex = uint(field0 < isoValue);
    cubeindex += uint(field1 < isoValue) * 2;
    cubeindex += uint(field2 < isoValue) * 4;
    cubeindex += uint(field3 < isoValue) * 8;
    cubeindex += uint(field4 < isoValue) * 16;
    cubeindex += uint(field5 < isoValue) * 32;
    cubeindex += uint(field6 < isoValue) * 64;
    cubeindex += uint(field7 < isoValue) * 128;

    // read number of vertices from texture
    uint numVerts = numVertsTable[cubeindex];

    if (i < numVoxels)
    {
        voxelVerts[i] = numVerts;
        if ((numVerts > 0))
        {
            voxelOccupied[i] = 1;
        }
    }
}

// compact voxel array
__global__ void compactVoxels(uint* compactedVoxelArray, uint* voxelOccupied, uint* voxelOccupiedScan, uint numVoxels)
{
    uint blockId = __mul24(blockIdx.y, gridDim.x) + blockIdx.x;
    uint i = __mul24(blockId, blockDim.x) + threadIdx.x;

    if (voxelOccupied[i] && (i < numVoxels))
    {
        compactedVoxelArray[voxelOccupiedScan[i]] = i;
    }
}

__global__ void extractIsosurface(float3* result, uint* compactedVoxelArray, uint* numVertsScanned,
    uint3 gridSize, float3 basePoint, float3 voxelSize, float isoValue, float scale,
    float3* samplePts, uint sampleLength, float fusion)
{
    uint blockId = __mul24(blockIdx.y, gridDim.x) + blockIdx.x;
    uint i = __mul24(blockId, blockDim.x) + threadIdx.x;

    // compute position in 3d grid
    uint3 gridPos = calcGridPos(compactedVoxelArray[i], gridSize);

    float3 p;
    p.x = basePoint.x + gridPos.x * voxelSize.x;
    p.y = basePoint.y + gridPos.y * voxelSize.y;
    p.z = basePoint.z + gridPos.z * voxelSize.z;

    float distance = voxelSize.x * voxelSize.x + voxelSize.y * voxelSize.y + voxelSize.z * voxelSize.z;
    float radius = distance * fusion;

    float field[8];
    field[0] = computeValue(samplePts, p, sampleLength, radius);
    field[1] = computeValue(samplePts, make_float3(voxelSize.x + p.x, 0.0f + p.y, 0.0f + p.z), sampleLength, radius);
    field[2] = computeValue(samplePts, make_float3(voxelSize.x + p.x, voxelSize.y + p.y, 0.0f + p.z), sampleLength, radius);
    field[3] = computeValue(samplePts, make_float3(0.0f + p.x, voxelSize.y + p.y, 0.0f + p.z), sampleLength, radius);
    field[4] = computeValue(samplePts, make_float3(0.0f + p.x, 0.0f + p.y, voxelSize.z + p.z), sampleLength, radius);
    field[5] = computeValue(samplePts, make_float3(voxelSize.x + p.x, 0.0f + p.y, voxelSize.z + p.z), sampleLength, radius);
    field[6] = computeValue(samplePts, make_float3(voxelSize.x + p.x, voxelSize.y + p.y, voxelSize.z + p.z), sampleLength, radius);
    field[7] = computeValue(samplePts, make_float3(0.0f + p.x, voxelSize.y + p.y, voxelSize.z + p.z), sampleLength, radius);

    // calculate flag indicating if each vertex is inside or outside isosurface
    uint cubeindex;
    cubeindex = uint(field[0] < isoValue);
    cubeindex += uint(field[1] < isoValue) * 2;
    cubeindex += uint(field[2] < isoValue) * 4;
    cubeindex += uint(field[3] < isoValue) * 8;
    cubeindex += uint(field[4] < isoValue) * 16;
    cubeindex += uint(field[5] < isoValue) * 32;
    cubeindex += uint(field[6] < isoValue) * 64;
    cubeindex += uint(field[7] < isoValue) * 128;

    float3 vertlist[12];
    float offsetV[12];

    //compute t values from two end points on each edge
    offsetV[0] = calcOffsetValue(field[0], field[1], isoValue);
    offsetV[1] = calcOffsetValue(field[1], field[2], isoValue);
    offsetV[2] = calcOffsetValue(field[2], field[3], isoValue);
    offsetV[3] = calcOffsetValue(field[3], field[0], isoValue);
    offsetV[4] = calcOffsetValue(field[4], field[5], isoValue);
    offsetV[5] = calcOffsetValue(field[5], field[6], isoValue);
    offsetV[6] = calcOffsetValue(field[6], field[7], isoValue);
    offsetV[7] = calcOffsetValue(field[7], field[4], isoValue);
    offsetV[8] = calcOffsetValue(field[0], field[4], isoValue);
    offsetV[9] = calcOffsetValue(field[1], field[5], isoValue);
    offsetV[10] = calcOffsetValue(field[2], field[6], isoValue);
    offsetV[11] = calcOffsetValue(field[3], field[7], isoValue);

    // compute the position of all vertices
    vertlist[0].x = basePoint.x + (gridPos.x + 0.0f + offsetV[0] * 1.0f) * scale;
    vertlist[0].y = basePoint.y + (gridPos.y + 0.0f + offsetV[0] * 0.0f) * scale;
    vertlist[0].z = basePoint.z + (gridPos.z + 0.0f + offsetV[0] * 0.0f) * scale;

    vertlist[1].x = basePoint.x + (gridPos.x + 1.0f + offsetV[1] * 0.0f) * scale;
    vertlist[1].y = basePoint.y + (gridPos.y + 0.0f + offsetV[1] * 1.0f) * scale;
    vertlist[1].z = basePoint.z + (gridPos.z + 0.0f + offsetV[1] * 0.0f) * scale;

    vertlist[2].x = basePoint.x + (gridPos.x + 1.0f + offsetV[2] * -1.0f) * scale;
    vertlist[2].y = basePoint.y + (gridPos.y + 1.0f + offsetV[2] * 0.0f) * scale;
    vertlist[2].z = basePoint.z + (gridPos.z + 0.0f + offsetV[2] * 0.0f) * scale;

    vertlist[3].x = basePoint.x + (gridPos.x + 0.0f + offsetV[3] * 0.0f) * scale;
    vertlist[3].y = basePoint.y + (gridPos.y + 1.0f + offsetV[3] * -1.0f) * scale;
    vertlist[3].z = basePoint.z + (gridPos.z + 0.0f + offsetV[3] * 0.0f) * scale;

    vertlist[4].x = basePoint.x + (gridPos.x + 0.0f + offsetV[4] * 1.0f) * scale;
    vertlist[4].y = basePoint.y + (gridPos.y + 0.0f + offsetV[4] * 0.0f) * scale;
    vertlist[4].z = basePoint.z + (gridPos.z + 1.0f + offsetV[4] * 0.0f) * scale;

    vertlist[5].x = basePoint.x + (gridPos.x + 1.0f + offsetV[5] * 0.0f) * scale;
    vertlist[5].y = basePoint.y + (gridPos.y + 0.0f + offsetV[5] * 1.0f) * scale;
    vertlist[5].z = basePoint.z + (gridPos.z + 1.0f + offsetV[5] * 0.0f) * scale;

    vertlist[6].x = basePoint.x + (gridPos.x + 1.0f + offsetV[6] * -1.0f) * scale;
    vertlist[6].y = basePoint.y + (gridPos.y + 1.0f + offsetV[6] * 0.0f) * scale;
    vertlist[6].z = basePoint.z + (gridPos.z + 1.0f + offsetV[6] * 0.0f) * scale;

    vertlist[7].x = basePoint.x + (gridPos.x + 0.0f + offsetV[7] * 0.0f) * scale;
    vertlist[7].y = basePoint.y + (gridPos.y + 1.0f + offsetV[7] * -1.0f) * scale;
    vertlist[7].z = basePoint.z + (gridPos.z + 1.0f + offsetV[7] * 0.0f) * scale;

    vertlist[8].x = basePoint.x + (gridPos.x + 0.0f + offsetV[8] * 0.0f) * scale;
    vertlist[8].y = basePoint.y + (gridPos.y + 0.0f + offsetV[8] * 0.0f) * scale;
    vertlist[8].z = basePoint.z + (gridPos.z + 0.0f + offsetV[8] * 1.0f) * scale;

    vertlist[9].x = basePoint.x + (gridPos.x + 1.0f + offsetV[9] * 0.0f) * scale;
    vertlist[9].y = basePoint.y + (gridPos.y + 0.0f + offsetV[9] * 0.0f) * scale;
    vertlist[9].z = basePoint.z + (gridPos.z + 0.0f + offsetV[9] * 1.0f) * scale;

    vertlist[10].x = basePoint.x + (gridPos.x + 1.0f + offsetV[10] * 0.0f) * scale;
    vertlist[10].y = basePoint.y + (gridPos.y + 1.0f + offsetV[10] * 0.0f) * scale;
    vertlist[10].z = basePoint.z + (gridPos.z + 0.0f + offsetV[10] * 1.0f) * scale;

    vertlist[11].x = basePoint.x + (gridPos.x + 0.0f + offsetV[11] * 0.0f) * scale;
    vertlist[11].y = basePoint.y + (gridPos.y + 1.0f + offsetV[11] * 0.0f) * scale;
    vertlist[11].z = basePoint.z + (gridPos.z + 0.0f + offsetV[11] * 1.0f) * scale;

    // read number of vertices from texture
    uint numVerts = numVertsTable[cubeindex];

    for (int j = 0; j < numVerts; j++)
    {
        //find out which edge intersects the isosurface
        uint edge = triTable[cubeindex * 16 + j];
        uint index = numVertsScanned[compactedVoxelArray[i]] + j;

        result[index] = vertlist[edge];
    }
}

#pragma region pass methods


extern "C" void launch_classifyVoxel(dim3 grid, dim3 threads, uint * voxelVerts, uint * voxelOccupied, uint3 gridSize,
    uint numVoxels, float3 basePoint, float3 voxelSize,
    float isoValue, float3 * samplePts, uint sampleLength,float fusion)
{
    // calculate number of vertices need per voxel
    classifyVoxel << <grid, threads >> > (voxelVerts, voxelOccupied, gridSize,
        numVoxels, basePoint, voxelSize,
        isoValue, samplePts, sampleLength, fusion);
    getLastCudaError("classifyVoxel failed");
}

extern "C" void launch_compactVoxels(dim3 grid, dim3 threads, uint * compactedVoxelArray, uint * voxelOccupied, uint * voxelOccupiedScan, uint numVoxels)
{
    compactVoxels << <grid, threads >> > (compactedVoxelArray, voxelOccupied,
        voxelOccupiedScan, numVoxels);
    getLastCudaError("compactVoxels failed");
}

extern "C" void exclusiveSumScan(uint * output, uint * input, uint numElements)
{
    thrust::exclusive_scan(thrust::device_ptr<uint>(input),
        thrust::device_ptr<uint>(input + numElements),
        thrust::device_ptr<uint>(output));
}

extern "C" void launch_extractIsosurface(dim3 grid, dim3 threads,
    float3 * result, uint * compactedVoxelArray, uint * numVertsScanned,
    uint3 gridSize, float3 basePoint, float3 voxelSize, float isoValue, float scale,
    float3 * samplePts, uint sampleLength, float fusion)
{
    extractIsosurface << <grid, threads >> > (result, compactedVoxelArray, numVertsScanned,
        gridSize, basePoint, voxelSize, isoValue, scale,
        samplePts, sampleLength, fusion);
    getLastCudaError("extract Isosurface failed");
}
#pragma endregion
