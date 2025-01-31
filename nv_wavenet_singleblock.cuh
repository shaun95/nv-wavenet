/******************************************************************************
 * Copyright (c) 2018, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

#include "matrix_math.cuh"
#include "softmax.cuh"

template <int M, int K>
__device__ __inline__ void loadWeights(half2 weights_local[K/2], half2* weights_remote, int layer, int row, int lda=M) {
    loadVectorizedWeights<M,K>(weights_local,weights_remote,layer,row,lda);
}

__device__ float toFloat(float f) { return f; }
__device__ float toFloat(half f) { return __half2float(f); }

template <typename T_weight, typename T_data, int R, int S, int BATCH_UNROLL>
__device__ void nv_wavenet_singleBlock_skip(int row, int num_layers, int batch_offset, int batch_size, T_weight* Wskip, T_data* Bskip, T_data h_sh[BATCH_UNROLL][R], T_data skip_out_sh[BATCH_UNROLL][S], T_data* skip_out, bool dumpActivations) {
    const int WV = sizeof(T_weight)/sizeof(T_data);
    T_weight weights[R/WV];
    T_data accum[BATCH_UNROLL];
    T_data skip_accum_last[BATCH_UNROLL];

    for (int b=0; b<BATCH_UNROLL; b++) {
        skip_accum_last[b] = 0.f;
    }

    for (int layer=0; layer<num_layers; layer++) {
        __syncthreads();
        loadWeights<S,R>(weights,Wskip,layer,row);
        T_data bias = Bskip[layer*S + row];
        namedBarrierSync(2,2*R+S);
        GEMM<R,2,BATCH_UNROLL>(weights,h_sh,accum);
        for (int b=0; b<BATCH_UNROLL; b++) { 
            accum[b] += bias;
            T_data val = accum[b] + skip_accum_last[b];
            skip_accum_last[b] += accum[b];
            skip_out_sh[b][row] = val;
            if (dumpActivations) skip_out[layer*batch_size*S + (batch_offset+b)*S + row] = val;
        }
    }
}

template <typename T_weight, typename T_data, int R, int S, int A, int BATCH_UNROLL>
__global__ void nv_wavenet_singleBlock_8R(nv_wavenet_params<T_weight, T_data> params) {


    int batch_offset = blockIdx.x * BATCH_UNROLL;

    const int pool_size = BATCH_UNROLL*(R + S + 2*A);

    __shared__ T_data shared_pool[pool_size];

    //__shared__ T_data xt_sh[BATCH_UNROLL][R];
    //__shared__ T_data skip_out_sh[BATCH_UNROLL][S];
    //__shared__ T_data a_cur_sh[BATCH_UNROLL][2*R];
    //__shared__ T_data h_sh[BATCH_UNROLL][R];
    T_data (*xt_sh)[R] = (T_data (*)[R])shared_pool;
    T_data (*skip_out_sh)[S] = (T_data (*)[S])(shared_pool + BATCH_UNROLL*R);
    T_data (*a_cur_sh)[2*R] = (T_data (*)[2*R])(shared_pool + BATCH_UNROLL*(4*R+S));
    T_data (*h_sh)[R] = (T_data (*)[R])(shared_pool + BATCH_UNROLL*(6*R+S));


    for (int sample = params.init_sample; sample < params.init_sample + params.num_samples_per_chunk; sample++) {

        // Embedding
        if (threadIdx.x < R) {
            int row = threadIdx.x;
            int yPrev[BATCH_UNROLL];
            int yCur[BATCH_UNROLL];
            for (int b=0; b<BATCH_UNROLL; b++) {
                yPrev[b] = params.yInPrev[batch_offset+b];
                yCur[b] = params.yInCur[batch_offset+b];

                T_data val = params.embedPrev[yPrev[b]*R + row] + params.embedCur[yCur[b]*R + row];
                if (params.tanhEmbed) val = _tanh(val);
                xt_sh[b][row] = val;
                T_data* Xt = params.xt + (sample%(params.maxDilation+1))*(params.num_layers+1)*R*params.batch_size;
                Xt[(batch_offset+b)*R + row] = val;

            }
        }

        __syncthreads();

        // Calculate prev for first sample, remaining samples are pipelined against final layers below
        if (threadIdx.x < 4*R && sample == 0) {
            int row = threadIdx.x;
            nv_wavenet_prev<T_weight, T_data, R, BATCH_UNROLL>(sample, row, params.num_layers, params.maxDilation, batch_offset, params.batch_size, params.Wprev, params.L, params.xt, params.a_prev, params.dumpActivations);
        }
        
        // int R=64, int S=128, int A=256
        // R : the number of residual channels
        // S : the number of skip channels
        // A : the number of audio channels
        // 64 residual channels, 128 skip channels, 256 audio channels
        
        __syncthreads();

        if (threadIdx.x < 2*R) {
            int row = threadIdx.x;
            nv_wavenet_cur<T_weight, T_data, R, BATCH_UNROLL>(sample, row, params.num_layers, batch_offset, params.batch_size, params.Wcur, params.B, params.L, xt_sh, a_cur_sh, params.a_prev);
        }
        else if (threadIdx.x < 3*R) {
            int row = threadIdx.x - 2*R;
            nv_wavenet_pointwise<T_weight, T_data, R, S, BATCH_UNROLL>(sample, row, params.num_layers, batch_offset, params.batch_size, params.xtmd, xt_sh, a_cur_sh, h_sh, NULL, NULL);
        }
        else if (threadIdx.x < 4*R) {
            int row = threadIdx.x - 3*R;
            nv_wavenet_res<T_weight, T_data, R, S, BATCH_UNROLL>(sample, row, params.num_layers, params.maxDilation, batch_offset, params.batch_size, params.Wres, params.Bres, h_sh, xt_sh, params.xt, params.xtOut, params.dumpActivations);
        }
        else if (threadIdx.x < 4*R+S) {
            int row = threadIdx.x - 4*R;
            nv_wavenet_singleBlock_skip<T_weight, T_data, R, S, BATCH_UNROLL>(row, params.num_layers, batch_offset, params.batch_size, params.Wskip, params.Bskip, h_sh, skip_out_sh, params.skip_out, params.dumpActivations);
        }
        else {
            for (int layer=0; layer<params.num_layers; layer++) {
                __syncthreads();
            }
        }

        __syncthreads();

        // We're all done with the shared memory from the loop, reuse

        //__shared__ T_data skip_out_final_sh[BATCH_UNROLL][A];
        T_data (*skip_out_final_sh)[A] = (T_data (*)[A])(shared_pool + BATCH_UNROLL*(R+S));

        const int WV = sizeof(T_weight)/sizeof(T_data);
        T_weight weights[R/WV];
        T_data accum[BATCH_UNROLL];

        int row = threadIdx.x;
        const int M = 4*R;  //  M = 256

        T_data zero = 0.f;

        // relu
        for (int r = threadIdx.x; r < S; r += blockDim.x) {
            for (int b=0; b<BATCH_UNROLL; b++) {
                T_data d = skip_out_sh[b][r];
                skip_out_sh[b][r] = d < zero ? zero : d;
            }
        }
        __syncthreads();

        //__shared__ T_data out_sh[BATCH_UNROLL][A];
        T_data (*out_sh)[A] = (T_data (*)[A])(shared_pool + BATCH_UNROLL*(R+S+A));

        if (threadIdx.x < M) {
            // SkipOut: AxS 
            for (int tile_m = 0; tile_m < A/M; tile_m++) {
                T_data bias = params.BskipOut[tile_m*M+row];
                T_data split_accum[BATCH_UNROLL];
                for (int b=0; b<BATCH_UNROLL; b++) {
                    split_accum[b] = 0.f; 
                }
                for (int tile_k = 0; tile_k < S/R; tile_k++) {
                    loadWeights<M,R>(weights, params.WskipOut + tile_m*M,  tile_k, threadIdx.x, A);
                    T_data activations[BATCH_UNROLL][R];
                    for (int b=0; b<BATCH_UNROLL; b++) {
                        for (int i=0; i<R; i++) {
                            activations[b][i] = skip_out_sh[b][tile_k*R + i];
                        }
                    }
                    GEMM<R,2,BATCH_UNROLL>(weights,activations,accum);
                    for (int b=0; b<BATCH_UNROLL; b++) {
                        split_accum[b] += accum[b];
                    }
                }
                for (int b=0; b<BATCH_UNROLL; b++) {
                    int finalLayer = S/R - 1;
                    split_accum[b] += bias;
                    skip_out_final_sh[b][tile_m*M + row] = split_accum[b] < zero ? zero : split_accum[b]; // relu
                    if (params.dumpActivations) params.skipOutFinal[finalLayer*params.batch_size*A + (batch_offset+b)*A + tile_m*M + row] = split_accum[b];
                }
            }

            namedBarrierSync(1,M);


            // Out: AxA
            for (int tile_m = 0; tile_m < A/M; tile_m++) {
                T_data bias = params.Bout[tile_m*M+row];
                T_data split_accum[BATCH_UNROLL];
                for (int b=0; b<BATCH_UNROLL; b++) {
                    split_accum[b] = 0.f; 
                }
                for (int tile_k = 0; tile_k < A/R; tile_k++) {
                    loadWeights<M,R>(weights, params.Wout + tile_m*M, tile_k, threadIdx.x, A);
                    T_data activations[BATCH_UNROLL][R];
                    for (int b=0; b<BATCH_UNROLL; b++) {
                        for (int i=0; i<R; i++) {
                            activations[b][i] = skip_out_final_sh[b][tile_k*R + i];
                        }
                    }
                    GEMM<R,2,BATCH_UNROLL>(weights,activations,accum);
                    for (int b=0; b<BATCH_UNROLL; b++) {
                        split_accum[b] += accum[b];
                    }
                }
                for (int b=0; b<BATCH_UNROLL; b++) {
                    int finalLayer = A/R - 1;
                    split_accum[b] += bias;
                    out_sh[b][tile_m*M + row] = split_accum[b];
                    if (params.dumpActivations) params.out[finalLayer*params.batch_size*A + (batch_offset+b)*A + tile_m*M + row] = split_accum[b];
                }
            }

            namedBarrierSync(1,M);

            //__shared__ T_data p_sh[BATCH_UNROLL][A];
            T_data (*p_sh)[A] = skip_out_final_sh;

            __shared__ int yOut_sh[BATCH_UNROLL];
            softmax_select<T_data, M, A,BATCH_UNROLL>(0,BATCH_UNROLL, (T_data*)out_sh, params.dumpActivations ? (T_data*)p_sh : NULL, params.outputSelectors + sample*params.batch_size + batch_offset, yOut_sh, 1, M);

            namedBarrierSync(1,M);

            for (int u=0; u<BATCH_UNROLL; u++) {
                if (params.dumpActivations) {
                    for (int i=threadIdx.x; i<A; i += M) {
                        params.p[(batch_offset+u)*A + i] = p_sh[u][i];
                    }
                }

                // Now that we're done, prepare for next sample: yInPrev = yInCur, yIn = yOut
                if (threadIdx.x == 0) {
                    params.yOut[(batch_offset+u)*params.num_samples + sample] = yOut_sh[u];
                    params.yInPrev[batch_offset+u] = params.yInCur[batch_offset+u];
                    params.yInCur[batch_offset+u] = yOut_sh[u];
                }
            }
        }
        else if (threadIdx.x < A+4*R && sample+1<params.num_samples) {
            // Precompute prev for next sample
            int row = threadIdx.x-M;
            nv_wavenet_prev<T_weight, T_data, R, BATCH_UNROLL>(sample+1, row, params.num_layers, params.maxDilation, batch_offset, params.batch_size, params.Wprev, params.L, params.xt, params.a_prev, params.dumpActivations);
        }
        __syncthreads();
    }
}


template <typename T_weight, typename T_data, int R, int S, int A, int BATCH_UNROLL>
struct launch_singleBlock {
    bool operator() (nv_wavenet_params<T_weight, T_data> params, cudaStream_t stream) {
        dim3 grid(params.batch_size/BATCH_UNROLL);
        dim3 block(8*R);
        int occ = getOccupancy(0, block.x*block.y*block.z,(void*)nv_wavenet_singleBlock_8R<T_weight, T_data, R, S, A, BATCH_UNROLL>);
        assert(occ>0);
        nv_wavenet_singleBlock_8R<T_weight, T_data, R, S, A, BATCH_UNROLL><<<grid,block,0,stream>>>(params);
        return true;
    }
};

template <typename T_weight, typename T_data, int S, int A, int BATCH_UNROLL>
struct launch_singleBlock<T_weight,T_data,128,S,A,BATCH_UNROLL> {
    bool operator() (nv_wavenet_params<T_weight, T_data> params, cudaStream_t stream) {
        printf("R=128 with single block not supported\n");
        return false;
    }
};
template <typename T_weight, typename T_data, int S, int A, int BATCH_UNROLL>
struct launch_singleBlock<T_weight,T_data,256,S,A,BATCH_UNROLL> {
    bool operator() (nv_wavenet_params<T_weight, T_data> params, cudaStream_t stream) {
        printf("R=256 with single block not supported\n");
        return false;
    }
};
