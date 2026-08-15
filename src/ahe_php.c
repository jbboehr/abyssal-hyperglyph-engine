/*
 * Abyssal Hyperglyph Engine: Gate of the Adamantine Oath
 *
 * Copyright (c) 2026 Abyssal Hyperglyph Engine contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-only WITH romic-exception
 */

#ifndef __linux__
# error "The AHE launcher currently supports Linux only"
#endif

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/personality.h>
#include <unistd.h>

#ifndef AHE_PHP_BINARY
# define AHE_PHP_BINARY "php"
#endif

int main(int argc, char **argv)
{
	int current_personality;

	(void) argc;

	errno = 0;
	current_personality = personality(0xffffffffUL);
	if (current_personality == -1) {
		fprintf(stderr, "ahe-php: cannot read process personality: %s\n", strerror(errno));
		return 126;
	}

	if (!(current_personality & ADDR_NO_RANDOMIZE)
	 && personality((unsigned long) current_personality | ADDR_NO_RANDOMIZE) == -1) {
		fprintf(stderr, "ahe-php: cannot disable ASLR: %s\n", strerror(errno));
		return 126;
	}

	if (setenv("AHE_EXPECT_NO_ASLR", "1", 1) == -1) {
		fprintf(stderr, "ahe-php: cannot prepare the PHP environment: %s\n", strerror(errno));
		return 126;
	}

	argv[0] = (char *) AHE_PHP_BINARY;
	execv(AHE_PHP_BINARY, argv);

	fprintf(stderr, "ahe-php: cannot execute %s: %s\n", AHE_PHP_BINARY, strerror(errno));
	return errno == ENOENT ? 127 : 126;
}
