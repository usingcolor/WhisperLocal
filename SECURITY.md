# Security

Please report vulnerabilities **privately** via GitHub Security Advisories:

https://github.com/usingcolor/WhisperLocal/security/advisories/new

Do not file a public issue for a security report. Include the WhisperLocal version (`About` / menu bar) and enough detail to reproduce.

Audio stays on this Mac unless the user opts in to cloud polish, which sends transcript text only — never audio. Optional auto-update downloads a DMG from [GitHub Releases](https://github.com/usingcolor/WhisperLocal/releases) and replaces `/Applications/WhisperLocal.app`.

When a release publishes `SHA256SUMS`, the updater hashes the DMG (SHA-256) before install. That is transport/CDN integrity, not authenticity: whoever can swap the DMG on the release can swap the checksum file beside it. Official release DMGs and apps are Developer ID signed and Apple-notarized; the mounted bundle's signature check also rejects post-signing corruption. Downloads remain quarantined (`LSFileQuarantineEnabled`) so Gatekeeper assesses the installed app. Local and fallback builds may still use ad-hoc signing, which has no stable publisher identity.
