# Development certificates and profile

`make signing-setup` runs `fastlane mac development_signing`. The lane reads ignored `.env` credentials and restores the existing Apple Development certificates and the development provisioning profiles ("match Development dev.capturecontext.arx macos", and Arx Dev's "match Development dev.capturecontext.arx.dev macos" once it exists; until then the lane only warns) from the configured encrypted Match repository. It uses App Store Connect API authentication.

Match runs read-only. No certificate or profile creation, revocation, device registration, archive upload, or distribution is part of this lane. If the repository has no usable certificate or profile, setup fails rather than creating one.

Install pinned tooling with `mise install`. mise installs Fastlane itself (`gem:fastlane` in `mise.toml`) with `gem install` into its own directory; there is no Gemfile or Bundler. Only Fastlane's own version is pinned: RubyGems resolves its dependencies when it installs, and `mise.lock` records only the top-level version for `gem:` tools, so two installs at different times can get different dependency versions. Make and the scripts run `fastlane` through `mise exec`; run it by hand as `mise exec -- fastlane …`. Configure `.env.example` keys in `.env`. Never commit credentials, certificate private keys, provisioning profiles or device lists. Match installs profiles into `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`, where the build scripts look for them; `make signing-check` shows the identity and profile a signed build will use.

# Developer ID certificate and profile

`make release-signing-setup` runs `fastlane mac developer_id_signing`, which restores the existing Developer ID Application certificate and the Developer ID profile ("match Direct dev.capturecontext.arx macos") for release builds (`make dmg`) the same way: Match read-only, no creation or revocation. The certificate has to be created once in the Apple Developer portal and stored in the Match repository (`import_developer_id` below); until then the lane and `make dmg` fail with that instruction.

On CI, setting `ARX_RELEASE_KEYCHAIN` and `ARX_RELEASE_KEYCHAIN_PASSWORD` makes the lane import into a throwaway keychain with that name instead of the login keychain. `release_keychain_cleanup` (`make release-signing-cleanup`) deletes it afterwards.

# iCloud provisioning profiles (writes)

Signed Arx carries iCloud (CloudKit) and push entitlements for the container `iCloud.dev.capturecontext.arx`, so every signed build needs a provisioning profile. Two lanes write to the Apple portal or the Match repository. A person runs them by hand, never the build scripts or CI:

- `mise exec -- fastlane mac signing_profiles [devices:<file>] [force:true]` registers the Macs listed in the devices file, then runs Match for `development` (Arx and Arx Dev, `dev.capturecontext.arx.dev`) and `developer_id` (Arx only) with profiles. Arx Dev's profile needs its App ID registered in the portal first, with iCloud on the same container and Push Notifications (DEVELOPMENT.md › Arx Dev); until it is, the lane says it skipped Arx Dev and still makes Arx's profiles. The devices file is tab-separated `Device ID<TAB>Device Name` and lives outside the repository (for example `~/.config/arx/devices.txt`). The development profile is regenerated when a new Mac is registered. Pass `force:true` after a capability, container or certificate change so both profiles are made again.
- `mise exec -- fastlane mac import_developer_id cert:<file.cer> p12:<file.p12>` stores an existing Developer ID Application certificate in Match, because the App Store Connect API can't create one.

After either lane, other Macs run `make signing-setup` and `make release-signing-setup` to restore the new profiles.
