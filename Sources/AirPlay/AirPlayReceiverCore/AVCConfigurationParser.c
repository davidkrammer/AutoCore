#include "AVCConfigurationParser.h"

#include <string.h>

bool AutoCoreParseAVCConfiguration(const uint8_t *bytes, size_t length,
                                 AutoCoreAVCConfiguration *configuration) {
    if (!bytes || !configuration || length < 7 || bytes[0] != 1) {
        return false;
    }

    AutoCoreAVCConfiguration result;
    memset(&result, 0, sizeof(result));
    size_t offset = 5;
    result.spsCount = bytes[offset++] & 0x1f;
    if (result.spsCount == 0) {
        return false;
    }

    for (uint8_t index = 0; index < result.spsCount; index++) {
        if (length - offset < 2) {
            return false;
        }
        size_t nalLength = ((size_t)bytes[offset] << 8) | bytes[offset + 1];
        offset += 2;
        if (nalLength == 0 || nalLength > length - offset) {
            return false;
        }
        if (!result.sps && (bytes[offset] & 0x1f) == 7) {
            result.sps = bytes + offset;
            result.spsLength = nalLength;
        }
        offset += nalLength;
    }

    if (offset >= length) {
        return false;
    }
    result.ppsCount = bytes[offset++];
    if (result.ppsCount == 0) {
        return false;
    }
    for (uint8_t index = 0; index < result.ppsCount; index++) {
        if (length - offset < 2) {
            return false;
        }
        size_t nalLength = ((size_t)bytes[offset] << 8) | bytes[offset + 1];
        offset += 2;
        if (nalLength == 0 || nalLength > length - offset) {
            return false;
        }
        if (!result.pps && (bytes[offset] & 0x1f) == 8) {
            result.pps = bytes + offset;
            result.ppsLength = nalLength;
        }
        offset += nalLength;
    }

    if (!result.sps || !result.pps) {
        return false;
    }
    *configuration = result;
    return true;
}
