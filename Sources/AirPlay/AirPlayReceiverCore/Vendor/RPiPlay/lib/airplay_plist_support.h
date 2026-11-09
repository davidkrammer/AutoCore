#ifndef AIRPLAY_PLIST_SUPPORT_H
#define AIRPLAY_PLIST_SUPPORT_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t type;
    uint64_t stream_connection_id;
} airplay_setup_request_stream_t;

typedef struct {
    bool has_encryption_info;
    unsigned char eiv[16];
    unsigned char *ekey;
    int ekey_len;
    bool has_timing_port;
    uint64_t timing_port;
    int stream_count;
    airplay_setup_request_stream_t streams[4];
} airplay_setup_request_t;

typedef struct {
    uint64_t type;
    uint16_t data_port;
    bool has_control_port;
    uint16_t control_port;
} airplay_setup_response_stream_t;

typedef struct {
    bool has_timing_port;
    uint16_t timing_port;
    bool has_event_port;
    uint16_t event_port;
    int stream_count;
    airplay_setup_response_stream_t streams[4];
} airplay_setup_response_t;

typedef struct {
    const char *airplay_txt;
    int airplay_txt_len;
    const char *name;
    const unsigned char *public_key;
    int public_key_len;
    const char *device_id;
    const char *model;
    const char *source_version;
    uint32_t width_pixels;
    uint32_t height_pixels;
    double refresh_rate;
} airplay_info_response_t;

void airplay_setup_request_init(airplay_setup_request_t *request);
void airplay_setup_request_free(airplay_setup_request_t *request);
int airplay_parse_setup_request(const char *data, int data_len, airplay_setup_request_t *request);
int airplay_create_setup_response(const airplay_setup_response_t *response, char **response_data, int *response_datalen);
int airplay_create_info_response(const airplay_info_response_t *info, char **response_data, int *response_datalen);

#ifdef __cplusplus
}
#endif

#endif
