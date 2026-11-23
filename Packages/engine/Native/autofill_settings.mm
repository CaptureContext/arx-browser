#include "chrome/browser/arx/autofill_settings.h"

#include "chrome/browser/arx/autofill_bridge.h"

#import <AppKit/AppKit.h>

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/uuid.h"
#include "base/values.h"
#include "chrome/browser/autofill/personal_data_manager_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/autofill/core/browser/country_type.h"
#include "components/autofill/core/browser/data_manager/addresses/address_data_manager.h"
#include "components/autofill/core/browser/data_manager/payments/payments_data_manager.h"
#include "components/autofill/core/browser/data_manager/personal_data_manager.h"
#include "components/autofill/core/browser/data_manager/personal_data_manager_observer.h"
#include "components/autofill/core/browser/data_model/addresses/autofill_profile.h"
#include "components/autofill/core/browser/data_model/addresses/autofill_structured_address_component.h"
#include "components/autofill/core/browser/data_model/payments/credit_card.h"
#include "components/autofill/core/browser/field_types.h"
#include "content/public/browser/browser_thread.h"

namespace arx {
namespace {
using autofill::AutofillProfile;
using autofill::CreditCard;
using autofill::FieldType;
using autofill::PersonalDataManager;

constexpr size_t kMaximumJsonBytes = 16 * 1024;
constexpr size_t kMaximumFieldBytes = 512;
constexpr size_t kMaximumRequests = 8;
constexpr base::TimeDelta kLoadWait = base::Seconds(10);
// A change that alters nothing (an unchanged edit, a duplicate) never notifies;
// after this long the current listing is the answer.
constexpr base::TimeDelta kChangeWait = base::Seconds(2);

// The address fields Settings shows and edits, by JSON key.
constexpr std::pair<const char*, FieldType> kAddressFields[] = {
    {"name", autofill::NAME_FULL},
    {"organization", autofill::COMPANY_NAME},
    {"street", autofill::ADDRESS_HOME_STREET_ADDRESS},
    {"city", autofill::ADDRESS_HOME_CITY},
    {"state", autofill::ADDRESS_HOME_STATE},
    {"zip", autofill::ADDRESS_HOME_ZIP},
    {"country", autofill::ADDRESS_HOME_COUNTRY},
    {"phone", autofill::PHONE_HOME_WHOLE_NUMBER},
    {"email", autofill::EMAIL_ADDRESS},
};

class Waiter;

struct Registry {
  AutofillDataReply reply = nullptr;
  std::map<uint64_t, std::unique_ptr<Waiter>> pending;
};

Registry& State() {
  static base::NoDestructor<Registry> registry;
  return *registry;
}

void Reply(uint64_t request, ArxAutofillDataStatus status, std::string json = std::string()) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
      [](uint64_t request, ArxAutofillDataStatus status, std::string json) {
        auto reply = State().reply;
        if (!reply) return;
        reply(request, status,
              json.empty() ? nullptr : reinterpret_cast<const uint8_t*>(json.data()), json.size());
      }, request, status, std::move(json)));
}

std::string Write(base::Value value) {
  std::string json;
  base::JSONWriter::Write(value, &json);
  return json;
}

std::string Field(const std::u16string& value) {
  std::string text = base::UTF16ToUTF8(value);
  return text.size() <= kMaximumFieldBytes ? text : std::string();
}

std::string Listing(const PersonalDataManager& data) {
  base::ListValue addresses;
  for (const AutofillProfile* profile : data.address_data_manager().GetProfilesForSettings()) {
    if (profile->record_type() != AutofillProfile::RecordType::kLocalOrSyncable) continue;
    base::DictValue item;
    item.Set("id", profile->guid());
    for (const auto& [key, type] : kAddressFields) item.Set(key, Field(profile->GetRawInfo(type)));
    addresses.Append(std::move(item));
  }
  base::ListValue cards;
  for (const CreditCard* card : data.payments_data_manager().GetLocalCreditCards()) {
    base::DictValue item;
    item.Set("id", card->guid());
    item.Set("name", Field(card->GetRawInfo(autofill::CREDIT_CARD_NAME_FULL)));
    item.Set("network", card->network());
    // Never more of the number than Chrome shows on a card's face in a list.
    item.Set("lastFour", Field(card->LastFourDigits()));
    item.Set("month", card->expiration_month());
    item.Set("year", card->expiration_year());
    item.Set("nickname", Field(card->nickname()));
    cards.Append(std::move(item));
  }
  base::DictValue body;
  body.Set("addresses", std::move(addresses));
  body.Set("cards", std::move(cards));
  return Write(base::Value(std::move(body)));
}

// Waits for the profile's data to load, or for a change to land, then lists.
class Waiter final : public autofill::PersonalDataManagerObserver {
 public:
  Waiter(uint64_t request, PersonalDataManager* data, bool changed)
      : request_(request), data_(data) {
    observation_.Observe(data);
    timer_.Start(FROM_HERE, changed ? kChangeWait : kLoadWait,
                 base::BindOnce(&Waiter::TimedOut, base::Unretained(this)));
  }

  // A change that altered nothing never notifies: once nothing is pending,
  // the current listing is the answer. A write still on its way is waited
  // for, up to kLoadWait in all.
  void TimedOut() {
    const bool pending = data_->address_data_manager().IsAwaitingPendingAddressChanges() ||
        data_->payments_data_manager().HasPendingPaymentQueries();
    if (data_->IsDataLoaded() && !pending) return Finish(ARX_AUTOFILL_DATA_OK);
    if (base::TimeTicks::Now() - started_ < kLoadWait) {
      timer_.Start(FROM_HERE, kChangeWait, base::BindOnce(&Waiter::TimedOut, base::Unretained(this)));
      return;
    }
    Finish(ARX_AUTOFILL_DATA_UNAVAILABLE);
  }

  bool done() const { return done_; }

  void OnPersonalDataChanged() override {
    if (data_->IsDataLoaded()) Finish(ARX_AUTOFILL_DATA_OK);
  }

  void Finish(ArxAutofillDataStatus status) {
    if (done_) return;
    done_ = true;
    timer_.Stop();
    observation_.Reset();
    Reply(request_, status, status == ARX_AUTOFILL_DATA_OK ? Listing(*data_) : std::string());
    // Owned by the registry; leave after this task.
    // The owner's address only, never followed: this can run twice, and a pointer bound into
    // the task would dangle once the first run erases the owner.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
        [](uint64_t request, uintptr_t owner) {
          auto& pending = State().pending;
          auto found = pending.find(request);
          if (found != pending.end() && reinterpret_cast<uintptr_t>(found->second.get()) == owner)
            pending.erase(found);
        }, request_, reinterpret_cast<uintptr_t>(this)));
  }

 private:
  const uint64_t request_;
  const base::TimeTicks started_ = base::TimeTicks::Now();
  bool done_ = false;
  raw_ptr<PersonalDataManager> data_;
  base::ScopedObservation<PersonalDataManager, autofill::PersonalDataManagerObserver> observation_{this};
  base::OneShotTimer timer_;
};

// The profile's data, or a reply saying why there is none.
PersonalDataManager* Begin(Profile* profile, uint64_t request) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& state = State();
  if (!request || state.pending.contains(request)) {
    Reply(request, ARX_AUTOFILL_DATA_INVALID);
    return nullptr;
  }
  if (!profile || profile->IsOffTheRecord() || !state.reply) {
    Reply(request, ARX_AUTOFILL_DATA_UNAVAILABLE);
    return nullptr;
  }
  if (state.pending.size() >= kMaximumRequests) {
    Reply(request, ARX_AUTOFILL_DATA_BUSY);
    return nullptr;
  }
  // The app's switches, even for a profile with no page open since they changed.
  ApplyAutofillProducts(profile->GetPrefs());
  auto* data = autofill::PersonalDataManagerFactory::GetForBrowserContext(profile);
  if (!data) Reply(request, ARX_AUTOFILL_DATA_UNAVAILABLE);
  return data;
}

// Lists now when loaded and nothing is pending, otherwise after the next change.
void ListWhenSettled(PersonalDataManager* data, uint64_t request, bool changed) {
  if (!changed && data->IsDataLoaded()) return Reply(request, ARX_AUTOFILL_DATA_OK, Listing(*data));
  State().pending[request] = std::make_unique<Waiter>(request, data, changed);
}

std::optional<base::DictValue> Body(const char* json) {
  const size_t length = json ? strnlen(json, kMaximumJsonBytes + 1) : 0;
  if (!length || length > kMaximumJsonBytes) return std::nullopt;
  auto value = base::JSONReader::Read(std::string_view(json, length), base::JSON_PARSE_RFC);
  if (!value || !value->is_dict()) return std::nullopt;
  return std::move(*value).TakeDict();
}

std::optional<std::u16string> Text(const base::DictValue& body, const char* key) {
  const std::string* value = body.FindString(key);
  if (!value) return std::u16string();
  if (value->size() > kMaximumFieldBytes || !base::IsStringUTF8(*value)) return std::nullopt;
  return base::UTF8ToUTF16(base::TrimWhitespaceASCII(*value, base::TRIM_ALL));
}
}  // namespace

void StartAutofillSettings(AutofillDataReply reply) {
  State().reply = reply;
}

void StopAutofillSettings() {
  auto& state = State();
  for (auto& [request, waiter] : state.pending)
    if (!waiter->done()) Reply(request, ARX_AUTOFILL_DATA_CANCELLED);
  state.pending.clear();
  state.reply = nullptr;
}

void ListAutofillData(Profile* profile, uint64_t request) {
  if (auto* data = Begin(profile, request)) ListWhenSettled(data, request, false);
}

void SaveAutofillAddress(Profile* profile, uint64_t request, const char* json) {
  auto* data = Begin(profile, request);
  if (!data) return;
  auto body = Body(json);
  if (!body || !data->IsDataLoaded()) return Reply(request, ARX_AUTOFILL_DATA_INVALID);
  std::map<FieldType, std::u16string> values;
  bool any = false;
  for (const auto& [key, type] : kAddressFields) {
    auto value = Text(*body, key);
    if (!value) return Reply(request, ARX_AUTOFILL_DATA_INVALID);
    any |= !value->empty() && type != autofill::ADDRESS_HOME_COUNTRY;
    values[type] = std::move(*value);
  }
  if (!any) return Reply(request, ARX_AUTOFILL_DATA_INVALID);
  const std::string country = base::UTF16ToUTF8(values[autofill::ADDRESS_HOME_COUNTRY]);
  if (!country.empty() && (country.size() != 2 || !base::IsStringASCII(country)))
    return Reply(request, ARX_AUTOFILL_DATA_INVALID);

  auto& addresses = data->address_data_manager();
  // Chromium drops address writes while address filling is off.
  if (!addresses.IsAutofillProfileEnabled()) return Reply(request, ARX_AUTOFILL_DATA_DISABLED);
  const std::string* id = body->FindString("id");
  AutofillProfile profile_data(autofill::AddressCountryCode(base::ToUpperASCII(country)));
  if (id) {
    const AutofillProfile* existing = addresses.GetProfileByGUID(*id);
    if (!existing || existing->record_type() != AutofillProfile::RecordType::kLocalOrSyncable)
      return Reply(request, ARX_AUTOFILL_DATA_NOT_FOUND);
    profile_data = *existing;
  }
  for (const auto& [type, value] : values) {
    if (type == autofill::ADDRESS_HOME_COUNTRY) {
      profile_data.SetRawInfoWithVerificationStatus(type, base::ToUpperASCII(value),
                                                    autofill::VerificationStatus::kUserVerified);
      continue;
    }
    profile_data.SetRawInfoWithVerificationStatus(type, value,
                                                  autofill::VerificationStatus::kUserVerified);
  }
  profile_data.FinalizeAfterImport();
  if (id) addresses.UpdateProfile(profile_data);
  else addresses.AddProfile(profile_data);
  ListWhenSettled(data, request, true);
}

void SaveAutofillCard(Profile* profile, uint64_t request, const char* json, void* number_field) {
  // Read the lent field now, on the main thread, and keep the digits only here.
  std::u16string number;
  if (number_field) {
    NSTextField* field = (__bridge NSTextField*)number_field;
    if ([field isKindOfClass:[NSTextField class]]) {
      for (char16_t c : base::SysNSStringToUTF16([field stringValue]))
        if (c >= u'0' && c <= u'9') number.push_back(c);
    }
  }
  auto* data = Begin(profile, request);
  if (!data) return;
  auto body = Body(json);
  if (!body || !data->IsDataLoaded() || number.size() > 19)
    return Reply(request, ARX_AUTOFILL_DATA_INVALID);
  auto name = Text(*body, "name");
  auto nickname = Text(*body, "nickname");
  const int month = body->FindInt("month").value_or(0);
  const int year = body->FindInt("year").value_or(0);
  if (!name || !nickname || month < 1 || month > 12 || year < 2000 || year > 2200)
    return Reply(request, ARX_AUTOFILL_DATA_INVALID);

  auto& payments = data->payments_data_manager();
  // Chromium drops card writes while card filling is off.
  if (!payments.IsAutofillPaymentMethodsEnabled()) return Reply(request, ARX_AUTOFILL_DATA_DISABLED);
  const std::string* id = body->FindString("id");
  CreditCard card(base::Uuid::GenerateRandomV4().AsLowercaseString());
  if (id) {
    const CreditCard* existing = payments.GetCreditCardByGUID(*id);
    if (!existing || existing->record_type() != CreditCard::RecordType::kLocalCard)
      return Reply(request, ARX_AUTOFILL_DATA_NOT_FOUND);
    card = *existing;
  } else if (number.empty()) {
    return Reply(request, ARX_AUTOFILL_DATA_INVALID);
  }
  // An edit with an empty number keeps the saved one.
  if (!number.empty()) card.SetNumber(number);
  card.SetRawInfo(autofill::CREDIT_CARD_NAME_FULL, *name);
  card.SetExpirationMonth(month);
  card.SetExpirationYear(year);
  card.SetNickname(*nickname);
  // Entered by the user in Settings, as Chrome's own Settings marks it: a later
  // checkout form never rewrites it silently.
  card.set_is_user_confirmed(true);
  if (!card.HasValidCardNumber()) return Reply(request, ARX_AUTOFILL_DATA_INVALID);
  if (id) payments.UpdateCreditCard(card);
  else payments.AddCreditCard(card);
  ListWhenSettled(data, request, true);
}

void RemoveAutofillData(Profile* profile, uint64_t request, const char* id) {
  auto* data = Begin(profile, request);
  if (!data) return;
  const size_t length = id ? strnlen(id, 64 + 1) : 0;
  if (!length || length > 64 || !data->IsDataLoaded()) return Reply(request, ARX_AUTOFILL_DATA_INVALID);
  const std::string guid(id, length);
  if (const auto* address = data->address_data_manager().GetProfileByGUID(guid);
      address && address->record_type() == AutofillProfile::RecordType::kLocalOrSyncable) {
    data->address_data_manager().RemoveProfile(guid);
  } else if (const auto* card = data->payments_data_manager().GetCreditCardByGUID(guid);
             card && card->record_type() == CreditCard::RecordType::kLocalCard) {
    data->payments_data_manager().RemoveByGUID(guid);
  } else {
    return Reply(request, ARX_AUTOFILL_DATA_NOT_FOUND);
  }
  ListWhenSettled(data, request, true);
}

void CancelAutofillData(uint64_t request) {
  auto& pending = State().pending;
  auto found = pending.find(request);
  if (found == pending.end()) return;
  const bool done = found->second->done();
  pending.erase(found);
  if (!done) Reply(request, ARX_AUTOFILL_DATA_CANCELLED);
}
}  // namespace arx
