/*
 * Copyright (c) 2019 dsafa22, All Rights Reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 */

#include "raop_rtp_mirror.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <netinet/tcp.h>

#include "raop.h"
#include "netutils.h"
#include "compat.h"
#include "logger.h"
#include "byteutils.h"
#include "mirror_buffer.h"
#include "stream.h"
#include "../../../AVCConfigurationParser.h"

struct raop_rtp_mirror_s {
    logger_t *logger;
    raop_callbacks_t callbacks;
    raop_ntp_t *ntp;

    /* Buffer to handle all resends */
    mirror_buffer_t *buffer;

    /* Remote address as sockaddr */
    struct sockaddr_storage remote_saddr;
    socklen_t remote_saddr_len;

    /* MUTEX LOCKED VARIABLES START */
    /* These variables only edited mutex locked */
    int running;
    int joined;

    int flush;
    thread_handle_t thread_mirror;
    mutex_handle_t run_mutex;

    /* MUTEX LOCKED VARIABLES END */
    int mirror_data_sock;

    unsigned short mirror_data_lport;
};

static int
raop_rtp_parse_remote(raop_rtp_mirror_t *raop_rtp_mirror, const unsigned char *remote, int remotelen)
{
    assert(raop_rtp_mirror);
    int ret = netutils_address_from_bytes(remote, remotelen, 0, 0,
                                          &raop_rtp_mirror->remote_saddr,
                                          sizeof(raop_rtp_mirror->remote_saddr));
    if (ret < 0) {
        return -1;
    }
    raop_rtp_mirror->remote_saddr_len = ret;
    return 0;
}

#define NO_FLUSH (-42)
raop_rtp_mirror_t *raop_rtp_mirror_init(logger_t *logger, raop_callbacks_t *callbacks, raop_ntp_t *ntp,
                                        const unsigned char *remote, int remotelen,
                                        const unsigned char *aeskey, const unsigned char *ecdh_secret)
{
    raop_rtp_mirror_t *raop_rtp_mirror;

    assert(logger);
    assert(callbacks);

    raop_rtp_mirror = calloc(1, sizeof(raop_rtp_mirror_t));
    if (!raop_rtp_mirror) {
        return NULL;
    }
    raop_rtp_mirror->logger = logger;
    raop_rtp_mirror->ntp = ntp;

    memcpy(&raop_rtp_mirror->callbacks, callbacks, sizeof(raop_callbacks_t));
    raop_rtp_mirror->buffer = mirror_buffer_init(logger, aeskey, ecdh_secret);
    if (!raop_rtp_mirror->buffer) {
        free(raop_rtp_mirror);
        return NULL;
    }
    if (raop_rtp_parse_remote(raop_rtp_mirror, remote, remotelen) < 0) {
        mirror_buffer_destroy(raop_rtp_mirror->buffer);
        free(raop_rtp_mirror);
        return NULL;
    }
    raop_rtp_mirror->running = 0;
    raop_rtp_mirror->joined = 1;
    raop_rtp_mirror->mirror_data_sock = -1;
    raop_rtp_mirror->flush = NO_FLUSH;

    MUTEX_CREATE(raop_rtp_mirror->run_mutex);
    return raop_rtp_mirror;
}

void
raop_rtp_init_mirror_aes(raop_rtp_mirror_t *raop_rtp_mirror, uint64_t streamConnectionID)
{
    mirror_buffer_init_aes(raop_rtp_mirror->buffer, streamConnectionID);
}

//#define DUMP_H264

#define RAOP_PACKET_LEN 32768
/**
 * Mirror
 */
static THREAD_RETVAL
raop_rtp_mirror_thread(void *arg)
{
    raop_rtp_mirror_t *raop_rtp_mirror = arg;
    assert(raop_rtp_mirror);

    int stream_fd = -1;
    unsigned char packet[128];
    memset(packet, 0 , 128);
    unsigned char* payload = NULL;
    unsigned int readstart = 0;
    unsigned int empty_packet_count = 0;

#ifdef DUMP_H264
    // C decrypted
    FILE* file = fopen("/home/pi/Airplay.h264", "wb");
    // Encrypted source file
    FILE* file_source = fopen("/home/pi/Airplay.source", "wb");
    FILE* file_len = fopen("/home/pi/Airplay.len", "wb");
#endif

    while (1) {
        fd_set rfds;
        struct timeval tv;
        int nfds, ret;
        MUTEX_LOCK(raop_rtp_mirror->run_mutex);
        if (!raop_rtp_mirror->running) {
            MUTEX_UNLOCK(raop_rtp_mirror->run_mutex);
            break;
        }
        MUTEX_UNLOCK(raop_rtp_mirror->run_mutex);

        /* Set timeout value to 5ms */
        tv.tv_sec = 0;
        tv.tv_usec = 5000;

        /* Get the correct nfds value and set rfds */
        FD_ZERO(&rfds);
        if (stream_fd == -1) {
            FD_SET(raop_rtp_mirror->mirror_data_sock, &rfds);
            nfds = raop_rtp_mirror->mirror_data_sock+1;
        } else {
            FD_SET(stream_fd, &rfds);
            nfds = stream_fd+1;
        }
        ret = select(nfds, &rfds, NULL, NULL, &tv);
        if (ret == 0) {
            /* Timeout happened */
            continue;
        } else if (ret == -1) {
            logger_log(raop_rtp_mirror->logger, LOGGER_ERR, "raop_rtp_mirror error in select %d %s", errno, strerror(errno));
            break;
        }

        if (stream_fd == -1 && FD_ISSET(raop_rtp_mirror->mirror_data_sock, &rfds)) {
            struct sockaddr_storage saddr;
            socklen_t saddrlen;

            logger_log(raop_rtp_mirror->logger, LOGGER_DEBUG, "raop_rtp_mirror accepting client");
            saddrlen = sizeof(saddr);
            stream_fd = accept(raop_rtp_mirror->mirror_data_sock, (struct sockaddr *)&saddr, &saddrlen);
            if (stream_fd == -1) {
                logger_log(raop_rtp_mirror->logger, LOGGER_ERR, "raop_rtp_mirror error in accept %d %s", errno, strerror(errno));
                break;
            }
            logger_log(raop_rtp_mirror->logger, LOGGER_INFO, "Mirroring video TCP client connected");

            // We're calling recv for a certain amount of data, so we need a timeout
            struct timeval tv;
            tv.tv_sec = 0;
            tv.tv_usec = 5000;
            if (setsockopt(stream_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
                logger_log(raop_rtp_mirror->logger, LOGGER_ERR, "raop_rtp_mirror could not set stream socket timeout %d %s", errno, strerror(errno));
                break;
            }
            int option;
            option = 1;
            if (setsockopt(stream_fd, SOL_SOCKET, SO_KEEPALIVE, &option, sizeof(option)) < 0) {
                logger_log(raop_rtp_mirror->logger, LOGGER_WARNING, "raop_rtp_mirror could not set stream socket keepalive %d %s", errno, strerror(errno));
            }
            option = 60;
#if defined(TCP_KEEPIDLE)
            if (setsockopt(stream_fd, IPPROTO_TCP, TCP_KEEPIDLE, &option, sizeof(option)) < 0) {
                logger_log(raop_rtp_mirror->logger, LOGGER_WARNING, "raop_rtp_mirror could not set stream socket keepalive time %d %s", errno, strerror(errno));
            }
#elif defined(TCP_KEEPALIVE)
            if (setsockopt(stream_fd, IPPROTO_TCP, TCP_KEEPALIVE, &option, sizeof(option)) < 0) {
                logger_log(raop_rtp_mirror->logger, LOGGER_WARNING, "raop_rtp_mirror could not set stream socket keepalive time %d %s", errno, strerror(errno));
            }
#endif
            option = 10;
#if defined(TCP_KEEPINTVL)
            if (setsockopt(stream_fd, IPPROTO_TCP, TCP_KEEPINTVL, &option, sizeof(option)) < 0) {
                logger_log(raop_rtp_mirror->logger, LOGGER_WARNING, "raop_rtp_mirror could not set stream socket keepalive interval %d %s", errno, strerror(errno));
            }
#endif
            option = 6;
#if defined(TCP_KEEPCNT)
            if (setsockopt(stream_fd, IPPROTO_TCP, TCP_KEEPCNT, &option, sizeof(option)) < 0) {
                logger_log(raop_rtp_mirror->logger, LOGGER_WARNING, "raop_rtp_mirror could not set stream socket keepalive probes %d %s", errno, strerror(errno));
            }
#endif
            readstart = 0;
        }

        if (stream_fd != -1 && FD_ISSET(stream_fd, &rfds)) {

            // The first 128 bytes are some kind of header for the payload that follows
            while (payload == NULL && readstart < 128) {
                ret = recv(stream_fd, packet + readstart, 128 - readstart, 0);
                if (ret <= 0) break;
                readstart = readstart + ret;
            }

            if (payload == NULL && ret == 0) {
                logger_log(raop_rtp_mirror->logger, LOGGER_INFO, "Mirroring video TCP client disconnected before header");
                closesocket(stream_fd);
                stream_fd = -1;
                memset(packet, 0, sizeof(packet));
                readstart = 0;
                continue;
            } else if (payload == NULL && ret == -1) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) continue; // Timeouts can happen even if the connection is fine
                logger_log(raop_rtp_mirror->logger, LOGGER_ERR, "raop_rtp_mirror error in header recv: %d", errno);
                break;
            }

            int payload_size = byteutils_get_int(packet, 0);
            unsigned short payload_type = byteutils_get_short(packet, 4) & 0xff;
            unsigned short payload_option = byteutils_get_short(packet, 6);

            /* Some senders start with a zero-length control/keepalive header.
             * The 128-byte header is complete; there is no payload to read. */
            if (payload_size == 0) {
                if (++empty_packet_count <= 3) {
                    logger_log(raop_rtp_mirror->logger, LOGGER_INFO,
                               "Empty mirror packet type %u option %u", payload_type, payload_option);
                }
                memset(packet, 0, sizeof(packet));
                readstart = 0;
                continue;
            }
            if (payload_size < 0 || payload_size > 64 * 1024 * 1024) {
                logger_log(raop_rtp_mirror->logger, LOGGER_ERR,
                           "Invalid mirror packet size %d", payload_size);
                break;
            }
            empty_packet_count = 0;

            if (payload == NULL) {
                payload = malloc(payload_size);
                readstart = 0;
            }

            while (readstart < payload_size) {
                // Payload data
                ret = recv(stream_fd, payload + readstart, payload_size - readstart, 0);
                if (ret <= 0) break;
                readstart = readstart + ret;
            }

            if (ret == 0) {
                logger_log(raop_rtp_mirror->logger, LOGGER_INFO, "Mirroring video TCP client disconnected during payload");
                closesocket(stream_fd);
                stream_fd = -1;
                free(payload);
                payload = NULL;
                memset(packet, 0, sizeof(packet));
                readstart = 0;
                continue;
            } else if (ret == -1) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) continue; // Timeouts can happen even if the connection is fine
                logger_log(raop_rtp_mirror->logger, LOGGER_ERR, "raop_rtp_mirror error in recv: %d", errno);
                break;
            }

            if (payload_type == 0) {
                // Normal video data (VCL NAL)

                // Conveniently, the video data is already stamped with the remote wall clock time,
                // so no additional clock syncing needed. The only thing odd here is that the video
                // ntp time stamps don't include the SECONDS_FROM_1900_TO_1970, so it's really just
                // counting micro seconds since last boot.
                uint64_t ntp_timestamp_raw = byteutils_get_long(packet, 8);
                uint64_t ntp_timestamp_remote = raop_ntp_timestamp_to_micro_seconds(ntp_timestamp_raw, false);
                uint64_t ntp_timestamp = raop_ntp_convert_remote_time(raop_rtp_mirror->ntp, ntp_timestamp_remote);

                uint64_t ntp_now = raop_ntp_get_local_time(raop_rtp_mirror->ntp);
                logger_log(raop_rtp_mirror->logger, LOGGER_DEBUG, "raop_rtp_mirror video ntp = %llu, now = %llu, latency = %lld",
                           ntp_timestamp, ntp_now, ((int64_t) ntp_now) - ((int64_t) ntp_timestamp));

#ifdef DUMP_H264
                fwrite(payload, payload_size, 1, file_source);
                fwrite(&readstart, sizeof(readstart), 1, file_len);
#endif

                // Decrypt data
                unsigned char* payload_decrypted = malloc(payload_size);
                mirror_buffer_decrypt(raop_rtp_mirror->buffer, payload, payload_decrypted, payload_size);

                int nalu_type = payload[4] & 0x1f;
                int nalu_size = 0;
                int nalus_count = 0;

                // It seems the AirPlay protocol prepends NALs with their size, which we're replacing with the 4-byte
                // start code for the NAL Byte-Stream Format.
                while (nalu_size < payload_size) {
                    int nc_len = (payload_decrypted[nalu_size + 0] << 24) | (payload_decrypted[nalu_size + 1] << 16) |
                                 (payload_decrypted[nalu_size + 2] << 8) | (payload_decrypted[nalu_size + 3]);
                    assert(nc_len > 0);

                    payload_decrypted[nalu_size + 0] = 0;
                    payload_decrypted[nalu_size + 1] = 0;
                    payload_decrypted[nalu_size + 2] = 0;
                    payload_decrypted[nalu_size + 3] = 1;
                    nalu_size += nc_len + 4;
                    nalus_count++;
                }

                // logger_log(raop_rtp_mirror->logger, LOGGER_DEBUG, "nalutype = %d", nalu_type);
                // logger_log(raop_rtp_mirror->logger, LOGGER_DEBUG, "nalu_size = %d, payloadsize = %d nalus_count = %d",
                //        nalu_size, payload_size, nalus_count);

#ifdef DUMP_H264
                fwrite(payload_decrypted, payload_size, 1, file);
#endif

                h264_decode_struct h264_data;
                h264_data.data_len = payload_size;
                h264_data.data = payload_decrypted;
                h264_data.frame_type = 1;
                h264_data.pts = ntp_timestamp;

                raop_rtp_mirror->callbacks.video_process(raop_rtp_mirror->callbacks.cls, raop_rtp_mirror->ntp, &h264_data);
                free(payload_decrypted);

            } else if ((payload_type & 255) == 1) {
                // The information in the payload contains an SPS and a PPS NAL

                float width_source = byteutils_get_float(packet, 40);
                float height_source = byteutils_get_float(packet, 44);
                float width = byteutils_get_float(packet, 56);
                float height = byteutils_get_float(packet, 60);
                logger_log(raop_rtp_mirror->logger, LOGGER_DEBUG, "raop_rtp_mirror width_source = %f height_source = %f width = %f height = %f",
                           width_source, height_source, width, height);

                // The AVC configuration record is unencrypted. Walk every length-prefixed
                // parameter set: older iPhones can provide more than one SPS or PPS.
                AutoCoreAVCConfiguration h264;
                if (!AutoCoreParseAVCConfiguration(payload, (size_t)payload_size, &h264)) {
                    logger_log(raop_rtp_mirror->logger, LOGGER_ERR,
                               "Invalid AVC configuration record (%d bytes)", payload_size);
                } else if (h264.spsLength + h264.ppsLength + 8 > 102400) {
                    logger_log(raop_rtp_mirror->logger, LOGGER_ERR,
                               "AVC parameter sets exceed maximum size");
                } else {
                    size_t sps_pps_len = h264.spsLength + h264.ppsLength + 8;
                    unsigned char *sps_pps = malloc(sps_pps_len);
                    if (sps_pps) {
                        static const unsigned char start_code[4] = {0, 0, 0, 1};
                        memcpy(sps_pps, start_code, 4);
                        memcpy(sps_pps + 4, h264.sps, h264.spsLength);
                        memcpy(sps_pps + 4 + h264.spsLength, start_code, 4);
                        memcpy(sps_pps + 8 + h264.spsLength, h264.pps, h264.ppsLength);
                        logger_log(raop_rtp_mirror->logger, LOGGER_INFO,
                                   "AVC configuration SPS=%zu PPS=%zu counts=%u/%u types=%u/%u",
                                   h264.spsLength, h264.ppsLength, h264.spsCount, h264.ppsCount,
                                   h264.sps[0] & 0x1f, h264.pps[0] & 0x1f);

#ifdef DUMP_H264
                        fwrite(sps_pps, sps_pps_len, 1, file);
#endif

                        h264_decode_struct h264_data;
                        h264_data.data_len = (int)sps_pps_len;
                        h264_data.data = sps_pps;
                        h264_data.frame_type = 0;
                        h264_data.pts = 0;
                        raop_rtp_mirror->callbacks.video_process(raop_rtp_mirror->callbacks.cls,
                                                                  raop_rtp_mirror->ntp, &h264_data);
                        free(sps_pps);
                    }
                }
            }

            free(payload);
            payload = NULL;
            memset(packet, 0, 128);
            readstart = 0;
        }
    }

    /* Close the stream file descriptor */
    if (stream_fd != -1) {
        closesocket(stream_fd);
    }

#ifdef DUMP_H264
        fclose(file);
    fclose(file_source);
    fclose(file_len);
#endif

    // Ensure running reflects the actual state
    MUTEX_LOCK(raop_rtp_mirror->run_mutex);
    raop_rtp_mirror->running = false;
    MUTEX_UNLOCK(raop_rtp_mirror->run_mutex);

    logger_log(raop_rtp_mirror->logger, LOGGER_DEBUG, "raop_rtp_mirror exiting TCP thread");

    return 0;
}

void
raop_rtp_start_mirror(raop_rtp_mirror_t *raop_rtp_mirror, int use_udp, unsigned short *mirror_data_lport)
{
    logger_log(raop_rtp_mirror->logger, LOGGER_INFO, "raop_rtp_mirror starting mirroring");
    int use_ipv6 = 0;

    assert(raop_rtp_mirror);

    MUTEX_LOCK(raop_rtp_mirror->run_mutex);
    if (raop_rtp_mirror->running || !raop_rtp_mirror->joined) {
        MUTEX_UNLOCK(raop_rtp_mirror->run_mutex);
        return;
    }

    if (raop_rtp_mirror->remote_saddr.ss_family == AF_INET6) {
        use_ipv6 = 1;
    }
    if (raop_rtp_init_mirror_sockets(raop_rtp_mirror, use_ipv6) < 0) {
        logger_log(raop_rtp_mirror->logger, LOGGER_ERR, "raop_rtp_mirror initializing sockets failed");
        MUTEX_UNLOCK(raop_rtp_mirror->run_mutex);
        return;
    }
    if (mirror_data_lport) *mirror_data_lport = raop_rtp_mirror->mirror_data_lport;

    /* Create the thread and initialize running values */
    raop_rtp_mirror->running = 1;
    raop_rtp_mirror->joined = 0;

    THREAD_CREATE(raop_rtp_mirror->thread_mirror, raop_rtp_mirror_thread, raop_rtp_mirror);
    if (!raop_rtp_mirror->thread_mirror) {
        logger_log(raop_rtp_mirror->logger, LOGGER_ERR, "Unable to create mirroring video worker");
        raop_rtp_mirror->running = 0;
        raop_rtp_mirror->joined = 1;
        closesocket(raop_rtp_mirror->mirror_data_sock);
        raop_rtp_mirror->mirror_data_sock = -1;
        raop_rtp_mirror->mirror_data_lport = 0;
        if (mirror_data_lport) *mirror_data_lport = 0;
    }
    MUTEX_UNLOCK(raop_rtp_mirror->run_mutex);
}

void raop_rtp_mirror_stop(raop_rtp_mirror_t *raop_rtp_mirror) {
    assert(raop_rtp_mirror);

    MUTEX_LOCK(raop_rtp_mirror->run_mutex);
    int needs_join = !raop_rtp_mirror->joined;
    raop_rtp_mirror->running = 0;
    MUTEX_UNLOCK(raop_rtp_mirror->run_mutex);

    /* A worker can exit on its own before teardown. It still needs joining,
     * and its listening socket still belongs to this session. */
    if (needs_join) {
        THREAD_JOIN(raop_rtp_mirror->thread_mirror);
        MUTEX_LOCK(raop_rtp_mirror->run_mutex);
        raop_rtp_mirror->joined = 1;
        MUTEX_UNLOCK(raop_rtp_mirror->run_mutex);
    }

    if (raop_rtp_mirror->mirror_data_sock != -1) {
        closesocket(raop_rtp_mirror->mirror_data_sock);
        raop_rtp_mirror->mirror_data_sock = -1;
    }
}

void raop_rtp_mirror_destroy(raop_rtp_mirror_t *raop_rtp_mirror) {
    if (raop_rtp_mirror) {
        raop_rtp_mirror_stop(raop_rtp_mirror);
        MUTEX_DESTROY(raop_rtp_mirror->run_mutex);
        mirror_buffer_destroy(raop_rtp_mirror->buffer);
        free(raop_rtp_mirror);
    }
}

static int
raop_rtp_init_mirror_sockets(raop_rtp_mirror_t *raop_rtp_mirror, int use_ipv6)
{
    int dsock = -1;
    unsigned short dport = 0;

    assert(raop_rtp_mirror);

    dsock = netutils_init_socket(&dport, use_ipv6, 0);
    if (dsock == -1) {
        goto sockets_cleanup;
    }

    /* Listen to the data socket if using TCP */
    if (listen(dsock, 1) < 0) {
        goto sockets_cleanup;
    }

    /* Set socket descriptors */
    raop_rtp_mirror->mirror_data_sock = dsock;

    /* Set port values */
    raop_rtp_mirror->mirror_data_lport = dport;
    return 0;

    sockets_cleanup:
    if (dsock != -1) closesocket(dsock);
    return -1;
}
