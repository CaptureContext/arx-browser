"""Real owned protocol lookup/dialog fixture; final OS dispatch is suppressed.

No installed user scheme is touched. Registration is limited to one unique owned
bundle and cleanup unregisters exactly that bundle before removing runner storage.
"""
from dataclasses import dataclass
import os
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import uuid

LSREGISTER = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')
MARKER = 'ARX_EXTERNAL_CONSENT_MAIN_SUCCESS'
DIALOG_PHASES = ('cancel', 'accept', 'stale', 'noopener')
PHASES = (*DIALOG_PHASES, 'unregistered')
BLANK_HTTP_PHASES = ('blank-http-immediate', 'blank-http-delayed')
BLANK_DIALOG_PHASES = ('blank-cancel', 'blank-accept', 'blank-stale', 'blank-source-loss', 'blank-private')
BLANK_DENIED_PHASES = ('blank-after-http',)
BLANK_MARKERS = ('ARX_BLANK_CHILD_HTTP_SUCCESS', 'ARX_BLANK_CHILD_EXTERNAL_SUCCESS', 'ARX_BLANK_CHILD_PRIVATE_SUCCESS')


@dataclass
class Handler:
    root: Path
    bundle: Path
    identity: tuple
    environment: dict

    def cleanup(self):
        info = self.bundle.lstat()
        if (info.st_dev, info.st_ino) != self.identity or not stat.S_ISDIR(info.st_mode):
            raise ValueError('Owned protocol bundle changed before cleanup')
        subprocess.run([str(LSREGISTER), '-u', str(self.bundle)], check=True, capture_output=True, timeout=20)


def prepare(root, application):
    root = Path(root)
    application = Path(application).resolve()
    if not application.is_dir() or not (application / 'Contents/MacOS/Arx').is_file():
        raise ValueError('External consent fixture requires its exact built application')
    if root.resolve() != root or not root.name.startswith('app-smoke-'):
        raise ValueError('External consent fixture requires a canonical owned app-smoke root')
    for path in (root, root / 'profile'):
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700 or info.st_uid != os.getuid():
            raise ValueError('External consent fixture requires private owned directories')
    token = uuid.uuid4().hex
    marker = root / '.arx-external-consent'
    fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        stream.write(token)
        stream.flush()
        os.fsync(stream.fileno())
    config = root / 'external-consent-fixture.json'
    descriptor = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump({'version': 1, 'application': application.as_uri()}, stream)
        stream.flush()
        os.fsync(stream.fileno())
    scheme = 'arx-consent-' + token
    bundle = root / 'Arx Owned External Handler.app'
    contents = bundle / 'Contents'
    binary = contents / 'MacOS/OwnedHandler'
    binary.parent.mkdir(parents=True, mode=0o700)
    with (contents / 'Info.plist').open('xb') as stream:
        plistlib.dump({
            'CFBundleIdentifier': 'dev.capturecontext.arx.external-fixture.' + token,
            'CFBundleName': 'Arx Owned External Handler',
            'CFBundleDisplayName': 'Arx Owned External Handler',
            'CFBundleExecutable': 'OwnedHandler', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'LSBackgroundOnly': True,
            'CFBundleURLTypes': [{'CFBundleURLSchemes': [scheme], 'CFBundleTypeRole': 'Viewer'}],
        }, stream)
    # Even a broken OS interception could only start this inert owned executable.
    # The acceptance gate still fails unless its final boundary was intercepted.
    subprocess.run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(binary)],
                   input='int main(void) { return 73; }\n', text=True,
                   capture_output=True, check=True, timeout=30)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(bundle)],
                   capture_output=True, check=True, timeout=30)
    info = bundle.lstat()
    handler = Handler(root, bundle, (info.st_dev, info.st_ino), {'ARX_EXTERNAL_CONSENT_FIXTURE_ROOT': str(root)})
    try:
        subprocess.run([str(LSREGISTER), '-f', str(bundle)], check=True, capture_output=True, timeout=20)
        pages = root / 'external-consent'
        pages.mkdir(mode=0o700)
        for phase in PHASES:
            relation = 'noopener' if phase == 'noopener' else 'opener'
            target_scheme = scheme + '-unregistered' if phase == 'unregistered' else scheme
            (pages / (phase + '.html')).write_text(f'''<!doctype html><meta charset="utf-8">
<title>Arx External loading</title>
<style>a{{position:fixed;left:16px;top:16px;width:232px;height:42px;display:block}}</style>
<a href="{target_scheme}:{phase}" target="_blank" rel="{relation}">Open owned external handler</a>
<p>Disposable protocol fixture. Real Chrome consent; every OS launch is intercepted.</p>
<script>requestAnimationFrame(()=>requestAnimationFrame(()=>{{document.title='Arx External {phase}';}}));</script>''')
        for phase in (*BLANK_HTTP_PHASES, *BLANK_DIALOG_PHASES, *BLANK_DENIED_PHASES):
            delay = 250 if phase != 'blank-http-immediate' and phase != 'blank-cancel' else 0
            target = ("blank-http-destination.html?phase=" + phase
                      if phase in (*BLANK_HTTP_PHASES, *BLANK_DENIED_PHASES) else scheme + ':' + phase)
            target_expression = ('new URL(' + json.dumps(target) + ',location.href).href'
                                 if phase in (*BLANK_HTTP_PHASES, *BLANK_DENIED_PHASES) else json.dumps(target))
            (pages / (phase + '.html')).write_text(f'''<!doctype html><meta charset="utf-8">
<title>Arx Blank source loading</title>
<style>button{{position:fixed;left:16px;top:16px;width:232px;height:42px}}</style>
<button id="open">Open owned blank child</button>
<script>requestAnimationFrame(()=>requestAnimationFrame(()=>{{document.title='Arx Blank source {phase}';}}));
let child=null;document.getElementById('open').onclick=()=>{{
 sessionStorage.setItem('arx-blank-proof',{json.dumps(phase)});
 child=window.open('about:blank','_blank');if(!child)return;
 child.document.title='Arx Blank child {phase}|'+child.sessionStorage.getItem('arx-blank-proof');
 const target={target_expression};
 {'child.location=target;' if delay == 0 else 'setTimeout(()=>{child.location=target;},' + str(delay) + ');'}
}};
window.addEventListener('message',event=>{{if(event.source!==child||event.origin!==location.origin||
 event.data!=='arx-blank-http-ready'||{json.dumps(phase)}!=='blank-after-http')return;
 child.location={json.dumps(scheme + ':blank-after-http')};
 document.title='Arx Blank attempted blank-after-http';}});
</script>''')
        (pages / 'blank-http-destination.html').write_text('''<!doctype html><meta charset="utf-8">
<title>Arx Blank HTTP loading</title><script>
const phase=new URL(location.href).searchParams.get('phase');
if(['blank-http-immediate','blank-http-delayed','blank-after-http'].includes(phase)){
 document.title='Arx Blank HTTP '+phase+'|'+sessionStorage.getItem('arx-blank-proof');
 if(phase==='blank-after-http')window.opener?.postMessage('arx-blank-http-ready',location.origin);
}</script>''')
        (pages / 'destination.html').write_text('<!doctype html><title>Arx External destination</title>Source replaced')
    except BaseException:
        handler.cleanup()
        raise
    return handler


def verify(root, stdout, stderr):
    if any(marker not in stdout.splitlines() for marker in (MARKER, *BLANK_MARKERS)):
        raise ValueError('External consent fixture did not finish')
    receipt = (Path(root) / 'external-consent.receipt').read_text().splitlines()
    expected = ['armed', 'os-attempt:accept:intercepted']
    expected += [f'dialog:{phase}:visible' for phase in DIALOG_PHASES]
    expected += [f'child:{phase}:drained' for phase in PHASES]
    expected += ['os-attempt:blank-accept:intercepted']
    expected += [f'dialog:{phase}:visible' for phase in BLANK_DIALOG_PHASES]
    expected += [f'published:{phase}:requested' for phase in (*BLANK_DIALOG_PHASES, *BLANK_DENIED_PHASES)]
    expected += [f'published:{phase}:drained' for phase in BLANK_DIALOG_PHASES]
    if sorted(receipt) != sorted(expected) or 'ARX_EXTERNAL_CONSENT_FIXTURE_RECEIPT_FAILURE' in stderr:
        raise ValueError('External consent receipt is incomplete or contains unexpected activity')
