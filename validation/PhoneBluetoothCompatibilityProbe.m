#import "PhoneBluetoothCompatibility.h"

@interface Peer : NSObject
@property(copy) void (^connectL2CAPCallback)(id, long long);
@property(copy) void (^disconnectL2CAPCallback)(id, long long);
@end
@implementation Peer
@end

@interface Receiver : NSObject
@property NSInteger calls;
@property long long error;
- (void)peerL2CAPChannelConnected:(id)channel error:(long long)error;
- (void)peerL2CAPChannelDisconnected:(id)channel error:(long long)error;
@end
@implementation Receiver
- (void)peerL2CAPChannelConnected:(id)channel error:(long long)error { self.calls++; self.error = error; }
- (void)peerL2CAPChannelDisconnected:(id)channel error:(long long)error { self.calls++; self.error = error; }
@end

// Model the real coordinator: these methods are supplied by forwarding after
// channel registration, rather than implemented directly by the coordinator.
@interface Forwarder : NSObject
@property Receiver *receiver;
@end
@implementation Forwarder
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [super methodSignatureForSelector:selector] ?: [self.receiver methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:self.receiver]; }
@end

@interface WrongReceiver : NSObject
@property NSInteger calls;
- (void)peerL2CAPChannelConnected:(id)channel error:(int)error;
@end
@implementation WrongReceiver
- (void)peerL2CAPChannelConnected:(id)channel error:(int)error { self.calls++; }
@end

int main(void) {
    @autoreleasepool {
        int checks = 0;
#define CHECK(condition) do { if (!(condition)) { NSLog(@"FAIL line %d", __LINE__); return 1; } checks++; } while (0)
        CHECK(LXBluetoothCompatibilitySupportsVersion(27));
        CHECK(!LXBluetoothCompatibilitySupportsVersion(26));
        CHECK(!LXBluetoothCompatibilitySupportsVersion(28));
        Peer *peer = [Peer new];
        Forwarder *forwarder = [Forwarder new];
        CHECK(LXInstallMissingBluetoothCallbacks(peer, forwarder));
        CHECK(peer.connectL2CAPCallback != nil && peer.disconnectL2CAPCallback != nil);
        // No delegate yet: should safely drop instead of sending an unknown selector.
        peer.connectL2CAPCallback(nil, 1);
        forwarder.receiver = [Receiver new];
        peer.connectL2CAPCallback(nil, 0x123456789LL);
        peer.disconnectL2CAPCallback(nil, -4);
        CHECK(forwarder.receiver.calls == 2 && forwarder.receiver.error == -4);
        id original = peer.connectL2CAPCallback;
        CHECK(LXInstallMissingBluetoothCallbacks(peer, forwarder));
        CHECK(original == peer.connectL2CAPCallback);
        CHECK(!LXInstallMissingBluetoothCallbacks([NSObject new], forwarder));
        Peer *wrongPeer = [Peer new];
        WrongReceiver *wrong = [WrongReceiver new];
        CHECK(LXInstallMissingBluetoothCallbacks(wrongPeer, wrong));
        wrongPeer.connectL2CAPCallback(nil, 123);
        CHECK(wrong.calls == 0);
        printf("%d Bluetooth compatibility checks passed\n", checks);
    }
    return 0;
}
