/**
 * RPiPlay - An open-source AirPlay mirroring server for Raspberry Pi
 * Copyright (C) 2019 Florian Draschbacher
 * Copyright (C) 2020 Jaslo Ziska
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
 */

#include "crypto.h"

#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>

#include <assert.h>
#include <stdlib.h>
#include <string.h>

struct aes_ctx_s {
    CCCryptorRef cryptor;
    uint8_t key[AES_128_BLOCK_SIZE];
    uint8_t iv[AES_128_BLOCK_SIZE];
    CCMode mode;
    CCOperation operation;
    uint8_t block_offset;
};

struct sha_ctx_s {
    CC_SHA512_CTX digest_ctx;
};

static uint8_t waste[AES_128_BLOCK_SIZE];

static aes_ctx_t *aes_init_common(const uint8_t *key, const uint8_t *iv, CCMode mode, aes_direction_t direction) {
    aes_ctx_t *ctx = (aes_ctx_t *) calloc(1, sizeof(aes_ctx_t));
    CCCryptorStatus status;

    assert(ctx);
    memcpy(ctx->key, key, AES_128_BLOCK_SIZE);
    memcpy(ctx->iv, iv, AES_128_BLOCK_SIZE);
    ctx->mode = mode;
    ctx->operation = direction == AES_ENCRYPT ? kCCEncrypt : kCCDecrypt;

    status = CCCryptorCreateWithMode(ctx->operation,
                                     ctx->mode,
                                     kCCAlgorithmAES128,
                                     ccNoPadding,
                                     ctx->iv,
                                     ctx->key,
                                     AES_128_BLOCK_SIZE,
                                     NULL,
                                     0,
                                     0,
                                     0,
                                     &ctx->cryptor);
    if (status != kCCSuccess) {
        free(ctx);
        return NULL;
    }

    return ctx;
}

static void aes_reset_common(aes_ctx_t *ctx) {
    if (!ctx) {
        return;
    }
    if (ctx->cryptor) {
        CCCryptorRelease(ctx->cryptor);
        ctx->cryptor = NULL;
    }

    CCCryptorCreateWithMode(ctx->operation,
                            ctx->mode,
                            kCCAlgorithmAES128,
                            ccNoPadding,
                            ctx->iv,
                            ctx->key,
                            AES_128_BLOCK_SIZE,
                            NULL,
                            0,
                            0,
                            0,
                            &ctx->cryptor);
    ctx->block_offset = 0;
}

static void aes_update(aes_ctx_t *ctx, const uint8_t *in, uint8_t *out, int len) {
    size_t moved = 0;
    CCCryptorStatus status;

    if (!ctx || len <= 0) {
        return;
    }

    status = CCCryptorUpdate(ctx->cryptor, in, (size_t) len, out, (size_t) len, &moved);
    assert(status == kCCSuccess);
    assert(moved == (size_t) len);
}

aes_ctx_t *aes_ctr_init(const uint8_t *key, const uint8_t *iv) {
    return aes_init_common(key, iv, kCCModeCTR, AES_ENCRYPT);
}

void aes_ctr_reset(aes_ctx_t *ctx) {
    aes_reset_common(ctx);
}

void aes_ctr_encrypt(aes_ctx_t *ctx, const uint8_t *in, uint8_t *out, int len) {
    aes_update(ctx, in, out, len);
    ctx->block_offset = (uint8_t) ((ctx->block_offset + len) % AES_128_BLOCK_SIZE);
}

void aes_ctr_decrypt(aes_ctx_t *ctx, const uint8_t *in, uint8_t *out, int len) {
    aes_ctr_encrypt(ctx, in, out, len);
}

void aes_ctr_start_fresh_block(aes_ctx_t *ctx) {
    if (!ctx || ctx->block_offset == 0) {
        return;
    }
    aes_ctr_encrypt(ctx, waste, waste, AES_128_BLOCK_SIZE - ctx->block_offset);
}

void aes_ctr_destroy(aes_ctx_t *ctx) {
    if (!ctx) {
        return;
    }
    if (ctx->cryptor) {
        CCCryptorRelease(ctx->cryptor);
    }
    free(ctx);
}

aes_ctx_t *aes_cbc_init(const uint8_t *key, const uint8_t *iv, aes_direction_t direction) {
    return aes_init_common(key, iv, kCCModeCBC, direction);
}

void aes_cbc_reset(aes_ctx_t *ctx) {
    aes_reset_common(ctx);
}

void aes_cbc_encrypt(aes_ctx_t *ctx, const uint8_t *in, uint8_t *out, int len) {
    aes_update(ctx, in, out, len);
}

void aes_cbc_decrypt(aes_ctx_t *ctx, const uint8_t *in, uint8_t *out, int len) {
    aes_update(ctx, in, out, len);
}

void aes_cbc_destroy(aes_ctx_t *ctx) {
    aes_ctr_destroy(ctx);
}

sha_ctx_t *sha_init() {
    sha_ctx_t *ctx = (sha_ctx_t *) calloc(1, sizeof(sha_ctx_t));
    assert(ctx);
    CC_SHA512_Init(&ctx->digest_ctx);
    return ctx;
}

void sha_update(sha_ctx_t *ctx, const uint8_t *in, int len) {
    CC_SHA512_Update(&ctx->digest_ctx, in, (CC_LONG) len);
}

void sha_final(sha_ctx_t *ctx, uint8_t *out, unsigned int *len) {
    CC_SHA512_Final(out, &ctx->digest_ctx);
    if (len) {
        *len = CC_SHA512_DIGEST_LENGTH;
    }
}

void sha_reset(sha_ctx_t *ctx) {
    CC_SHA512_Init(&ctx->digest_ctx);
}

void sha_destroy(sha_ctx_t *ctx) {
    free(ctx);
}
