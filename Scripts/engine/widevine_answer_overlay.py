"""Answer Widevine as Chrome on the Mac does, without any Widevine at all (DEV-1144).

Arx uses no Widevine: no CDM, no component, no download, never registered or loaded
(`component_updates.h` leaves it out). All protected playback in Arx is FairPlay, through
Arx's FairPlay helper or a WebKit page. Pages that see no Widevine at all may treat the
browser as a bot: Apple's online store answers its checkout steps with HTTP 541. So with
`kArxWidevineAnswer` on (the default), the renderer's key system list gets Chrome's Mac
Widevine entry: software-secure VP8, VP9, AV1 and H.264, `cenc` and `cbcs`, temporary
sessions. `requestMediaKeySystemAccess('com.widevine.alpha', ...)` resolves, and
`createMediaKeys()` then rejects cleanly with NotSupportedError.

Nothing here can reach a real Widevine CDM, even one that appears on disk: the renderer
ignores any Widevine capability the browser reports (the answer replaces it, and with the
feature off Widevine isn't listed), and `MediaInterfaceProxy::CreateLibraryCdm` refuses
Widevine before it looks for a CDM factory.

`ARX_WIDEVINE_ANSWER=off` makes the engine add the feature to `--disable-features`
(`engine_bridge.mm`); Chromium copies feature state to renderers.

Since access now resolves, the DEV-877 hook can't report the first key system question any
more: Apple's store probes Widevine without playing anything. `protected_media_overlay.py`
no longer reports that question at all (DEV-1211). Instead, this overlay records a library CDM
that couldn't be created on its document, which is where a page that took the answer fails:
failed playback once a media element wants keys, keys without media until then (a bot check
may create keys it never uses). `protected_media_overlay.py` also reports a document left
without protected media: a
`requestMediaKeySystemAccess` the renderer refused (a configuration the answer doesn't cover,
or another protected key system) with no protected key system granted to the document within
3 seconds. Bot detection that probes every key system is granted Widevine, as Chrome is, and
isn't offered WebKit (DEV-1205).

If an anchor changes, the build stops.
"""
from .overlay import replace_once

SWITCHES_HEADER = "media/base/media_switches.h"
SWITCHES_SOURCE = "media/base/media_switches.cc"
KEY_SYSTEMS = "components/cdm/renderer/key_system_support_update.cc"
INTERFACE_PROXY = "content/browser/media/media_interface_proxy.cc"

HOOKS = '#include "chrome/browser/arx/protected_media_hooks.h"  // nogncheck\n'

CAPABILITY = '''
// Arx (DEV-1144): Chrome's Mac Widevine entry, for a renderer whose browser has
// no Widevine CDM. Creating the keys then fails in the browser.
media::KeySystemCapability ArxWidevineCapabilityWithoutCdm() {
  media::CdmCapability capability;
  capability.audio_codecs = media::GetCdmSupportedAudioCodecs();
  const media::VideoCodecInfo all_profiles;
  capability.video_codecs.emplace(media::VideoCodec::kVP8, all_profiles);
  capability.video_codecs.emplace(media::VideoCodec::kVP9, all_profiles);
  capability.video_codecs.emplace(media::VideoCodec::kAV1, all_profiles);
#if BUILDFLAG(USE_PROPRIETARY_CODECS)
  capability.video_codecs.emplace(media::VideoCodec::kH264, all_profiles);
#endif  // BUILDFLAG(USE_PROPRIETARY_CODECS)
  capability.encryption_schemes = {media::EncryptionScheme::kCenc,
                                   media::EncryptionScheme::kCbcs};
  capability.session_types = {CdmSessionType::kTemporary};
  media::KeySystemCapability key_system_capability;
  key_system_capability.sw_cdm_capability_or_status = capability;
  return key_system_capability;
}
'''


def patches():
    yield SWITCHES_HEADER, "MEDIA_EXPORT BASE_DECLARE_FEATURE(kExternalClearKeyForTesting);\n", (
        "MEDIA_EXPORT BASE_DECLARE_FEATURE(kExternalClearKeyForTesting);\n"
        "// Arx (DEV-1144): answer Widevine without a CDM. widevine_answer_overlay.py.\n"
        "MEDIA_EXPORT BASE_DECLARE_FEATURE(kArxWidevineAnswer);\n")
    yield SWITCHES_SOURCE, "BASE_FEATURE(kExternalClearKeyForTesting, base::FEATURE_DISABLED_BY_DEFAULT);\n", (
        "BASE_FEATURE(kExternalClearKeyForTesting, base::FEATURE_DISABLED_BY_DEFAULT);\n\n"
        "// Arx (DEV-1144): the renderer lists Chrome's Mac Widevine entry while no\n"
        "// Widevine CDM is registered. ARX_WIDEVINE_ANSWER=off disables it.\n"
        "BASE_FEATURE(kArxWidevineAnswer, base::FEATURE_ENABLED_BY_DEFAULT);\n")
    yield KEY_SYSTEMS, '#include "components/cdm/renderer/widevine_key_system_info.h"\n', (
        '#include "components/cdm/renderer/widevine_key_system_info.h"\n'
        '#include "media/cdm/supported_audio_codecs.h"\n')
    yield KEY_SYSTEMS, "void OnKeySystemSupportUpdated(\n", (
        "#if BUILDFLAG(ENABLE_WIDEVINE)" + CAPABILITY + "#endif  // BUILDFLAG(ENABLE_WIDEVINE)\n\n"
        "void OnKeySystemSupportUpdated(\n")
    yield KEY_SYSTEMS, "  KeySystemInfos key_systems;\n  for (const auto& [key_system, capability] : key_system_capabilities) {\n", (
        "  KeySystemInfos key_systems;\n"
        "#if BUILDFLAG(ENABLE_WIDEVINE)\n"
        "  // Arx (DEV-1144): Widevine answered as in Chrome. Arx has no Widevine; the\n"
        "  // keys fail to be created, and every protected playback is FairPlay.\n"
        "  if (base::FeatureList::IsEnabled(media::kArxWidevineAnswer)) {\n"
        "    AddWidevine(ArxWidevineCapabilityWithoutCdm(), can_persist_data,\n"
        "                &key_systems);\n"
        "  }\n"
        "#endif  // BUILDFLAG(ENABLE_WIDEVINE)\n"
        "  for (const auto& [key_system, capability] : key_system_capabilities) {\n")
    # A Widevine capability the browser reports (a CDM on disk) is never used.
    yield KEY_SYSTEMS, "    if (key_system == kWidevineKeySystem) {\n      AddWidevine(capability, can_persist_data, &key_systems);\n      continue;\n    }\n", (
        "    if (key_system == kWidevineKeySystem) {\n"
        "      // Arx (DEV-1144): never a real Widevine CDM, even one on disk.\n"
        "      continue;\n"
        "    }\n")
    yield INTERFACE_PROXY, '#include "content/browser/media/media_interface_proxy.h"\n', (
        '#include "content/browser/media/media_interface_proxy.h"\n\n' + HOOKS)
    yield INTERFACE_PROXY, "  auto* factory = GetCdmFactory(cdm_config.key_system);\n  if (!factory) {\n", (
        "  // Arx (DEV-1144): Arx has no Widevine. Its keys are never created, even\n"
        "  // with a Widevine CDM on disk; the page fails cleanly and plays FairPlay.\n"
        "  auto* factory = cdm_config.key_system == \"com.widevine.alpha\"\n"
        "                      ? nullptr\n"
        "                      : GetCdmFactory(cdm_config.key_system);\n"
        "  if (!factory) {\n"
        "    // A page that wanted protected media and found no CDM, such as Widevine\n"
        "    // answered without one. The embedder may offer another engine for the\n"
        "    // page; it posts its work.\n"
        "    arx::ReportProtectedMediaFailure(&render_frame_host());\n")


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
