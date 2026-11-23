"""Developer-only fixed CRX3 packages, signed with keys confined to an owned root.

The envelope follows pinned components/crx_file/{crx_creator.cc,crx3.proto}:
RSA_PKCS1_SHA256 over context+SignedData length+SignedData+ZIP. Chromium still
performs its independent sandboxed signature/manifest verification at install.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import zipfile

SENTINEL = b"Arx extension Settings disposable fixture v1\n"
FILES = ("v1.crx", "v2.crx", "other-key.crx", "corrupt.crx")
# Developer-mode folders. "unpacked-missing" is deliberately never created and
# "unpacked-unreadable" has no permissions until restore_permissions(root).
UNPACKED = "unpacked"
UNPACKED_INVALID = "unpacked-invalid"
UNPACKED_UNREADABLE = "unpacked-unreadable"
UNPACKED_MISSING = "unpacked-missing"
CONTEXT = b"CRX3 SignedData\x00"
WORKER = """chrome.runtime.onMessage.addListener((message,sender,reply)=>{
 if(message?.kind==='owned-window-open'&&sender.tab){
  chrome.windows.create({url:'window.html',type:'popup',width:360,height:480,focused:true},window=>{
   if(chrome.runtime.lastError||!window){reply({error:chrome.runtime.lastError?.message||'none'});return;}
   chrome.storage.session.set({extensionWindow:window.id,probeTab:sender.tab.id},
    ()=>reply({id:window.id,tabs:(window.tabs||[]).length}));
  });
  return true;
 }
 if(message?.kind==='owned-tab-open'&&sender.tab){
  chrome.tabs.create({url:'window.html'},tab=>{
   if(chrome.runtime.lastError||!tab){reply({error:chrome.runtime.lastError?.message||'none'});return;}
   chrome.storage.session.set({extensionWindow:tab.windowId,probeTab:sender.tab.id},
    ()=>reply({id:tab.windowId,tabs:tab.id>=0?1:0}));
  });
  return true;
 }
 if(message?.kind==='owned-window-typed'){
  chrome.storage.session.get({extensionWindow:-1,probeTab:-1},state=>{
   chrome.windows.remove(state.extensionWindow,()=>{
    const error=chrome.runtime.lastError?.message||'';
    chrome.tabs.sendMessage(state.probeTab,{kind:'owned-window-closed',typed:String(message.typed),error});
   });
  });
  return false;
 }
 if(message?.kind!=='owned-settings-probe'||!sender.tab)return false;
 chrome.storage.local.get({count:0},state=>{const count=state.count+1;
  chrome.storage.local.set({count},()=>reply({version:chrome.runtime.getManifest().version,count}));});
 return true;
});"""
CONTENT = """chrome.runtime.sendMessage({kind:'owned-settings-probe'},result=>{
 if(chrome.runtime.lastError||!result)return;
 document.title='ARX_EXTENSION_SETTINGS_WORKER:v='+result.version+':count='+result.count;
});"""


def _varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result) + bytes([value])


def _field(number, payload):
    return _varint(number * 8 + 2) + _varint(len(payload)) + payload


def _exclusive(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)


def _key(root, name):
    path = root / name
    _exclusive(path, b"")
    subprocess.run(["/usr/bin/openssl", "genrsa", "-out", str(path), "2048"],
                   check=True, capture_output=True)
    os.chmod(path, 0o600)
    public = subprocess.run(["/usr/bin/openssl", "pkey", "-in", str(path), "-pubout", "-outform", "DER"],
                            check=True, capture_output=True).stdout
    return path, public


# DEV-1240: the extension's own window (chrome.windows.create, as 1Password's pop-out). The probe
# page asks the worker to open it; the window reports the ID it's in, takes a typed key, and
# the worker then closes it with chrome.windows.remove and tells the probe page.
WINDOW_PROBE = """chrome.runtime.onMessage.addListener(message=>{
 if(message?.kind!=='owned-window-closed')return;
 document.title='ARX_EXTENSION_WINDOW_CLOSED:'+message.typed+(message.error?':'+message.error:'');
});
// DEV-1314: the tab probe page has the worker open the same page with chrome.tabs.create
// instead (1Password's welcome and sign-in page); the answer is the window its tab is in.
const kind=location.pathname==='/extension-tab-probe.html'?'owned-tab-open':'owned-window-open';
chrome.runtime.sendMessage({kind},result=>{
 if(chrome.runtime.lastError||!result||result.error){document.title='ARX_EXTENSION_WINDOW_FAILED';return;}
 document.title='ARX_EXTENSION_WINDOW_CREATED:'+result.id+':'+result.tabs;
});"""
WINDOW = "<!doctype html><meta charset=utf-8><title>Arx extension window</title><input id=field autofocus><script src=window.js></script>"
WINDOW_SCRIPT = """const field=document.getElementById('field');
field.focus();
chrome.tabs.getCurrent(tab=>chrome.windows.getCurrent(window=>{
 document.title=tab&&window&&tab.windowId===window.id?'ARX_EXTENSION_WINDOW_READY:'+window.id:'ARX_EXTENSION_WINDOW_MISMATCH';
}));
field.addEventListener('input',()=>{
 document.title='ARX_EXTENSION_WINDOW_TYPED:'+field.value;
 chrome.runtime.sendMessage({kind:'owned-window-typed',typed:field.value});
});"""
POPUP = "<!doctype html><meta charset=utf-8><title>Arx settings popup</title><p>Arx settings popup</p>"


def _archive(version):
    manifest = {
        "manifest_version": 3, "name": "Arx Settings Signed Fixture", "version": version,
        "permissions": ["storage"] + (["tabs", "nativeMessaging"] if version == "2.0" else []),
        "host_permissions": ["http://127.0.0.1/*"],
        "background": {"service_worker": "worker.js"},
        "content_scripts": [{"matches": ["http://127.0.0.1/extension-settings-probe.html*"], "js": ["content.js"], "run_at": "document_idle"},
                            {"matches": ["http://127.0.0.1/extension-window-probe.html*", "http://127.0.0.1/extension-tab-probe.html*"],
                             "js": ["window-probe.js"], "run_at": "document_idle"}],
        # A toolbar popup, which the site menu's tile opens (DEV-828). It asks for no permission.
        "action": {"default_popup": "popup.html"},
    }
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        files = {"manifest.json": json.dumps(manifest), "worker.js": WORKER, "content.js": CONTENT, "popup.html": POPUP,
                 "window-probe.js": WINDOW_PROBE, "window.html": WINDOW, "window.js": WINDOW_SCRIPT}
        for name, data in files.items():
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 30, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100600 << 16
            archive.writestr(info, data)
    return output.getvalue()


def _unpacked(directory, files):
    directory.mkdir(mode=0o700)
    for name, data in files.items():
        _exclusive(directory / name, data.encode())


def _unpacked_manifest(version):
    return json.dumps({
        "manifest_version": 3, "name": "Arx Settings Unpacked Fixture", "version": version,
        "permissions": ["storage"], "host_permissions": ["http://127.0.0.1/*"],
        "background": {"service_worker": "worker.js"},
        "content_scripts": [{"matches": ["http://127.0.0.1/extension-settings-probe.html*"], "js": ["content.js"], "run_at": "document_idle"}],
    })


def restore_permissions(root):
    """Lets cleanup remove the deliberately unreadable folder."""
    unreadable = Path(root) / UNPACKED_UNREADABLE
    if unreadable.is_dir() and not unreadable.is_symlink():
        unreadable.chmod(0o700)


def _sign(key, public, archive):
    signed = _field(1, hashlib.sha256(public).digest()[:16])
    payload = CONTEXT + struct.pack("<I", len(signed)) + signed + archive
    signature = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-sign", str(key)],
                               input=payload, check=True, capture_output=True).stdout
    proof = _field(1, public) + _field(2, signature)
    header = _field(2, proof) + _field(10000, signed)
    return b"Cr24" + struct.pack("<II", 3, len(header)) + header + archive


def prepare(root):
    root = Path(root)
    info = root.lstat()
    if (not root.name.startswith("app-extension-install-smoke-") or root.resolve() != root
            or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise ValueError("Extension Settings fixture requires a fresh owned root")
    if any(root.iterdir()):
        raise ValueError("Extension Settings fixture root must be empty")
    key, public = _key(root, "fixture-key.pem")
    other_key, other_public = _key(root, "other-key.pem")
    v1, v2 = _archive("1.0"), _archive("2.0")
    packages = {
        "v1.crx": _sign(key, public, v1),
        "v2.crx": _sign(key, public, v2),
        "other-key.crx": _sign(other_key, other_public, v2),
    }
    corrupt = bytearray(packages["v1.crx"])
    corrupt[-1] ^= 255
    packages["corrupt.crx"] = bytes(corrupt)
    for name, data in packages.items():
        _exclusive(root / name, data)
    _unpacked(root / UNPACKED, {"manifest.json": _unpacked_manifest("1.0"), "worker.js": WORKER, "content.js": CONTENT})
    _unpacked(root / UNPACKED_INVALID, {"manifest.json": '{"manifest_version": 3, "name": ', "worker.js": WORKER})
    _unpacked(root / UNPACKED_UNREADABLE, {"manifest.json": _unpacked_manifest("1.0")})
    (root / UNPACKED_UNREADABLE).chmod(0)
    _exclusive(root / ".arx-extension-settings-smoke", SENTINEL)
    (root / "profile").mkdir(mode=0o700)
    digest = hashlib.sha256(public).digest()[:16]
    extension_id = "".join(chr(97 + nibble) for byte in digest for nibble in (byte >> 4, byte & 15))
    return {"extensionID": extension_id,
            "packages": {name: hashlib.sha256(data).hexdigest() for name, data in packages.items()}}
