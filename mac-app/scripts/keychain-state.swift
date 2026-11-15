// Prints "locked" or "unlocked" for a keychain file. Never shows UI: SecKeychainGetStatus only reads the state, and
// user interaction is switched off for this process anyway. (`security show-keychain-info` must NOT be used for this:
// on a locked keychain it asks for the password in a GUI dialog.)
//   swift scripts/keychain-state.swift <path>
import Security
SecKeychainSetUserInteractionAllowed(false)
var kc: SecKeychain?
guard CommandLine.arguments.count == 2, SecKeychainOpen(CommandLine.arguments[1], &kc) == errSecSuccess else {
    print("error"); exit(2)
}
var st: SecKeychainStatus = 0
guard SecKeychainGetStatus(kc, &st) == errSecSuccess else { print("error"); exit(2) }
print((st & UInt32(kSecUnlockStateStatus)) != 0 ? "unlocked" : "locked")
