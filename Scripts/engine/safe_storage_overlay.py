"""Harden Keychain Safe Storage (DEV-900).

The "Arx Storage Key" Keychain item holds the key to every saved password and
cookie. Helium already keeps loading paused when the key can't be read
(`prevent-reset-on-keychain-unavailability.patch`) and then shows an error and
exits. On top of that:

* a missing item never becomes a new key while profiles hold data encrypted
  with the old one: `arx::SetSafeStorageKeyCreationPolicy` decides, and the
  key is created with SecItemAdd only, because `AddGenericPassword` overwrites
  an item that appeared since the lookup;
* Arx explains a key it can't read and offers Try Again
  (`arx::SetSafeStorageUnavailableHandler`, `safe_storage_bridge.mm`);
* a protected preference whose encrypted hash was made with an earlier key
  falls back to its HMAC, so a key change doesn't reset extensions and other
  tracked settings (an HMAC that doesn't hold still resets, as before);
* decrypted secrets are overwritten before their memory is freed: the
  intermediate buffers of `os_crypt_async::Encryptor` and the plain-text
  backing of `password_manager::PasswordString`;
* the item's service and account names come from the outer app's
  `ArxStorageKeyService` and `ArxStorageKeyAccount` Info.plist values when it
  has them, so Arx Dev keeps its own item (DEV-1013).
"""
from .overlay import replace_once

KEYCHAIN_HEADER = "crypto/apple/keychain_v2.h"
KEYCHAIN = "crypto/apple/keychain_v2.mm"
FAKE_KEYCHAIN_HEADER = "crypto/apple/fake_keychain_v2.h"
FAKE_KEYCHAIN = "crypto/apple/fake_keychain_v2.mm"
PASSWORD = "components/os_crypt/common/keychain_password_mac.mm"
PROVIDER = "components/os_crypt/async/browser/keychain_key_provider.mm"
STRINGS = "chrome/app/generated_resources.grd"
PREF_HASHES = "services/preferences/tracked/pref_hash_store_impl.cc"
ENCRYPTOR = "components/os_crypt/async/common/encryptor.cc"
PASSWORD_STRING = "components/password_manager/core/browser/password_string.cc"

HOOKS = '#include "chrome/browser/arx/safe_storage_hooks.h"  // nogncheck\n'

ADD_DECLARATION = '''  virtual OSStatus AddGenericPassword(std::string_view service_name,
                                      std::string_view account_name,
                                      base::span<const uint8_t> password);
'''
FAKE_ADD_DECLARATION = '''  OSStatus AddGenericPassword(std::string_view service_name,
                              std::string_view account_name,
                              base::span<const uint8_t> password) override;
'''
FAKE_ADD = '''  called_add_generic_ = true;

  DCHECK(!password.empty());
  return noErr;
}
'''

BUNDLE_INCLUDES = '#include "base/apple/bundle_locations.h"\n#include "base/apple/foundation_util.h"\n'
KEYCHAIN_SERVICE_NAME = '''// static
KeychainPassword::KeychainNameType& KeychainPassword::GetServiceName() {
  static KeychainNameContainerType service_name(kDefaultServiceName);
'''
KEYCHAIN_ACCOUNT_NAME = '''  static KeychainNameContainerType account_name(kDefaultAccountName);
'''
ARX_KEYCHAIN_NAMES = '''namespace {

// Arx (DEV-1013): an Info.plist value of the outer app, or `fallback`.
std::string ArxKeychainName(NSString* key, const char* fallback) {
  NSString* value = base::apple::ObjCCast<NSString>(
      [base::apple::OuterBundle() objectForInfoDictionaryKey:key]);
  return value.length ? std::string(value.UTF8String) : std::string(fallback);
}

}  // namespace

std::string arx::SafeStorageKeyServiceName() {
  return ArxKeychainName(@"ArxStorageKeyService", kDefaultServiceName);
}

std::string arx::SafeStorageKeyAccountName() {
  return ArxKeychainName(@"ArxStorageKeyAccount", kDefaultAccountName);
}

'''

WIPE = '''// Arx (DEV-900): overwrites a buffer that held decrypted data, its spare
// capacity included, before the memory is freed or reused.
template <typename Buffer>
void ArxWipe(Buffer& buffer) {
  buffer.resize(buffer.capacity());
  crypto::SecureZeroBuffer(base::as_writable_byte_span(buffer));
  buffer.clear();
}
'''


def patches():
    # Create-only Keychain add.
    yield KEYCHAIN_HEADER, ADD_DECLARATION, ADD_DECLARATION + '''  // Arx (DEV-900): adds a generic password only when none exists and
  // returns errSecDuplicateItem otherwise. Never changes an existing item.
  virtual OSStatus AddGenericPasswordIfAbsent(
      std::string_view service_name,
      std::string_view account_name,
      base::span<const uint8_t> password);
'''
    yield KEYCHAIN, "base::expected<std::vector<uint8_t>, OSStatus> KeychainV2::FindGenericPassword(\n", '''OSStatus KeychainV2::AddGenericPasswordIfAbsent(
    std::string_view service_name,
    std::string_view account_name,
    base::span<const uint8_t> password) {
  base::apple::ScopedCFTypeRef<CFDictionaryRef> keychain_data =
      MakeKeychainData(service_name, account_name, password,
                       kKeychainActionCreate);
  return ItemAdd(keychain_data.get(), /*result=*/nullptr);
}

base::expected<std::vector<uint8_t>, OSStatus> KeychainV2::FindGenericPassword(
'''
    yield FAKE_KEYCHAIN_HEADER, FAKE_ADD_DECLARATION, FAKE_ADD_DECLARATION + '''  OSStatus AddGenericPasswordIfAbsent(
      std::string_view service_name,
      std::string_view account_name,
      base::span<const uint8_t> password) override;
'''
    yield FAKE_KEYCHAIN, FAKE_ADD, FAKE_ADD + '''
OSStatus FakeKeychainV2::AddGenericPasswordIfAbsent(
    std::string_view service_name,
    std::string_view account_name,
    base::span<const uint8_t> password) {
  if (find_generic_result_ == noErr) {
    return errSecDuplicateItem;
  }
  return AddGenericPassword(service_name, account_name, password);
}
'''

    # Never a new key over existing data.
    yield PASSWORD, '#include "crypto/apple/keychain_v2.h"\n', \
        '#include "crypto/apple/keychain_v2.h"\n' + HOOKS + '\n#include <atomic>\n'
    # The item's names from the outer app's Info.plist (DEV-1013).
    yield PASSWORD, '#include "base/apple/osstatus_logging.h"\n', \
        '#include "base/apple/osstatus_logging.h"\n' + BUNDLE_INCLUDES
    yield PASSWORD, KEYCHAIN_SERVICE_NAME, ARX_KEYCHAIN_NAMES + KEYCHAIN_SERVICE_NAME.replace(
        "service_name(kDefaultServiceName)",
        "service_name(\n      arx::SafeStorageKeyServiceName())")
    yield PASSWORD, KEYCHAIN_ACCOUNT_NAME, KEYCHAIN_ACCOUNT_NAME.replace(
        "account_name(kDefaultAccountName)",
        "account_name(\n      arx::SafeStorageKeyAccountName())")
    yield PASSWORD, "// Generates a random password and adds it to the Keychain.", '''// Arx (DEV-900): whether a missing item may become a new key. Set before
// threads start; asked on Keychain worker threads.
std::atomic<arx::SafeStorageKeyCreationPolicy> g_arx_key_creation_policy{
    nullptr};

// Generates a random password and adds it to the Keychain.'''
    yield PASSWORD, '''  OSStatus error = keychain.AddGenericPassword(service_name, account_name,
                                               base::as_byte_span(password));
''', '''  // Arx (DEV-900): create only. AddGenericPassword overwrites an item that
  // appeared since the lookup, which would replace a key data depends on.
  OSStatus error = keychain.AddGenericPasswordIfAbsent(
      service_name, account_name, base::as_byte_span(password));
  if (error == errSecDuplicateItem) {
    auto existing = keychain.FindGenericPassword(service_name, account_name);
    if (!existing.has_value()) {
      return base::unexpected(existing.error());
    }
    return std::string(base::as_string_view(*existing));
  }
'''
    yield PASSWORD, '''    uma_result = FindGenericPasswordResult::kPasswordNotFound;
    return AddRandomPasswordToKeychain(''', '''    uma_result = FindGenericPasswordResult::kPasswordNotFound;
    // Arx (DEV-900): a missing item stays an error while data encrypted with
    // the old key exists. A new key would make it unreadable for good.
    const arx::SafeStorageKeyCreationPolicy policy =
        g_arx_key_creation_policy.load();
    if (policy && !policy()) {
      LOG(ERROR) << "The Safe Storage key is missing; not replacing it";
      return base::unexpected(errSecItemNotFound);
    }
    return AddRandomPasswordToKeychain('''
    yield PASSWORD, '''  return base::unexpected(password.error());
}
''', '''  return base::unexpected(password.error());
}

void arx::SetSafeStorageKeyCreationPolicy(
    arx::SafeStorageKeyCreationPolicy policy) {
  g_arx_key_creation_policy.store(policy);
}
'''

    # Explain and retry instead of exiting.
    yield PROVIDER, '#include "components/os_crypt/common/os_crypt_switches.h"\n', \
        '#include "components/os_crypt/common/os_crypt_switches.h"\n' + HOOKS
    yield PROVIDER, "constexpr base::TimeDelta kKeychainRetryDelay = base::Seconds(1);\n", '''constexpr base::TimeDelta kKeychainRetryDelay = base::Seconds(1);

// Arx (DEV-900): the embedder's handler for a key it can't read. Set before
// threads start; called on the UI thread.
arx::SafeStorageUnavailableHandler g_arx_unavailable_handler = nullptr;
'''
    yield PROVIDER, '''  // Keep it waiting while the browser shows the error and exits.
  if (on_failure_) {
''', '''  // Keep it waiting while the browser shows the error and exits.
  // Arx (DEV-900): the embedder explains the error and reads the Keychain
  // again when asked; loading stays paused until then.
  if (g_arx_unavailable_handler) {
    g_arx_unavailable_handler(
        key.error(),
        base::BindOnce(&KeychainKeyProvider::GetKeyWithRetries,
                       weak_factory_.GetWeakPtr(), std::move(callback),
                       kMaxKeychainRetries));
    return;
  }
  if (on_failure_) {
'''
    yield PROVIDER, '''bool KeychainKeyProvider::UseForEncryption() {
  return true;
}

}  // namespace os_crypt_async
''', '''bool KeychainKeyProvider::UseForEncryption() {
  return true;
}

}  // namespace os_crypt_async

void arx::SetSafeStorageUnavailableHandler(
    arx::SafeStorageUnavailableHandler handler) {
  os_crypt_async::g_arx_unavailable_handler = handler;
}
'''
    # Chromium's own error, shown only without Arx's handler, named Helium.
    yield STRINGS, "          Helium couldn't access the macOS Keychain. To protect your data, the browser will close. If prompted by macOS, allow access to Helium's encryption key. Quit any other copies of Helium, then reopen it.\n", \
        "          Arx couldn't open its key in the macOS Keychain. To protect your saved passwords and cookies, Arx will close. If macOS asks, allow Arx to use its key, then open Arx again.\n"

    # A key change keeps protected preferences whose HMAC still holds.
    yield PREF_HASHES, '''      MaybeReportWeakHash(result, reporting_id);
      return value ? ValueState::CHANGED_ENCRYPTED
                   : ValueState::CLEARED_ENCRYPTED;
''', '''      MaybeReportWeakHash(result, reporting_id);
      // Arx (DEV-900): an encrypted hash made with an earlier Safe Storage
      // key fails here. The value's HMAC still decides, as it does for a
      // preference with no encrypted hash; a fresh one is stored after.
      // This trusts nothing new: removing the encrypted hash from the same
      // file already leaves the HMAC alone to decide (below), and
      // kDisallowLegacyPrefMacFallback still turns both off.
      if (stored_hmac.has_value() &&
          !base::FeatureList::IsEnabled(
              tracked::kDisallowLegacyPrefMacFallback) &&
          outer_->pref_hash_calculator_.ValidateHmac(path, value,
                                                     *stored_hmac) ==
              ValidationResult::VALID_HMAC) {
        return ValueState::UNCHANGED_VIA_HMAC_FALLBACK;
      }
      return value ? ValueState::CHANGED_ENCRYPTED
                   : ValueState::CLEARED_ENCRYPTED;
'''
    yield PREF_HASHES, '''      std::map<std::string, std::string> current_encrypted =
          split_encrypted_hashes;
''', '''      std::map<std::string, std::string> current_encrypted =
          split_encrypted_hashes;
      // Arx (DEV-900): keys whose HMAC held after their encrypted hash failed,
      // as for a single preference above.
      bool kept_by_hmac = false;
'''
    yield PREF_HASHES, '''            if (validation_result != ValidationResult::VALID_ENCRYPTED) {
              MaybeReportWeakHash(validation_result, reporting_id);
              invalid_keys->push_back(key);
            }
''', '''            if (validation_result != ValidationResult::VALID_ENCRYPTED) {
              MaybeReportWeakHash(validation_result, reporting_id);
              const auto hmac = split_hmacs.find(key);
              if (has_hmacs && hmac != split_hmacs.end() &&
                  !base::FeatureList::IsEnabled(
                      tracked::kDisallowLegacyPrefMacFallback) &&
                  outer_->pref_hash_calculator_.ValidateHmac(
                      keyed_path, &value, hmac->second) ==
                      ValidationResult::VALID_HMAC) {
                kept_by_hmac = true;
              } else {
                invalid_keys->push_back(key);
              }
            }
'''
    yield PREF_HASHES, '''      if (invalid_keys->empty()) {
        return ValueState::UNCHANGED_ENCRYPTED;
      }
''', '''      if (invalid_keys->empty()) {
        // A fallback stores fresh encrypted hashes with the current key.
        return kept_by_hmac ? ValueState::UNCHANGED_VIA_HMAC_FALLBACK
                            : ValueState::UNCHANGED_ENCRYPTED;
      }
'''

    # Decrypted data doesn't outlive its use in freed memory.
    yield ENCRYPTOR, '#include "crypto/random.h"\n', '#include "crypto/random.h"\n#include "crypto/secure_util.h"\n'
    yield ENCRYPTOR, "};\n\n}  // namespace\n\nEncryptor::Key::Key(", "};\n\n" + WIPE + "\n}  // namespace\n\nEncryptor::Key::Key("
    yield ENCRYPTOR, '''  *plaintext = std::string(decrypted->begin(), decrypted->end());
''', '''  plaintext->assign(decrypted->begin(), decrypted->end());
  ArxWipe(*decrypted);
'''
    yield ENCRYPTOR, '''          return std::string(plaintext->begin(), plaintext->end());
''', '''          std::string decrypted(plaintext->begin(), plaintext->end());
          ArxWipe(*plaintext);
          return decrypted;
'''
    yield ENCRYPTOR, '''  *plaintext = base::UTF8ToUTF16(utf8);
  return true;
''', '''  *plaintext = base::UTF8ToUTF16(utf8);
  ArxWipe(utf8);
  return true;
'''
    yield PASSWORD_STRING, "}\n\n}  // namespace\n\nPasswordString::PasswordString() :", \
        "}\n\n" + WIPE + "\n}  // namespace\n\nPasswordString::PasswordString() :"
    yield PASSWORD_STRING, '''  if (this != &other) {
    value_ = std::move(other.value_);
    other.clear();
  }
''', '''  if (this != &other) {
    clear();
    value_ = std::move(other.value_);
    other.clear();
  }
'''
    yield PASSWORD_STRING, '''PasswordString& PasswordString::operator=(const PasswordString&) = default;

PasswordString::~PasswordString() = default;
''', '''PasswordString& PasswordString::operator=(const PasswordString& other) {
  if (this != &other) {
    clear();
    value_ = other.value_;
  }
  return *this;
}

PasswordString::~PasswordString() {
  if (std::holds_alternative<std::u16string>(value_)) {
    ArxWipe(std::get<std::u16string>(value_));
  }
}
'''
    yield PASSWORD_STRING, '''  CHECK(std::holds_alternative<std::u16string>(value_));
  std::get<std::u16string>(value_).clear();
}
''', '''  CHECK(std::holds_alternative<std::u16string>(value_));
  ArxWipe(std::get<std::u16string>(value_));
}
'''


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
