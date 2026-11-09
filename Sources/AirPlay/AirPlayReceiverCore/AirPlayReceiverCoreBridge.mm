#import "AirPlayReceiverCoreBridge.h"

#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include "Vendor/RPiPlay/lib/dnssd.h"
#include "Vendor/RPiPlay/lib/logger.h"
#include "Vendor/RPiPlay/lib/raop.h"

NSErrorDomain const AirPlayReceiverCoreErrorDomain = @"AirPlayReceiverCoreErrorDomain";

static NSUInteger AirPlayStartCodeLength(const uint8_t *bytes, NSUInteger length, NSUInteger index) {
    if (index + 3 < length &&
        bytes[index] == 0 &&
        bytes[index + 1] == 0 &&
        bytes[index + 2] == 0 &&
        bytes[index + 3] == 1) {
        return 4;
    }

    if (index + 2 < length &&
        bytes[index] == 0 &&
        bytes[index + 1] == 0 &&
        bytes[index + 2] == 1) {
        return 3;
    }

    return 0;
}

static NSData *AirPlayCopyNALUnit(const uint8_t *bytes, NSUInteger length, NSUInteger start, NSUInteger end) {
    if (end <= start) {
        return [NSData data];
    }
    return [NSData dataWithBytes:bytes + start length:end - start];
}

@interface AirPlayReceiverCoreBridge () {
    raop_t *_raop;
    dnssd_t *_dnssd;
    CGSize _displaySize;
    CGFloat _displayScale;
    double _refreshRate;
}

@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, readwrite) uint16_t port;
@property (nonatomic, getter=isStopping) BOOL stopping;
@property (nonatomic, copy, nullable) NSString *lastCoreErrorMessage;
@end

static AirPlayReceiverCoreBridge *AirPlayBridgeFromOpaque(void *opaque) {
    return (__bridge AirPlayReceiverCoreBridge *) opaque;
}

static void AirPlayReceiverAudioProcess(void *cls, raop_ntp_t *ntp, aac_decode_struct *data) {
    (void) ntp;

    AirPlayReceiverCoreBridge *bridge = AirPlayBridgeFromOpaque(cls);
    if (!bridge || bridge.isStopping || !data || !data->data || data->data_len <= 0) {
        return;
    }

    id<AirPlayReceiverCoreBridgeDelegate> delegate = bridge.delegate;
    if (!delegate) {
        return;
    }

    NSData *packet = [NSData dataWithBytes:data->data length:(NSUInteger) data->data_len];
    [delegate receiverBridge:bridge didReceiveAudioPacket:packet ptsMicroseconds:data->pts];
}

static void AirPlayReceiverAudioFlush(void *cls) {
    AirPlayReceiverCoreBridge *bridge = AirPlayBridgeFromOpaque(cls);
    if (!bridge || bridge.isStopping) {
        return;
    }

    id<AirPlayReceiverCoreBridgeDelegate> delegate = bridge.delegate;
    if (!delegate) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate receiverBridgeDidFlushAudio:bridge];
    });
}

static void AirPlayReceiverAudioSetVolume(void *cls, float volume) {
    AirPlayReceiverCoreBridge *bridge = AirPlayBridgeFromOpaque(cls);
    if (!bridge || bridge.isStopping) {
        return;
    }

    id<AirPlayReceiverCoreBridgeDelegate> delegate = bridge.delegate;
    if (!delegate) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate receiverBridge:bridge didUpdateAudioVolume:volume];
    });
}

static void AirPlayReceiverLogCallback(void *cls, int level, const char *message) {
    AirPlayReceiverCoreBridge *bridge = AirPlayBridgeFromOpaque(cls);
    if (!bridge || bridge.isStopping || !message) {
        return;
    }

    NSString *logMessage = [NSString stringWithUTF8String:message] ?: @"";
    if (level <= LOGGER_ERR) {
        bridge.lastCoreErrorMessage = logMessage;
    }
    id<AirPlayReceiverCoreBridgeDelegate> delegate = bridge.delegate;
    if (!delegate) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate receiverBridge:bridge didLogMessage:logMessage level:(AirPlayReceiverCoreLogLevel) level];
    });
}

static void AirPlayReceiverConnect(void *cls, const unsigned char *remote, int remotelen,
                                   unsigned int remoteScopeID) {
    AirPlayReceiverCoreBridge *bridge = AirPlayBridgeFromOpaque(cls);
    if (!bridge || bridge.isStopping) {
        return;
    }

    id<AirPlayReceiverCoreBridgeDelegate> delegate = bridge.delegate;
    if (!delegate) {
        return;
    }

    char address[INET6_ADDRSTRLEN] = {0};
    int family = remotelen == 4 ? AF_INET : (remotelen == 16 ? AF_INET6 : AF_UNSPEC);
    const char *numericHost = family == AF_UNSPEC || !remote
        ? NULL : inet_ntop(family, remote, address, sizeof(address));
    NSString *host = numericHost ? [NSString stringWithUTF8String:numericHost] : nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate receiverBridge:bridge didStartConnectingFromHost:host scopeID:remoteScopeID];
    });
}

static void AirPlayReceiverDisconnect(void *cls) {
    AirPlayReceiverCoreBridge *bridge = AirPlayBridgeFromOpaque(cls);
    if (!bridge || bridge.isStopping) {
        return;
    }

    id<AirPlayReceiverCoreBridgeDelegate> delegate = bridge.delegate;
    if (!delegate) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate receiverBridgeDidDisconnect:bridge reason:@"Sender disconnected"];
    });
}

static void AirPlayReceiverVideoFlush(void *cls) {
    AirPlayReceiverCoreBridge *bridge = AirPlayBridgeFromOpaque(cls);
    if (!bridge || bridge.isStopping) {
        return;
    }

    id<AirPlayReceiverCoreBridgeDelegate> delegate = bridge.delegate;
    if (!delegate) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate receiverBridgeDidFlushVideo:bridge];
    });
}

static void AirPlayReceiverVideoProcess(void *cls, raop_ntp_t *ntp, h264_decode_struct *data) {
    (void) ntp;

    AirPlayReceiverCoreBridge *bridge = AirPlayBridgeFromOpaque(cls);
    if (!bridge || bridge.isStopping || !data || !data->data || data->data_len <= 0) {
        return;
    }

    id<AirPlayReceiverCoreBridgeDelegate> delegate = bridge.delegate;
    if (!delegate) {
        return;
    }

    if (data->frame_type == 0) {
        const uint8_t *bytes = data->data;
        NSUInteger length = (NSUInteger) data->data_len;
        NSUInteger firstStart = NSNotFound;
        NSUInteger secondStart = NSNotFound;
        NSUInteger thirdStart = NSNotFound;

        for (NSUInteger index = 0; index < length; index++) {
            NSUInteger startCodeLength = AirPlayStartCodeLength(bytes, length, index);
            if (startCodeLength == 0) {
                continue;
            }

            if (firstStart == NSNotFound) {
                firstStart = index;
                index += startCodeLength - 1;
                continue;
            }

            if (secondStart == NSNotFound) {
                secondStart = index;
                index += startCodeLength - 1;
                continue;
            }

            thirdStart = index;
            break;
        }

        if (firstStart == NSNotFound || secondStart == NSNotFound) {
            return;
        }

        NSUInteger firstCodeLength = AirPlayStartCodeLength(bytes, length, firstStart);
        NSUInteger secondCodeLength = AirPlayStartCodeLength(bytes, length, secondStart);
        NSUInteger spsStart = firstStart + firstCodeLength;
        NSUInteger ppsStart = secondStart + secondCodeLength;
        NSUInteger ppsEnd = thirdStart == NSNotFound ? length : thirdStart;

        NSData *sps = AirPlayCopyNALUnit(bytes, length, spsStart, secondStart);
        NSData *pps = AirPlayCopyNALUnit(bytes, length, ppsStart, ppsEnd);
        [delegate receiverBridge:bridge didReceiveParameterSetsWithSPS:sps pps:pps];
        return;
    }

    NSData *frame = [NSData dataWithBytes:data->data length:(NSUInteger) data->data_len];
    [delegate receiverBridge:bridge didReceiveFrame:frame ptsMicroseconds:data->pts];
}

static void AirPlayReceiverHardwareAddress(uint8_t output[6], NSString *receiverName) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // "<App>#1111": the app's first receiver keeps the address saved
    // without its name.
    NSString *prefix = [receiverName componentsSeparatedByString:@"#"].firstObject ?: @"";
    NSString *primarySuffix = [defaults stringForKey:[prefix stringByAppendingString:@".receiverSuffix"]] ?: @"";
    NSString *primaryName = [[prefix stringByAppendingString:@"#"] stringByAppendingString:primarySuffix];
    // The iPhone knows a receiver by this address, so each receiver keeps
    // its own: "<App>.hardwareAddress[.<receiver name>]".
    NSString *base = [prefix stringByAppendingString:@".hardwareAddress"];
    NSString *key = [receiverName isEqualToString:primaryName]
        ? base
        : [[base stringByAppendingString:@"."] stringByAppendingString:receiverName];
    NSData *savedAddress = [defaults dataForKey:key];

    if (savedAddress.length == 6) {
        memcpy(output, savedAddress.bytes, 6);
    } else {
        uuid_t uuidBytes = {0};
        [[NSUUID UUID] getUUIDBytes:uuidBytes];
        memcpy(output, uuidBytes, 6);
    }

    output[0] |= 0x02;
    output[0] &= 0xFE;

    NSData *address = [NSData dataWithBytes:output length:6];
    [defaults setObject:address forKey:key];
}

static BOOL AirPlayPortIsAvailable(unsigned short port) {
    int ipv4Socket = socket(AF_INET, SOCK_STREAM, 0);
    if (ipv4Socket < 0) {
        return NO;
    }

    struct sockaddr_in ipv4Address;
    memset(&ipv4Address, 0, sizeof(ipv4Address));
    ipv4Address.sin_len = sizeof(ipv4Address);
    ipv4Address.sin_family = AF_INET;
    ipv4Address.sin_addr.s_addr = htonl(INADDR_ANY);
    ipv4Address.sin_port = htons(port);

    BOOL ipv4Available = bind(ipv4Socket, (struct sockaddr *) &ipv4Address, sizeof(ipv4Address)) == 0;
    close(ipv4Socket);

    if (!ipv4Available) {
        return NO;
    }

    int ipv6Socket = socket(AF_INET6, SOCK_STREAM, 0);
    if (ipv6Socket < 0) {
        return NO;
    }

    struct sockaddr_in6 ipv6Address;
    memset(&ipv6Address, 0, sizeof(ipv6Address));
    ipv6Address.sin6_len = sizeof(ipv6Address);
    ipv6Address.sin6_family = AF_INET6;
    ipv6Address.sin6_addr = in6addr_any;
    ipv6Address.sin6_port = htons(port);

    BOOL ipv6Available = bind(ipv6Socket, (struct sockaddr *) &ipv6Address, sizeof(ipv6Address)) == 0;
    close(ipv6Socket);

    return ipv6Available;
}

static unsigned short AirPlayFirstAvailablePort(void) {
    for (unsigned short port = 7000; port <= 7010; port++) {
        if (AirPlayPortIsAvailable(port)) {
            return port;
        }
    }

    return 0;
}

@implementation AirPlayReceiverCoreConfiguration

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _receiverName = @"Air2Me";
    _displaySize = CGSizeMake(1280.0, 720.0);
    _scale = 1.0;
    _refreshRate = 60.0;
    return self;
}

@end

@implementation AirPlayReceiverCoreBridge

- (instancetype)initWithDelegate:(id<AirPlayReceiverCoreBridgeDelegate>)delegate {
    self = [super init];
    if (!self) {
        return nil;
    }

    _delegate = delegate;
    _displaySize = CGSizeMake(1280.0, 720.0);
    _displayScale = 1.0;
    _refreshRate = 60.0;
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)startWithConfiguration:(AirPlayReceiverCoreConfiguration *)configuration error:(NSError **)error {
    [self stop];

    self.stopping = NO;
    self.lastCoreErrorMessage = nil;
    _displaySize = configuration.displaySize;
    _displayScale = configuration.scale;
    _refreshRate = configuration.refreshRate > 0.0 ? configuration.refreshRate : 60.0;

    raop_callbacks_t callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.cls = (__bridge void *) self;
    callbacks.audio_process = &AirPlayReceiverAudioProcess;
    callbacks.audio_flush = &AirPlayReceiverAudioFlush;
    callbacks.audio_set_volume = &AirPlayReceiverAudioSetVolume;
    callbacks.video_process = &AirPlayReceiverVideoProcess;
    callbacks.conn_init = &AirPlayReceiverConnect;
    callbacks.conn_destroy = &AirPlayReceiverDisconnect;
    callbacks.video_flush = &AirPlayReceiverVideoFlush;

    /* iOS may keep auxiliary RTSP connections open while establishing the
     * mirroring session. One socket slot can stall the second handshake. */
    _raop = raop_init(8, &callbacks);
    if (!_raop) {
        if (error) {
            *error = [NSError errorWithDomain:AirPlayReceiverCoreErrorDomain
                                         code:AirPlayReceiverCoreErrorUnableToCreateReceiver
                                     userInfo:@{NSLocalizedDescriptionKey: @"Unable to create the AirPlay receiver core."}];
        }
        return NO;
    }

    raop_set_log_level(_raop, LOGGER_DEBUG);
    raop_set_log_callback(_raop, &AirPlayReceiverLogCallback, (__bridge void *) self);

    uint8_t hardwareAddress[6] = {0};
    AirPlayReceiverHardwareAddress(hardwareAddress, configuration.receiverName);

    NSData *nameData = [configuration.receiverName dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    int dnssdError = DNSSD_ERROR_NOERROR;
    _dnssd = dnssd_init(
        (const char *) nameData.bytes,
        (int) nameData.length,
        (const char *) hardwareAddress,
        (int) sizeof(hardwareAddress),
        &dnssdError
    );

    if (!_dnssd) {
        raop_destroy(_raop);
        _raop = NULL;

        if (error) {
            *error = [NSError errorWithDomain:AirPlayReceiverCoreErrorDomain
                                         code:AirPlayReceiverCoreErrorUnableToCreateBonjour
                                     userInfo:@{NSLocalizedDescriptionKey: @"Unable to create Bonjour advertisement for the receiver."}];
        }
        return NO;
    }

    [self updateDisplaySize:configuration.displaySize scale:configuration.scale refreshRate:configuration.refreshRate];

    unsigned short listeningPort = AirPlayFirstAvailablePort();
    if (listeningPort == 0) {
        [self stop];

        if (error) {
            *error = [NSError errorWithDomain:AirPlayReceiverCoreErrorDomain
                                         code:AirPlayReceiverCoreErrorUnableToStartReceiver
                                     userInfo:@{NSLocalizedDescriptionKey: @"No AirPlay receiver port is available in the 7000-7010 range."}];
        }
        return NO;
    }

    raop_set_dnssd(_raop, _dnssd);
    raop_set_port(_raop, listeningPort);

    if (dnssd_register_raop(_dnssd, listeningPort) != 0 || dnssd_register_airplay(_dnssd, listeningPort) != 0) {
        [self stop];

        if (error) {
            *error = [NSError errorWithDomain:AirPlayReceiverCoreErrorDomain
                                         code:AirPlayReceiverCoreErrorUnableToAdvertiseReceiver
                                     userInfo:@{NSLocalizedDescriptionKey: @"Unable to advertise the receiver over Bonjour."}];
        }
        return NO;
    }

    int startResult = raop_start(_raop, &listeningPort);
    if (startResult != 1) {
        dnssd_destroy(_dnssd);
        _dnssd = NULL;
        raop_destroy(_raop);
        _raop = NULL;

        if (error) {
            *error = [NSError errorWithDomain:AirPlayReceiverCoreErrorDomain
                                         code:AirPlayReceiverCoreErrorUnableToStartReceiver
                                     userInfo:@{
                                        NSLocalizedDescriptionKey: self.lastCoreErrorMessage ?: [NSString stringWithFormat:@"Unable to start the AirPlay receiver listener (code %d).", startResult]
                                     }];
        }
        return NO;
    }

    self.port = listeningPort;
    self.running = YES;

    raop_set_port(_raop, listeningPort);

    id<AirPlayReceiverCoreBridgeDelegate> delegate = self.delegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate receiverBridge:self didUpdateDiscoverabilityOnPort:listeningPort];
        });
    }

    return YES;
}

- (void)updateDisplaySize:(CGSize)displaySize scale:(CGFloat)scale refreshRate:(double)refreshRate {
    _displaySize = displaySize;
    _displayScale = scale > 0.0 ? scale : 1.0;
    _refreshRate = refreshRate > 0.0 ? refreshRate : 60.0;

    if (!_dnssd) {
        return;
    }

    uint32_t widthPixels = (uint32_t) llround(MAX(displaySize.width * _displayScale, 1.0));
    uint32_t heightPixels = (uint32_t) llround(MAX(displaySize.height * _displayScale, 1.0));
    dnssd_set_display_dimensions(_dnssd, widthPixels, heightPixels, _refreshRate);
}

- (void)stop {
    if (!_raop && !_dnssd) {
        self.running = NO;
        self.port = 0;
        return;
    }

    self.stopping = YES;

    if (_dnssd) {
        dnssd_destroy(_dnssd);
        _dnssd = NULL;
    }

    if (_raop) {
        raop_destroy(_raop);
        _raop = NULL;
    }

    self.running = NO;
    self.port = 0;
    self.stopping = NO;
}

@end
