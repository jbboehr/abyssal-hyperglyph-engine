/*
 * Abyssal Hyperglyph Engine: Gate of the Adamantine Oath
 *
 * Copyright (c) 2026 Abyssal Hyperglyph Engine contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-only WITH romic-exception
 */

#ifndef AHE_BROKER_CLIENT_H
#define AHE_BROKER_CLIENT_H

#include <stdbool.h>
#include <stddef.h>

#include "ahe_opcache_provider.h"

typedef struct _ahe_broker_client {
	int socket_fd;
	int cache_fd;
	int lock_fd;
	void *mapping;
	size_t mapping_size;
	void *segment_allocation;
	bool creator;
	bool reattached;
	bool acquired;
	bool ready;
	bool timed_out;
} ahe_broker_client;

#define AHE_BROKER_CLIENT_INITIALIZER \
	{ -1, -1, -1, NULL, 0, NULL, false, false, false, false, false }

int ahe_broker_client_acquire(
	ahe_broker_client *client,
	const char *socket_path,
	const char *cache_key,
	size_t requested_size,
	ahe_opcache_shm_segment_v1 ***shared_segments,
	int *shared_segment_count,
	void **reattached_shared_globals,
	const char **error_in
);

int ahe_broker_client_lock(ahe_broker_client *client);
int ahe_broker_client_unlock(ahe_broker_client *client);
int ahe_broker_client_publish(ahe_broker_client *client, void *shared_globals);
void ahe_broker_client_abort(ahe_broker_client *client);
int ahe_broker_client_detach(
	ahe_broker_client *client,
	ahe_opcache_shm_segment_v1 *shared_segment
);
void ahe_broker_client_shutdown(ahe_broker_client *client);

#endif /* AHE_BROKER_CLIENT_H */
