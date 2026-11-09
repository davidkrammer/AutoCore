/**
 *  Copyright (C) 2018  Juho Vähä-Herttua
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 */

/* This file should be only included from raop.c as it defines static handler
 * functions and depends on raop internals */

#include "dnssdint.h"
#include "airplay_plist_support.h"
#include "utils.h"
#include <ctype.h>
#include <stdlib.h>

typedef void (*raop_handler_t)(raop_conn_t *, http_request_t *,
                               http_response_t *, char **, int *);

static void
raop_handler_info(raop_conn_t *conn,
                  http_request_t *request, http_response_t *response,
                  char **response_data, int *response_datalen)
{
    assert(conn->raop->dnssd);

    int airplay_txt_len = 0;
    const char *airplay_txt = dnssd_get_airplay_txt(conn->raop->dnssd, &airplay_txt_len);

    int name_len = 0;
    const char *name = dnssd_get_name(conn->raop->dnssd, &name_len);

    int hw_addr_raw_len = 0;
    const char *hw_addr_raw = dnssd_get_hw_addr(conn->raop->dnssd, &hw_addr_raw_len);

    char *hw_addr = calloc(1, 3 * hw_addr_raw_len);
    int hw_addr_len = utils_hwaddr_airplay(hw_addr, 3 * hw_addr_raw_len, hw_addr_raw, hw_addr_raw_len);

    int pk_len = 0;
    char *pk = utils_parse_hex(AIRPLAY_PK, strlen(AIRPLAY_PK), &pk_len);

    airplay_info_response_t info = {
        .airplay_txt = airplay_txt,
        .airplay_txt_len = airplay_txt_len,
        .name = name,
        .public_key = (unsigned char *) pk,
        .public_key_len = pk_len,
        .device_id = hw_addr,
        .model = GLOBAL_MODEL,
        .source_version = AIRPLAY_SRCVERS,
        .width_pixels = dnssd_get_display_width(conn->raop->dnssd),
        .height_pixels = dnssd_get_display_height(conn->raop->dnssd),
        .refresh_rate = dnssd_get_refresh_rate(conn->raop->dnssd),
    };

    airplay_create_info_response(&info, response_data, response_datalen);
    logger_log(conn->raop->logger, LOGGER_DEBUG, "INFO len = %d", *response_datalen);
    http_response_add_header(response, "Content-Type", "application/x-apple-binary-plist");
    free(pk);
    free(hw_addr);
}

static void
raop_handler_pairsetup(raop_conn_t *conn,
                       http_request_t *request, http_response_t *response,
                       char **response_data, int *response_datalen)
{
    unsigned char public_key[ED25519_KEY_SIZE];
    const char *data;
    int datalen;

    data = http_request_get_data(request, &datalen);
    if (datalen != 32) {
        logger_log(conn->raop->logger, LOGGER_ERR, "Invalid pair-setup data");
        return;
    }

    pairing_get_public_key(conn->raop->pairing, public_key);
    pairing_session_set_setup_status(conn->pairing);

    *response_data = malloc(sizeof(public_key));
    if (*response_data) {
        http_response_add_header(response, "Content-Type", "application/octet-stream");
        memcpy(*response_data, public_key, sizeof(public_key));
        *response_datalen = sizeof(public_key);
    }
}

static void
raop_handler_pairverify(raop_conn_t *conn,
                        http_request_t *request, http_response_t *response,
                        char **response_data, int *response_datalen)
{
    if (pairing_session_check_handshake_status(conn->pairing)) {
        return;
    }
    unsigned char public_key[X25519_KEY_SIZE];
    unsigned char signature[PAIRING_SIG_SIZE];
    const unsigned char *data;
    int datalen;

    data = (unsigned char *) http_request_get_data(request, &datalen);
    if (datalen < 4) {
        logger_log(conn->raop->logger, LOGGER_ERR, "Invalid pair-verify data");
        return;
    }
    switch (data[0]) {
        case 1:
            if (datalen != 4 + X25519_KEY_SIZE + X25519_KEY_SIZE) {
                logger_log(conn->raop->logger, LOGGER_ERR, "Invalid pair-verify data");
                return;
            }
            /* We can fall through these errors, the result will just be garbage... */
            if (pairing_session_handshake(conn->pairing, data + 4, data + 4 + X25519_KEY_SIZE)) {
                logger_log(conn->raop->logger, LOGGER_ERR, "Error initializing pair-verify handshake");
            }
            if (pairing_session_get_public_key(conn->pairing, public_key)) {
                logger_log(conn->raop->logger, LOGGER_ERR, "Error getting ECDH public key");
            }
            if (pairing_session_get_signature(conn->pairing, signature)) {
                logger_log(conn->raop->logger, LOGGER_ERR, "Error getting ED25519 signature");
            }
            *response_data = malloc(sizeof(public_key) + sizeof(signature));
            if (*response_data) {
                http_response_add_header(response, "Content-Type", "application/octet-stream");
                memcpy(*response_data, public_key, sizeof(public_key));
                memcpy(*response_data + sizeof(public_key), signature, sizeof(signature));
                *response_datalen = sizeof(public_key) + sizeof(signature);
            }
            break;
        case 0:
            if (datalen != 4 + PAIRING_SIG_SIZE) {
                logger_log(conn->raop->logger, LOGGER_ERR, "Invalid pair-verify data");
                return;
            }

            if (pairing_session_finish(conn->pairing, data + 4)) {
                logger_log(conn->raop->logger, LOGGER_ERR, "Incorrect pair-verify signature");
                http_response_set_disconnect(response, 1);
                return;
            }
            http_response_add_header(response, "Content-Type", "application/octet-stream");
            break;
    }
}

static void
raop_handler_fpsetup(raop_conn_t *conn,
                     http_request_t *request, http_response_t *response,
                     char **response_data, int *response_datalen)
{
    const unsigned char *data;
    int datalen;

    data = (unsigned char *) http_request_get_data(request, &datalen);
    if (datalen == 16) {
        *response_data = malloc(142);
        if (*response_data) {
            http_response_add_header(response, "Content-Type", "application/octet-stream");
            if (!fairplay_setup(conn->fairplay, data, (unsigned char *) *response_data)) {
                *response_datalen = 142;
            } else {
                // Handle error?
                free(*response_data);
                *response_data = NULL;
            }
        }
    } else if (datalen == 164) {
        *response_data = malloc(32);
        if (*response_data) {
            http_response_add_header(response, "Content-Type", "application/octet-stream");
            if (!fairplay_handshake(conn->fairplay, data, (unsigned char *) *response_data)) {
                *response_datalen = 32;
            } else {
                // Handle error?
                free(*response_data);
                *response_data = NULL;
            }
        }
    } else {
        logger_log(conn->raop->logger, LOGGER_ERR, "Invalid fp-setup data length");
        return;
    }
}

static void
raop_handler_options(raop_conn_t *conn,
                     http_request_t *request, http_response_t *response,
                     char **response_data, int *response_datalen)
{
    http_response_add_header(response, "Public", "SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER");
}

static void
raop_handler_setup(raop_conn_t *conn,
                   http_request_t *request, http_response_t *response,
                   char **response_data, int *response_datalen)
{
    unsigned short remote_cport = 0;

    const char *transport;
    int use_udp;
    const char *dacp_id;
    const char *active_remote_header;

    const char *data;
    int data_len;

    data = http_request_get_data(request, &data_len);

    dacp_id = http_request_get_header(request, "DACP-ID");
    active_remote_header = http_request_get_header(request, "Active-Remote");

    if (dacp_id && active_remote_header) {
        logger_log(conn->raop->logger, LOGGER_DEBUG, "DACP-ID: %s", dacp_id);
        logger_log(conn->raop->logger, LOGGER_DEBUG, "Active-Remote: %s", active_remote_header);
        if (conn->raop_rtp) {
            raop_rtp_remote_control_id(conn->raop_rtp, dacp_id, active_remote_header);
        }
    }

    transport = http_request_get_header(request, "Transport");
    if (transport) {
        logger_log(conn->raop->logger, LOGGER_DEBUG, "Transport: %s", transport);
        use_udp = strncmp(transport, "RTP/AVP/TCP", 11);
    } else {
        logger_log(conn->raop->logger, LOGGER_DEBUG, "Transport: null");
        use_udp = 0;
    }

    airplay_setup_request_t request_info;
    airplay_setup_response_t response_info;

    airplay_setup_request_init(&request_info);
    memset(&response_info, 0, sizeof(response_info));

    if (airplay_parse_setup_request(data, data_len, &request_info) != 0) {
        logger_log(conn->raop->logger, LOGGER_ERR, "Unable to parse SETUP request");
        return;
    }

    if (request_info.has_encryption_info) {
        // The first SETUP call that initializes keys and timing

        unsigned char aesiv[16];
        unsigned char aeskey[16];
        logger_log(conn->raop->logger, LOGGER_DEBUG, "SETUP 1");

        // First setup
        memcpy(aesiv, request_info.eiv, sizeof(aesiv));
        logger_log(conn->raop->logger, LOGGER_DEBUG, "eiv_len = %d", sizeof(aesiv));
        logger_log(conn->raop->logger, LOGGER_DEBUG, "ekey_len = %d", request_info.ekey_len);

        // ekey is 72 bytes, aeskey is 16 bytes
        int ret = fairplay_decrypt(conn->fairplay, request_info.ekey, aeskey);
        logger_log(conn->raop->logger, LOGGER_DEBUG, "fairplay_decrypt ret = %d", ret);
        unsigned char ecdh_secret[X25519_KEY_SIZE];
        pairing_get_ecdh_secret_key(conn->pairing, ecdh_secret);

        // Time port
        uint64_t timing_rport = request_info.timing_port;
        logger_log(conn->raop->logger, LOGGER_DEBUG, "timing_rport = %llu", timing_rport);

        unsigned short timing_lport = 0;
        conn->raop_ntp = raop_ntp_init(conn->raop->logger, conn->remote,
                                       conn->remotelen, conn->remote_scope_id,
                                       timing_rport);
        if (!conn->raop_ntp) {
            logger_log(conn->raop->logger, LOGGER_ERR, "Unable to initialize AirPlay timing address");
            http_response_set_disconnect(response, 1);
            airplay_setup_request_free(&request_info);
            return;
        }
        raop_ntp_start(conn->raop_ntp, &timing_lport);
        if (timing_lport == 0) {
            logger_log(conn->raop->logger, LOGGER_ERR, "Unable to start AirPlay timing socket");
            http_response_set_disconnect(response, 1);
            airplay_setup_request_free(&request_info);
            return;
        }

        conn->raop_rtp = raop_rtp_init(conn->raop->logger, &conn->raop->callbacks, conn->raop_ntp, conn->remote, conn->remotelen, aeskey, aesiv, ecdh_secret);
        conn->raop_rtp_mirror = raop_rtp_mirror_init(conn->raop->logger, &conn->raop->callbacks, conn->raop_ntp, conn->remote, conn->remotelen, aeskey, ecdh_secret);
        if (!conn->raop_rtp || !conn->raop_rtp_mirror) {
            logger_log(conn->raop->logger, LOGGER_ERR, "Unable to initialize AirPlay streams");
            http_response_set_disconnect(response, 1);
            airplay_setup_request_free(&request_info);
            return;
        }

        response_info.has_event_port = true;
        response_info.event_port = conn->raop->port;
        response_info.has_timing_port = true;
        response_info.timing_port = timing_lport;

        logger_log(conn->raop->logger, LOGGER_DEBUG, "eport = %d, tport = %d", conn->raop->port, timing_lport);
    }

    // Process stream setup requests
    for (int i = 0; i < request_info.stream_count; i++) {
        uint64_t type = request_info.streams[i].type;
        logger_log(conn->raop->logger, LOGGER_DEBUG, "type = %llu", type);

        switch (type) {
            case 110: {
                unsigned short dport = 0;
                uint64_t stream_connection_id = request_info.streams[i].stream_connection_id;
                logger_log(conn->raop->logger, LOGGER_DEBUG, "streamConnectionID = %llu", stream_connection_id);

                if (conn->raop_rtp_mirror) {
                    raop_rtp_init_mirror_aes(conn->raop_rtp_mirror, stream_connection_id);
                    raop_rtp_start_mirror(conn->raop_rtp_mirror, use_udp, &dport);
                    if (dport != 0) {
                        logger_log(conn->raop->logger, LOGGER_DEBUG, "Mirroring initialized successfully");
                        if (!conn->mirror_session_started) {
                            conn->mirror_session_started = 1;
                            if (conn->raop->callbacks.conn_init) {
                                conn->raop->callbacks.conn_init(conn->raop->callbacks.cls, conn->remote,
                                                                 conn->remotelen, conn->remote_scope_id);
                            }
                        }
                    } else {
                        logger_log(conn->raop->logger, LOGGER_ERR, "Mirroring data socket failed to start");
                        http_response_set_disconnect(response, 1);
                    }
                } else {
                    logger_log(conn->raop->logger, LOGGER_ERR, "Mirroring not initialized at SETUP, playing will fail!");
                    http_response_set_disconnect(response, 1);
                }

                response_info.streams[response_info.stream_count].type = 110;
                response_info.streams[response_info.stream_count].data_port = dport;
                response_info.stream_count += 1;
                break;
            }
            case 96: {
                unsigned short cport = 0;
                unsigned short dport = 0;

                if (conn->raop_rtp) {
                    raop_rtp_start_audio(conn->raop_rtp, use_udp, remote_cport, &cport, &dport);
                    logger_log(conn->raop->logger, LOGGER_DEBUG, "RAOP initialized success");
                } else {
                    logger_log(conn->raop->logger, LOGGER_ERR, "RAOP not initialized at SETUP, playing will fail!");
                    http_response_set_disconnect(response, 1);
                }

                response_info.streams[response_info.stream_count].type = 96;
                response_info.streams[response_info.stream_count].data_port = dport;
                response_info.streams[response_info.stream_count].has_control_port = true;
                response_info.streams[response_info.stream_count].control_port = cport;
                response_info.stream_count += 1;
                break;
            }
            default:
                logger_log(conn->raop->logger, LOGGER_ERR, "SETUP tries to setup stream of unknown type %llu", type);
                http_response_set_disconnect(response, 1);
                break;
        }
    }

    airplay_create_setup_response(&response_info, response_data, response_datalen);
    http_response_add_header(response, "Content-Type", "application/x-apple-binary-plist");
    airplay_setup_request_free(&request_info);
}

static void
raop_handler_get_parameter(raop_conn_t *conn,
                           http_request_t *request, http_response_t *response,
                           char **response_data, int *response_datalen)
{
    const char *content_type;
    const char *data;
    int datalen;

    content_type = http_request_get_header(request, "Content-Type");
    data = http_request_get_data(request, &datalen);
    if (!strcmp(content_type, "text/parameters")) {
        const char *current = data;

        while (current && (datalen - (current - data) > 0)) {
            const char *next;

            /* This is a bit ugly, but seems to be how airport works too */
            if ((datalen - (current - data) >= 8) && !strncmp(current, "volume\r\n", 8)) {
                const char volume[] = "volume: 0.0\r\n";

                http_response_add_header(response, "Content-Type", "text/parameters");
                *response_data = strdup(volume);
                if (*response_data) {
                    *response_datalen = strlen(*response_data);
                }
                return;
            }

            for (next = current ; (datalen - (next - data) > 0) ; ++next)
                if (*next == '\r')
                    break;

            if ((datalen - (next - data) >= 2) && !strncmp(next, "\r\n", 2)) {
                if ((next - current) > 0) {
                    logger_log(conn->raop->logger, LOGGER_WARNING,
                               "Found an unknown parameter: %.*s", (next - current), current);
                }
                current = next + 2;
            } else {
                current = NULL;
            }
        }
    }
}

static void
raop_handler_set_parameter(raop_conn_t *conn,
                           http_request_t *request, http_response_t *response,
                           char **response_data, int *response_datalen)
{
    const char *content_type;
    const char *data;
    int datalen;

    content_type = http_request_get_header(request, "Content-Type");
    data = http_request_get_data(request, &datalen);
    if (!strcmp(content_type, "text/parameters")) {
        char *datastr;
        datastr = calloc(1, datalen+1);
        if (data && datastr && conn->raop_rtp) {
            memcpy(datastr, data, datalen);
            if ((datalen >= 8) && !strncmp(datastr, "volume: ", 8)) {
                float vol = 0.0;
                sscanf(datastr+8, "%f", &vol);
                raop_rtp_set_volume(conn->raop_rtp, vol);
            } else if ((datalen >= 10) && !strncmp(datastr, "progress: ", 10)) {
                unsigned int start, curr, end;
                sscanf(datastr+10, "%u/%u/%u", &start, &curr, &end);
                raop_rtp_set_progress(conn->raop_rtp, start, curr, end);
            }
        } else if (!conn->raop_rtp) {
            logger_log(conn->raop->logger, LOGGER_WARNING, "RAOP not initialized at SET_PARAMETER");
        }
        free(datastr);
    } else if (!strcmp(content_type, "image/jpeg") || !strcmp(content_type, "image/png")) {
        logger_log(conn->raop->logger, LOGGER_INFO, "Got image data of %d bytes", datalen);
        if (conn->raop_rtp) {
            raop_rtp_set_coverart(conn->raop_rtp, data, datalen);
        } else {
            logger_log(conn->raop->logger, LOGGER_WARNING, "RAOP not initialized at SET_PARAMETER coverart");
        }
    } else if (!strcmp(content_type, "application/x-dmap-tagged")) {
        logger_log(conn->raop->logger, LOGGER_INFO, "Got metadata of %d bytes", datalen);
        if (conn->raop_rtp) {
            raop_rtp_set_metadata(conn->raop_rtp, data, datalen);
        } else {
            logger_log(conn->raop->logger, LOGGER_WARNING, "RAOP not initialized at SET_PARAMETER metadata");
        }
    }
}


static void
raop_handler_feedback(raop_conn_t *conn,
                      http_request_t *request, http_response_t *response,
                      char **response_data, int *response_datalen)
{
    logger_log(conn->raop->logger, LOGGER_DEBUG, "raop_handler_feedback");
}

static void
raop_handler_record(raop_conn_t *conn,
                    http_request_t *request, http_response_t *response,
                    char **response_data, int *response_datalen)
{
    logger_log(conn->raop->logger, LOGGER_DEBUG, "raop_handler_record");
    http_response_add_header(response, "Audio-Latency", "11025");
    http_response_add_header(response, "Audio-Jack-Status", "connected; type=analog");
}
