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
#include "Zend/zend_execute.h"
#include "Zend/zend_extensions.h"
#include "Zend/zend_ini.h"
#include "Zend/zend_system_id.h"
#include "ext/standard/md5.h"
#include "main/SAPI.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
#ifdef __linux__
# include <sys/personality.h>
#endif

#include "abyssal_hyperglyph_engine.h"
#include "ahe_broker_client.h"
#include "ahe_broker_protocol.h"
#include "ahe_opcache_provider.h"

static bool ahe_opcache_seen = false;
static bool ahe_opcache_provider_registered = false;
static bool ahe_opcache_provider_enabled = false;
static ahe_broker_client ahe_broker = AHE_BROKER_CLIENT_INITIALIZER;

typedef struct _ahe_ini_fingerprint_entry {
	zend_string *name;
	zend_string *value;
} ahe_ini_fingerprint_entry;

static int ahe_compare_ini_fingerprint_entries(const void *left, const void *right)
{
	const ahe_ini_fingerprint_entry *left_entry = left;
	const ahe_ini_fingerprint_entry *right_entry = right;

	return strcmp(ZSTR_VAL(left_entry->name), ZSTR_VAL(right_entry->name));
}

static void ahe_md5_update_field(
	PHP_MD5_CTX *context,
	const void *value,
	size_t value_length
)
{
	uint64_t encoded_length = value_length;

	PHP_MD5Update(context, &encoded_length, sizeof(encoded_length));
	if (value_length) {
		PHP_MD5Update(context, value, value_length);
	}
}

static int ahe_opcache_configuration_digest(char digest_hex[33])
{
	static const char hex[] = "0123456789abcdef";
	ahe_ini_fingerprint_entry *entries;
	zend_ini_entry *ini_entry;
	PHP_MD5_CTX context;
	unsigned char digest[16];
	size_t entry_count = 0;
	size_t entry_index = 0;
	size_t i;

	if (!EG(ini_directives)) {
		return FAILURE;
	}

	ZEND_HASH_MAP_FOREACH_PTR(EG(ini_directives), ini_entry) {
		if (ini_entry->name
		 && ZSTR_LEN(ini_entry->name) > sizeof("opcache.") - 1
		 && memcmp(
			ZSTR_VAL(ini_entry->name),
			"opcache.",
			sizeof("opcache.") - 1
		 ) == 0) {
			entry_count++;
		}
	} ZEND_HASH_FOREACH_END();

	if (!entry_count) {
		return FAILURE;
	}
	entries = malloc(entry_count * sizeof(*entries));
	if (!entries) {
		return FAILURE;
	}

	ZEND_HASH_MAP_FOREACH_PTR(EG(ini_directives), ini_entry) {
		if (ini_entry->name
		 && ZSTR_LEN(ini_entry->name) > sizeof("opcache.") - 1
		 && memcmp(
			ZSTR_VAL(ini_entry->name),
			"opcache.",
			sizeof("opcache.") - 1
		 ) == 0) {
			entries[entry_index].name = ini_entry->name;
			entries[entry_index].value = ini_entry->value;
			entry_index++;
		}
	} ZEND_HASH_FOREACH_END();

	qsort(
		entries,
		entry_count,
		sizeof(*entries),
		ahe_compare_ini_fingerprint_entries
	);
	PHP_MD5Init(&context);
	for (i = 0; i < entry_count; i++) {
		ahe_md5_update_field(
			&context,
			ZSTR_VAL(entries[i].name),
			ZSTR_LEN(entries[i].name)
		);
		if (entries[i].value) {
			ahe_md5_update_field(
				&context,
				ZSTR_VAL(entries[i].value),
				ZSTR_LEN(entries[i].value)
			);
		} else {
			ahe_md5_update_field(&context, NULL, 0);
		}
	}
	free(entries);
	PHP_MD5Final(digest, &context);

	for (i = 0; i < sizeof(digest); i++) {
		digest_hex[i * 2] = hex[digest[i] >> 4];
		digest_hex[i * 2 + 1] = hex[digest[i] & 0x0f];
	}
	digest_hex[sizeof(digest) * 2] = '\0';
	return SUCCESS;
}

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
	ahe_broker_client *broker = context;
	const char *cache_namespace;
	const char *socket_path;
	char cache_key[AHE_BROKER_CACHE_KEY_SIZE];
	char configuration_digest[33];
	int cache_key_length;
	int result;

	*shared_segments = NULL;
	*shared_segment_count = 0;
	*reattached_shared_globals = NULL;
	*error_in = NULL;
	if (!ahe_opcache_provider_enabled) {
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}

	socket_path = getenv("AHE_BROKER_SOCKET");
	if (!socket_path || !socket_path[0]) {
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}
	cache_namespace = getenv("AHE_CACHE_NAMESPACE");
	if (!cache_namespace || !cache_namespace[0]) {
		cache_namespace = "default";
	}
	if (zend_ini_long(
		"opcache.force_restart_timeout",
		sizeof("opcache.force_restart_timeout") - 1,
		false
	) != 0) {
		*error_in = "AHE requires opcache.force_restart_timeout=0 to avoid killing attached CLI processes";
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}
	if (ahe_opcache_configuration_digest(configuration_digest) != SUCCESS) {
		*error_in = "AHE could not fingerprint the OPcache configuration";
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}

	cache_key_length = snprintf(
		cache_key,
		sizeof(cache_key),
		"abi=2|uid=%ju|namespace=%s|sapi=%s|system=%.*s|opcache=%s|execute=%"
		PRIxPTR "|size=%zu",
		(uintmax_t) geteuid(),
		cache_namespace,
		sapi_module.name ? sapi_module.name : "unknown",
		(int) sizeof(zend_system_id),
		zend_system_id,
		configuration_digest,
		(uintptr_t) execute_ex,
		requested_size
	);
	if (cache_key_length < 0 || (size_t) cache_key_length >= sizeof(cache_key)) {
		*error_in = "AHE cache identity is too long";
		return ZEND_OPCACHE_SHM_ALLOC_FAILURE;
	}

	result = ahe_broker_client_acquire(
		broker,
		socket_path,
		cache_key,
		requested_size,
		shared_segments,
		shared_segment_count,
		reattached_shared_globals,
		error_in
	);
	if (result == ZEND_OPCACHE_SHM_ALLOC_FAILURE && broker->timed_out) {
		zend_error(
			E_CORE_WARNING,
			"%s: the broker did not respond; using process-local OPcache for this invocation",
			AHE_NAME
		);
	}

	return result;
}

static int ahe_detach_segment(void *context, ahe_opcache_shm_segment_v1 *shared_segment)
{
	return ahe_broker_client_detach(context, shared_segment);
}

static size_t ahe_segment_type_size(void *context)
{
	(void) context;

	return sizeof(ahe_opcache_shm_segment_v1);
}

static int ahe_get_lock_file(void *context)
{
	ahe_broker_client *broker = context;

	return broker->lock_fd;
}

static int ahe_lock(void *context)
{
	return ahe_broker_client_lock(context);
}

static int ahe_unlock(void *context)
{
	return ahe_broker_client_unlock(context);
}

static void ahe_startup_complete(void *context, int reattached, void *shared_globals)
{
	ahe_broker_client *broker = context;

	if (!reattached && broker->creator
	 && ahe_broker_client_publish(broker, shared_globals) < 0) {
		ahe_broker_client_abort(broker);
		zend_error(
			E_CORE_WARNING,
			"%s: persistence was abandoned because the OPcache generation could not be published",
			AHE_NAME
		);
	}
}

static void ahe_startup_aborted(void *context, const char *reason)
{
	(void) reason;
	ahe_broker_client_abort(context);
}

static void ahe_provider_shutdown(void *context)
{
	ahe_broker_client_shutdown(context);
}

static const ahe_opcache_shm_provider_v2 ahe_opcache_provider = {
	ZEND_OPCACHE_SHM_PROVIDER_ABI_V2,
	sizeof(ahe_opcache_shm_provider_v2),
	"abyssal-hyperglyph-engine",
	&ahe_broker,
	ahe_create_segments,
	ahe_detach_segment,
	ahe_segment_type_size,
	ahe_get_lock_file,
	ahe_lock,
	ahe_unlock,
	ahe_startup_complete,
	ahe_startup_aborted,
	ahe_provider_shutdown,
};

static void ahe_message_handler(int message, void *arg)
{
	zend_extension *loaded_extension;
	ahe_opcache_register_shared_memory_provider_v2_t register_provider;

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

	register_provider = (ahe_opcache_register_shared_memory_provider_v2_t)
		DL_FETCH_SYMBOL(
			loaded_extension->handle,
			ZEND_OPCACHE_SHM_PROVIDER_REGISTER_SYMBOL_V2
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
	const char *broker_socket = getenv("AHE_BROKER_SOCKET");

	if (!getenv("AHE_EXPECT_NO_ASLR") && (!broker_socket || !broker_socket[0])) {
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
