#include <cassert>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <functional>
#include <tuple>
#include "extension_action_policy.h"
struct NSEvent {int type=1;bool isARepeat=false;void* window=nullptr;double timestamp=10;int key=1;};
constexpr int NSEventTypeKeyDown=1;
struct NSView {void* window;};
struct {struct {double systemUptime=10;} processInfo;} NSProcessInfo;
namespace gfx {struct NativeEvent {NSEvent* value=nullptr;NSEvent* Get()const{return value;}};}
namespace blink {struct WebInputEvent {enum class Type {kRawKeyDown,kKeyUp};enum {kIsComposing=1,kIsAutoRepeat=2};};}
namespace base {
namespace apple {struct OwnedNSEvent {NSEvent* value;explicit OwnedNSEvent(NSEvent* event):value(event){}};}
template<class T>T* Unretained(T* value){return value;}
template<class F,class...A>auto BindOnce(F f,A...args){return [=]()mutable{std::invoke(f,std::move(args)...);};}
}
namespace input {struct NativeWebKeyboardEvent {
 gfx::NativeEvent os_event;bool skip_if_unhandled=false;blink::WebInputEvent::Type type=blink::WebInputEvent::Type::kRawKeyDown;int key=1,modifiers=0;
 explicit NativeWebKeyboardEvent(base::apple::OwnedNSEvent native):os_event{native.value},key(native.value?native.value->key:1){}
 blink::WebInputEvent::Type GetType()const{return type;}int GetModifiers()const{return modifiers;}
};}
namespace content {struct WebContents;struct WeakDocument;struct Frame {bool active=true,live=true;Frame* GetOutermostMainFrame(){return this;}WeakDocument GetWeakDocumentPtr();bool IsActive(){return active;}bool IsRenderFrameLive(){return live;}};struct WeakDocument {Frame* frame;Frame* AsRenderFrameHostIfValid()const{return frame;}};inline WeakDocument Frame::GetWeakDocumentPtr(){return {this};}}
struct Profile {bool private_=false,escalated=false;static Profile* FromBrowserContext(Profile* p){return p;}bool IsOffTheRecord(){return private_;}};
namespace extensions {
struct Extension {std::string id_="a";int version=3,location_=1;const std::string& id()const{return id_;}int manifest_version()const{return version;}int location()const{return location_;}};
struct Command {static bool IsActionRelatedCommand(const std::string& c){return c=="_execute_action";}};
struct Manifest {static bool IsComponentLocation(int l){return l==2;}};
struct ExtensionPrefs {Profile* p;static ExtensionPrefs* Get(Profile* p){static ExtensionPrefs f;f.p=p;return &f;}bool DidExtensionEscalatePermissions(const std::string&){return p->escalated;}};
struct Registry {const Extension* enabled=nullptr;Registry& enabled_extensions(){return *this;}const Extension* GetByID(const std::string&){return enabled;}};
}
namespace content {struct WebContents {explicit WebContents(Profile* p):profile(p){}Profile* profile;Frame primary;Frame* active=&primary;bool visible=true;Frame* GetPrimaryMainFrame(){return active;}Profile* GetBrowserContext(){return profile;}Frame* GetFocusedFrame(){return active;}
 NSView view{reinterpret_cast<void*>(1)};struct NativeView {NSView* view;NSView* GetNativeNSView(){return view;}};NativeView GetNativeView(){return {&view};}
};}
namespace ui {struct Accelerator {int key=1;bool operator!=(const Accelerator& other)const{return key!=other.key;}};
Accelerator GetAcceleratorFromNativeWebKeyboardEvent(const input::NativeWebKeyboardEvent& event){return {event.key};}
}
template<class T>struct scoped_refptr {T* ptr;scoped_refptr(T* p):ptr(p){}T* get()const{return ptr;}T* operator->()const{return ptr;}};
bool capability=true;bool ExtensionViewsAvailable(){return capability;}
// DEV-956: a private source runs only extensions allowed in private windows; this one isn't.
bool ExtensionRunsInContext(const extensions::Extension&,Profile* p){return !p->IsOffTheRecord();}bool Visible(content::WebContents* s){return s->visible;}
struct Commands {
 std::string id="a",command="named";int key=1,dispatched=0;
 bool Match(ui::Accelerator a,std::string* actual_id,std::string* actual_command){*actual_id=id;*actual_command=command;return key==a.key;}
 bool Dispatch(ui::Accelerator a,const std::string& expected_id,const std::string& expected_command){assert(a.key==key&&id==expected_id&&command==expected_command);++dispatched;return true;}
};
struct Owner {
 Owner(content::WebContents* source,extensions::Registry* registry,Commands* commands):source_(source),registry_(registry),commands_(commands){}
 struct Runner {void Run(std::function<void()> work){work();}}run_;
 struct Factory {Owner* owner;Owner* GetWeakPtr(){return owner;}}weak_factory_{this};
 arx::ExtensionShortcutReplayGuard shortcut_replay_;gfx::NativeEvent shortcut_event_;
 // HANDLE_SHORTCUT
 struct Current {uint64_t generation=1;uint64_t Run()const{return generation;}} current_;
 struct Choice {scoped_refptr<const extensions::Extension> extension;content::WeakDocument document;std::string command;ui::Accelerator accelerator;uint64_t generation;double host_epoch;bool native_key;};
 content::WebContents* source_;extensions::Registry* registry_;Commands* commands_;double shortcut_epoch_=1;bool focused=true,menu_key=true;int actions=0;
 bool KeyboardFocused(){return focused;}bool MenuHostIsKey(){return menu_key;}
 void RunAction(Choice){++actions;}
 // SOURCE_CURRENT
 // ALLOWED
 // RUN_COMMAND
};
int main(){
 Profile profile;content::WebContents source{&profile};extensions::Extension extension,replacement;extensions::Registry registry{&extension};Commands commands;Owner owner{&source,&registry,&commands};
 Owner::Choice original{{&extension},{source.active},"named",{1},1,1,true};
 bool handled=false;owner.RunCommand(original,&handled);assert(handled&&commands.dispatched==1);
 for(int reason=0;reason<12;++reason){
  auto choice=original;handled=false;owner.focused=reason!=0;source.visible=reason!=1;owner.current_.generation=reason==2?0:1;registry.enabled=reason==3?nullptr:reason==4?&replacement:&extension;profile.private_=reason==5;profile.escalated=reason==6;capability=reason!=7;source.primary.live=reason!=8;choice.document.frame=reason==9?nullptr:&source.primary;owner.shortcut_epoch_=reason==10?2:1;owner.current_.generation=reason==11?2:owner.current_.generation;
  owner.RunCommand(choice,&handled);assert(!handled&&commands.dispatched==1&&owner.actions==0);
 }
 owner.focused=source.visible=source.primary.live=capability=true;owner.current_.generation=1;owner.shortcut_epoch_=1;registry.enabled=&extension;profile.private_=profile.escalated=false;
 commands.id="foreign-profile-extension";owner.RunCommand(original,&handled);assert(!handled&&commands.dispatched==1);
 commands.id="a";commands.command="changed-binding";owner.RunCommand(original,&handled);assert(!handled&&commands.dispatched==1);
 commands.command="named";commands.key=2;owner.RunCommand(original,&handled);assert(!handled&&commands.dispatched==1);
 commands.key=1;owner.RunCommand(original,&handled);assert(handled&&commands.dispatched==2);
 auto action=original;action.command=commands.command="_execute_action";handled=false;owner.RunCommand(action,&handled);assert(handled&&owner.actions==1&&commands.dispatched==2);
 commands.command="named";
 auto menu_choice=original;menu_choice.native_key=false;owner.focused=false;handled=false;
 owner.RunCommand(menu_choice,&handled);assert(handled&&commands.dispatched==3); // Explicit menu has source/window authority.
 owner.menu_key=false;handled=false;owner.RunCommand(menu_choice,&handled);assert(!handled&&commands.dispatched==3);
 owner.menu_key=owner.focused=true;
 // Real production native-event admission; absent/synthetic events cannot use it.
 commands.command="named";commands.dispatched=0;owner.actions=0;owner.current_.generation=1;
 auto physical=NSEvent{1,false,source.view.window,10,1};
 input::NativeWebKeyboardEvent event{base::apple::OwnedNSEvent(&physical)};
 assert(owner.HandleShortcut(event));assert(commands.dispatched==1);
 assert(!owner.HandleShortcut(event));
 auto reconstructed=physical;input::NativeWebKeyboardEvent replay{base::apple::OwnedNSEvent(&reconstructed)};
 assert(!owner.HandleShortcut(replay));assert(commands.dispatched==1);
 for(int reason=0;reason<9;++reason){
  NSEvent native{1,false,source.view.window,11.0+reason,1};NSProcessInfo.processInfo.systemUptime=native.timestamp;
  input::NativeWebKeyboardEvent bad{base::apple::OwnedNSEvent(&native)};
  if(reason==0)bad.os_event={};
  if(reason==1)bad.skip_if_unhandled=true;
  if(reason==2)bad.type=blink::WebInputEvent::Type::kKeyUp;
  if(reason==3)native.type=2;
  if(reason==4)native.isARepeat=true;
  if(reason==5)native.window=reinterpret_cast<void*>(2);
  if(reason==6)bad.modifiers=blink::WebInputEvent::kIsComposing;
  if(reason==7)bad.modifiers=blink::WebInputEvent::kIsAutoRepeat;
  if(reason==8)bad.key=2; // web payload contradicts the actual native event
  assert(!owner.HandleShortcut(bad));assert(commands.dispatched==1);
 }
 owner.shortcut_epoch_=30;NSProcessInfo.processInfo.systemUptime=30;
 NSEvent before_rehost{1,false,source.view.window,29,1};
 input::NativeWebKeyboardEvent stale{base::apple::OwnedNSEvent(&before_rehost)};assert(!owner.HandleShortcut(stale));
 NSEvent after_rehost{1,false,source.view.window,30,1};
 input::NativeWebKeyboardEvent fresh{base::apple::OwnedNSEvent(&after_rehost)};assert(owner.HandleShortcut(fresh));assert(commands.dispatched==2);

}
