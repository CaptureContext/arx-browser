"""Owned loopback documents for semantic inspection and reference invalidation."""

import time
from urllib.parse import urlsplit

SAFE_TEXT = "ARX_INSPECTION_SAFE_TEXT"
SAFE_SHADOW_TEXT = "ARX_INSPECTION_SAFE_SHADOW_TEXT"
BUTTON_NAME = "Arx inspection button"
# Plain buttons are named by their own words (DEV-1008).
PLAIN_BUTTON_NAMES = ("Arx plain button", "Arx submit input")
EXCLUDED = (
    "ARX_PASSWORD_SECRET", "ARX_FORM_VALUE_SECRET", "ARX_SHADOW_PASSWORD_SECRET",
    "ARX_FORMER_PASSWORD_SECRET",
    "ARX_FRAME_SECRET", "ARX_CROSS_ORIGIN_SECRET", "ARX_CANVAS_FALLBACK_SECRET",
    "ARX_EDITABLE_SECRET", "ARX_GENERATED_SECRET", "ARX_BUTTON_NESTED_SECRET",
)

# Trusted reference clicks on the two named controls drive the mutations.
# Both finish synchronously in the click task and update the title.
DOCUMENTS = {
    "/inspection/main": """<!doctype html><meta charset="utf-8">
<title>Arx inspection ready</title>
<style>
body{margin:16px;padding-top:60px;font:16px sans-serif}
.control{position:fixed;top:16px;width:160px;height:36px}
#replace{left:16px}#reinsert{left:200px}
input[type=password]{-webkit-text-security:none}
#generated::before{content:'ARX_GENERATED_SECRET'}
</style>
<button class="control" id="replace" aria-label="Replace content">Replace content</button>
<button class="control" id="reinsert" aria-label="Remove and reinsert">Remove and reinsert</button>
<p>ARX_INSPECTION_SAFE_TEXT</p>
<button id="target" aria-label="Arx inspection button">Safe button contents</button>
<button>Arx <b>plain</b> button</button>
<input type="submit" value="Arx submit input">
<button>Arx nested <input value="ARX_BUTTON_NESTED_SECRET"></button>
<input id="password" type="password" value="ARX_PASSWORD_SECRET">
<input id="former-password" type="password" value="ARX_FORMER_PASSWORD_SECRET">
<input aria-label="Ordinary input" value="ARX_FORM_VALUE_SECRET">
<button aria-labelledby="password">Computed password label must be omitted</button>
<button aria-labelledby="former-password">Computed former-password label must be omitted</button>
<div id="shadow"></div><div id="safe-shadow"></div><div id="generated"></div>
<div contenteditable>ARX_EDITABLE_SECRET</div>
<canvas width="20" height="20"><button>ARX_CANVAS_FALLBACK_SECRET</button></canvas>
<iframe src="/inspection/frame"></iframe>
<iframe sandbox srcdoc="<p>ARX_CROSS_ORIGIN_SECRET</p>"></iframe>
<script>
document.getElementById('former-password').type='text';
const shadow=document.getElementById('shadow').attachShadow({mode:'closed'});
shadow.innerHTML='<input type="password" style="-webkit-text-security:none" value="ARX_SHADOW_PASSWORD_SECRET">';
const safeShadow=document.getElementById('safe-shadow').attachShadow({mode:'closed'});
safeShadow.innerHTML='<p>ARX_INSPECTION_SAFE_SHADOW_TEXT</p>';
document.getElementById('replace').onclick=(event)=>{
 if(!event.isTrusted){document.title='Arx inspection untrusted input';return;}
 const old=document.getElementById('target');
 const replacement=old.cloneNode(true);
 replacement.setAttribute('aria-label','Arx replacement button');
 old.replaceWith(replacement);
 document.title='Arx inspection replaced';
};
document.getElementById('reinsert').onclick=(event)=>{
 if(!event.isTrusted){document.title='Arx inspection untrusted input';return;}
 const node=document.getElementById('target');
 const parent=node.parentNode;
 node.remove();parent.appendChild(node);
 document.title='Arx inspection reinserted';
};
</script>""",
    "/inspection/frame": """<!doctype html><meta charset="utf-8">
<title>Arx excluded frame</title><p>ARX_FRAME_SECRET</p>""",
    # ABI25 windows: far more projected nodes than one 512-node window.
    "/inspection/large": "<!doctype html><meta charset=\"utf-8\"><title>Arx inspection large</title>"
        + "".join(f"<p>ARX_LARGE_ITEM_{index}</p>" for index in range(1500)),
    # ABI25 frames: one same-origin and one cross-site (localhost) frame.
    "/inspection/frames": """<!doctype html><meta charset="utf-8">
<title>Arx inspection frames</title>
<p>ARX_FRAMES_MAIN_TEXT</p>
<iframe id="same" src="/inspection/child"></iframe>
<iframe id="cross" src="http://localhost:PORT/inspection/child"></iframe>""",
    "/inspection/child": """<!doctype html><meta charset="utf-8">
<title>Arx inspection child</title><p>ARX_FRAME_CHILD_TEXT</p>
<button aria-label="Arx frame button">Frame button</button>""",
    # ABI25 opt-in values: ordinary values appear, password and payment never do.
    "/inspection/values": """<!doctype html><meta charset="utf-8">
<title>Arx inspection values</title>
<input aria-label="Ordinary field" value="ARX_ORDINARY_VALUE">
<input aria-label="Agreement" type="checkbox" checked>
<input type="password" value="ARX_PASSWORD_SECRET">
<input aria-label="Card number" autocomplete="cc-number" value="ARX_CARD_SECRET">
<input type="hidden" value="ARX_HIDDEN_SECRET">
<button aria-label="Arx values button">Values button</button>""",
    # ABI27 pointer input. Hovering #hover changes nothing in the DOM, so its
    # snapshot stays current; #mutate's title change is a DOM mutation.
    "/inspection/pointer": """<!doctype html><meta charset="utf-8">
<title>Arx pointer ready</title>
<style>
body{margin:0;font:14px sans-serif}
button,.box{position:absolute;width:120px;height:40px;margin:0}
#hover{left:10px;top:10px}#mutate{left:150px;top:10px}#double{left:290px;top:10px}
#covered{left:430px;top:10px}
#cover{position:absolute;left:420px;top:0;width:150px;height:60px;background:rgba(0,0,0,.02)}
#slider{left:10px;top:80px;width:300px;height:30px;background:#ddd}
#source{left:10px;top:150px;background:#cfc}
#zone{left:300px;top:140px;width:200px;height:80px;background:#ccf}
</style>
<button id="hover" aria-label="Arx hover target">Hover</button>
<button id="mutate" aria-label="Arx hover mutation">Mutate</button>
<button id="double" aria-label="Arx double click">Double</button>
<button id="covered" aria-label="Arx covered button">Covered</button><div id="cover"></div>
<div id="slider" class="box" tabindex="0" aria-label="Arx slider"></div>
<div id="source" class="box" tabindex="0" draggable="true" aria-label="Arx drag source">Drag</div>
<div id="zone" class="box" tabindex="0" aria-label="Arx drop zone">Drop</div>
<script>
let hovered=false,start=null,moves=0;
const $=(id)=>document.getElementById(id);
$('hover').addEventListener('mouseover',(e)=>{hovered=e.isTrusted&&$('hover').matches(':hover');});
$('mutate').addEventListener('mouseover',(e)=>{
 document.title=e.isTrusted&&hovered&&$('mutate').matches(':hover')?'Arx pointer hovered':'Arx pointer bad hover';
});
$('double').addEventListener('dblclick',(e)=>{
 document.title=e.isTrusted&&navigator.userActivation.isActive?'Arx pointer double clicked':'Arx pointer bad click';
});
$('covered').addEventListener('click',()=>{document.title='Arx pointer covered clicked';});
$('cover').addEventListener('click',(e)=>{document.title='Arx pointer point clicked '+(e.isTrusted?'trusted':'untrusted');});
$('slider').addEventListener('mousedown',(e)=>{start=e.clientX;moves=0;});
addEventListener('mousemove',(e)=>{if(start!==null&&e.buttons===1)moves++;});
addEventListener('mouseup',(e)=>{
 if(start===null)return;
 document.title='Arx pointer slid '+(e.clientX-start>=100&&moves>=4?'far':'short');start=null;
});
$('source').addEventListener('dragstart',(e)=>{e.dataTransfer.setData('text/plain','ARX_DRAG_DATA');});
$('zone').addEventListener('dragover',(e)=>e.preventDefault());
$('zone').addEventListener('drop',(e)=>{e.preventDefault();document.title='Arx pointer dropped '+e.dataTransfer.getData('text/plain');});
</script>""",
    # ABI28 keyboard input. Effects show as #log text or opt-in form values.
    "/inspection/keyboard": """<!doctype html><meta charset="utf-8">
<title>Arx keyboard ready</title>
<style>body{margin:8px;font:14px sans-serif}input,textarea,div[contenteditable]{display:block;margin:4px 0;width:300px}
div[contenteditable]{min-height:20px;border:1px solid #888}</style>
<input id="field" aria-label="Arx type field" value="AB">
<textarea id="area" aria-label="Arx type area"></textarea>
<div id="editor" contenteditable="true" aria-label="Arx type editor"></div>
<input id="redirect" aria-label="Arx redirect field">
<input id="secret" type="password" aria-label="Arx secret field">
<input id="before" aria-label="Arx before field">
<input id="after" aria-label="Arx after field">
<button id="probe" aria-label="Arx focus probe">Probe</button>
<button id="opener" aria-label="Arx dialog opener">Opener</button>
<dialog id="dialog"><button id="inside" aria-label="Arx dialog button">Inside</button></dialog>
<p id="log">ARX_KEYBOARD_START</p>
<script>
const $=(id)=>document.getElementById(id);
const log=(text)=>{$('log').textContent+=' '+text;};
$('editor').addEventListener('input',()=>log('ARX_EDITOR_'+$('editor').textContent.replace(/\\s/g,'_')));
$('redirect').addEventListener('keydown',()=>$('secret').focus());
$('secret').addEventListener('input',()=>log('ARX_SECRET_LEAKED'));
// Focus events only fire while the page is focused; the probe reads focus directly.
$('probe').addEventListener('mouseover',()=>log('ARX_ACTIVE_'+(document.activeElement||{}).id));
$('field').addEventListener('keydown',(e)=>{
 if(e.isTrusted&&e.ctrlKey&&e.key==='k')log('ARX_SHORTCUT_SEEN');
});
$('opener').addEventListener('click',()=>$('dialog').showModal());
$('dialog').addEventListener('close',()=>log('ARX_DIALOG_CLOSED'));
</script>""",
    # ABI29 explicit form state. Events show as #log text.
    "/inspection/state": """<!doctype html><meta charset="utf-8">
<title>Arx state ready</title>
<input id="agree" type="checkbox" aria-label="Arx state agree">
<input id="red" type="radio" name="color" value="red" checked aria-label="Arx state red">
<input id="blue" type="radio" name="color" value="blue" aria-label="Arx state blue">
<select id="colors" multiple size="4" aria-label="Arx state colors">
<option value="red">Red</option><option value="green">Green</option>
<option value="blue">Blue</option><option value="gray" disabled>Gray</option>
</select>
<p id="log">ARX_STATE_START</p>
<script>
const $=(id)=>document.getElementById(id);
const log=(text)=>{$('log').textContent+=' '+text;};
$('agree').addEventListener('input',()=>log('ARX_INPUT_agree'));
$('agree').addEventListener('change',()=>log('ARX_CHANGE_agree_'+$('agree').checked));
$('blue').addEventListener('change',()=>log('ARX_CHANGE_blue'));
$('colors').addEventListener('change',()=>log('ARX_SELECT_'+[...$('colors').selectedOptions].map(o=>o.value).join('_')));
</script>""",
    # ABI30 file choosers. The page reports chosen names and sizes, or a cancel.
    "/inspection/upload": """<!doctype html><meta charset="utf-8">
<title>Arx upload ready</title>
<input id="file" type="file" multiple aria-label="Arx upload file" style="display:block;width:300px;height:40px">
<p id="log">ARX_UPLOAD_START</p>
<script>
const file=document.getElementById('file');
const log=(text)=>{document.getElementById('log').textContent+=' '+text;};
file.addEventListener('change',()=>log('ARX_FILES_'+[...file.files].map(f=>f.name+':'+f.size).join('_')));
file.addEventListener('cancel',()=>log('ARX_FILE_CANCEL'));
</script>""",
    # DEV-1309: choosers a person opens, which get the macOS open panel, and a
    # drop target. Each control sits at a fixed point the smoke clicks with a
    # window event, not an automation action: a plain input, a detached input
    # opened from script, the same in a cross-site frame, and a drop zone.
    "/inspection/person-upload": """<!doctype html><meta charset="utf-8">
<title>Arx person upload ready</title>
<style>body{margin:0}.at{position:absolute;left:20px;width:300px;height:40px;margin:0}</style>
<input id="plain" class="at" style="top:20px" type="file" aria-label="Arx plain file">
<button id="script" class="at" style="top:80px" aria-label="Arx script file">Choose</button>
<iframe id="cross" class="at" style="top:140px;height:60px;border:0"
 src="http://localhost:PORT/inspection/person-upload-frame"></iframe>
<div id="drop" class="at" style="top:240px;height:100px;background:#ddd" aria-label="Arx drop zone">Drop</div>
<p id="log" style="position:absolute;top:360px;left:20px">ARX_PERSON_UPLOAD_START</p>
<script>
const $=(id)=>document.getElementById(id);
const log=(text)=>{$('log').textContent+=' '+text;};
const watch=(input,name)=>{
  input.addEventListener('change',()=>log('ARX_PICKED_'+name+'_'+[...input.files].map(f=>f.name).join('_')));
  input.addEventListener('cancel',()=>log('ARX_CANCEL_'+name));
};
watch($('plain'),'plain');
$('script').onclick=()=>{const input=document.createElement('input');input.type='file';watch(input,'script');input.click();};
addEventListener('message',(event)=>{if(typeof event.data==='string'&&event.data.startsWith('ARX_'))log(event.data);});
$('drop').addEventListener('dragover',(event)=>event.preventDefault());
$('drop').addEventListener('drop',(event)=>{event.preventDefault();
  log('ARX_DROPPED_'+[...event.dataTransfer.files].map(f=>f.name+':'+f.size).join('_'));});
</script>""",
    "/inspection/person-upload-frame": """<!doctype html><meta charset="utf-8">
<title>Arx person upload frame</title>
<style>body{margin:0}button{position:absolute;left:0;top:0;width:300px;height:40px;margin:0}</style>
<button id="frame" aria-label="Arx frame file">Choose in frame</button>
<script>
document.getElementById('frame').onclick=()=>{
  const input=document.createElement('input');input.type='file';
  input.addEventListener('change',()=>parent.postMessage('ARX_PICKED_frame_'+[...input.files].map(f=>f.name).join('_'),'*'));
  input.addEventListener('cancel',()=>parent.postMessage('ARX_CANCEL_frame','*'));
  input.click();
};
</script>""",
    # ABI31 dialogs. Outcomes show as #log text once the dialog is gone.
    "/inspection/dialogs": """<!doctype html><meta charset="utf-8">
<title>Arx dialogs ready</title>
<style>button{display:block;margin:4px;width:200px;height:28px}</style>
<button id="alert" aria-label="Arx alert">Alert</button>
<button id="confirm" aria-label="Arx confirm">Confirm</button>
<button id="prompt" aria-label="Arx prompt">Prompt</button>
<button id="guard" aria-label="Arx guard">Guard</button>
<button id="geo" aria-label="Arx location">Location</button>
<button id="screens" aria-label="Arx screens">Screens</button>
<p id="log">ARX_DIALOGS_START</p>
<script>
const $=(id)=>document.getElementById(id);
const log=(text)=>{$('log').textContent+=' '+text;};
$('alert').onclick=()=>{alert('ARX_ALERT_TEXT');log('ARX_ALERT_DONE');};
$('confirm').onclick=()=>log('ARX_CONFIRM_'+confirm('ARX_CONFIRM_TEXT'));
$('prompt').onclick=()=>log('ARX_PROMPT_'+prompt('ARX_PROMPT_TEXT','ARX_DEFAULT'));
$('guard').onclick=()=>{onbeforeunload=(e)=>{e.preventDefault();e.returnValue='';};log('ARX_GUARDED');};
$('geo').onclick=()=>navigator.geolocation.getCurrentPosition(()=>log('ARX_GEO_OK'),(e)=>log('ARX_GEO_ERROR_'+e.code));
$('screens').onclick=()=>getScreenDetails().then((d)=>log('ARX_SCREENS_'+d.screens.length),(e)=>log('ARX_SCREENS_ERROR'));
</script>""",
    "/inspection/replacement": """<!doctype html><meta charset="utf-8">
<title>Arx inspection replacement</title><p>ARX_INSPECTION_REPLACEMENT_TEXT</p>
<button aria-label="Replacement document button">Replacement document</button>""",
}


def pdf_document(text="ARX_PDF_TEXT"):
    """A one-page PDF whose only text is `text`, with an exact cross-reference table."""
    stream = f"BT /F1 24 Tf 72 700 Td ({text}) Tj ET".encode("ascii")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length " + str(len(stream)).encode("ascii") + b" >>\nstream\n" + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    output = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(output))
        output += f"{number} 0 obj\n".encode("ascii") + body + b"\nendobj\n"
    table = len(output)
    output += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode("ascii")
    for offset in offsets:
        output += f"{offset:010d} 00000 n \n".encode("ascii")
    output += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{table}\n%%EOF\n".encode("ascii")
    return bytes(output)


# ABI26 PDF source: a PDF document the tab shows.
BINARY_DOCUMENTS = {"/inspection/document.pdf": ("application/pdf", pdf_document())}


# ABI48 document type (DEV-819): the same PDF, its second half sent only after a pause, so
# the page commits as a PDF and is still loading while the smoke reads its type.
SLOW_PDF_PATH = "/inspection/slow.pdf"
SLOW_PDF_PAUSE = 4.0


def serve_slow_pdf(handler):
    data = pdf_document()
    half = len(data) // 2
    handler.send_response(200)
    handler.send_header("Content-Type", "application/pdf")
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", "private, max-age=60")
    handler.end_headers()
    handler.wfile.write(data[:half])
    handler.wfile.flush()
    time.sleep(SLOW_PDF_PAUSE)
    handler.wfile.write(data[half:])
    return True


def serve(handler):
    if urlsplit(handler.path).path == SLOW_PDF_PATH:
        return serve_slow_pdf(handler)
    binary = BINARY_DOCUMENTS.get(urlsplit(handler.path).path)
    if binary is not None:
        content_type, data = binary
        handler.send_response(200)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(data)))
        handler.send_header("Cache-Control", "private, max-age=60")
        handler.end_headers()
        handler.wfile.write(data)
        return True
    body = DOCUMENTS.get(urlsplit(handler.path).path)
    if body is None:
        return False
    # The cross-site frame names this server's own port; tests without a server keep the template.
    server = getattr(handler, "server", None)
    if server is not None:
        body = body.replace("PORT", str(server.server_address[1]))
    encoded = body.encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(encoded)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(encoded)
    return True
