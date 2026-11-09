#import <Foundation/Foundation.h>

#include "dnssd.h"
#include "dnssdint.h"
#include "global.h"
#include "utils.h"

struct dnssd_s {
    char *name;
    int name_len;
    char *hw_addr;
    int hw_addr_len;

    void *raop_service;
    void *airplay_service;
    void *raop_record;
    void *airplay_record;

    uint32_t display_width;
    uint32_t display_height;
    double refresh_rate;
};

static NSData *dnssd_data_from_cstring(const char *value) {
    if (!value) {
        return [NSData data];
    }
    return [[NSString stringWithUTF8String:value] dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *dnssd_make_txt_record(NSDictionary<NSString *, NSData *> *dictionary) {
    return [NSNetService dataFromTXTRecordDictionary:dictionary];
}

static NSNetService *dnssd_publish_service(NSString *name, NSString *type, NSData *txtRecord, unsigned short port) {
    NSNetService *service = [[NSNetService alloc] initWithDomain:@"local." type:type name:name port:port];
    service.includesPeerToPeer = NO;
    [service setTXTRecordData:txtRecord];
    [service publish];
    return service;
}

dnssd_t *
dnssd_init(const char* name, int name_len, const char* hw_addr, int hw_addr_len, int *error)
{
    dnssd_t *dnssd = (dnssd_t *) calloc(1, sizeof(dnssd_t));
    if (!dnssd) {
        if (error) *error = DNSSD_ERROR_OUTOFMEM;
        return NULL;
    }

    dnssd->name = (char *) calloc(1, name_len + 1);
    dnssd->hw_addr = (char *) calloc(1, hw_addr_len);
    if (!dnssd->name || !dnssd->hw_addr) {
        free(dnssd->name);
        free(dnssd->hw_addr);
        free(dnssd);
        if (error) *error = DNSSD_ERROR_OUTOFMEM;
        return NULL;
    }

    memcpy(dnssd->name, name, name_len);
    memcpy(dnssd->hw_addr, hw_addr, hw_addr_len);
    dnssd->name_len = name_len;
    dnssd->hw_addr_len = hw_addr_len;
    dnssd->display_width = 1920;
    dnssd->display_height = 1080;
    dnssd->refresh_rate = 60.0;

    if (error) *error = DNSSD_ERROR_NOERROR;
    return dnssd;
}

static NSData *dnssd_build_raop_record(void) {
    NSDictionary *txt = @{
        @"ch": dnssd_data_from_cstring(RAOP_CH),
        @"cn": dnssd_data_from_cstring(RAOP_CN),
        @"da": dnssd_data_from_cstring(RAOP_DA),
        @"et": dnssd_data_from_cstring(RAOP_ET),
        @"vv": dnssd_data_from_cstring(RAOP_VV),
        @"ft": dnssd_data_from_cstring(RAOP_FT),
        @"am": dnssd_data_from_cstring(GLOBAL_MODEL),
        @"md": dnssd_data_from_cstring(RAOP_MD),
        @"rhd": dnssd_data_from_cstring(RAOP_RHD),
        @"pw": dnssd_data_from_cstring("false"),
        @"sr": dnssd_data_from_cstring(RAOP_SR),
        @"ss": dnssd_data_from_cstring(RAOP_SS),
        @"sv": dnssd_data_from_cstring(RAOP_SV),
        @"tp": dnssd_data_from_cstring(RAOP_TP),
        @"txtvers": dnssd_data_from_cstring(RAOP_TXTVERS),
        @"sf": dnssd_data_from_cstring(RAOP_SF),
        @"vs": dnssd_data_from_cstring(RAOP_VS),
        @"vn": dnssd_data_from_cstring(RAOP_VN),
        @"pk": dnssd_data_from_cstring(RAOP_PK),
    };
    return dnssd_make_txt_record(txt);
}

static NSData *dnssd_build_airplay_record(dnssd_t *dnssd) {
    char device_id[3 * MAX_HWADDR_LEN] = {0};
    if (utils_hwaddr_airplay(device_id, sizeof(device_id), dnssd->hw_addr, dnssd->hw_addr_len) < 0) {
        return nil;
    }

    NSDictionary *txt = @{
        @"deviceid": dnssd_data_from_cstring(device_id),
        @"features": dnssd_data_from_cstring(AIRPLAY_FEATURES),
        @"flags": dnssd_data_from_cstring(AIRPLAY_FLAGS),
        @"model": dnssd_data_from_cstring(GLOBAL_MODEL),
        @"pk": dnssd_data_from_cstring(AIRPLAY_PK),
        @"pi": dnssd_data_from_cstring(AIRPLAY_PI),
        @"srcvers": dnssd_data_from_cstring(AIRPLAY_SRCVERS),
        @"vv": dnssd_data_from_cstring(AIRPLAY_VV),
    };
    return dnssd_make_txt_record(txt);
}

int
dnssd_register_raop(dnssd_t *dnssd, unsigned short port)
{
    char servname[3 * MAX_HWADDR_LEN + 1 + 256] = {0};
    NSData *txtRecord;

    assert(dnssd);

    if (utils_hwaddr_raop(servname, sizeof(servname), dnssd->hw_addr, dnssd->hw_addr_len) < 0) {
        return -1;
    }

    strncat(servname, "@", sizeof(servname) - strlen(servname) - 1);
    strncat(servname, dnssd->name, sizeof(servname) - strlen(servname) - 1);

    txtRecord = dnssd_build_raop_record();
    dnssd->raop_record = (void *) CFBridgingRetain(txtRecord);
    dnssd->raop_service = (void *) CFBridgingRetain(dnssd_publish_service(@(servname), @"_raop._tcp.", txtRecord, port));
    return 0;
}

int
dnssd_register_airplay(dnssd_t *dnssd, unsigned short port)
{
    NSData *txtRecord;

    assert(dnssd);
    txtRecord = dnssd_build_airplay_record(dnssd);
    if (!txtRecord) {
        return -1;
    }

    dnssd->airplay_record = (void *) CFBridgingRetain(txtRecord);
    dnssd->airplay_service = (void *) CFBridgingRetain(dnssd_publish_service(@(dnssd->name), @"_airplay._tcp.", txtRecord, port));
    return 0;
}

const char *
dnssd_get_airplay_txt(dnssd_t *dnssd, int *length)
{
    NSData *data = (__bridge NSData *) dnssd->airplay_record;
    if (!data) {
        if (length) *length = 0;
        return NULL;
    }
    if (length) *length = (int) data.length;
    return (const char *) data.bytes;
}

const char *
dnssd_get_name(dnssd_t *dnssd, int *length)
{
    if (length) *length = dnssd->name_len;
    return dnssd->name;
}

const char *
dnssd_get_hw_addr(dnssd_t *dnssd, int *length)
{
    if (length) *length = dnssd->hw_addr_len;
    return dnssd->hw_addr;
}

void
dnssd_set_display_dimensions(dnssd_t *dnssd, uint32_t width, uint32_t height, double refresh_rate)
{
    if (!dnssd) {
        return;
    }
    dnssd->display_width = width;
    dnssd->display_height = height;
    dnssd->refresh_rate = refresh_rate;
}

uint32_t
dnssd_get_display_width(dnssd_t *dnssd)
{
    return dnssd ? dnssd->display_width : 1920;
}

uint32_t
dnssd_get_display_height(dnssd_t *dnssd)
{
    return dnssd ? dnssd->display_height : 1080;
}

double
dnssd_get_refresh_rate(dnssd_t *dnssd)
{
    return dnssd ? dnssd->refresh_rate : 60.0;
}

static void dnssd_stop_service(void **service_ref) {
    if (!service_ref || !*service_ref) {
        return;
    }
    NSNetService *service = CFBridgingRelease(*service_ref);
    [service stop];
    *service_ref = NULL;
}

static void dnssd_release_record(void **record_ref) {
    if (!record_ref || !*record_ref) {
        return;
    }
    CFBridgingRelease(*record_ref);
    *record_ref = NULL;
}

void
dnssd_unregister_raop(dnssd_t *dnssd)
{
    if (!dnssd) {
        return;
    }
    dnssd_stop_service(&dnssd->raop_service);
    dnssd_release_record(&dnssd->raop_record);
}

void
dnssd_unregister_airplay(dnssd_t *dnssd)
{
    if (!dnssd) {
        return;
    }
    dnssd_stop_service(&dnssd->airplay_service);
    dnssd_release_record(&dnssd->airplay_record);
}

void
dnssd_destroy(dnssd_t *dnssd)
{
    if (!dnssd) {
        return;
    }

    dnssd_unregister_raop(dnssd);
    dnssd_unregister_airplay(dnssd);

    free(dnssd->name);
    free(dnssd->hw_addr);
    free(dnssd);
}
