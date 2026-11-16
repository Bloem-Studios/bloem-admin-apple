import Security

struct SecurityClient: Sendable {
    var copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    var add: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var delete: @Sendable (CFDictionary) -> OSStatus

    static let live = SecurityClient(
        copyMatching: { SecItemCopyMatching($0, $1) },
        update: { SecItemUpdate($0, $1) },
        add: { SecItemAdd($0, $1) },
        delete: { SecItemDelete($0) }
    )
}
