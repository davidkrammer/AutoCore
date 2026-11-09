#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const AirPlayReceiverCoreErrorDomain;

typedef NS_ENUM(NSInteger, AirPlayReceiverCoreErrorCode) {
    AirPlayReceiverCoreErrorUnableToCreateReceiver = 1,
    AirPlayReceiverCoreErrorUnableToCreateBonjour,
    AirPlayReceiverCoreErrorUnableToStartReceiver,
    AirPlayReceiverCoreErrorUnableToAdvertiseReceiver,
};

typedef NS_ENUM(NSInteger, AirPlayReceiverCoreLogLevel) {
    AirPlayReceiverCoreLogLevelEmergency = 0,
    AirPlayReceiverCoreLogLevelAlert = 1,
    AirPlayReceiverCoreLogLevelCritical = 2,
    AirPlayReceiverCoreLogLevelError = 3,
    AirPlayReceiverCoreLogLevelWarning = 4,
    AirPlayReceiverCoreLogLevelNotice = 5,
    AirPlayReceiverCoreLogLevelInfo = 6,
    AirPlayReceiverCoreLogLevelDebug = 7,
};

@class AirPlayReceiverCoreBridge;

@protocol AirPlayReceiverCoreBridgeDelegate <NSObject>
- (void)receiverBridge:(AirPlayReceiverCoreBridge *)bridge didUpdateDiscoverabilityOnPort:(uint16_t)port;
- (void)receiverBridge:(AirPlayReceiverCoreBridge *)bridge
    didStartConnectingFromHost:(nullable NSString *)host scopeID:(uint32_t)scopeID;
- (void)receiverBridgeDidDisconnect:(AirPlayReceiverCoreBridge *)bridge reason:(nullable NSString *)reason;
- (void)receiverBridgeDidFlushAudio:(AirPlayReceiverCoreBridge *)bridge;
- (void)receiverBridgeDidFlushVideo:(AirPlayReceiverCoreBridge *)bridge;
- (void)receiverBridge:(AirPlayReceiverCoreBridge *)bridge didReceiveAudioPacket:(NSData *)packet ptsMicroseconds:(uint64_t)ptsMicroseconds;
- (void)receiverBridge:(AirPlayReceiverCoreBridge *)bridge didReceiveParameterSetsWithSPS:(NSData *)sps pps:(NSData *)pps;
- (void)receiverBridge:(AirPlayReceiverCoreBridge *)bridge didReceiveFrame:(NSData *)frame ptsMicroseconds:(uint64_t)ptsMicroseconds;
- (void)receiverBridge:(AirPlayReceiverCoreBridge *)bridge didUpdateAudioVolume:(float)volume;
- (void)receiverBridge:(AirPlayReceiverCoreBridge *)bridge didLogMessage:(NSString *)message level:(AirPlayReceiverCoreLogLevel)level;
@end

@interface AirPlayReceiverCoreConfiguration : NSObject
@property (nonatomic, copy) NSString *receiverName;
@property (nonatomic) CGSize displaySize;
@property (nonatomic) CGFloat scale;
@property (nonatomic) double refreshRate;
@end

@interface AirPlayReceiverCoreBridge : NSObject
@property (nonatomic, weak, nullable) id<AirPlayReceiverCoreBridgeDelegate> delegate;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) uint16_t port;

- (instancetype)initWithDelegate:(nullable id<AirPlayReceiverCoreBridgeDelegate>)delegate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (BOOL)startWithConfiguration:(AirPlayReceiverCoreConfiguration *)configuration error:(NSError **)error;
- (void)updateDisplaySize:(CGSize)displaySize scale:(CGFloat)scale refreshRate:(double)refreshRate;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
