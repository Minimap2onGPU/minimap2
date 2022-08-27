#include <pthread.h>
#include <stdlib.h>
#include <limits.h>
#include <stdint.h>
#include "kthread.h"

#if (defined(WIN32) || defined(_WIN32)) && defined(_MSC_VER)
#define __sync_fetch_and_add(ptr, addend)     _InterlockedExchangeAdd((void*)ptr, addend)
#endif

/************
 * kt_for() *
 ************/

struct kt_for_t;

typedef struct {
	struct kt_for_t *t;
	long i;
} ktf_worker_t;

typedef struct kt_for_t {
	int n_threads;
	long n;
	ktf_worker_t *w;
	void (*func)(void*,long,int);
	void *data;
} kt_for_t;

static inline long steal_work(kt_for_t *t)
{
	// NOTE: check if other thread is lagging behind and do its future work
	int i, min_i = -1;
	long k, min = LONG_MAX;
	for (i = 0; i < t->n_threads; ++i)
		if (min > t->w[i].i) min = t->w[i].i, min_i = i;
	k = __sync_fetch_and_add(&t->w[min_i].i, t->n_threads);
	return k >= t->n? -1 : k;
}

static void *ktf_worker(void *data)
{
	ktf_worker_t *w = (ktf_worker_t*)data;
	long i;
	for (;;) {
		i = __sync_fetch_and_add(&w->i, w->t->n_threads); // NOTE: atomic add, i starts from thread_idx
		// FIXME: why atomic add is necessary here
		if (i >= w->t->n) break;
		w->t->func(w->t->data, i, w - w->t->w);
	}
	while ((i = steal_work(w->t)) >= 0)
		w->t->func(w->t->data, i, w - w->t->w);
	pthread_exit(0);
}

#include <stdio.h>

void kt_for(int n_threads, void (*func)(void*,long,int), void *data, long n)
{	
	// NOTE: func = worker_for, n_threads is input of mm_map_file_frag(), n is number of frags
    // n_threads = 1; // FIXME: comment this to enable multithread
	fprintf(stderr, "[M: %s] kt_for %ld segs on %d threads\n", __func__, n, n_threads);
    if (n_threads > 1) {
        int i;
		kt_for_t t; // NOTE: multithreads' metadata
		pthread_t *tid;
		t.func = func, t.data = data, t.n_threads = n_threads, t.n = n;
		t.w = (ktf_worker_t*)calloc(n_threads, sizeof(ktf_worker_t));
		tid = (pthread_t*)calloc(n_threads, sizeof(pthread_t));
		for (i = 0; i < n_threads; ++i)
			t.w[i].t = &t, t.w[i].i = i;
		for (i = 0; i < n_threads; ++i) pthread_create(&tid[i], 0, ktf_worker, &t.w[i]);
		for (i = 0; i < n_threads; ++i) pthread_join(tid[i], 0);
		free(tid); free(t.w);
    } else {
        long j;
		for (j = 0; j < n; ++j) func(data, j, 0);
    }
}

/*****************
 * kt_pipeline() *
 *****************/

struct ktp_t;

typedef struct {
	struct ktp_t *pl;
	int64_t index;
	int step;
	void *data;
} ktp_worker_t;

typedef struct ktp_t {
	void *shared;
	void *(*func)(void*, int, void*);
	int64_t index;
	int n_workers, n_steps;
	ktp_worker_t *workers;
	pthread_mutex_t mutex;
	pthread_cond_t cv;
} ktp_t;

static void *ktp_worker(void *data)
{	// NOTE: called from kt_pipeline
	ktp_worker_t *w = (ktp_worker_t*)data;
	ktp_t *p = w->pl;
	while (w->step < p->n_steps) { // NOTE: stop when all steps is done
		// test whether we can kick off the job with this worker
		pthread_mutex_lock(&p->mutex);
		for (;;) {
			int i;
			// test whether another worker is doing the same step
			for (i = 0; i < p->n_workers; ++i) {
				if (w == &p->workers[i]) continue; // ignore itself
				if (p->workers[i].step <= w->step && p->workers[i].index < w->index)
					break;
			}
			if (i == p->n_workers) break; // no workers with smaller indices are doing w->step or the previous steps
			pthread_cond_wait(&p->cv, &p->mutex);
		}
		pthread_mutex_unlock(&p->mutex);

		// NOTE: working on w->step
		fprintf(stderr, "[M: %s] ktp_worker %ld on step %d\n", __func__, w->index, w->step);
		w->data = p->func(p->shared, w->step, w->step? w->data : 0); // NOTE: for the first step, input is NULL, enter worker_pipeline()
		fprintf(stderr, "[M: %s] ktp_worker %ld done step %d\n", __func__, w->index, w->step);

		// update step and let other workers know
		pthread_mutex_lock(&p->mutex);
		// NOTE: stop pipeline when step = n_steps-1 and data is empty, step 1 is mapping
		w->step = ((w->step == p->n_steps - 1) || w->data) ? ((w->step + 1) % p->n_steps) : p->n_steps;
		if (w->step == 0) w->index = p->index++; // NOTE: index increase after finish n_steps
		pthread_cond_broadcast(&p->cv);
		pthread_mutex_unlock(&p->mutex);
	}
	pthread_exit(0);
}

// n_steps = 3, func = worker_pipeline, n_threads = (at most) 3
void kt_pipeline(int n_threads, void *(*func)(void*, int, void*), void *shared_data, int n_steps)
{
	// NOTE: called from mm_map_file_frag
	ktp_t aux;
	pthread_t *tid;
	int i;

	if (n_threads < 1) n_threads = 1;
	aux.n_workers = n_threads;
	aux.n_steps = n_steps;
	aux.func = func;
	aux.shared = shared_data; // include n_threads in kt_for
	aux.index = 0;
	pthread_mutex_init(&aux.mutex, 0);
	pthread_cond_init(&aux.cv, 0);

	aux.workers = (ktp_worker_t*)calloc(n_threads, sizeof(ktp_worker_t));
	for (i = 0; i < n_threads; ++i) {
		ktp_worker_t *w = &aux.workers[i];
		w->step = 0; w->pl = &aux; w->data = 0;
		w->index = aux.index++;
	}
	fprintf(stderr, "[M: %s] pl_threads %d, max_aux_index %ld\n", __func__, n_threads, aux.index);

	tid = (pthread_t*)calloc(n_threads, sizeof(pthread_t));
	for (i = 0; i < n_threads; ++i) pthread_create(&tid[i], 0, ktp_worker, &aux.workers[i]); // NOTE: aux go to worker_pipeline
	for (i = 0; i < n_threads; ++i) pthread_join(tid[i], 0);
	free(tid); free(aux.workers);

	pthread_mutex_destroy(&aux.mutex);
	pthread_cond_destroy(&aux.cv);
}
