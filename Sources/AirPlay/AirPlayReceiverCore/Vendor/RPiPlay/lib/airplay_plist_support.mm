#import <Foundation/Foundation.h>

#include <stdlib.h>
#include <string.h>

#include "airplay_plist_support.h"

static int airplay_copy_output(NSData *data, char **response_data, int *response_datalen) {
    char *buffer;

    if (!data || !response_data || !response_datalen) {
        return -1;
    }

    buffer = (char *) malloc(data.length);
    if (!buffer) {
        return -1;
    }

    memcpy(buffer, data.bytes, data.length);
    *response_data = buffer;
    *response_datalen = (int) data.length;
    return 0;
}

static id airplay_number(uint64_t value) {
    return @(value);
}

static NSDictionary *airplay_display_dictionary(const airplay_info_response_t *info) {
    double refresh_interval = info->refresh_rate > 0.0 ? (1.0 / info->refresh_rate) : (1.0 / 60.0);
    return @{
        @"uuid": @"e0ff8a27-6738-3d56-8a16-cc53aacee925",
        @"widthPhysical": @0,
        @"heightPhysical": @0,
        @"width": @(info->width_pixels),
        @"height": @(info->height_pixels),
        @"widthPixels": @(info->width_pixels),
        @"heightPixels": @(info->height_pixels),
        @"rotation": @NO,
        @"refreshRate": @(refresh_interval),
        @"overscanned": @NO,
        @"features": @14,
    };
}

void airplay_setup_request_init(airplay_setup_request_t *request) {
    if (request) {
        memset(request, 0, sizeof(*request));
    }
}

void airplay_setup_request_free(airplay_setup_request_t *request) {
    if (!request) {
        return;
    }
    free(request->ekey);
    memset(request, 0, sizeof(*request));
}

int airplay_parse_setup_request(const char *data, int data_len, airplay_setup_request_t *request) {
    NSData *plistData;
    NSError *error = nil;
    id object;
    NSDictionary *root;
    NSData *eiv;
    NSData *ekey;
    NSNumber *timingPort;
    NSArray *streams;

    if (!data || data_len <= 0 || !request) {
        return -1;
    }

    plistData = [NSData dataWithBytes:data length:(NSUInteger) data_len];
    object = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:nil error:&error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return -1;
    }

    root = (NSDictionary *) object;
    eiv = [root[@"eiv"] isKindOfClass:[NSData class]] ? root[@"eiv"] : nil;
    ekey = [root[@"ekey"] isKindOfClass:[NSData class]] ? root[@"ekey"] : nil;
    if (eiv && ekey && eiv.length >= 16) {
        request->has_encryption_info = true;
        memcpy(request->eiv, eiv.bytes, 16);
        request->ekey_len = (int) ekey.length;
        request->ekey = (unsigned char *) malloc((size_t) request->ekey_len);
        if (!request->ekey) {
            return -1;
        }
        memcpy(request->ekey, ekey.bytes, (size_t) request->ekey_len);
    }

    timingPort = [root[@"timingPort"] isKindOfClass:[NSNumber class]] ? root[@"timingPort"] : nil;
    if (timingPort) {
        request->has_timing_port = true;
        request->timing_port = timingPort.unsignedLongLongValue;
    }

    streams = [root[@"streams"] isKindOfClass:[NSArray class]] ? root[@"streams"] : nil;
    if (streams) {
        for (NSDictionary *stream in streams) {
            NSNumber *type;
            NSNumber *streamConnectionID;
            if (request->stream_count >= 4 || ![stream isKindOfClass:[NSDictionary class]]) {
                break;
            }

            type = [stream[@"type"] isKindOfClass:[NSNumber class]] ? stream[@"type"] : nil;
            if (!type) {
                continue;
            }

            request->streams[request->stream_count].type = type.unsignedLongLongValue;
            streamConnectionID = [stream[@"streamConnectionID"] isKindOfClass:[NSNumber class]] ? stream[@"streamConnectionID"] : nil;
            request->streams[request->stream_count].stream_connection_id = streamConnectionID.unsignedLongLongValue;
            request->stream_count += 1;
        }
    }

    return 0;
}

int airplay_create_setup_response(const airplay_setup_response_t *response, char **response_data, int *response_datalen) {
    NSMutableDictionary *root = [NSMutableDictionary dictionary];
    NSMutableArray *streams = [NSMutableArray array];
    NSData *data;
    NSError *error = nil;

    if (!response) {
        return -1;
    }

    if (response->has_timing_port) {
        root[@"timingPort"] = @(response->timing_port);
    }
    if (response->has_event_port) {
        root[@"eventPort"] = @(response->event_port);
    }

    for (int index = 0; index < response->stream_count; index++) {
        const airplay_setup_response_stream_t *stream = &response->streams[index];
        NSMutableDictionary *streamNode = [NSMutableDictionary dictionary];
        streamNode[@"dataPort"] = @(stream->data_port);
        streamNode[@"type"] = airplay_number(stream->type);
        if (stream->has_control_port) {
            streamNode[@"controlPort"] = @(stream->control_port);
        }
        [streams addObject:streamNode];
    }
    if (streams.count > 0) {
        root[@"streams"] = streams;
    }

    data = [NSPropertyListSerialization dataWithPropertyList:root format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    return airplay_copy_output(data, response_data, response_datalen);
}

int airplay_create_info_response(const airplay_info_response_t *info, char **response_data, int *response_datalen) {
    NSDictionary *root;
    NSData *txtAirPlay;
    NSData *pk;
    NSData *data;
    NSError *error = nil;

    if (!info) {
        return -1;
    }

    txtAirPlay = [NSData dataWithBytes:info->airplay_txt length:(NSUInteger) info->airplay_txt_len];
    pk = [NSData dataWithBytes:info->public_key length:(NSUInteger) info->public_key_len];
    root = @{
        @"txtAirPlay": txtAirPlay,
        @"features": @(((uint64_t) 0x1E << 32) | 0x5A7FFFF7),
        @"name": @(info->name),
        @"audioFormats": @[
            @{@"type": @100, @"audioInputFormats": @67108860, @"audioOutputFormats": @67108860},
            @{@"type": @101, @"audioInputFormats": @67108860, @"audioOutputFormats": @67108860},
        ],
        @"pi": @"2e388006-13ba-4041-9a67-25dd4a43d536",
        @"vv": @2,
        @"statusFlags": @68,
        @"keepAliveLowPower": @YES,
        @"sourceVersion": @(info->source_version),
        @"pk": pk,
        @"keepAliveSendStatsAsBody": @YES,
        @"deviceID": @(info->device_id),
        @"audioLatencies": @[
            @{@"outputLatencyMicros": @0, @"type": @100, @"audioType": @"default", @"inputLatencyMicros": @0},
            @{@"outputLatencyMicros": @0, @"type": @101, @"audioType": @"default", @"inputLatencyMicros": @0},
        ],
        @"model": @(info->model),
        @"macAddress": @(info->device_id),
        @"displays": @[airplay_display_dictionary(info)],
    };

    data = [NSPropertyListSerialization dataWithPropertyList:root format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    return airplay_copy_output(data, response_data, response_datalen);
}
