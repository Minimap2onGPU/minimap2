#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#include "mmpriv.h"
#include "kalloc.h"
#include "krmq.h"

#include "plchain.h"
#include "debug.h"
#include <time.h>

static int64_t mg_chain_bk_end(int32_t max_drop, const mm128_t *z, const int32_t *f, const int64_t *p, int32_t *t, int64_t k)
{
	int64_t i = z[k].y, end_i = -1, max_i = i;
	int32_t max_s = 0;
	if (i < 0 || t[i] != 0) return i;
	do {
		int32_t s;
		t[i] = 2;
		end_i = i = p[i];
		s = i < 0? z[k].x : (int32_t)z[k].x - f[i];
		if (s > max_s) max_s = s, max_i = i;
		else if (max_s - s > max_drop) break;
	} while (i >= 0 && t[i] == 0);
	for (i = z[k].y; i >= 0 && i != end_i; i = p[i]) // reset modified t[]
		t[i] = 0;
	return max_i;
}

uint64_t *mg_chain_backtrack(void *km, int64_t n, const int32_t *f, const int64_t *p, int32_t *v, int32_t *t, int32_t min_cnt, int32_t min_sc, int32_t max_drop, int32_t *n_u_, int32_t *n_v_)
{
	mm128_t *z;
	uint64_t *u;
	int64_t i, k, n_z, n_v;
	int32_t n_u;

	*n_u_ = *n_v_ = 0;
	for (i = 0, n_z = 0; i < n; ++i) // precompute n_z
		if (f[i] >= min_sc) ++n_z;
	if (n_z == 0) return 0;
	KMALLOC(km, z, n_z);
	for (i = 0, k = 0; i < n; ++i) // populate z[]
		if (f[i] >= min_sc) z[k].x = f[i], z[k++].y = i;
	radix_sort_128x(z, z + n_z);

	memset(t, 0, n * 4); // NOTE: meaning t is not used as an input
	for (k = n_z - 1, n_v = n_u = 0; k >= 0; --k) { // precompute n_u
		if (t[z[k].y] == 0) {
			int64_t n_v0 = n_v, end_i;
			int32_t sc;
			end_i = mg_chain_bk_end(max_drop, z, f, p, t, k);
			for (i = z[k].y; i != end_i; i = p[i])
				++n_v, t[i] = 1;
			sc = i < 0? z[k].x : (int32_t)z[k].x - f[i];
			if (sc >= min_sc && n_v > n_v0 && n_v - n_v0 >= min_cnt)
				++n_u;
			else n_v = n_v0;
		}
	}
	KMALLOC(km, u, n_u);
	memset(t, 0, n * 4);
	for (k = n_z - 1, n_v = n_u = 0; k >= 0; --k) { // populate u[]
		if (t[z[k].y] == 0) {
			int64_t n_v0 = n_v, end_i;
			int32_t sc;
			end_i = mg_chain_bk_end(max_drop, z, f, p, t, k);
			for (i = z[k].y; i != end_i; i = p[i])
				v[n_v++] = i, t[i] = 1; // NOTE: v is noly written into, never read from
			sc = i < 0? z[k].x : (int32_t)z[k].x - f[i];
			if (sc >= min_sc && n_v > n_v0 && n_v - n_v0 >= min_cnt)
				u[n_u++] = (uint64_t)sc << 32 | (n_v - n_v0);
			else n_v = n_v0;
		}
	}
	kfree(km, z);
	assert(n_v < INT32_MAX);
	*n_u_ = n_u, *n_v_ = n_v;
	return u;
}

static mm128_t *compact_a(void *km, int32_t n_u, uint64_t *u, int32_t n_v, int32_t *v, mm128_t *a)
{
	mm128_t *b, *w;
	uint64_t *u2;
	int64_t i, j, k;

	// write the result to b[]
	KMALLOC(km, b, n_v);
	for (i = 0, k = 0; i < n_u; ++i) {
		int32_t k0 = k, ni = (int32_t)u[i];
		for (j = 0; j < ni; ++j)
			b[k++] = a[v[k0 + (ni - j - 1)]];
	}
	kfree(km, v);

	// sort u[] and a[] by the target position, such that adjacent chains may be joined
	KMALLOC(km, w, n_u);
	for (i = k = 0; i < n_u; ++i) {
		w[i].x = b[k].x, w[i].y = (uint64_t)k<<32|i;
		k += (int32_t)u[i];
	}
	radix_sort_128x(w, w + n_u);
	KMALLOC(km, u2, n_u);
	for (i = k = 0; i < n_u; ++i) {
		int32_t j = (int32_t)w[i].y, n = (int32_t)u[j];
		u2[i] = u[j];
		memcpy(&a[k], &b[w[i].y>>32], n * sizeof(mm128_t));
		k += n;
	}
	memcpy(u, u2, n_u * 8);
	memcpy(b, a, k * sizeof(mm128_t)); // write _a_ to _b_ and deallocate _a_ because _a_ is oversized, sometimes a lot
	kfree(km, a); 
	kfree(km, w); kfree(km, u2);
	return b;
}

static inline int32_t comput_sc(const mm128_t *ai, const mm128_t *aj, int32_t max_dist_x, int32_t max_dist_y, int32_t bw, float chn_pen_gap, float chn_pen_skip, int is_cdna, int n_seg)
{
	int32_t dq = (int32_t)ai->y - (int32_t)aj->y, dr, dd, dg, q_span, sc;
	int32_t sidi = (ai->y & MM_SEED_SEG_MASK) >> MM_SEED_SEG_SHIFT;
	int32_t sidj = (aj->y & MM_SEED_SEG_MASK) >> MM_SEED_SEG_SHIFT;
	if (dq <= 0 || dq > max_dist_x) return INT32_MIN;
	dr = (int32_t)(ai->x - aj->x);
	if (sidi == sidj && (dr == 0 || dq > max_dist_y)) return INT32_MIN;
	dd = dr > dq? dr - dq : dq - dr;
	if (sidi == sidj && dd > bw) return INT32_MIN;
	if (n_seg > 1 && !is_cdna && sidi == sidj && dr > max_dist_y) return INT32_MIN; // nseg = 1 by default
	dg = dr < dq? dr : dq;
	q_span = aj->y>>32&0xff;
	sc = q_span < dg? q_span : dg;
	if (dd || dg > q_span) {
		float lin_pen, log_pen;
		lin_pen = chn_pen_gap * (float)dd + chn_pen_skip * (float)dg;
		log_pen = dd >= 1? mg_log2(dd + 1) : 0.0f; // mg_log2() only works for dd>=2
		if (is_cdna || sidi != sidj) {
			if (sidi != sidj && dr == 0) ++sc; // possibly due to overlapping paired ends; give a minor bonus
			else if (dr > dq || sidi != sidj) sc -= (int)(lin_pen < log_pen? lin_pen : log_pen); // deletion or jump between paired ends
			else sc -= (int)(lin_pen + .5f * log_pen);
		} else sc -= (int)(lin_pen + .5f * log_pen);
	}
	return sc;
}

/* Input:
 *   a[].x: tid<<33 | rev<<32 | tpos: reference position
 *   a[].y: flags<<40 | q_span<<32 | q_pos: query position
 * Output:
 *   n_u: #chains // num of chains
 *   u[]: score<<32 | #anchors (sum of lower 32 bits of u[] is the returned length of a[]) // number of anchors
 * input a[] is deallocated on return
 */
#include <stdio.h>
mm128_t *mg_lchain_dp(
    int max_dist_x, int max_dist_y, int bw, int max_skip, int max_iter,
    int min_cnt, int min_sc, float chn_pen_gap, float chn_pen_skip, int is_cdna,
    int n_seg, int64_t n,  // NOTE: n is number of anchors
    mm128_t *a,            // NOTE: a is ptr to anchors.
    int *n_u_, uint64_t **_u,
    void *km) {  // TODO: make sure this works when n has more than 32 bits
	
    int32_t *f, *t, *v, n_u, n_v, mmax_f = 0, max_drop = bw;
	int64_t *p, i, j, max_ii; // NOTE: max_ii: the anchor idx that holds max score on the chain
	int64_t st = 0, n_iter = 0; // NOTE: n_iter: scores calculated
	uint64_t *u;

	max_skip = INT32_MAX; // FIXME: no skip limitation for test purpose

    if (_u) *_u = 0, *n_u_ = 0;
	if (n == 0 || a == 0) {
		kfree(km, a);
		return 0;
	}
	if (max_dist_x < bw) max_dist_x = bw;
	if (max_dist_y < bw && !is_cdna) max_dist_y = bw;
	if (is_cdna) max_drop = INT32_MAX;
	KMALLOC(km, p, n); // NOTE: previous anchor
	KMALLOC(km, f, n); // NOTE: score
	KMALLOC(km, v, n); // NOTE: max score upto i
	KCALLOC(km, t, n); // NOTE: used to track if it is a predecessor of an anchor already chained to

	#ifdef DEBUG_INPUT
	debug_chain_input(a, n, max_iter, max_dist_x, max_dist_y, max_skip,\
                        bw, chn_pen_gap, chn_pen_skip, is_cdna, n_seg);
	#endif // DEBUG_INPUT
	fprintf(stderr, "[M: %s] enter backward chaining\n", __func__);

	// fill the score and backtrack arrays
	for (i = 0, max_ii = -1; i < n; ++i) { 
		// NOTE: iterate through all the anchors. i: current anchor idx
		int64_t max_j = -1, end_j;
		int32_t max_f = a[i].y>>32&0xff, n_skip = 0; // NOTE: max_f: q_span(w), serve as the minimum for chaining score
        while (st < i && 
				(a[i].x >> 32 != a[st].x >> 32 // NOTE: ????
				|| a[i].x > a[st].x + max_dist_x))
            // NOTE: st: predecessor range start idx. 
			++st;
		if (i - st > max_iter) st = i - max_iter; 
		// even if distance satisfied, there shouldn't be too much anchors between
        for (j = i - 1; j >= st; --j) {  // NOTE: j: predecessor idx
            int32_t sc; 
			sc = comput_sc(&a[i], &a[j], max_dist_x, max_dist_y, bw, chn_pen_gap, chn_pen_skip, is_cdna, n_seg);
			++n_iter;
			if (sc == INT32_MIN) continue;
            sc += f[j];  // NOTE: score
            if (sc > max_f) {
				max_f = sc, max_j = j; // NOTE: update max score
				if (n_skip > 0) --n_skip;
			} else if (t[j] == (int32_t)i) { // NOTE: go to next anchor if  we continue comming across predecessor of anchors we have already tried to chain to. 
				if (++n_skip > max_skip)
					break;
			}
			if (p[j] >= 0) t[p[j]] = i;
        }
        end_j = j;

		// NOTE: update max_ii (idx of anchor that holds peak score)
		if (max_ii < 0 || a[i].x - a[max_ii].x > (int64_t)max_dist_x) {
			int32_t max = INT32_MIN;
			max_ii = -1;
			for (j = i - 1; j >= st; --j)
				if (max < f[j]) max = f[j], max_ii = j;
		}
		if (max_ii >= 0 && max_ii < end_j) {
			int32_t tmp;
			tmp = comput_sc(&a[i], &a[max_ii], max_dist_x, max_dist_y, bw, chn_pen_gap, chn_pen_skip, is_cdna, n_seg);
			if (tmp != INT32_MIN && max_f < tmp + f[max_ii])
				max_f = tmp + f[max_ii], max_j = max_ii;
		}
		f[i] = max_f, p[i] = max_j;
		v[i] = max_j >= 0 && v[max_j] > max_f? v[max_j] : max_f; // v[] keeps the peak score up to i; f[] is the score ending at i, not always the peak
		if (max_ii < 0 || (a[i].x - a[max_ii].x <= (int64_t)max_dist_x && f[max_ii] < f[i]))
			max_ii = i;
		if (mmax_f < max_f) mmax_f = max_f;
	}
	fprintf(stderr, "[M: %s] enter backtracking\n", __func__);

	// NOTE: t is not use, v is updated, f & p are inputs, n_u & n_v are outputs.
	u = mg_chain_backtrack(km, n, f, p, v, t, min_cnt, min_sc, max_drop, &n_u, &n_v);
	*n_u_ = n_u, *_u = u; // NB: note that u[] may not be sorted by score here

	#ifdef DEBUG_OUTPUT
	debug_chain_output(f, t, v, p, n);
	#endif // DEBUG_OUTPUT

	kfree(km, p); kfree(km, f); kfree(km, t);
	if (n_u == 0) {
		kfree(km, a); kfree(km, v);
		return 0;
	}
	fprintf(stderr, "[M: %s] done backward chaining\n", __func__);
	return compact_a(km, n_u, u, n_v, v, a);
}

typedef struct lc_elem_s {
	int32_t y;
	int64_t i;
	double pri;
	KRMQ_HEAD(struct lc_elem_s) head;
} lc_elem_t;

#define lc_elem_cmp(a, b) ((a)->y < (b)->y? -1 : (a)->y > (b)->y? 1 : ((a)->i > (b)->i) - ((a)->i < (b)->i))
#define lc_elem_lt2(a, b) ((a)->pri < (b)->pri)
KRMQ_INIT(lc_elem, lc_elem_t, head, lc_elem_cmp, lc_elem_lt2)

KALLOC_POOL_INIT(rmq, lc_elem_t)

static inline int32_t comput_sc_simple(const mm128_t *ai, const mm128_t *aj, float chn_pen_gap, float chn_pen_skip, int32_t *exact, int32_t *width)
{
	int32_t dq = (int32_t)ai->y - (int32_t)aj->y, dr, dd, dg, q_span, sc;
	dr = (int32_t)(ai->x - aj->x);
	*width = dd = dr > dq? dr - dq : dq - dr;
	dg = dr < dq? dr : dq;
	q_span = aj->y>>32&0xff;
	sc = q_span < dg? q_span : dg;
	if (exact) *exact = (dd == 0 && dg <= q_span);
	if (dd || dq > q_span) {
		float lin_pen, log_pen;
		lin_pen = chn_pen_gap * (float)dd + chn_pen_skip * (float)dg;
		log_pen = dd >= 1? mg_log2(dd + 1) : 0.0f; // mg_log2() only works for dd>=2
		sc -= (int)(lin_pen + .5f * log_pen);
	}
	return sc;
}

mm128_t *mg_lchain_rmq(int max_dist, int max_dist_inner, int bw, int max_chn_skip, int cap_rmq_size, int min_cnt, int min_sc, float chn_pen_gap, float chn_pen_skip,
					   int64_t n, mm128_t *a, int *n_u_, uint64_t **_u, void *km)
{
	int32_t *f,*t, *v, n_u, n_v, mmax_f = 0, max_rmq_size = 0, max_drop = bw;
	int64_t *p, i, i0, st = 0, st_inner = 0, n_iter = 0;
	uint64_t *u;
	lc_elem_t *root = 0, *root_inner = 0;
	void *mem_mp = 0;
	kmp_rmq_t *mp;

	if (_u) *_u = 0, *n_u_ = 0;
	if (n == 0 || a == 0) {
		kfree(km, a);
		return 0;
	}
	if (max_dist < bw) max_dist = bw;
	if (max_dist_inner <= 0 || max_dist_inner >= max_dist) max_dist_inner = 0;
	KMALLOC(km, p, n);
	KMALLOC(km, f, n);
	KCALLOC(km, t, n);
	KMALLOC(km, v, n);
	mem_mp = km_init2(km, 0x10000);
	mp = kmp_init_rmq(mem_mp);

	// fill the score and backtrack arrays
	for (i = i0 = 0; i < n; ++i) {
		int64_t max_j = -1;
		int32_t q_span = a[i].y>>32&0xff, max_f = q_span;
		lc_elem_t s, *q, *r, lo, hi;
		// add in-range anchors
		if (i0 < i && a[i0].x != a[i].x) {
			int64_t j;
			for (j = i0; j < i; ++j) {
				q = kmp_alloc_rmq(mp);
				q->y = (int32_t)a[j].y, q->i = j, q->pri = -(f[j] + 0.5 * chn_pen_gap * ((int32_t)a[j].x + (int32_t)a[j].y));
				krmq_insert(lc_elem, &root, q, 0);
				if (max_dist_inner > 0) {
					r = kmp_alloc_rmq(mp);
					*r = *q;
					krmq_insert(lc_elem, &root_inner, r, 0);
				}
			}
			i0 = i;
		}
		// get rid of active chains out of range
		while (st < i && (a[i].x>>32 != a[st].x>>32 || a[i].x > a[st].x + max_dist || krmq_size(head, root) > cap_rmq_size)) {
			s.y = (int32_t)a[st].y, s.i = st;
			if ((q = krmq_find(lc_elem, root, &s, 0)) != 0) {
				q = krmq_erase(lc_elem, &root, q, 0);
				kmp_free_rmq(mp, q);
			}
			++st;
		}
		if (max_dist_inner > 0)  { // similar to the block above, but applied to the inner tree
			while (st_inner < i && (a[i].x>>32 != a[st_inner].x>>32 || a[i].x > a[st_inner].x + max_dist_inner || krmq_size(head, root_inner) > cap_rmq_size)) {
				s.y = (int32_t)a[st_inner].y, s.i = st_inner;
				if ((q = krmq_find(lc_elem, root_inner, &s, 0)) != 0) {
					q = krmq_erase(lc_elem, &root_inner, q, 0);
					kmp_free_rmq(mp, q);
				}
				++st_inner;
			}
		}
		// RMQ
		lo.i = INT32_MAX, lo.y = (int32_t)a[i].y - max_dist;
		hi.i = 0, hi.y = (int32_t)a[i].y;
		if ((q = krmq_rmq(lc_elem, root, &lo, &hi)) != 0) {
			int32_t sc, exact, width, n_skip = 0;
			int64_t j = q->i;
			assert(q->y >= lo.y && q->y <= hi.y);
			sc = f[j] + comput_sc_simple(&a[i], &a[j], chn_pen_gap, chn_pen_skip, &exact, &width);
			if (width <= bw && sc > max_f) max_f = sc, max_j = j;
			if (!exact && root_inner && (int32_t)a[i].y > 0) {
				lc_elem_t *lo, *hi;
				s.y = (int32_t)a[i].y - 1, s.i = n;
				krmq_interval(lc_elem, root_inner, &s, &lo, &hi);
				if (lo) {
					const lc_elem_t *q;
					int32_t width, n_rmq_iter = 0;
					krmq_itr_t(lc_elem) itr;
					krmq_itr_find(lc_elem, root_inner, lo, &itr);
					while ((q = krmq_at(&itr)) != 0) {
						if (q->y < (int32_t)a[i].y - max_dist_inner) break;
						++n_rmq_iter;
						j = q->i;
						sc = f[j] + comput_sc_simple(&a[i], &a[j], chn_pen_gap, chn_pen_skip, 0, &width);
						if (width <= bw) {
							if (sc > max_f) {
								max_f = sc, max_j = j;
								if (n_skip > 0) --n_skip;
							} else if (t[j] == (int32_t)i) {
								if (++n_skip > max_chn_skip)
									break;
							}
							if (p[j] >= 0) t[p[j]] = i;
						}
						if (!krmq_itr_prev(lc_elem, &itr)) break;
					}
					n_iter += n_rmq_iter;
				}
			}
		}
		// set max
		assert(max_j < 0 || (a[max_j].x < a[i].x && (int32_t)a[max_j].y < (int32_t)a[i].y));
		f[i] = max_f, p[i] = max_j;
		v[i] = max_j >= 0 && v[max_j] > max_f? v[max_j] : max_f; // v[] keeps the peak score up to i; f[] is the score ending at i, not always the peak
		if (mmax_f < max_f) mmax_f = max_f;
		if (max_rmq_size < krmq_size(head, root)) max_rmq_size = krmq_size(head, root);
	}
	km_destroy(mem_mp);

	u = mg_chain_backtrack(km, n, f, p, v, t, min_cnt, min_sc, max_drop, &n_u, &n_v);
	*n_u_ = n_u, *_u = u; // NB: note that u[] may not be sorted by score here
	kfree(km, p); kfree(km, f); kfree(km, t);
	if (n_u == 0) {
		kfree(km, a); kfree(km, v);
		return 0;
	}
	return compact_a(km, n_u, u, n_v, v, a);
}


mm128_t *mg_plchain_dp(
    int max_dist_x, int max_dist_y, int bw, int max_skip, int max_iter,
    int min_cnt, int min_sc, float chn_pen_gap, float chn_pen_skip, int is_cdna,
    int n_seg, int64_t n,  // NOTE: n is number of anchors
    mm128_t *a,            // NOTE: a is ptr to anchors.
    int *n_u_, uint64_t **_u,
    void *km) {  // TODO: make sure this works when n has more than 32 bits

	max_skip = INT32_MAX; // FIXME: no skip limitation for test purpose
	
	int64_t *p;
    int32_t *f, *t, *v, n_u, n_v, mmax_f = 0, max_drop = bw;
	uint64_t *u;

	if (_u) *_u = 0, *n_u_ = 0;
	if (n == 0 || a == 0) {
		kfree(km, a);
		return 0;
	}

	if (max_dist_x < bw) max_dist_x = bw;
	if (max_dist_y < bw && !is_cdna) max_dist_y = bw;
	if (is_cdna) max_drop = INT32_MAX;

	KMALLOC(km, p, n);
	KMALLOC(km, f, n);
	KMALLOC(km, v, n); // NOTE: max score up to i
	KCALLOC(km, t, n); // NOTE: used to track if it is a predecessor of an anchor already chained to

	size_t key = pltask_append(n, a, max_dist_x, max_dist_y, bw, max_skip, max_iter, chn_pen_gap, chn_pen_skip, is_cdna, n_seg); // NOTE: append anchors to pin memory, and get the key to result

    p = get_p(p, n, key);
    f = get_f(f, n, key); // get results from pin memory

    // NOTE: t is not use, v is updated, f & p are inputs, n_u & n_v are outputs.
	u = mg_chain_backtrack(km, n, f, p, v, t, min_cnt, min_sc, max_drop, &n_u, &n_v);
	*n_u_ = n_u, *_u = u; // NB: note that u[] may not be sorted by score here

	kfree(km, p); 
	kfree(km, f); 
	kfree(km, t);
	if (n_u == 0) {
		kfree(km, a); kfree(km, v);
		return 0;
	}

	mm128_t *b = compact_a(km, n_u, u, n_v, v, a);
	// debug_compact_anchors(b, n_v);

	return b;
}

mm128_t *forward_chain_cpu(int max_dist_x, int max_dist_y, int bw, int max_skip, int max_iter,
    int min_cnt, int min_sc, float chn_pen_gap, float chn_pen_skip, int is_cdna,
    int n_seg, int64_t n,  // NOTE: n is number of anchors
    mm128_t *a,            // NOTE: a is ptr to anchors.
    int *n_u_, uint64_t **_u,
    void *km) { 

	int64_t *p;
    int32_t *f, *t, *v, n_u, n_v, mmax_f = 0, max_drop = bw;
    int32_t *range;  // successor range
	uint64_t *u;

	if (_u) *_u = 0, *n_u_ = 0;
	if (n == 0 || a == 0) {
		kfree(km, a);
		return 0;
	}

	fprintf(stderr, "[M: %s] enter forward chaining\n", __func__);

	KMALLOC(km, p, n);
	KMALLOC(km, f, n);
	KMALLOC(km, v, n); // NOTE: max score up to i
	KCALLOC(km, t, n); // NOTE: used to track if it is a predecessor of an anchor already chained to

	if (max_dist_x < bw) max_dist_x = bw;
    if (max_dist_y < bw && !is_cdna) max_dist_y = bw;
	if (is_cdna) max_drop = INT32_MAX;

    /* range selection outputs */
	KMALLOC(km, range, n);

    /* score calculation outputs */
    for (int i = 0; i < n; ++i) {
        f[i] = a[i].y >> 32 & 0xff; // length of anchor
        p[i] = -1;
    }

    /* range selection */
    forward_range_selection_cpu_binary(a, n, max_dist_x, 5000, range); // max_iter = 4096

    /* score calculation */
    forward_score_cpu(a, n, range, max_dist_x, max_dist_y, bw, chn_pen_gap,
                      chn_pen_skip, is_cdna, n_seg, f, p);

	// NOTE: t is not use, v is updated, f & p are inputs, n_u & n_v are outputs.
	u = mg_chain_backtrack(km, n, f, p, v, t, min_cnt, min_sc, max_drop, &n_u, &n_v);
	*n_u_ = n_u, *_u = u; // NB: note that u[] may not be sorted by score here

	kfree(km, p); 
	kfree(km, f); 
	kfree(km, t);
	kfree(km, range);
	if (n_u == 0) {
		kfree(km, a); kfree(km, v);
		return 0;
	}

	mm128_t *b = compact_a(km, n_u, u, n_v, v, a);
	// debug_compact_anchors(b, n_v);
	fprintf(stderr, "[M: %s] done forward chaining\n", __func__);

	return b;
}

inline int64_t binary_search(mm128_t* a, int max_dist_x, int64_t i, int64_t start){
    int64_t st_high = start, st_low=i;
    while (st_high != st_low) {
        int64_t mid = (st_high + st_low -1) / 2+1;
        if (a[i].x >> 32 != a[mid].x >> 32 ||
            a[mid].x > a[i].x + max_dist_x) {
            st_high = mid - 1;
        } else {
            st_low = mid;
        }
    }
    return st_high;
}

void forward_range_selection_cpu_binary(mm128_t* a, int64_t n, int max_dist_x,
                                 int max_iter,  // input  max_detection_range
                                 int32_t* range) {  // output
    int64_t i;
    int range_op[7] = {16, 512, 1024, 2048, 3072, 4096, max_iter};  // Range Options
    for (i = 0; i < n; ++i) {
        int64_t st;
        for (int j = 0; j < 7; ++j) {
            st = i + range_op[j] < n ? i + range_op[j] : n - 1;
            if (st > i &&
                (a[i].x >> 32 != a[st].x >> 32 ||
                 a[st].x > a[i].x + max_dist_x)) {  // Find the smallest range
                                                    // with a too large gap
                break;
            }
        }
        st = binary_search(a, max_dist_x, i, st);
        range[i] = st - i;
    }  // iterate through all anchors
}

void forward_range_selection_cpu(mm128_t* a, int64_t n, int max_dist_x,
                                 int max_iter,  // input  max_detection_range
                                 int32_t* range) {  // output
    int64_t i;
    int range_op[7] = {16, 512, 1024, 2048, 3072, 4096, 5000};  // Range Options
    for (i = 0; i < n; ++i) {
        int64_t st = i + max_iter < n ? i + max_iter : n-1;
        for (int j = 0; j < 7; ++j) {
            st = i + range_op[j] < n ? i + range_op[j] : n-1;
            if (st > i && (a[i].x >> 32 != a[st].x >> 32
                          || a[st].x > a[i].x + max_dist_x)) {  // Find the smallest range with a too large gap
                break;
            }
        }
        while (st > i && (a[i].x >> 32 != a[st].x >> 32  // NOTE: different prefix cannot become predecessor 
                          || a[st].x > a[i].x + max_dist_x)) { // NOTE: same prefix compare the value
            --st;
        }
        range[i] = st - i;
    }  // iterate through all anchors
}

void forward_score_cpu(mm128_t* a, int64_t n  // [in] anchors
                       ,
                       int32_t* range  // [in] successor range
                       ,
                       int max_dist_x, int max_dist_y, int bw,
                       float chn_pen_gap, float chn_pen_skip, int is_cdna,
                       int n_seg  // [in] score function parameters
                       ,
                       int32_t* f,
                       int64_t* p  // [out] score and previous anchor chained to
) {
    for (int64_t i = 0; i < n; ++i) {  // iterate through all anchors
        for (int64_t j = i + 1; j <= i + range[i];
             ++j) {  // iterate through the successor range
            int32_t sc;
            sc = comput_sc(&a[j], &a[i], max_dist_x, max_dist_y, bw,
                           chn_pen_gap, chn_pen_skip, is_cdna, n_seg);
            if (sc == INT32_MIN) continue;
            sc += f[i];
            if (sc >= f[j] && sc != (a[j].y>>32 & 0xff)) {
                f[j] = sc;
                p[j] = i;
            }
        }  // j
    }      // i
}

