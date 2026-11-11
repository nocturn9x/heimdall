// Copyright 2026 Mattia Giambirtone & All Contributors
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Views into Nim's position; bitboards/squares use a8=0, packed pieces use
// color << 3 | kind. No assumption about the rest of Position's ABI.
typedef struct { const uint64_t *pieces; const uint8_t *mailbox; uint8_t stm; } HDBoard;
typedef struct { uint8_t from, to, side, piece, captured, capture, promotion, castle; } HDMove;
const char *hd_mr_load(const void *bytes, size_t size);
void *hd_mr_new(const void *source);
void hd_mr_delete(void *stack);
void hd_mr_copy(void *dest, const void *source);
void hd_mr_reset(void *stack, HDBoard board);
void hd_mr_push(void *stack, HDBoard after, HDMove move);
void hd_mr_pop(void *stack);
int32_t hd_mr_evaluate(void *stack, HDBoard board);
int32_t hd_mr_fresh(void *stack, HDBoard board);
const void *hd_mr_data(void *stack);
size_t hd_mr_size(void *stack);
int hd_mr_equal(void *a, void *b);
#ifdef __cplusplus
}
#endif
