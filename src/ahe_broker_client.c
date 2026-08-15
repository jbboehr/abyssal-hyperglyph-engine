/*
 * Abyssal Hyperglyph Engine: Gate of the Adamantine Oath
 *
 * Copyright (c) 2026 Abyssal Hyperglyph Engine contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-only WITH romic-exception
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License version 3,
 * as published by the Free Software Foundation, together with the Romic
 * Exception (an additional permission under section 7 of that license).
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 */

#include "ahe_broker_client.h"
#include "ahe_broker_protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef MAP_FIXED_NOREPLACE
# define MAP_FIXED_NOREPLACE 0x100000
#endif

#define AHE_BROKER_IO_TIMEOUT_SECONDS 1

static void ahe_broker_message_init(ahe_broker_message_v1 *message, uint32_t type)
{
	memset(message, 0, sizeof(*message));
	message->magic = AHE_BROKER_PROTOCOL_MAGIC;
	message->version = AHE_BROKER_PROTOCOL_VERSION;
	message->type = type;
}

static int ahe_broker_send_message(int socket_fd, const ahe_broker_message_v1 *message)
{
	ssize_t sent;

	do {
		sent = send(socket_fd, message, sizeof(*message), MSG_NOSIGNAL);
	} while (sent < 0 && errno == EINTR);

	return sent == (ssize_t) sizeof(*message) ? 0 : -1;
}

static void ahe_broker_close_received_fds(int *fds, size_t fd_count)
{
	size_t i;

	for (i = 0; i < fd_count; i++) {
		if (fds[i] >= 0) {
			close(fds[i]);
			fds[i] = -1;
		}
	}
}

static int ahe_broker_receive_message(
	int socket_fd,
	ahe_broker_message_v1 *message,
	int *fds,
	size_t fd_capacity,
	size_t *received_fd_count
)
{
	char control[CMSG_SPACE(sizeof(int) * AHE_BROKER_DESCRIPTOR_COUNT)];
	struct cmsghdr *control_message;
	struct iovec vector;
	struct msghdr header;
	ssize_t received;
	size_t fd_count = 0;
	size_t i;

	*received_fd_count = 0;
	for (i = 0; i < fd_capacity; i++) {
		fds[i] = -1;
	}

	memset(message, 0, sizeof(*message));
	memset(control, 0, sizeof(control));
	memset(&header, 0, sizeof(header));
	vector.iov_base = message;
	vector.iov_len = sizeof(*message);
	header.msg_iov = &vector;
	header.msg_iovlen = 1;
	header.msg_control = control;
	header.msg_controllen = sizeof(control);

	do {
		received = recvmsg(socket_fd, &header, MSG_CMSG_CLOEXEC);
	} while (received < 0 && errno == EINTR);
	if (received < 0) {
		return -1;
	}

	for (control_message = CMSG_FIRSTHDR(&header);
	     control_message;
	     control_message = CMSG_NXTHDR(&header, control_message)) {
		size_t payload_size;
		size_t supplied_fd_count;

		if (control_message->cmsg_level != SOL_SOCKET
		 || control_message->cmsg_type != SCM_RIGHTS
		 || control_message->cmsg_len < CMSG_LEN(0)) {
			continue;
		}

		payload_size = control_message->cmsg_len - CMSG_LEN(0);
		if (payload_size % sizeof(int) != 0) {
			int *supplied_fds = (int *) CMSG_DATA(control_message);

			for (i = 0; i < payload_size / sizeof(int); i++) {
				close(supplied_fds[i]);
			}
			ahe_broker_close_received_fds(fds, fd_count);
			errno = EPROTO;
			return -1;
		}
		supplied_fd_count = payload_size / sizeof(int);
		if (fd_count + supplied_fd_count > fd_capacity) {
			int *supplied_fds = (int *) CMSG_DATA(control_message);

			for (i = 0; i < supplied_fd_count; i++) {
				close(supplied_fds[i]);
			}
			ahe_broker_close_received_fds(fds, fd_count);
			errno = EPROTO;
			return -1;
		}

		memcpy(&fds[fd_count], CMSG_DATA(control_message), payload_size);
		fd_count += supplied_fd_count;
	}

	if (received != (ssize_t) sizeof(*message)
	 || (header.msg_flags & (MSG_TRUNC | MSG_CTRUNC))
	 || message->magic != AHE_BROKER_PROTOCOL_MAGIC
	 || message->version != AHE_BROKER_PROTOCOL_VERSION) {
		ahe_broker_close_received_fds(fds, fd_count);
		errno = EPROTO;
		return -1;
	}

	*received_fd_count = fd_count;
	return 0;
}

static int ahe_broker_connect(const char *socket_path)
{
	struct sockaddr_un address;
	struct stat socket_status;
	struct timeval timeout;
	struct ucred credentials;
	socklen_t credentials_size = sizeof(credentials);
	int socket_fd;
	size_t socket_path_length;

	socket_path_length = strlen(socket_path);
	if (!socket_path_length || socket_path_length >= sizeof(address.sun_path)) {
		errno = ENAMETOOLONG;
		return -1;
	}

	socket_fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	if (socket_fd < 0) {
		return -1;
	}
	memset(&timeout, 0, sizeof(timeout));
	timeout.tv_sec = AHE_BROKER_IO_TIMEOUT_SECONDS;
	if (setsockopt(
		socket_fd,
		SOL_SOCKET,
		SO_RCVTIMEO,
		&timeout,
		sizeof(timeout)
	) < 0 || setsockopt(
		socket_fd,
		SOL_SOCKET,
		SO_SNDTIMEO,
		&timeout,
		sizeof(timeout)
	) < 0) {
		close(socket_fd);
		return -1;
	}

	memset(&address, 0, sizeof(address));
	address.sun_family = AF_UNIX;
	memcpy(address.sun_path, socket_path, socket_path_length + 1);

	if (connect(socket_fd, (struct sockaddr *) &address, sizeof(address)) < 0) {
		close(socket_fd);
		return -1;
	}
	if (getsockopt(
		socket_fd,
		SOL_SOCKET,
		SO_PEERCRED,
		&credentials,
		&credentials_size
	) < 0
	 || credentials_size != sizeof(credentials)
	 || credentials.pid <= 0
	 || credentials.uid != geteuid()
	 || lstat(socket_path, &socket_status) < 0
	 || !S_ISSOCK(socket_status.st_mode)
	 || socket_status.st_uid != geteuid()
	 || (socket_status.st_mode & 0777) != 0600) {
		close(socket_fd);
		errno = EPERM;
		return -1;
	}

	return socket_fd;
}

static void ahe_broker_client_close_descriptors(ahe_broker_client *client)
{
	if (client->cache_fd >= 0) {
		close(client->cache_fd);
		client->cache_fd = -1;
	}
	if (client->lock_fd >= 0) {
		close(client->lock_fd);
		client->lock_fd = -1;
	}
	if (client->socket_fd >= 0) {
		close(client->socket_fd);
		client->socket_fd = -1;
	}
}

static int ahe_broker_allocate_segment(
	ahe_broker_client *client,
	ahe_opcache_shm_segment_v1 ***shared_segments,
	int *shared_segment_count
)
{
	ahe_opcache_shm_segment_v1 *shared_segment;
	void *allocation;

	allocation = calloc(1, sizeof(void *) + sizeof(*shared_segment));
	if (!allocation) {
		return -1;
	}

	*shared_segments = allocation;
	shared_segment = (ahe_opcache_shm_segment_v1 *)
		((char *) allocation + sizeof(void *));
	(*shared_segments)[0] = shared_segment;
	*shared_segment_count = 1;

	shared_segment->p = client->mapping;
	shared_segment->pos = 0;
	shared_segment->end = client->mapping_size;
	shared_segment->size = client->mapping_size;
	client->segment_allocation = allocation;

	return 0;
}

int ahe_broker_client_acquire(
	ahe_broker_client *client,
	const char *socket_path,
	const char *cache_key,
	size_t requested_size,
	ahe_opcache_shm_segment_v1 ***shared_segments,
	int *shared_segment_count,
	void **reattached_shared_globals,
	const char **error_in
)
{
	ahe_broker_message_v1 request;
	ahe_broker_message_v1 response;
	int received_fds[AHE_BROKER_DESCRIPTOR_COUNT];
	size_t received_fd_count;
	void *requested_address = NULL;
	int mapping_flags = MAP_SHARED;
	int result;
	size_t cache_key_length;

	client->timed_out = false;
	cache_key_length = strlen(cache_key);
	if (cache_key_length >= sizeof(request.cache_key)) {
		*error_in = "AHE cache key is too long";
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}

	client->socket_fd = ahe_broker_connect(socket_path);
	if (client->socket_fd < 0) {
		*error_in = "AHE broker is unavailable";
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}

	ahe_broker_message_init(&request, AHE_BROKER_ACQUIRE);
	request.mapping_size = requested_size;
	memcpy(request.cache_key, cache_key, cache_key_length + 1);

	if (ahe_broker_send_message(client->socket_fd, &request) < 0
	 || ahe_broker_receive_message(
		client->socket_fd,
		&response,
		received_fds,
		AHE_BROKER_DESCRIPTOR_COUNT,
		&received_fd_count
	 ) < 0) {
		client->timed_out = errno == EAGAIN || errno == EWOULDBLOCK;
		*error_in = client->timed_out
			? "AHE broker did not respond before the timeout"
			: "AHE broker protocol failure";
		ahe_broker_client_close_descriptors(client);
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}

	if (response.type == AHE_BROKER_DECLINE || response.type == AHE_BROKER_ERROR) {
		*error_in = response.type == AHE_BROKER_DECLINE
			? "AHE broker declined the cache key"
			: "AHE broker could not create the cache";
		ahe_broker_close_received_fds(received_fds, received_fd_count);
		ahe_broker_client_close_descriptors(client);
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}
	if (received_fd_count != AHE_BROKER_DESCRIPTOR_COUNT
	 || response.mapping_size != requested_size
	 || (response.type != AHE_BROKER_CREATE && response.type != AHE_BROKER_ATTACH)) {
		*error_in = "AHE broker returned an invalid allocation response";
		ahe_broker_close_received_fds(received_fds, received_fd_count);
		ahe_broker_client_close_descriptors(client);
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}
	client->cache_fd = received_fds[0];
	client->lock_fd = received_fds[1];

	if (response.type == AHE_BROKER_ATTACH) {
		if (!response.mapping_base
		 || response.shared_globals_offset >= response.mapping_size) {
			*error_in = "AHE broker returned invalid reattachment metadata";
			ahe_broker_client_close_descriptors(client);
			return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
		}
		requested_address = (void *) (uintptr_t) response.mapping_base;
		mapping_flags |= MAP_FIXED_NOREPLACE;
	}

	client->mapping = mmap(
		requested_address,
		requested_size,
		PROT_READ | PROT_WRITE,
		mapping_flags,
		client->cache_fd,
		0
	);
	if (client->mapping == MAP_FAILED) {
		client->mapping = NULL;
		*error_in = response.type == AHE_BROKER_ATTACH
			? "AHE cache address is unavailable"
			: "AHE cache mapping failed";
		ahe_broker_client_close_descriptors(client);
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}
	if (requested_address && client->mapping != requested_address) {
		munmap(client->mapping, requested_size);
		client->mapping = NULL;
		*error_in = "AHE cache mapped at the wrong address";
		ahe_broker_client_close_descriptors(client);
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}

	client->mapping_size = requested_size;
	if (ahe_broker_allocate_segment(client, shared_segments, shared_segment_count) < 0) {
		munmap(client->mapping, client->mapping_size);
		client->mapping = NULL;
		client->mapping_size = 0;
		*error_in = "AHE segment allocation failed";
		ahe_broker_client_close_descriptors(client);
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}

	client->creator = response.type == AHE_BROKER_CREATE;
	client->reattached = response.type == AHE_BROKER_ATTACH;
	client->acquired = true;
	if (client->reattached) {
		*reattached_shared_globals = (char *) client->mapping
			+ response.shared_globals_offset;
		result = ZEND_OPCACHE_SHM_SUCCESSFULLY_REATTACHED;
	} else {
		result = ZEND_OPCACHE_SHM_ALLOC_SUCCESS;
	}

	return result;
}

static int ahe_broker_client_set_lock(ahe_broker_client *client, short lock_type, int command)
{
	struct flock lock;
	int result;

	if (client->lock_fd < 0) {
		return ZEND_OPCACHE_SHM_PROVIDER_FAILURE;
	}

	memset(&lock, 0, sizeof(lock));
	lock.l_type = lock_type;
	lock.l_whence = SEEK_SET;
	lock.l_start = 0;
	lock.l_len = 1;

	do {
		result = fcntl(client->lock_fd, command, &lock);
	} while (result < 0 && errno == EINTR);

	return result == 0
		? ZEND_OPCACHE_SHM_PROVIDER_SUCCESS
		: ZEND_OPCACHE_SHM_PROVIDER_FAILURE;
}

int ahe_broker_client_lock(ahe_broker_client *client)
{
	return ahe_broker_client_set_lock(client, F_WRLCK, F_SETLKW);
}

int ahe_broker_client_unlock(ahe_broker_client *client)
{
	return ahe_broker_client_set_lock(client, F_UNLCK, F_SETLK);
}

static int ahe_broker_client_notify(ahe_broker_client *client, uint32_t type)
{
	ahe_broker_message_v1 request;
	ahe_broker_message_v1 response;
	int unused_fds[1];
	size_t received_fd_count;

	if (client->socket_fd < 0) {
		return -1;
	}

	ahe_broker_message_init(&request, type);
	if (ahe_broker_send_message(client->socket_fd, &request) < 0
	 || ahe_broker_receive_message(
		client->socket_fd,
		&response,
		unused_fds,
		0,
		&received_fd_count
	 ) < 0
	 || response.type != AHE_BROKER_ACK) {
		return -1;
	}

	return 0;
}

int ahe_broker_client_publish(ahe_broker_client *client, void *shared_globals)
{
	ahe_broker_message_v1 request;
	ahe_broker_message_v1 response;
	uintptr_t mapping_base;
	uintptr_t globals;
	int unused_fds[1];
	size_t received_fd_count;

	if (!client->creator || !client->mapping || !shared_globals) {
		return -1;
	}

	mapping_base = (uintptr_t) client->mapping;
	globals = (uintptr_t) shared_globals;
	if (globals < mapping_base || globals - mapping_base >= client->mapping_size) {
		return -1;
	}

	ahe_broker_message_init(&request, AHE_BROKER_READY);
	request.mapping_size = client->mapping_size;
	request.mapping_base = mapping_base;
	request.shared_globals_offset = globals - mapping_base;
	if (ahe_broker_send_message(client->socket_fd, &request) < 0
	 || ahe_broker_receive_message(
		client->socket_fd,
		&response,
		unused_fds,
		0,
		&received_fd_count
	 ) < 0
	 || response.type != AHE_BROKER_ACK) {
		return -1;
	}

	client->ready = true;
	/* OPcache copied this descriptor into shared memory and freed the allocation. */
	client->segment_allocation = NULL;
	return 0;
}

void ahe_broker_client_abort(ahe_broker_client *client)
{
	if (client->acquired) {
		(void) ahe_broker_client_notify(client, AHE_BROKER_ABORT);
	}
}

int ahe_broker_client_detach(
	ahe_broker_client *client,
	ahe_opcache_shm_segment_v1 *shared_segment
)
{
	ahe_opcache_shm_segment_v1 *owned_segment = NULL;

	if (!shared_segment || !shared_segment->p || !shared_segment->size) {
		return ZEND_OPCACHE_SHM_PROVIDER_FAILURE;
	}
	if (client->segment_allocation) {
		owned_segment = (ahe_opcache_shm_segment_v1 *)
			((char *) client->segment_allocation + sizeof(void *));
	}

	if (munmap(shared_segment->p, shared_segment->size) < 0) {
		return ZEND_OPCACHE_SHM_PROVIDER_FAILURE;
	}
	if (client->mapping == shared_segment->p) {
		client->mapping = NULL;
		client->mapping_size = 0;
	}
	if (shared_segment == owned_segment) {
		/* OPcache owns and will free the containing temporary allocation. */
		client->segment_allocation = NULL;
	}

	return ZEND_OPCACHE_SHM_PROVIDER_SUCCESS;
}

void ahe_broker_client_shutdown(ahe_broker_client *client)
{
	if (client->acquired && client->socket_fd >= 0) {
		(void) ahe_broker_client_notify(client, AHE_BROKER_DETACH);
	}
	if (client->mapping && client->mapping_size) {
		munmap(client->mapping, client->mapping_size);
	}
	if (client->reattached && client->segment_allocation) {
		free(client->segment_allocation);
	}

	ahe_broker_client_close_descriptors(client);
	client->mapping = NULL;
	client->mapping_size = 0;
	client->segment_allocation = NULL;
	client->creator = false;
	client->reattached = false;
	client->acquired = false;
	client->ready = false;
	client->timed_out = false;
}
