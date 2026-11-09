#ifndef AUTOCORE_AVC_CONFIGURATION_PARSER_H
#define AUTOCORE_AVC_CONFIGURATION_PARSER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const uint8_t *sps;
    size_t spsLength;
    const uint8_t *pps;
    size_t ppsLength;
    uint8_t spsCount;
    uint8_t ppsCount;
} AutoCoreAVCConfiguration;

// The returned pointers borrow bytes from the caller's AVCDecoderConfigurationRecord.
bool AutoCoreParseAVCConfiguration(const uint8_t *bytes, size_t length,
                                 AutoCoreAVCConfiguration *configuration);

#ifdef __cplusplus
}
#endif

#endif
