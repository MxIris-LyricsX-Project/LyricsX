#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Worker-local workaround; never changes system services or existing callbacks.
void LXPrepareBluetoothCallbacks(NSObject *device);

/// Internal helpers exposed to the offline compatibility probe.
BOOL LXBluetoothCompatibilitySupportsVersion(NSInteger majorVersion);
BOOL LXInstallMissingBluetoothCallbacks(NSObject *peer, NSObject *coordinator);

NS_ASSUME_NONNULL_END
