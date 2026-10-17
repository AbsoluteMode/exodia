# Keep Case data recoverable

Case stores encrypted values on this Mac. Its vault and Keychain encryption key
must stay in the same application flavor: production uses its existing file,
while beta/dev have a separate bundle-specific directory.

Before replacing an existing encrypted vault, `CaseVaultStore` keeps its prior
bytes in a `.bak` file. If the vault cannot be decrypted, Reset archives that
file instead of deleting it. Reset does not recover the previous encryption key;
the archive preserves evidence for recovery, without claiming it can be decoded.
No plaintext values are included in logs, this record or the repository.

Verified by `Tests/SidekeyTests/Case/CaseVaultStoreTests.swift` and
`Tests/SidekeyTests/Case/CaseViewModelTests.swift`. The open-source migration
preserves these safeguards from the installed local-data implementation.
