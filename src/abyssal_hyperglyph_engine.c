/*
 * Abyssal Hyperglyph Engine: Gate of the Adamantine Oath
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include "php.h"
#include "Zend/zend_extensions.h"

#include "abyssal_hyperglyph_engine.h"

static int ahe_startup(zend_extension *extension)
{
	(void) extension;

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
	NULL, /* message_handler */
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
