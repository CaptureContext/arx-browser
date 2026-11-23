#include "components/arx_page_media/page_media_agent.h"

#include <tuple>
#include <utility>

#include "base/functional/bind.h"
#include "content/public/renderer/render_frame.h"
#include "gin/arguments.h"
#include "gin/function_template.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_registry.h"
#include "third_party/blink/public/platform/scheduler/web_agent_group_scheduler.h"
#include "third_party/blink/public/platform/web_security_origin.h"
#include "third_party/blink/public/platform/web_string.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_local_frame.h"
#include "third_party/blink/public/web/web_script_source.h"
#include "v8/include/v8-context.h"
#include "v8/include/v8-function.h"
#include "v8/include/v8-isolate.h"
#include "v8/include/v8-local-handle.h"
#include "v8/include/v8-microtask-queue.h"
#include "v8/include/v8-primitive.h"

namespace arx::page_media {

PageMediaAgent::PageMediaAgent(content::RenderFrame* frame)
    : RenderFrameObserver(frame), RenderFrameObserverTracker<PageMediaAgent>(frame) {
  frame->GetAssociatedInterfaceRegistry()->AddInterface<mojom::PageMediaAgent>(
      base::BindRepeating(&PageMediaAgent::Bind, weak_factory_.GetWeakPtr()));
}

PageMediaAgent::~PageMediaAgent() = default;

void PageMediaAgent::Bind(mojo::PendingAssociatedReceiver<mojom::PageMediaAgent> receiver) {
  // The browser asks for the agent again for each navigation; the latest wins.
  receiver_.reset();
  receiver_.Bind(std::move(receiver));
}

void PageMediaAgent::Prepare(const std::string& origin, const std::string& script) {
  if (origin.empty() || script.empty() || script.size() > kMaximumScriptBytes) {
    prepared_.reset();
    return;
  }
  prepared_ = Prepared{origin, script};
}

void PageMediaAgent::DidCreateDocumentElement() {
  if (!context_.IsEmpty()) {
    // document.open() or document.write() can make a new document element in
    // the same document and context; the running script stays.
    blink::WebLocalFrame* frame = render_frame()->GetWebFrame();
    v8::Isolate* isolate = frame->GetAgentGroupScheduler()->Isolate();
    v8::HandleScope handles(isolate);
    if (frame->MainWorldScriptContext() == context_.Get(isolate)) return;
  }
  // A new document leaves the previous one's script behind.
  pending_script_.clear();
  context_.Reset();
  receive_.Reset();
  host_.reset();
  if (!prepared_) return;

  // The frame's initial empty document, or a document of another origin, keeps
  // the preparation for the document it was meant for.
  const blink::WebSecurityOrigin origin =
      render_frame()->GetWebFrame()->GetDocument().GetSecurityOrigin();
  if (origin.IsOpaque() || origin.ToString().Utf8() != prepared_->origin) return;

  pending_script_ = std::move(prepared_->script);
  prepared_.reset();
}

// static
void PageMediaAgent::RunAtDocumentStart(content::RenderFrame* frame) {
  PageMediaAgent* agent = frame ? Get(frame) : nullptr;
  if (!agent || agent->pending_script_.empty()) return;
  const std::string script = std::move(agent->pending_script_);
  agent->pending_script_.clear();
  agent->Run(script);
}

void PageMediaAgent::Run(const std::string& script) {
  blink::WebLocalFrame* frame = render_frame()->GetWebFrame();
  v8::Isolate* isolate = frame->GetAgentGroupScheduler()->Isolate();
  v8::HandleScope handles(isolate);
  v8::Local<v8::Context> context = frame->MainWorldScriptContext();
  if (context.IsEmpty()) return;
  v8::Context::Scope scope(context);

  v8::Local<v8::Value> factory =
      frame->ExecuteScriptAndReturnValue(blink::WebScriptSource(blink::WebString::FromUtf8(script)));
  if (factory.IsEmpty() || !factory->IsFunction()) return;

  // The script may send while it sets itself up, before it returns its receive function.
  context_.Reset(isolate, context);
  v8::Local<v8::Function> send;
  if (!gin::CreateFunctionTemplate(
           isolate, base::BindRepeating(&PageMediaAgent::SendFromPage, weak_factory_.GetWeakPtr()))
           ->GetFunction(context)
           .ToLocal(&send)) {
    context_.Reset();
    return;
  }
  v8::Local<v8::Value> arguments[] = {send};
  v8::Local<v8::Value> receive;
  if (!frame->ExecuteMethodAndReturnValue(factory.As<v8::Function>(), v8::Undefined(isolate), 1,
                                          arguments)
           .ToLocal(&receive) ||
      !receive->IsFunction()) {
    // A script that didn't set itself up sends nothing more.
    context_.Reset();
    host_.reset();
    return;
  }
  receive_.Reset(isolate, receive.As<v8::Function>());
}

// static
void PageMediaAgent::SendFromPage(base::WeakPtr<PageMediaAgent> agent, gin::Arguments* arguments) {
  std::string message;
  if (!agent || !arguments->GetNext(&message) || message.size() > kMaximumMessageBytes) return;
  agent->Send(std::move(message));
}

void PageMediaAgent::Send(std::string message) {
  if (context_.IsEmpty()) return;
  if (!host_) render_frame()->GetRemoteAssociatedInterfaces()->GetInterface(&host_);
  host_->Send(message);
}

void PageMediaAgent::Deliver(const std::string& message) {
  if (receive_.IsEmpty() || message.size() > kMaximumMessageBytes) return;
  blink::WebLocalFrame* frame = render_frame()->GetWebFrame();
  v8::Isolate* isolate = frame->GetAgentGroupScheduler()->Isolate();
  v8::HandleScope handles(isolate);
  v8::Local<v8::Context> context = frame->MainWorldScriptContext();
  // A message for a document that is gone, such as one the frame navigated
  // away from while the app answered, is dropped.
  if (context.IsEmpty() || context != context_.Get(isolate)) return;
  v8::Context::Scope scope(context);

  v8::Local<v8::String> text;
  if (!v8::String::NewFromUtf8(isolate, message.data(), v8::NewStringType::kNormal,
                               static_cast<int>(message.size()))
           .ToLocal(&text)) {
    return;
  }
  v8::Local<v8::Value> arguments[] = {text};
  std::ignore = frame->ExecuteMethodAndReturnValue(receive_.Get(isolate), v8::Undefined(isolate), 1,
                                                   arguments);
}

void PageMediaAgent::OnDestruct() {
  delete this;
}

}  // namespace arx::page_media
