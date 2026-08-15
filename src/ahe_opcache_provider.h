/*
 * Abyssal Hyperglyph Engine: Gate of the Adamantine Oath
 *
 * Copyright (c) 2026 Abyssal Hyperglyph Engine contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-only WITH romic-exception
 */

#ifndef AHE_OPCACHE_PROVIDER_H
#define AHE_OPCACHE_PROVIDER_H

#include <stddef.h>
#include <stdint.h>

#define ZEND_OPCACHE_SHM_PROVIDER_ABI_V1 1u
#define ZEND_OPCACHE_SHM_PROVIDER_REGISTER_SYMBOL_V1 \
	"zend_opcache_register_shared_memory_provider_v1"

#define ZEND_OPCACHE_SHM_PROVIDER_SUCCESS 0
#define ZEND_OPCACHE_SHM_PROVIDER_FAILURE -1

#define ZEND_OPCACHE_SHM_ALLOC_FAILURE 0

typedef struct _ahe_opcache_shm_segment_v1 {
	size_t size;
	size_t end;
	size_t pos;
	void *p;
} ahe_opcache_shm_segment_v1;

typedef struct _ahe_opcache_shm_provider_v1 {
	uint32_t abi_version;
	uint32_t struct_size;
	const char *name;
	void *context;

	int (*create_segments)(
		void *context,
		size_t requested_size,
		ahe_opcache_shm_segment_v1 ***shared_segments,
		int *shared_segment_count,
		void **reattached_shared_globals,
		const char **error_in
	);
	int (*detach_segment)(void *context, ahe_opcache_shm_segment_v1 *shared_segment);
	size_t (*segment_type_size)(void *context);

	int (*lock)(void *context);
	int (*unlock)(void *context);

	void (*startup_complete)(void *context, int reattached, void *shared_globals);
	void (*startup_aborted)(void *context, const char *reason);
	void (*shutdown)(void *context);
} ahe_opcache_shm_provider_v1;

typedef int (*ahe_opcache_register_shared_memory_provider_v1_t)(
	const ahe_opcache_shm_provider_v1 *provider
);

#endif /* AHE_OPCACHE_PROVIDER_H */
