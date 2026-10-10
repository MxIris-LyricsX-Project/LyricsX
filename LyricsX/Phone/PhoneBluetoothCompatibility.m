#import "PhoneBluetoothCompatibility.h"

// These selectors are undocumented. Restrict the workaround to the OS on which
// the missing callback was observed; other releases use native IOBluetooth.
BOOL LXBluetoothCompatibilitySupportsVersion(NSInteger majorVersion) {
    return majorVersion == 27;
}

static BOOL LXMatches(id target, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != arguments.count + 2 || strcmp(signature.methodReturnType, result)) {
        return NO;
    }
    for (NSUInteger index = 0; index < arguments.count; index++) {
        if (strcmp([signature getArgumentTypeAtIndex:index + 2], arguments[index].UTF8String)) {
            return NO;
        }
    }
    return YES;
}

static id LXGetObject(id target, SEL selector) {
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[target methodSignatureForSelector:selector]];
    invocation.target = target;
    invocation.selector = selector;
    [invocation invoke];
    __unsafe_unretained id result = nil;
    [invocation getReturnValue:&result];
    return result;
}

BOOL LXInstallMissingBluetoothCallbacks(NSObject *peer, NSObject *coordinator) {
    @try {
        NSArray<NSArray<NSString *> *> *selectors = @[
            @[@"connectL2CAPCallback", @"setConnectL2CAPCallback:", @"peerL2CAPChannelConnected:error:"],
            @[@"disconnectL2CAPCallback", @"setDisconnectL2CAPCallback:", @"peerL2CAPChannelDisconnected:error:"]
        ];
        // Validate both callback slots before touching either one. Checking only
        // respondsToSelector would not establish a compatible ABI.
        for (NSArray<NSString *> *entry in selectors) {
            if (!LXMatches(peer, NSSelectorFromString(entry[0]), "@?", @[]) ||
                !LXMatches(peer, NSSelectorFromString(entry[1]), "v", @[@"@?"])) {
                return NO;
            }
        }
        for (NSArray<NSString *> *entry in selectors) {
            SEL getter = NSSelectorFromString(entry[0]);
            if (LXGetObject(peer, getter)) { continue; }
            SEL forward = NSSelectorFromString(entry[2]);
            void (^callback)(id, long long) = ^(id channel, long long error) {
                @try {
                    // The coordinator's forwarding signature becomes available
                    // after channel registration. Validate at delivery time.
                    if (!LXMatches(coordinator, forward, "v", @[@"@", @"q"])) { return; }
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[coordinator methodSignatureForSelector:forward]];
                    invocation.target = coordinator;
                    invocation.selector = forward;
                    [invocation setArgument:&channel atIndex:2];
                    [invocation setArgument:&error atIndex:3];
                    [invocation invoke];
                } @catch (NSException *exception) {
                    // A changed private implementation must not crash the worker.
                }
            };
            SEL setter = NSSelectorFromString(entry[1]);
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[peer methodSignatureForSelector:setter]];
            invocation.target = peer;
            invocation.selector = setter;
            [invocation setArgument:&callback atIndex:2];
            [invocation invoke];
        }
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

void LXPrepareBluetoothCallbacks(NSObject *device) {
#if defined(__arm64__)
    if (!LXBluetoothCompatibilitySupportsVersion(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion)) { return; }
    @try {
        SEL peerSelector = NSSelectorFromString(@"peer");
        Class coordinatorClass = NSClassFromString(@"IOBluetoothCoreBluetoothCoordinator");
        SEL shared = NSSelectorFromString(@"sharedInstance");
        if (!LXMatches(device, peerSelector, "@", @[]) || !LXMatches(coordinatorClass, shared, "@", @[])) { return; }
        NSObject *peer = LXGetObject(device, peerSelector);
        NSObject *coordinator = LXGetObject(coordinatorClass, shared);
        if (peer && coordinator) { LXInstallMissingBluetoothCallbacks(peer, coordinator); }
    } @catch (NSException *exception) {
        // Native connection timeouts report an unsupported bridge to the parent.
    }
#endif
}
