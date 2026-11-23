#ifndef ARX_PRIVATE_DOWNLOAD_PREFS_H_
#define ARX_PRIVATE_DOWNLOAD_PREFS_H_

class Profile;

namespace arx {
// ABI45 (DEV-729). A private window's off-the-record profile is made from the
// bootstrap or Default profile, never from the profile that opened it. These
// keep its downloads folder, save-as folder and "Ask where to save" equal to the
// opener's: copied at once into the OTR context's own (ephemeral) prefs and
// again whenever the opener's change. Download prefs aren't in Chromium's
// incognito persistent allowlist, so nothing is written to the OTR parent.
// Managed values are left alone. The link ends when either profile is
// destroyed or StopFollowingOpenerDownloadPreferences runs. UI thread.
void FollowOpenerDownloadPreferences(Profile* private_profile, Profile* opener);
void StopFollowingOpenerDownloadPreferences(Profile* private_profile);
}  // namespace arx
#endif
