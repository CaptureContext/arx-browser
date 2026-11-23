#include "components/arx_inspection/script_runner.h"

#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/strings/string_util.h"
#include "base/task/single_thread_task_runner.h"
#include "base/values.h"
#include "content/public/renderer/render_frame.h"
#include "third_party/blink/public/common/arx_developer_world_id.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_registry.h"
#include "third_party/blink/public/platform/scheduler/web_agent_group_scheduler.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_local_frame.h"
#include "third_party/blink/public/web/web_script_source.h"
#include "url/gurl.h"
#include "v8/include/v8-context.h"
#include "v8/include/v8-exception.h"
#include "v8/include/v8-isolate.h"
#include "v8/include/v8-local-handle.h"
#include "v8/include/v8-message.h"
#include "v8/include/v8-primitive.h"
#include "v8/include/v8-script.h"

namespace arx::developer {
namespace {
// Lines the wrapper adds before the agent's first line.
constexpr int kPrefixLines = 4;

std::string Bounded(const std::string& text, size_t bytes) {
  std::string output;
  base::TruncateUTF8ToByteSize(text, bytes, &output);
  return output;
}

std::string Write(const base::DictValue& value) {
  std::string json;
  base::JSONWriter::Write(value, &json);
  return json;
}

std::string Utf8(v8::Isolate* isolate, v8::Local<v8::Value> value) {
  if (value.IsEmpty()) return {};
  v8::String::Utf8Value text(isolate, value);
  return *text ? std::string(*text, text.length()) : std::string();
}

// The agent's script compiles on its own, so a syntax error names the
// agent's own line rather than failing the whole request without a reason.
bool SyntaxError(blink::WebLocalFrame* frame, int32_t world, const std::string& wrapped,
                 std::string* result) {
  v8::Isolate* isolate = frame->GetAgentGroupScheduler()->Isolate();
  v8::HandleScope handles(isolate);
  v8::Local<v8::Context> context = frame->GetScriptContextFromWorldId(isolate, world);
  if (context.IsEmpty()) return false;
  v8::Context::Scope scope(context);
  v8::TryCatch try_catch(isolate);
  v8::Local<v8::String> code;
  if (!v8::String::NewFromUtf8(isolate, wrapped.data(), v8::NewStringType::kNormal,
                               static_cast<int>(wrapped.size())).ToLocal(&code)) return false;
  if (!v8::Script::Compile(context, code).IsEmpty()) return false;
  base::DictValue error;
  error.Set("name", "SyntaxError");
  const auto message = try_catch.Message();
  error.Set("message", Bounded(message.IsEmpty() ? std::string() : Utf8(isolate, message->Get()),
                               kMaximumMessageBytes));
  if (!message.IsEmpty()) {
    const int line = message->GetLineNumber(context).FromMaybe(0) - kPrefixLines;
    if (line > 0) error.Set("line", line);
  }
  *result = Write(error);
  return true;
}

void Finished(uint32_t maximum_bytes, mojom::ScriptRunner::EvaluateCallback callback,
              std::optional<base::Value> value, base::TimeTicks) {
  const auto* dict = value ? value->GetIfDict() : nullptr;
  const auto* type = dict ? dict->FindString("t") : nullptr;
  if (!type) {
    std::move(callback).Run(mojom::ScriptStatus::kFailed, std::string());
    return;
  }
  base::DictValue result;
  if (*type == "json") {
    const auto* text = dict->FindString("s");
    if (!text) {
      std::move(callback).Run(mojom::ScriptStatus::kFailed, std::string());
      return;
    }
    if (text->size() > maximum_bytes) {
      std::move(callback).Run(mojom::ScriptStatus::kLimit, std::string());
      return;
    }
    result.Set("type", "json");
    result.Set("value", *text);
  } else if (*type == "undefined") {
    result.Set("type", "undefined");
  } else if (*type == "unserializable") {
    const auto* description = dict->FindString("d");
    result.Set("type", "unserializable");
    result.Set("description", Bounded(description ? *description : std::string(), 512));
  } else if (*type == "exception") {
    const auto* name = dict->FindString("n");
    const auto* message = dict->FindString("m");
    result.Set("name", Bounded(name ? *name : std::string("Error"), 128));
    result.Set("message", Bounded(message ? *message : std::string(), kMaximumMessageBytes));
    std::move(callback).Run(mojom::ScriptStatus::kException, Write(result));
    return;
  } else {
    std::move(callback).Run(mojom::ScriptStatus::kFailed, std::string());
    return;
  }
  std::move(callback).Run(mojom::ScriptStatus::kOK, Write(result));
}
}  // namespace

std::string WrapDeveloperScript(const std::string& source) {
  // kPrefixLines lines precede the agent's source.
  return "(async () => {\n"
         "let __arxValue;\n"
         "try {\n"
         "__arxValue = await (async () => {\n" +
         source +
         "\n})();\n"
         "} catch (error) {\n"
         "  let name = 'Error', message = '';\n"
         "  try {\n"
         "    name = String((error && error.name) || 'Error');\n"
         "    message = String(error && error.message !== undefined ? error.message : error);\n"
         "  } catch (_) {}\n"
         "  return { t: 'exception', n: name.slice(0, 128), m: message.slice(0, 2048) };\n"
         "}\n"
         "if (__arxValue === undefined) return { t: 'undefined' };\n"
         "try {\n"
         "  const text = JSON.stringify(__arxValue);\n"
         "  if (text === undefined) return { t: 'unserializable', d: typeof __arxValue };\n"
         "  return { t: 'json', s: text };\n"
         "} catch (error) {\n"
         "  return { t: 'unserializable', d: String((error && error.message) || error).slice(0, 512) };\n"
         "}\n"
         "})()";
}

ScriptRunner::ScriptRunner(content::RenderFrame* frame) : RenderFrameObserver(frame) {
  frame->GetAssociatedInterfaceRegistry()->AddInterface<mojom::ScriptRunner>(
      base::BindRepeating(&ScriptRunner::Bind, weak_.GetWeakPtr()));
}

ScriptRunner::~ScriptRunner() = default;

void ScriptRunner::Bind(mojo::PendingAssociatedReceiver<mojom::ScriptRunner> receiver) {
  receivers_.Add(this, std::move(receiver));
}

void ScriptRunner::Evaluate(const std::string& source, uint32_t maximum_bytes,
                            EvaluateCallback callback) {
  Run(blink::kArxDeveloperWorldId, source, maximum_bytes, std::move(callback));
}

void ScriptRunner::EvaluateTranslation(const std::string& source, uint32_t maximum_bytes,
                                       EvaluateTranslationCallback callback) {
  Run(blink::kArxTranslationWorldId, source, maximum_bytes, std::move(callback));
}

void ScriptRunner::Run(int32_t world, const std::string& source, uint32_t maximum_bytes,
                       EvaluateCallback callback) {
  if (source.empty() || source.size() > kMaximumSourceBytes || !base::IsStringUTF8(source) ||
      maximum_bytes == 0 || maximum_bytes > kMaximumResultBytes) {
    std::move(callback).Run(mojom::ScriptStatus::kInvalid, std::string());
    return;
  }
  auto* frame = render_frame() ? render_frame()->GetWebFrame() : nullptr;
  if (!frame || frame->GetDocument().IsNull() ||
      !GURL(frame->GetDocument().Url()).SchemeIsHTTPOrHTTPS()) {
    std::move(callback).Run(mojom::ScriptStatus::kUnavailable, std::string());
    return;
  }
  const std::string wrapped = WrapDeveloperScript(source);
  std::string syntax;
  if (SyntaxError(frame, world, wrapped, &syntax)) {
    std::move(callback).Run(mojom::ScriptStatus::kSyntax, syntax);
    return;
  }
  const blink::WebScriptSource script(blink::WebString::FromUtf8(wrapped));
  frame->RequestExecuteScript(
      world, base::span_from_ref(script),
      blink::mojom::UserActivationOption::kDoNotActivate,
      blink::mojom::EvaluationTiming::kSynchronous,
      blink::mojom::LoadEventBlockingOption::kDoNotBlock,
      base::BindOnce(&Finished, maximum_bytes, std::move(callback)),
      blink::BackForwardCacheAware::kAllow,
      blink::mojom::WantResultOption::kWantResult,
      blink::mojom::PromiseResultOption::kAwait, blink::WebString());
}

void ScriptRunner::OnDestruct() {
  receivers_.Clear();
  weak_.InvalidateWeakPtrs();
  base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, this);
}
}  // namespace arx::developer
