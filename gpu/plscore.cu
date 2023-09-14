#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#include "plscore.cuh"
#include "hipify.cuh"

/* 

Parallel chaining helper functions with CUDA

*/

__constant__ Misc misc;

/* arithmetic functions begin */

__device__ static inline float cuda_mg_log2(float x) // NB: this doesn't work when x<2
{
	union { float f; uint32_t i; } z = { x };
	float log_2 = ((z.i >> 23) & 255) - 128;
	z.i &= ~(255 << 23);
	z.i += 127 << 23;
	log_2 += (-0.34484843f * z.f + 2.02466578f) * z.f - 0.67487759f;
	return log_2;
}

__device__ int32_t comput_sc(const int32_t ai_x, const int32_t ai_y, const int32_t aj_x, const int32_t aj_y,
                                const int8_t sidi,  const int8_t sidj,
                                int32_t max_dist_x, int32_t max_dist_y,
                                int32_t bw, float chn_pen_gap,
                                float chn_pen_skip, int is_cdna, int n_seg) {
    int32_t dq = ai_y - aj_y, dr, dd, dg, q_span, sc;
    if (dq <= 0 || dq > max_dist_x) return INT32_MIN;
    dr = ai_x - aj_x;
    if (sidi == sidj && (dr == 0 || dq > max_dist_y)) return INT32_MIN;
    dd = dr > dq ? dr - dq : dq - dr;
    if (sidi == sidj && dd > bw) return INT32_MIN;
    if (n_seg > 1 && !is_cdna && sidi == sidj && dr > max_dist_y)
        return INT32_MIN;  // nseg = 1 by default
    dg = dr < dq ? dr : dq;
    q_span = MM_QSPAN;
    sc = q_span < dg ? q_span : dg;
    if (dd || dg > q_span) {
        float lin_pen, log_pen;
        lin_pen = chn_pen_gap * (float)dd + chn_pen_skip * (float)dg;
        log_pen =
            dd >= 1 ? cuda_mg_log2(dd + 1) : 0.0f;  // mg_log2() only works for dd>=2
        if (is_cdna || sidi != sidj) {
            if (sidi != sidj && dr == 0)
                ++sc;  // possibly due to overlapping paired ends; give a minor
                       // bonus
            else if (dr > dq || sidi != sidj)
                sc -=
                    (int)(lin_pen < log_pen ? lin_pen
                                            : log_pen);  // deletion or jump
                                                         // between paired ends
            else
                sc -= (int)(lin_pen + .5f * log_pen);
        } else
            sc -= (int)(lin_pen + .5f * log_pen);
    }
    return sc;
}

/* arithmetic functions end */

inline __device__ void compute_sc_seg_one_wf(int32_t* anchors_x, int32_t* anchors_y, int8_t* sid, int32_t* range, 
                    size_t start_idx, size_t end_idx,
                    int32_t* f, uint16_t* p
){
    Misc blk_misc = misc;
    int tid = threadIdx.x;
    // int bid = blockIdx.x;
    // init f and p
    for (size_t i=start_idx+tid; i < end_idx; i += blockDim.x) {
        f[i] = MM_QSPAN;
        p[i] = 0;
    }
    // __syncthreads();
    // assert(range[end_idx-1] == 0);
    for (size_t i=start_idx; i < end_idx; i++) {
        int32_t range_i = range[i];
        // if (range_i + i >= end_idx)
        //     printf("range_i %d i %lu start_idx %lu, end_idx %lu\n", range_i, i, start_idx, end_idx);
        // assert(range_i + i < end_idx);
        for (int32_t j = tid; j < range_i; j += blockDim.x) {
            int32_t sc = comput_sc(
                                anchors_x[i+j+1], 
                                anchors_y[i+j+1], 
                                anchors_x[i], 
                                anchors_y[i],
                                sid [i+j+1],
                                sid [i],
                                blk_misc.max_dist_x, blk_misc.max_dist_y, blk_misc.bw, blk_misc.chn_pen_gap, 
                                blk_misc.chn_pen_skip, blk_misc.is_cdna, blk_misc.n_seg);
            if (sc == INT32_MIN) continue;
            sc += f[i];
            if (sc >= f[i+j+1] && sc != MM_QSPAN) {
                f[i+j+1] = sc;
                p[i+j+1] = j+1;

            }
        }
        // __syncthreads();
    }
    
}


inline __device__ void compute_sc_long_seg_one_wf(const int32_t* anchors_x, const int32_t* anchors_y, const int8_t* sid, const int32_t* range, 
                    size_t start_idx, size_t end_idx,
                    int32_t* f, uint16_t* p
){
    Misc blk_misc = misc;
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    // init f and p
    for (size_t i=start_idx+tid; i < end_idx; i += blockDim.x) {
        f[i] = MM_QSPAN;
        p[i] = 0;
    }
    __syncthreads();
    // assert(range[end_idx-1] == 0);
    for (size_t i=start_idx; i < end_idx; i++) {
        int32_t range_i = range[i];
        // if (range_i + i >= end_idx)
        //     printf("range_i %d i %lu start_idx %lu, end_idx %lu\n", range_i, i, start_idx, end_idx);
        // assert(range_i + i < end_idx);
        for (int32_t j = tid; j < range_i; j += blockDim.x) {
            int32_t sc = comput_sc(
                                anchors_x[i+j+1], 
                                anchors_y[i+j+1], 
                                anchors_x[i], 
                                anchors_y[i],
                                sid [i+j+1],
                                sid [i],
                                blk_misc.max_dist_x, blk_misc.max_dist_y, blk_misc.bw, blk_misc.chn_pen_gap, 
                                blk_misc.chn_pen_skip, blk_misc.is_cdna, blk_misc.n_seg);
            if (sc == INT32_MIN) continue;
            sc += f[i];
            if (sc >= f[i+j+1] && sc != MM_QSPAN) {
                f[i+j+1] = sc;
                p[i+j+1] = j+1;

            }
        }
        __syncthreads();
    }
    
}

#define NUM_ANCHORS_PREFETCH 1024

// inline __device__ void compute_sc_seg_shared(const int64_t* anchors_x, const int64_t* anchors_y, int32_t* range, 
//                     size_t start_idx, size_t end_idx,
//                     int32_t* f, uint16_t* p
// ){
//     Misc blk_misc = misc;
//     int tid = threadIdx.x;
//     int bid = blockIdx.x;
//     // init f and p
//     for (size_t i=start_idx+tid; i < end_idx; i += blockDim.x) {
//         f[i] = anchors_y[i] >> 32 & 0xff;
//         p[i] = 0;
//     }
//     __syncthreads();
//     // assert(range[end_idx-1] == 0);
//     __shared__ int64_t anchors_x_shared[NUM_ANCHORS_PREFETCH];

//     __shared__ int64_t anchors_y_shared[NUM_ANCHORS_PREFETCH];
//     size_t prefetch_end_idx = 0;
//     unsigned int prefetch_smem_offset = 0;
//     for (size_t i = start_idx; i < end_idx; i++) {
//         int32_t range_i = range[i];
//         // if (range_i + i >= end_idx)
//         //     printf("range_i %d i %lu start_idx %lu, end_idx %lu\n", range_i, i, start_idx, end_idx);
//         // assert(range_i + i < end_idx);
//         for (int32_t j = tid; j < range_i; j += blockDim.x) {
//             int32_t sc = comput_sc(
//                                 anchors_x[i+j+1], 
//                                 anchors_y[i+j+1], 
//                                 anchors_x[i], 
//                                 anchors_y[i],
//                                 blk_misc.max_dist_x, blk_misc.max_dist_y, blk_misc.bw, blk_misc.chn_pen_gap, 
//                                 blk_misc.chn_pen_skip, blk_misc.is_cdna, blk_misc.n_seg);
//             if (sc == INT32_MIN) continue;
//             sc += f[i];
//             if (sc >= f[i+j+1] && sc != (anchors_y[i+j+1]>>32 & 0xff)) {
//                 f[i+j+1] = sc;
//                 p[i+j+1] = j+1;

//             }
//         }
//         __syncthreads();
//     }
// }

// inline __device__ void compute_sc_long_seg_one_wf(const int64_t* anchors_x, const int64_t* anchors_y, int32_t* range, 
//                     size_t start_idx, size_t end_idx,
//                     int32_t* f, uint16_t* p
// ){
//     Misc blk_misc = misc;
//     int tid = threadIdx.x;
//     // int bid = blockIdx.x;
//     // NOTE: smallest alignd offset that is greater than start_idx
//     //      anchor_offset = tid;
//     //      while (anchor_offset <= start_idx) anchor_offset += blockDim.x;
//     int anchor_offset = tid + (start_idx - tid + blockDim.x) / blockDim.x * blockDim.x;
//     // init f and p
//     for (size_t i=anchor_offset; i < end_idx; i += blockDim.x) {
//         f[i] = anchors_y[i] >> 32 & 0xff;
//         p[i] = 0;
//     }
//     // int64_t local_anchors[10];
//     int64_t anchor_x = anchors_x[anchor_offset];
//     int64_t anchor_y = anchors_y[anchor_offset];
//     __syncthreads();
//     // assert(range[end_idx-1] == 0);
//     for (size_t i=start_idx; i < end_idx; i++) {
//         int32_t range_i = range[i];
//         // if (range_i + i >= end_idx)
//         //     printf("range_i %d i %lu start_idx %lu, end_idx %lu\n", range_i, i, start_idx, end_idx);
//         // assert(range_i + i < end_idx);
//         // for (int32_t j = tid; j < range_i; j += blockDim.x) {
//         for (unsigned j = anchor_offset; j < i+range_i+1; j += blockDim.x) {
//             anchor_x = anchors_x[j];
//             anchor_y = anchors_y[j];
//             int32_t sc = comput_sc(
//                                 anchor_x, 
//                                 anchor_y, 
//                                 anchors_x[i], 
//                                 anchors_y[i],
//                                 blk_misc.max_dist_x, blk_misc.max_dist_y, blk_misc.bw, blk_misc.chn_pen_gap, 
//                                 blk_misc.chn_pen_skip, blk_misc.is_cdna, blk_misc.n_seg);
//             if (sc == INT32_MIN) continue;
//             sc += f[i];
//             if (sc >= f[j] && sc != (anchors_y[j]>>32 & 0xff)) {
//                 f[j] = sc;
//                 p[j] = j+1;
//             }
//         }
//         anchor_offset += (anchor_offset <= i+1) * blockDim.x; // update anchor offset
//         __syncthreads();
//     }
    
// }



/* kernels begin */
#ifdef __SHORT_BLOCK_SIZE__
template <size_t short_block_size>
__launch_bounds__(short_block_size)
#endif
__global__ void score_generation_short(
                                /* Input: Anchor & Range Inputs */
                                int32_t* anchors_x, int32_t* anchors_y, int8_t* sid, int32_t *range, 
                                /* Input: Segmentations */
                                size_t *seg_start_arr,
                                /* Output: Score and Previous Anchor */
                                int32_t* f, uint16_t* p, 
                                /* Sizes*/
                                size_t total_n, size_t seg_count,
                                /* Output: Long segs */
                                seg_t *long_seg, unsigned int *long_seg_count
                                ,seg_t *mid_seg, unsigned int *mid_seg_count){
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    // init f and p
    for(int segid = bid; segid < seg_count; segid += gridDim.x){
        size_t start_idx = seg_start_arr[segid];
        if (start_idx == SIZE_MAX) continue; // start at a failed cut: continue to next iteration
        size_t end_idx = SIZE_MAX;
        int end_segid = segid + 1;
        while (true) {
            if (end_segid >= seg_count) {
                end_idx = total_n;
                break;
            }
            if (seg_start_arr[end_segid] != SIZE_MAX) {
                end_idx = seg_start_arr[end_segid];
                break;
            }
            ++end_segid;
        }
        if (end_segid > segid + MM_LONG_SEG_CUTOFF) {
            if (tid == 0){
                int long_seg_idx = atomicAdd(long_seg_count, 1);
                long_seg[long_seg_idx].start_idx = start_idx;
                long_seg[long_seg_idx].end_idx = end_idx;
                long_seg[long_seg_idx].start_segid = segid;
                long_seg[long_seg_idx].end_segid = end_segid;
            }
            continue;
        } else if (end_segid > segid + MM_MID_SEG_CUTOFF) {
            if (tid == 0) {
                int mid_seg_idx = atomicAdd(mid_seg_count, 1);
                mid_seg[mid_seg_idx].start_idx = start_idx;
                mid_seg[mid_seg_idx].end_idx = end_idx;
            }
            continue;
        }
        // assert(end_idx <= total_n);
        compute_sc_seg_one_wf(anchors_x, anchors_y, sid, range, start_idx, end_idx, f, p);
    }
}

#ifdef __MID_BLOCK_SIZE__
template <size_t mid_block_size>
__launch_bounds__(mid_block_size)
#endif
__global__ void score_generation_mid(int32_t* anchors_x, int32_t* anchors_y, int8_t* sid, int32_t *range,
                                seg_t *long_seg, unsigned int* long_seg_count,
                                int32_t* f, uint16_t* p){
    int tid = threadIdx.x;
    int bid = blockIdx.x;

    for(int segid = bid; segid < *long_seg_count; segid += gridDim.x){
        seg_t seg = long_seg[segid]; 
        compute_sc_seg_one_wf(anchors_x, anchors_y, sid, range, seg.start_idx, seg.end_idx, f, p);
        // compute_sc_long_seg_one_wf(anchors_x, anchors_y, range, seg.start_idx, seg.end_idx, f, p);
    }
}

#ifdef __LONG_BLOCK_SIZE__
template <size_t long_block_size>
__launch_bounds__(long_block_size)
#endif
__global__ void score_generation_long(int32_t* anchors_x, int32_t* anchors_y, int8_t* sid, int32_t *range,
                                seg_t *long_seg, unsigned int* long_seg_count,
                                int32_t* f, uint16_t* p){
    int tid = threadIdx.x;
    int bid = blockIdx.x;

    for(int segid = bid; segid < *long_seg_count; segid += gridDim.x){
        seg_t seg = long_seg[segid]; 
        // compute_sc_seg_one_wf(anchors_x, anchors_y, sid, range, seg.start_idx, seg.end_idx, f, p);
        compute_sc_long_seg_one_wf(anchors_x, anchors_y, sid, range, seg.start_idx, seg.end_idx, f, p);
    }
}
__global__ void score_generation_naive(int32_t* anchors_x, int32_t* anchors_y, int8_t* sid, int32_t *range,
                        size_t *seg_start_arr, 
                        int32_t* f, uint16_t* p, size_t total_n, size_t seg_count) {

    // NOTE: each block deal with one batch 
    // the number of threads in a block is fixed, so we need to calculate iter
    // n = end_idx_arr - start_idx_arr
    // iter = (range[i] - 1) / num_threads + 1

    int tid = threadIdx.x;
    int bid = blockIdx.x;
    for (int segid = bid; segid < seg_count; segid += gridDim.x){
        /* calculate the segement for current block */
        size_t start_idx = seg_start_arr[segid];
        if (start_idx == SIZE_MAX) continue; // start at a failed cut: continue to next iteration
        size_t end_idx = SIZE_MAX;
        int end_segid = segid + 1;
        while (true) {
            if (end_segid >= seg_count) {
                end_idx = total_n;
                break;
            }
            if (seg_start_arr[end_segid] != SIZE_MAX) {
                end_idx = seg_start_arr[end_segid];
                break;
            }
            ++end_segid;
        }
        // assert(end_idx <= total_n);
        compute_sc_seg_one_wf(anchors_x, anchors_y, sid, range, start_idx, end_idx, f, p);
    }
}

/* kernels end */

/* host functions begin */
score_kernel_config_t score_kernel_config;

void plscore_upload_misc(Misc input_misc) {
#ifdef USEHIP
    hipMemcpyToSymbol(HIP_SYMBOL(misc), &input_misc, sizeof(Misc));
#else
    cudaMemcpyToSymbol(misc, &input_misc, sizeof(Misc));
#endif
    cudaCheck();
}

void plscore_async_long_short_forward_dp(deviceMemPtr* dev_mem, cudaStream_t* stream) {
    size_t total_n = dev_mem->total_n;
    size_t cut_num = dev_mem->num_cut;
    dim3 shortDimGrid(score_kernel_config.short_griddim, 1, 1);
    dim3 midDimGrid(score_kernel_config.mid_griddim, 1, 1);
    dim3 longDimGrid(score_kernel_config.long_griddim, 1, 1);

    // Run kernel
    // printf("Grid Dim, %d\n", DimGrid.x);
    cudaMemsetAsync(dev_mem->d_long_seg_count, 0, sizeof(unsigned int),
                    *stream);
    cudaMemsetAsync(dev_mem->d_mid_seg_count, 0, sizeof(unsigned int),
                    *stream);

    #ifdef __SHORT_BLOCK_SIZE__
    fprintf(stderr, "short block size: %d\n", __SHORT_BLOCK_SIZE__);
    score_generation_short<__SHORT_BLOCK_SIZE__><<<shortDimGrid, dim3(__SHORT_BLOCK_SIZE__, 1, 1), 0, *stream>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range,
        dev_mem->d_cut, dev_mem->d_f, dev_mem->d_p, total_n, cut_num,
        dev_mem->d_long_seg, dev_mem->d_long_seg_count,
        dev_mem->d_mid_seg, dev_mem->d_mid_seg_count);
    #else
    dim3 shortDimBlock(score_kernel_config.short_blockdim, 1, 1);
    score_generation_short<<<shortDimGrid, shortDimBlock, 0, *stream>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range,
        dev_mem->d_cut, dev_mem->d_f, dev_mem->d_p, total_n, cut_num,
        dev_mem->d_long_seg, dev_mem->d_long_seg_count, 
        dev_mem->d_mid_seg, dev_mem->d_mid_seg_count);
    #endif
    cudaCheck();

    #ifdef __MID_BLOCK_SIZE__
    fprintf(stderr, "mid block size: %d\n", __MID_BLOCK_SIZE__);
    score_generation_mid<__MID_BLOCK_SIZE__><<<midDimGrid, dim3(__MID_BLOCK_SIZE__, 1, 1), 0, *stream>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range, dev_mem->d_mid_seg,
        dev_mem->d_mid_seg_count, dev_mem->d_f, dev_mem->d_p);
    #else
    dim3 midDimBlock(score_kernel_config.mid_blockdim, 1, 1);
    score_generation_mid<<<midDimGrid, midDimBlock, 0, *stream>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range, dev_mem->d_mid_seg,
        dev_mem->d_mid_seg_count, dev_mem->d_f, dev_mem->d_p);
    #endif
    cudaCheck();

    #ifdef __LONG_BLOCK_SIZE__
    fprintf(stderr, "long block size: %d\n", __LONG_BLOCK_SIZE__);
    score_generation_long<__LONG_BLOCK_SIZE__><<<longDimGrid, dim3(__LONG_BLOCK_SIZE__, 1, 1), 0, *stream>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range, dev_mem->d_long_seg,
        dev_mem->d_long_seg_count, dev_mem->d_f, dev_mem->d_p);
    #else
    dim3 longDimBlock(score_kernel_config.long_blockdim, 1, 1);
    score_generation_long<<<longDimGrid, longDimBlock, 0, *stream>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range, dev_mem->d_long_seg,
        dev_mem->d_long_seg_count, dev_mem->d_f, dev_mem->d_p);
    #endif
    cudaCheck();

#ifdef DEBUG_VERBOSE
    fprintf(stderr, "[M::%s] score generation success\n", __func__);
#endif
    
    cudaCheck();
}

void plscore_async_naive_forward_dp(deviceMemPtr* dev_mem,
                                    cudaStream_t* stream) {
    size_t total_n = dev_mem->total_n;
    size_t cut_num = dev_mem->num_cut;
    dim3 DimBlock(score_kernel_config.long_blockdim, 1, 1);
    dim3 longDimGrid(score_kernel_config.long_griddim, 1, 1);
    dim3 shortDimGrid(score_kernel_config.short_griddim, 1, 1);

    // Run kernel
    // printf("Grid Dim, %d\n", DimGrid.x);
    score_generation_naive<<<shortDimGrid, DimBlock, 0, *stream>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range, dev_mem->d_cut,
        dev_mem->d_f, dev_mem->d_p, total_n, cut_num);
    cudaCheck();
#ifdef DEBUG_VERBOSE
    fprintf(stderr, "[M::%s] score generation kernel launch success\n", __func__);
#endif

    cudaCheck();
}

/**
 * Launch long/short kernel forward_dp for score calculation
 * Input
 *  dev_mem:    device memory pointers
 * Output
 *  f[]:        score array
 *  p[]:        previous anchor array
*/
void plscore_sync_long_short_forward_dp(deviceMemPtr* dev_mem, Misc misc_) {
    size_t total_n = dev_mem->total_n;
    size_t cut_num = dev_mem->num_cut;
    plscore_upload_misc(misc_);
    dim3 longDimGrid(score_kernel_config.long_griddim, 1, 1);
    dim3 midDimGrid(score_kernel_config.mid_griddim, 1, 1);
    dim3 shortDimGrid(score_kernel_config.short_griddim, 1, 1);
    cudaMemset(dev_mem->d_long_seg_count, 0, sizeof(unsigned int));
    #ifdef __SHORT_BLOCK_SIZE__
    printf("short block size: %d\n", __SHORT_BLOCK_SIZE__);
    score_generation_short<__SHORT_BLOCK_SIZE__><<<shortDimGrid, dim3(__SHORT_BLOCK_SIZE__, 1, 1)>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range,
        dev_mem->d_cut, dev_mem->d_f, dev_mem->d_p, total_n, cut_num, 
        dev_mem->d_long_seg, dev_mem->d_long_seg_count, 
        dev_mem->d_mid_seg, dev_mem->d_mid_seg_count);
    #else
    dim3 shortDimBlock(score_kernel_config.short_blockdim, 1, 1);
    score_generation_short<<<shortDimGrid, shortDimBlock>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range,
        dev_mem->d_cut, dev_mem->d_f, dev_mem->d_p, total_n, cut_num, 
        dev_mem->d_long_seg, dev_mem->d_long_seg_count, 
        dev_mem->d_mid_seg, dev_mem->d_mid_seg_count);
    #endif
    cudaCheck();
    cudaDeviceSynchronize();

#ifdef DEBUG_CHECK
    /* DEBUG: check long_segs */
    seg_t* long_seg;
    unsigned int long_seg_count;
    cudaMemcpy(&long_seg_count, dev_mem->d_long_seg_count, sizeof(unsigned int), cudaMemcpyDeviceToHost);
    long_seg = (seg_t*)malloc(sizeof(seg_t)*long_seg_count);
    cudaMemcpy(long_seg, dev_mem->d_long_seg, sizeof(seg_t)*long_seg_count, cudaMemcpyDeviceToHost);
    fprintf(stderr, "long_seg_count %u total seg %u\n", long_seg_count, cut_num);
    // for(int i =0; i<long_seg_count; ++i){
    //     printf("#%d, %lu - %lu\n", i, long_seg[i].start_idx, long_seg[i].end_idx);
    // }
    free(long_seg);

    /* DEBUG: check elapsed clock */
    // cudaMemcpy(elapsed_clk, d_clk, sizeof(long long int)*DimGrid.x, cudaMemcpyDeviceToHost);
#endif // DEBUG_CHECK

    #ifdef __MID_BLOCK_SIZE__
    fprintf(stderr, "mid block size: %d\n", __MID_BLOCK_SIZE__);
    score_generation_mid<__MID_BLOCK_SIZE__><<<midDimGrid, dim3(__MID_BLOCK_SIZE__, 1, 1)>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range, dev_mem->d_mid_seg,
        dev_mem->d_mid_seg_count, dev_mem->d_f, dev_mem->d_p);
    #else
    dim3 midDimBlock(score_kernel_config.mid_blockdim, 1, 1);
    score_generation_mid<<<midDimGrid, midDimBlock>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range, dev_mem->d_mid_seg,
        dev_mem->d_mid_seg_count, dev_mem->d_f, dev_mem->d_p);
    #endif

    #ifdef __LONG_BLOCK_SIZE__
    printf("long block size: %d\n", __LONG_BLOCK_SIZE__);
    score_generation_long<__LONG_BLOCK_SIZE__><<<longDimGrid, dim3(__LONG_BLOCK_SIZE__, 1, 1)>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range, dev_mem->d_long_seg, dev_mem->d_long_seg_count,
        dev_mem->d_f, dev_mem->d_p);
    #else
    dim3 longDimBlock(score_kernel_config.long_blockdim, 1, 1);
    score_generation_long<<<longDimGrid, longDimBlock>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range, dev_mem->d_long_seg, dev_mem->d_long_seg_count,
        dev_mem->d_f, dev_mem->d_p);
    #endif
    cudaCheck();
    cudaDeviceSynchronize();

    cudaCheck();

    cudaCheck();
    cudaDeviceSynchronize();
    cudaCheck();
}

/**
 * Launch naive kernel forward_dp for score calculation
 * Input
 *  dev_mem:    device memory pointers
 * Output
 *  f[]:        score array
 *  p[]:        previous anchor array
 */
void plscore_sync_naive_forward_dp(deviceMemPtr* dev_mem, Misc misc_) {
    size_t total_n = dev_mem->total_n;
    size_t cut_num = dev_mem->num_cut;
    plscore_upload_misc(misc_);
    dim3 DimBlock(score_kernel_config.long_blockdim, 1, 1);
    dim3 longDimGrid(score_kernel_config.long_griddim, 1, 1);
    dim3 shortDimGrid(score_kernel_config.short_griddim, 1, 1);
    // fprintf(stderr, "cut_num %d\n", cut_num);
    score_generation_naive<<<shortDimGrid, DimBlock>>>(
        dev_mem->d_ax, dev_mem->d_ay, dev_mem->d_sid, dev_mem->d_range,
        dev_mem->d_cut, dev_mem->d_f, dev_mem->d_p, total_n, cut_num);
    cudaCheck();
    cudaDeviceSynchronize();
    cudaCheck();
}

/* host functions end */


