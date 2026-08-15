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
 *
 * You should have received a copy of the GNU Affero General Public License
 * and the Romic Exception along with this program. If not, see
 * <https://www.gnu.org/licenses/> and docs/LICENSE_EXCEPTION.md.
 */

#include "php.h"
#include "Zend/zend_extensions.h"

#include <stdlib.h>
#include <string.h>
#ifdef __linux__
# include <sys/personality.h>
#endif

#include "abyssal_hyperglyph_engine.h"
#include "ahe_opcache_provider.h"

static bool ahe_opcache_seen = false;
static bool ahe_opcache_provider_registered = false;
static bool ahe_opcache_provider_enabled = false;

static bool ahe_opcache_is_loaded(void)
{
	zend_llist_position position;
	zend_extension *loaded_extension;

	loaded_extension = zend_llist_get_first_ex(&zend_extensions, &position);
	while (loaded_extension) {
		if (strcmp(loaded_extension->name, "Zend OPcache") == 0) {
			return true;
		}
		loaded_extension = zend_llist_get_next_ex(&zend_extensions, &position);
	}

	return false;
}

static int ahe_create_segments(
	void *context,
	size_t requested_size,
	ahe_opcache_shm_segment_v1 ***shared_segments,
	int *shared_segment_count,
	void **reattached_shared_globals,
	const char **error_in
)
{
	(void) context;
	(void) requested_size;

	*shared_segments = NULL;
	*shared_segment_count = 0;
	*reattached_shared_globals = NULL;
	*error_in = NULL;
	if (!ahe_opcache_provider_enabled) {
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}

	/* The broker backend is the next implementation milestone. */
	return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
}

static int ahe_detach_segment(void *context, ahe_opcache_shm_segment_v1 *shared_segment)
{
	(void) context;
	(void) shared_segment;

	return ZEND_OPCACHE_SHM_PROVIDER_SUCCESS;
}

static size_t ahe_segment_type_size(void *context)
{
	(void) context;

	return sizeof(ahe_opcache_shm_segment_v1);
}

static int ahe_lock(void *context)
{
	(void) context;

	return ZEND_OPCACHE_SHM_PROVIDER_FAILURE;
}

static int ahe_unlock(void *context)
{
	(void) context;

	return ZEND_OPCACHE_SHM_PROVIDER_FAILURE;
}

static void ahe_startup_complete(void *context, int reattached, void *shared_globals)
{
	(void) context;
	(void) reattached;
	(void) shared_globals;
}

static void ahe_startup_aborted(void *context, const char *reason)
{
	(void) context;
	(void) reason;
}

static void ahe_provider_shutdown(void *context)
{
	(void) context;
}

static const ahe_opcache_shm_provider_v1 ahe_opcache_provider = {
	ZEND_OPCACHE_SHM_PROVIDER_ABI_V1,
	sizeof(ahe_opcache_shm_provider_v1),
	"abyssal-hyperglyph-engine",
	NULL,
	ahe_create_segments,
	ahe_detach_segment,
	ahe_segment_type_size,
	ahe_lock,
	ahe_unlock,
	ahe_startup_complete,
	ahe_startup_aborted,
	ahe_provider_shutdown,
};

static void ahe_message_handler(int message, void *arg)
{
	zend_extension *loaded_extension;
	ahe_opcache_register_shared_memory_provider_v1_t register_provider;

	if (message != ZEND_EXTMSG_NEW_EXTENSION || !arg) {
		return;
	}

	loaded_extension = (zend_extension *) arg;
	if (strcmp(loaded_extension->name, "Zend OPcache") != 0) {
		return;
	}

	ahe_opcache_seen = true;
	if (!loaded_extension->handle) {
		return;
	}

	register_provider = (ahe_opcache_register_shared_memory_provider_v1_t)
		DL_FETCH_SYMBOL(
			loaded_extension->handle,
			ZEND_OPCACHE_SHM_PROVIDER_REGISTER_SYMBOL_V1
		);
	if (register_provider
	 && register_provider(&ahe_opcache_provider) == ZEND_OPCACHE_SHM_PROVIDER_SUCCESS) {
		ahe_opcache_provider_registered = true;
	}
}

static int ahe_verify_aslr_contract(void)
{
#ifdef __linux__
	int current_personality;
#endif

	if (!getenv("AHE_EXPECT_NO_ASLR")) {
		return SUCCESS;
	}

#ifdef __linux__
	current_personality = personality(0xffffffffUL);
	if (current_personality != -1 && (current_personality & ADDR_NO_RANDOMIZE)) {
		return SUCCESS;
	}
#endif

	zend_error(E_CORE_WARNING, "%s: the launcher did not disable ASLR", AHE_NAME);
	return FAILURE;
}

static int ahe_startup(zend_extension *extension)
{
	if ((ahe_opcache_seen || ahe_opcache_is_loaded())
	 && !ahe_opcache_provider_registered) {
		zend_error(
			E_CORE_WARNING,
			"%s: Zend OPcache does not expose the shared-memory provider ABI",
			AHE_NAME
		);
		return FAILURE;
	}

	if (ahe_opcache_provider_registered) {
		/* OPcache keeps provider callback addresses through post-shutdown. */
		extension->handle = NULL;
	}

	if (ahe_verify_aslr_contract() != SUCCESS) {
		return FAILURE;
	}

	ahe_opcache_provider_enabled = true;
	return SUCCESS;
}

static void ahe_shutdown(zend_extension *extension)
{
	(void) extension;
}

ZEND_DLEXPORT zend_extension zend_extension_entry = {
	AHE_NAME,
	AHE_VERSION,
	AHE_AUTHOR,
	AHE_URL,
	AHE_COPYRIGHT,
	ahe_startup,
	ahe_shutdown,
	NULL, /* activate */
	NULL, /* deactivate */
	ahe_message_handler,
	NULL, /* op_array_handler */
	NULL, /* statement_handler */
	NULL, /* fcall_begin_handler */
	NULL, /* fcall_end_handler */
	NULL, /* op_array_ctor */
	NULL, /* op_array_dtor */
	STANDARD_ZEND_EXTENSION_PROPERTIES
};

ZEND_DLEXPORT zend_extension_version_info extension_version_info = {
	ZEND_EXTENSION_API_NO,
	ZEND_EXTENSION_BUILD_ID
};
