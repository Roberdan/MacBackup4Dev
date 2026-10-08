#ifndef MB4D_KEYCHAIN_STATUS_H
#define MB4D_KEYCHAIN_STATUS_H

#include <stdbool.h>
#include <Security/Security.h>

static inline bool MB4DKeychainStatusIsLocked(OSStatus result, SecKeychainStatus status) {
    return result != errSecSuccess || (status & kSecUnlockStateStatus) == 0;
}

// File-based login Keychain status has no nondeprecated, dialog-free replacement.
// This compatibility boundary reads only lock status; secrets stay in /usr/bin/security.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline bool MB4DLoginKeychainIsLocked(void) {
    SecKeychainStatus status = 0;
    OSStatus result = SecKeychainGetStatus(NULL, &status);
    return MB4DKeychainStatusIsLocked(result, status);
}
#pragma clang diagnostic pop

#endif
