/*
 * Abyssal Hyperglyph Engine: Gate of the Adamantine Oath
 *
 * Copyright (c) 2026 Abyssal Hyperglyph Engine contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-only WITH romic-exception
 */

#include "ahe_broker_protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int ahe_mark_stalled(const char *marker_path)
{
	int marker_fd = open(marker_path, O_CREAT | O_CLOEXEC | O_WRONLY, 0600);

	if (marker_fd < 0) {
		return -1;
	}
	return close(marker_fd);
}

int main(int argc, char **argv)
{
	ahe_broker_message_v1 request;
	struct sockaddr_un address;
	ssize_t sent;
	size_t sent_count = 0;
	size_t socket_path_length;
	int socket_fd;
	int socket_flags;

	if (argc != 3) {
		fprintf(stderr, "Usage: %s SOCKET MARKER\n", argv[0]);
		return EXIT_FAILURE;
	}

	socket_path_length = strlen(argv[1]);
	if (!socket_path_length || socket_path_length >= sizeof(address.sun_path)) {
		fprintf(stderr, "The broker socket path is invalid.\n");
		return EXIT_FAILURE;
	}

	socket_fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	if (socket_fd < 0) {
		perror("broker-stall: socket");
		return EXIT_FAILURE;
	}
	memset(&address, 0, sizeof(address));
	address.sun_family = AF_UNIX;
	memcpy(address.sun_path, argv[1], socket_path_length + 1);
	if (connect(
		socket_fd,
		(const struct sockaddr *) &address,
		sizeof(address)
	) < 0) {
		perror("broker-stall: connect");
		close(socket_fd);
		return EXIT_FAILURE;
	}

	socket_flags = fcntl(socket_fd, F_GETFL, 0);
	if (socket_flags < 0 || fcntl(socket_fd, F_SETFL, socket_flags | O_NONBLOCK) < 0) {
		perror("broker-stall: nonblocking");
		close(socket_fd);
		return EXIT_FAILURE;
	}

	memset(&request, 0, sizeof(request));
	request.magic = AHE_BROKER_PROTOCOL_MAGIC;
	request.version = AHE_BROKER_PROTOCOL_VERSION;
	request.type = AHE_BROKER_ACQUIRE;
	request.mapping_size = 1;
	memcpy(request.cache_key, "deliberately-mismatched", sizeof("deliberately-mismatched"));

	while (sent_count < 1000000) {
		sent = send(socket_fd, &request, sizeof(request), MSG_NOSIGNAL);
		if (sent == (ssize_t) sizeof(request)) {
			sent_count++;
			continue;
		}
		if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK
		 || errno == EPIPE || errno == ECONNRESET)) {
			break;
		}
		perror("broker-stall: send");
		close(socket_fd);
		return EXIT_FAILURE;
	}
	if (sent_count == 1000000) {
		fprintf(stderr, "The broker client did not encounter backpressure.\n");
		close(socket_fd);
		return EXIT_FAILURE;
	}
	if (ahe_mark_stalled(argv[2]) < 0) {
		perror("broker-stall: marker");
		close(socket_fd);
		return EXIT_FAILURE;
	}

	sleep(30);
	close(socket_fd);
	return EXIT_SUCCESS;
}
