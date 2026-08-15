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

#include "ahe_broker_protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

enum ahe_generation_state {
	AHE_GENERATION_EMPTY,
	AHE_GENERATION_INITIALIZING,
	AHE_GENERATION_READY,
};

typedef struct _ahe_generation {
	enum ahe_generation_state state;
	int cache_fd;
	int lock_fd;
	int creator_fd;
	uint64_t mapping_size;
	uint64_t mapping_base;
	uint64_t shared_globals_offset;
	char cache_key[AHE_BROKER_CACHE_KEY_SIZE];
} ahe_generation;

typedef struct _ahe_broker_client_connection {
	int fd;
	bool handled_message;
} ahe_broker_client_connection;

static volatile sig_atomic_t ahe_broker_stopping = 0;

static void ahe_broker_handle_signal(int signal_number)
{
	(void) signal_number;
	ahe_broker_stopping = 1;
}

static void ahe_broker_message_init(ahe_broker_message_v1 *message, uint32_t type)
{
	memset(message, 0, sizeof(*message));
	message->magic = AHE_BROKER_PROTOCOL_MAGIC;
	message->version = AHE_BROKER_PROTOCOL_VERSION;
	message->type = type;
}

static int ahe_broker_send_message(
	int client_fd,
	const ahe_broker_message_v1 *message,
	const int *fds,
	size_t fd_count
)
{
	char control[CMSG_SPACE(sizeof(int) * AHE_BROKER_DESCRIPTOR_COUNT)];
	struct cmsghdr *control_message;
	struct iovec vector;
	struct msghdr header;
	ssize_t sent;

	memset(control, 0, sizeof(control));
	memset(&header, 0, sizeof(header));
	vector.iov_base = (void *) message;
	vector.iov_len = sizeof(*message);
	header.msg_iov = &vector;
	header.msg_iovlen = 1;

	if (fd_count) {
		if (fd_count > AHE_BROKER_DESCRIPTOR_COUNT) {
			errno = EINVAL;
			return -1;
		}
		header.msg_control = control;
		header.msg_controllen = CMSG_SPACE(sizeof(int) * fd_count);
		control_message = CMSG_FIRSTHDR(&header);
		control_message->cmsg_level = SOL_SOCKET;
		control_message->cmsg_type = SCM_RIGHTS;
		control_message->cmsg_len = CMSG_LEN(sizeof(int) * fd_count);
		memcpy(CMSG_DATA(control_message), fds, sizeof(int) * fd_count);
	}

	do {
		sent = sendmsg(client_fd, &header, MSG_DONTWAIT | MSG_NOSIGNAL);
	} while (sent < 0 && errno == EINTR && !ahe_broker_stopping);

	return sent == (ssize_t) sizeof(*message) ? 0 : -1;
}

static int ahe_broker_receive_message(int client_fd, ahe_broker_message_v1 *message)
{
	ssize_t received;

	do {
		received = recv(client_fd, message, sizeof(*message), MSG_DONTWAIT);
	} while (received < 0 && errno == EINTR && !ahe_broker_stopping);

	if (received == 0) {
		return 0;
	}
	if (received != (ssize_t) sizeof(*message)
	 || message->magic != AHE_BROKER_PROTOCOL_MAGIC
	 || message->version != AHE_BROKER_PROTOCOL_VERSION) {
		return -1;
	}

	return 1;
}

static void ahe_generation_init(ahe_generation *generation)
{
	memset(generation, 0, sizeof(*generation));
	generation->state = AHE_GENERATION_EMPTY;
	generation->cache_fd = -1;
	generation->lock_fd = -1;
	generation->creator_fd = -1;
}

static void ahe_generation_reset(ahe_generation *generation)
{
	if (generation->cache_fd >= 0) {
		close(generation->cache_fd);
	}
	if (generation->lock_fd >= 0) {
		close(generation->lock_fd);
	}
	ahe_generation_init(generation);
}

static int ahe_generation_create(
	ahe_generation *generation,
	int client_fd,
	const ahe_broker_message_v1 *request
)
{
	if (!request->mapping_size || request->mapping_size > (uint64_t) SIZE_MAX
	 || request->mapping_size > INT64_MAX
	 || !memchr(request->cache_key, '\0', sizeof(request->cache_key))
	 || !request->cache_key[0]) {
		errno = EINVAL;
		return -1;
	}

	generation->cache_fd = memfd_create("ahe-opcache", MFD_CLOEXEC);
	if (generation->cache_fd < 0
	 || ftruncate(generation->cache_fd, (off_t) request->mapping_size) < 0) {
		ahe_generation_reset(generation);
		return -1;
	}

	generation->lock_fd = memfd_create("ahe-opcache-lock", MFD_CLOEXEC);
	if (generation->lock_fd < 0 || ftruncate(generation->lock_fd, 1) < 0) {
		ahe_generation_reset(generation);
		return -1;
	}

	generation->state = AHE_GENERATION_INITIALIZING;
	generation->creator_fd = client_fd;
	generation->mapping_size = request->mapping_size;
	memcpy(generation->cache_key, request->cache_key, sizeof(generation->cache_key));
	return 0;
}

static bool ahe_generation_matches(
	const ahe_generation *generation,
	const ahe_broker_message_v1 *request
)
{
	return request->mapping_size == generation->mapping_size
		&& memchr(request->cache_key, '\0', sizeof(request->cache_key))
		&& strcmp(request->cache_key, generation->cache_key) == 0;
}

static int ahe_broker_handle_acquire(
	int client_fd,
	ahe_generation *generation,
	const ahe_broker_message_v1 *request
)
{
	ahe_broker_message_v1 response;
	int fds[AHE_BROKER_DESCRIPTOR_COUNT];

	if (generation->state == AHE_GENERATION_EMPTY
	 && ahe_generation_create(generation, client_fd, request) < 0) {
		ahe_broker_message_init(&response, AHE_BROKER_ERROR);
		return ahe_broker_send_message(client_fd, &response, NULL, 0);
	}

	if (!ahe_generation_matches(generation, request)
	 || (generation->state == AHE_GENERATION_INITIALIZING
	    && generation->creator_fd != client_fd)) {
		ahe_broker_message_init(&response, AHE_BROKER_DECLINE);
		return ahe_broker_send_message(client_fd, &response, NULL, 0);
	}

	ahe_broker_message_init(
		&response,
		generation->state == AHE_GENERATION_READY
			? AHE_BROKER_ATTACH
			: AHE_BROKER_CREATE
	);
	response.mapping_size = generation->mapping_size;
	response.mapping_base = generation->mapping_base;
	response.shared_globals_offset = generation->shared_globals_offset;
	fds[0] = generation->cache_fd;
	fds[1] = generation->lock_fd;

	return ahe_broker_send_message(
		client_fd,
		&response,
		fds,
		AHE_BROKER_DESCRIPTOR_COUNT
	);
}

static int ahe_broker_handle_ready(
	int client_fd,
	ahe_generation *generation,
	const ahe_broker_message_v1 *request
)
{
	ahe_broker_message_v1 response;

	if (generation->state != AHE_GENERATION_INITIALIZING
	 || generation->creator_fd != client_fd
	 || request->mapping_size != generation->mapping_size
	 || !request->mapping_base
	 || request->shared_globals_offset >= request->mapping_size) {
		ahe_broker_message_init(&response, AHE_BROKER_ERROR);
		return ahe_broker_send_message(client_fd, &response, NULL, 0);
	}

	ahe_broker_message_init(&response, AHE_BROKER_ACK);
	if (ahe_broker_send_message(client_fd, &response, NULL, 0) < 0) {
		return -1;
	}

	generation->mapping_base = request->mapping_base;
	generation->shared_globals_offset = request->shared_globals_offset;
	generation->state = AHE_GENERATION_READY;
	generation->creator_fd = -1;
	return 0;
}

static bool ahe_broker_handle_client_message(
	ahe_broker_client_connection *client,
	ahe_generation *generation
)
{
	ahe_broker_message_v1 request;
	ahe_broker_message_v1 response;
	int receive_result;

	receive_result = ahe_broker_receive_message(client->fd, &request);
	if (receive_result <= 0) {
		return false;
	}
	client->handled_message = true;

	switch (request.type) {
		case AHE_BROKER_ACQUIRE:
			return ahe_broker_handle_acquire(client->fd, generation, &request) == 0;
		case AHE_BROKER_READY:
			return ahe_broker_handle_ready(client->fd, generation, &request) == 0;
		case AHE_BROKER_ABORT:
			if (generation->state == AHE_GENERATION_INITIALIZING
			 && generation->creator_fd == client->fd) {
				ahe_generation_reset(generation);
			}
			ahe_broker_message_init(&response, AHE_BROKER_ACK);
			return ahe_broker_send_message(client->fd, &response, NULL, 0) == 0;
		case AHE_BROKER_DETACH:
			ahe_broker_message_init(&response, AHE_BROKER_ACK);
			(void) ahe_broker_send_message(client->fd, &response, NULL, 0);
			return false;
		default:
			ahe_broker_message_init(&response, AHE_BROKER_ERROR);
			(void) ahe_broker_send_message(client->fd, &response, NULL, 0);
			return false;
	}
}

static void ahe_broker_close_client(
	ahe_broker_client_connection *clients,
	size_t *client_count,
	size_t client_index,
	ahe_generation *generation
)
{
	int client_fd = clients[client_index].fd;

	if (generation->state == AHE_GENERATION_INITIALIZING
	 && generation->creator_fd == client_fd) {
		ahe_generation_reset(generation);
	}
	close(client_fd);
	clients[client_index] = clients[*client_count - 1];
	(*client_count)--;
}

static int ahe_broker_add_client(
	ahe_broker_client_connection **clients,
	size_t *client_count,
	size_t *client_capacity,
	int client_fd
)
{
	ahe_broker_client_connection *resized_clients;
	size_t new_capacity;

	if (*client_count == *client_capacity) {
		if (*client_capacity > SIZE_MAX / 2) {
			errno = ENOMEM;
			return -1;
		}
		new_capacity = *client_capacity ? *client_capacity * 2 : 8;
		if (new_capacity > SIZE_MAX / sizeof(**clients)) {
			errno = ENOMEM;
			return -1;
		}
		resized_clients = realloc(*clients, new_capacity * sizeof(**clients));
		if (!resized_clients) {
			return -1;
		}
		*clients = resized_clients;
		*client_capacity = new_capacity;
	}

	(*clients)[*client_count].fd = client_fd;
	(*clients)[*client_count].handled_message = false;
	(*client_count)++;
	return 0;
}

static int ahe_broker_prepare_parent_directory(const char *socket_path)
{
	char parent_path[sizeof(((struct sockaddr_un *) 0)->sun_path)];
	const char *last_slash;
	struct stat status;
	size_t parent_length;

	last_slash = strrchr(socket_path, '/');
	if (last_slash && !last_slash[1]) {
		errno = EINVAL;
		return -1;
	}
	if (!last_slash) {
		memcpy(parent_path, ".", sizeof("."));
	} else if (last_slash == socket_path) {
		memcpy(parent_path, "/", sizeof("/"));
	} else {
		parent_length = (size_t) (last_slash - socket_path);
		if (parent_length >= sizeof(parent_path)) {
			errno = ENAMETOOLONG;
			return -1;
		}
		memcpy(parent_path, socket_path, parent_length);
		parent_path[parent_length] = '\0';
	}

	if (mkdir(parent_path, 0700) < 0 && errno != EEXIST) {
		return -1;
	}
	if (lstat(parent_path, &status) < 0
	 || !S_ISDIR(status.st_mode)
	 || status.st_uid != geteuid()
	 || (status.st_mode & (S_IWGRP | S_IWOTH))) {
		errno = EPERM;
		return -1;
	}

	return 0;
}

static int ahe_broker_remove_stale_socket(
	const char *socket_path,
	const struct sockaddr_un *address
)
{
	struct stat initial_status;
	struct stat current_status;
	int probe_fd;
	int connect_errno;

	if (lstat(socket_path, &initial_status) < 0) {
		return errno == ENOENT ? 0 : -1;
	}
	if (!S_ISSOCK(initial_status.st_mode) || initial_status.st_uid != geteuid()) {
		errno = EPERM;
		return -1;
	}

	probe_fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
	if (probe_fd < 0) {
		return -1;
	}
	if (connect(
		probe_fd,
		(const struct sockaddr *) address,
		sizeof(*address)
	) == 0) {
		close(probe_fd);
		errno = EADDRINUSE;
		return -1;
	}
	connect_errno = errno;
	close(probe_fd);
	if (connect_errno == EINPROGRESS || connect_errno == EAGAIN
	 || connect_errno == EALREADY) {
		errno = EADDRINUSE;
		return -1;
	}
	if (connect_errno == ENOENT) {
		return 0;
	}
	if (connect_errno != ECONNREFUSED) {
		errno = connect_errno;
		return -1;
	}

	if (lstat(socket_path, &current_status) < 0) {
		return errno == ENOENT ? 0 : -1;
	}
	if (!S_ISSOCK(current_status.st_mode)
	 || current_status.st_uid != geteuid()
	 || current_status.st_dev != initial_status.st_dev
	 || current_status.st_ino != initial_status.st_ino) {
		errno = EAGAIN;
		return -1;
	}

	return unlink(socket_path);
}

static int ahe_broker_create_listener(const char *socket_path)
{
	struct sockaddr_un address;
	int listener_fd;
	int saved_errno;
	size_t socket_path_length;

	socket_path_length = strlen(socket_path);
	if (!socket_path_length || socket_path_length >= sizeof(address.sun_path)) {
		errno = ENAMETOOLONG;
		return -1;
	}

	listener_fd = socket(
		AF_UNIX,
		SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK,
		0
	);
	if (listener_fd < 0) {
		return -1;
	}

	memset(&address, 0, sizeof(address));
	address.sun_family = AF_UNIX;
	memcpy(address.sun_path, socket_path, socket_path_length + 1);
	umask(0077);
	if (ahe_broker_prepare_parent_directory(socket_path) < 0
	 || ahe_broker_remove_stale_socket(socket_path, &address) < 0) {
		close(listener_fd);
		return -1;
	}
	if (bind(listener_fd, (struct sockaddr *) &address, sizeof(address)) < 0) {
		close(listener_fd);
		return -1;
	}
	if (chmod(socket_path, 0600) < 0 || listen(listener_fd, 16) < 0) {
		saved_errno = errno;
		close(listener_fd);
		(void) unlink(socket_path);
		errno = saved_errno;
		return -1;
	}

	return listener_fd;
}

static int ahe_broker_parse_max_clients(const char *value, unsigned long *max_clients)
{
	char *end = NULL;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(value, &end, 10);
	if (errno || !end || *end || !parsed) {
		return -1;
	}
	*max_clients = parsed;
	return 0;
}

static void ahe_broker_usage(const char *program_name)
{
	fprintf(stderr, "Usage: %s --socket PATH [--max-clients COUNT]\n", program_name);
}

int main(int argc, char **argv)
{
	const char *socket_path = NULL;
	unsigned long max_clients = 0;
	unsigned long handled_clients = 0;
	ahe_broker_client_connection *clients = NULL;
	ahe_generation generation;
	struct pollfd *poll_fds = NULL;
	struct sigaction action;
	size_t client_capacity = 0;
	size_t client_count = 0;
	size_t poll_capacity = 0;
	int listener_fd = -1;
	int client_fd;
	int i;
	int exit_status = EXIT_SUCCESS;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
			socket_path = argv[++i];
		} else if (strcmp(argv[i], "--max-clients") == 0 && i + 1 < argc
		 && ahe_broker_parse_max_clients(argv[++i], &max_clients) == 0) {
			continue;
		} else {
			ahe_broker_usage(argv[0]);
			return EXIT_FAILURE;
		}
	}
	if (!socket_path) {
		ahe_broker_usage(argv[0]);
		return EXIT_FAILURE;
	}

	memset(&action, 0, sizeof(action));
	action.sa_handler = ahe_broker_handle_signal;
	sigemptyset(&action.sa_mask);
	if (sigaction(SIGINT, &action, NULL) < 0
	 || sigaction(SIGTERM, &action, NULL) < 0
	 || signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
		perror("ahe-broker: signal setup");
		return EXIT_FAILURE;
	}

	ahe_generation_init(&generation);
	listener_fd = ahe_broker_create_listener(socket_path);
	if (listener_fd < 0) {
		perror("ahe-broker: listen");
		return EXIT_FAILURE;
	}

	while (!ahe_broker_stopping) {
		size_t client_index;
		size_t poll_fd_count;
		struct pollfd *resized_poll_fds;
		int poll_result;

		if (max_clients && handled_clients >= max_clients) {
			if (listener_fd >= 0) {
				close(listener_fd);
				listener_fd = -1;
			}
			for (client_index = client_count; client_index > 0; client_index--) {
				size_t index = client_index - 1;

				if (!clients[index].handled_message) {
					ahe_broker_close_client(
						clients,
						&client_count,
						index,
						&generation
					);
				}
			}
			if (!client_count) {
				break;
			}
		}

		if (client_count == SIZE_MAX) {
			errno = ENOMEM;
			perror("ahe-broker: poll allocation");
			exit_status = EXIT_FAILURE;
			break;
		}
		poll_fd_count = client_count + 1;
		if (poll_fd_count > poll_capacity) {
			if (poll_fd_count > SIZE_MAX / sizeof(*poll_fds)) {
				errno = ENOMEM;
				perror("ahe-broker: poll allocation");
				exit_status = EXIT_FAILURE;
				break;
			}
			resized_poll_fds = realloc(
				poll_fds,
				poll_fd_count * sizeof(*poll_fds)
			);
			if (!resized_poll_fds) {
				perror("ahe-broker: poll allocation");
				exit_status = EXIT_FAILURE;
				break;
			}
			poll_fds = resized_poll_fds;
			poll_capacity = poll_fd_count;
		}

		poll_fds[0].fd = listener_fd;
		poll_fds[0].events = POLLIN;
		poll_fds[0].revents = 0;
		for (client_index = 0; client_index < client_count; client_index++) {
			poll_fds[client_index + 1].fd = clients[client_index].fd;
			poll_fds[client_index + 1].events = POLLIN;
			poll_fds[client_index + 1].revents = 0;
		}

		poll_result = poll(poll_fds, (nfds_t) poll_fd_count, -1);
		if (poll_result < 0) {
			if (errno == EINTR) {
				continue;
			}
			perror("ahe-broker: poll");
			exit_status = EXIT_FAILURE;
			break;
		}

		for (client_index = client_count; client_index > 0; client_index--) {
			size_t index = client_index - 1;
			short events = poll_fds[index + 1].revents;
			bool handled_before;
			bool keep_open = true;

			if (!events) {
				continue;
			}
			handled_before = clients[index].handled_message;
			if (max_clients && handled_clients >= max_clients
			 && !handled_before) {
				keep_open = false;
			} else if (events & POLLIN) {
				keep_open = ahe_broker_handle_client_message(
					&clients[index],
					&generation
				);
				if (!handled_before && clients[index].handled_message
				 && handled_clients < ULONG_MAX) {
					handled_clients++;
				}
			}
			if (events & (POLLERR | POLLHUP | POLLNVAL)) {
				keep_open = false;
			}
			if (!keep_open) {
				ahe_broker_close_client(
					clients,
					&client_count,
					index,
					&generation
				);
			}
		}

		if ((max_clients && handled_clients >= max_clients)
		 || !(poll_fds[0].revents & POLLIN)) {
			if (poll_fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
				fprintf(stderr, "ahe-broker: listener poll failure\n");
				exit_status = EXIT_FAILURE;
				break;
			}
			continue;
		}

		client_fd = accept4(
			listener_fd,
			NULL,
			NULL,
			SOCK_CLOEXEC | SOCK_NONBLOCK
		);
		if (client_fd < 0) {
			if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
				continue;
			}
			perror("ahe-broker: accept");
			exit_status = EXIT_FAILURE;
			break;
		}

		{
			struct ucred credentials;
			socklen_t credentials_size = sizeof(credentials);

			if (getsockopt(
				client_fd,
				SOL_SOCKET,
				SO_PEERCRED,
				&credentials,
				&credentials_size
			) < 0
			 || credentials_size != sizeof(credentials)
			 || credentials.pid <= 0
			 || credentials.uid != geteuid()) {
				close(client_fd);
				continue;
			}
		}

		if (ahe_broker_add_client(
			&clients,
			&client_count,
			&client_capacity,
			client_fd
		) < 0) {
			perror("ahe-broker: client allocation");
			close(client_fd);
			exit_status = EXIT_FAILURE;
			break;
		}
	}

	while (client_count) {
		ahe_broker_close_client(
			clients,
			&client_count,
			client_count - 1,
			&generation
		);
	}
	free(clients);
	free(poll_fds);
	ahe_generation_reset(&generation);
	if (listener_fd >= 0) {
		close(listener_fd);
	}
	if (unlink(socket_path) < 0 && errno != ENOENT) {
		perror("ahe-broker: unlink");
		exit_status = EXIT_FAILURE;
	}

	return exit_status;
}
