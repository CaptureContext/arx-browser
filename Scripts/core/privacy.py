"""Info.plist privacy usage descriptions for bundles that run the engine (DEV-861).

Chromium asks macOS for these permissions, and macOS terminates an app that asks without a
description. The app gets them from .xcodegen/macOS.yml, the engine host from this table, and
Scripts/tests/test_privacy.py keeps both in step with Chromium's own list.
"""

BLUETOOTH = "Websites you allow can use Bluetooth in Arx, for example to sign in with a passkey on your phone."

USAGE_DESCRIPTIONS = {
    "NSAppleEventsUsageDescription": "Arx hands app links, such as sign-in callbacks, to the app you chose for this profile.",
    "NSAudioCaptureUsageDescription": "Websites you allow can capture audio in Arx.",
    "NSBluetoothAlwaysUsageDescription": BLUETOOTH,
    "NSBluetoothPeripheralUsageDescription": BLUETOOTH,
    "NSCameraUsageDescription": "Websites you allow can use your camera in Arx.",
    "NSLocalNetworkUsageDescription": "Arx finds Chromecasts and other devices to cast to on your local network, and websites you allow can reach devices on it.",
    "NSLocationUsageDescription": "Websites you allow can use your location in Arx.",
    "NSMicrophoneUsageDescription": "Websites you allow can use your microphone in Arx.",
    "NSWebBrowserPublicKeyCredentialUsageDescription": "Websites you allow can use your passkeys in Arx.",
}

# Cast (DEV-927): the Bonjour service Chromium's Media Router browses for Chromecasts. macOS shows
# the Local Network prompt for it and refuses to browse a type the bundle doesn't list. DIAL's
# SSDP search is plain multicast, which the same Local Network permission covers.
BONJOUR_SERVICES = ["_googlecast._tcp"]
