/*
 * Abyssal Hyperglyph Engine: Gate of the Adamantine Oath
 *
 * Copyright (c) 2026 Abyssal Hyperglyph Engine contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-only WITH romic-exception
 */

#ifndef AHE_BROKER_PROTOCOL_H
#define AHE_BROKER_PROTOCOL_H

#include <stdint.h>

#define AHE_BROKER_PROTOCOL_MAGIC 0x41484531u
#define AHE_BROKER_PROTOCOL_VERSION 1u
#define AHE_BROKER_CACHE_KEY_SIZE 256u
#define AHE_BROKER_DESCRIPTOR_COUNT 2u

enum ahe_broker_message_type {
	AHE_BROKER_ACQUIRE = 1,
	AHE_BROKER_READY = 2,
	AHE_BROKER_ABORT = 3,
	AHE_BROKER_DETACH = 4,
	AHE_BROKER_CREATE = 101,
	AHE_BROKER_ATTACH = 102,
	AHE_BROKER_DECLINE = 103,
	AHE_BROKER_ACK = 104,
	AHE_BROKER_ERROR = 105,
};

typedef struct _ahe_broker_message_v1 {
	uint32_t magic;
	uint32_t version;
	uint32_t type;
	uint32_t reserved;
	uint64_t mapping_size;
	uint64_t mapping_base;
	uint64_t shared_globals_offset;
	char cache_key[AHE_BROKER_CACHE_KEY_SIZE];
} ahe_broker_message_v1;

#endif /* AHE_BROKER_PROTOCOL_H */
