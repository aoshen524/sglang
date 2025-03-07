#include <ATen/cuda/CUDAContext.h>
#include <c10/util/Float8_e4m3fn.h>

#include <cmath>
#include <cub/block/block_reduce.cuh>
#include <flashinfer/vec_dtypes.cuh>

#include "utils.h"

#define WARP_SIZE 32

#ifndef USE_ROCM
#include <c10/util/Float8_e4m3fn.h>
using FP8_TYPE = c10::Float8_e4m3fn;
C10_HOST_DEVICE constexpr auto FP8_E4M3_MAX = std::numeric_limits<FP8_TYPE>::max();
#else
#include <c10/util/Float8_e4m3fnuz.h>

#include "amd/quant_utils.cuh"
using FP8_TYPE = c10::Float8_e4m3fnuz;
// Using the default max value from pytorch (240.0) will cause accuracy
// issue when running dynamic quantization. Here use 224.0f for rocm.
constexpr auto FP8_E4M3_MAX = 224.0f;
#endif

__device__ __forceinline__ float warpReduceMax(float max_value) {
  max_value = fmaxf(max_value, __shfl_xor_sync(0xffffffff, max_value, 16));
  max_value = fmaxf(max_value, __shfl_xor_sync(0xffffffff, max_value, 8));
  max_value = fmaxf(max_value, __shfl_xor_sync(0xffffffff, max_value, 4));
  max_value = fmaxf(max_value, __shfl_xor_sync(0xffffffff, max_value, 2));
  max_value = fmaxf(max_value, __shfl_xor_sync(0xffffffff, max_value, 1));
  return max_value;
}

template <typename T>
__global__ void per_token_quant_fp8_kernel(const T* __restrict__ input, FP8_TYPE* __restrict__ output_q,
                                           float* __restrict__ output_s, const int64_t hidden_dim,
                                           const int64_t num_tokens) {
  const int token_idx = blockIdx.x;

  if (token_idx >= num_tokens) return;

  const int tid = threadIdx.x;
  const int block_dim = blockDim.x;

  const T* token_input = input + token_idx * hidden_dim;
  FP8_TYPE* token_output = output_q + token_idx * hidden_dim;

  float max_value = 0.0f;

  for (int i = tid; i < hidden_dim; i += block_dim) {
    float val = static_cast<float>(token_input[i]);
    max_value = fmaxf(max_value, fabsf(val));
  }

  max_value = warpReduceMax(max_value);

  static __shared__ float warpLevelMaxs[WARP_SIZE];
  const int laneId = threadIdx.x % WARP_SIZE;
  const int warpId = threadIdx.x / WARP_SIZE;

  if (laneId == 0) warpLevelMaxs[warpId] = max_value;
  __syncthreads();

  if (warpId == 0) {
    max_value = (threadIdx.x < blockDim.x / WARP_SIZE) ? warpLevelMaxs[laneId] : 0;
    max_value = warpReduceMax(max_value);
  }

  __shared__ float block_max;
  if (tid == 0) {
    block_max = max_value / FP8_E4M3_MAX;
    output_s[token_idx] = block_max;
  }
  __syncthreads();

  const float scale_val = 1.0f / block_max;

  constexpr uint32_t vec_size = 16 / sizeof(T);
  using vec_t = flashinfer::vec_t<T, vec_size>;

  const int32_t num_vec_elems = hidden_dim / vec_size;

  for (int32_t i = tid; i < num_vec_elems; i += block_dim) {
    vec_t input_vec;
    input_vec.cast_load(token_input + i * vec_size);

    FP8_TYPE output_arr[vec_size];
#pragma unroll
    for (uint32_t j = 0; j < vec_size; ++j) {
      float val = fmax(fmin(static_cast<float>(input_vec[j]) * scale_val, FP8_E4M3_MAX), -FP8_E4M3_MAX);
#ifndef USE_ROCM
      output_arr[j] = static_cast<FP8_TYPE>(val);
#else
      output_arr[j] = c10::Float8_e4m3fnuz(
          __hip_cvt_float_to_fp8(val, fp8::fp8_type::__default_saturation, fp8::fp8_type::__default_interpret),
          c10::Float8_e4m3fnuz::from_bits());
#endif
    }

#pragma unroll
    for (uint32_t j = 0; j < vec_size; ++j) {
      token_output[i * vec_size + j] = output_arr[j];
    }
  }

  const int32_t remaining_start = num_vec_elems * vec_size;
  for (int32_t idx = remaining_start + tid; idx < hidden_dim; idx += block_dim) {
    float val = fmax(-FP8_E4M3_MAX, fmin(static_cast<float>(token_input[idx]) * scale_val, FP8_E4M3_MAX));
#ifndef USE_ROCM
    token_output[idx] = static_cast<FP8_TYPE>(val);
#else
    token_output[idx] = c10::Float8_e4m3fnuz(
        __hip_cvt_float_to_fp8(val, fp8::fp8_type::__default_saturation, fp8::fp8_type::__default_interpret),
        c10::Float8_e4m3fnuz::from_bits());
#endif
  }
}

void sgl_per_token_quant_fp8(torch::Tensor input, torch::Tensor output_q, torch::Tensor output_s) {
  CHECK_INPUT(input);
  CHECK_INPUT(output_q);
  CHECK_INPUT(output_s);

  const auto input_sizes = input.sizes();
  const int64_t num_tokens = input_sizes[0];
  const int64_t hidden_dim = input_sizes[1];

  const int block_size = 128;
  const int num_blocks = num_tokens;

  dim3 grid(num_blocks);
  dim3 block(block_size);

  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  DISPATCH_PYTORCH_DTYPE_TO_CTYPE_FLOAT_FP16(input.scalar_type(), scalar_t, [&] {
    per_token_quant_fp8_kernel<scalar_t><<<grid, block, 0, stream>>>(
        static_cast<scalar_t*>(input.data_ptr()), static_cast<FP8_TYPE*>(output_q.data_ptr()),
        static_cast<float*>(output_s.data_ptr()), hidden_dim, num_tokens);
    return true;
  });
}
