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
