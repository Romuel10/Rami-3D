#!/usr/bin/env python3
"""Verify real signing keys, secret handling and publication guards without network writes.

Requires Python 3, Bash and a JDK (keytool), as provided by the Android workflow.
The gh executable and all GitHub mutations are mocked.
"""
import ast
import base64
from contextlib import redirect_stdout, redirect_stderr
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import re
import shutil
import textwrap

project=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('rami_signing',project/'scripts/setup-signing.py')
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
checks=0

def check(value,message):
    global checks
    checks += 1
    if not value: raise AssertionError(message)

workflow_text=(project/'.github/workflows/android.yml').read_text()
# CI itself validates YAML; inspect the literal shell/Python programs using only
# the standard library, so this regression does not need a package install.
steps=[]
for match in re.finditer(r'^      - name: ([^\n]+)\n(.*?)(?=^      - name: |\Z)', workflow_text, re.M | re.S):
    name, block = match.groups()
    step={'name':name}
    for key in ['id','if']:
        value=re.search(r'^        '+key+r': ([^\n]+)',block,re.M)
        if value: step[key]=value.group(1)
    program=re.search(r'^        run: \|\n((?:          [^\n]*\n|\n)+)',block,re.M)
    if program: step['run']=textwrap.dedent(program.group(1))
    step['env']=dict(re.findall(r'^          ([A-Z][A-Z0-9_]+): ([^\n]+)',block,re.M))
    steps.append(step)
for step in steps:
    if 'run' in step:
        result=subprocess.run(['bash','-n'],input=step['run'],text=True,capture_output=True)
        check(result.returncode==0,'Bash syntax: '+step['name'])
        lines=step['run'].splitlines()
        for i,line in enumerate(lines):
            if "python3 - <<'" in line:
                marker=line.split("<<'",1)[1].split("'",1)[0]
                code='\n'.join(lines[i+1:lines.index(marker,i+1)])
                ast.parse(code)
                check(True,'Python syntax '+step['name'])
signing=next(s for s in steps if s.get('id')=='signing')
check(len(signing['env'])==4,'All four signing secrets are protected')
for expression in signing['env'].values():
    check("github.ref == 'refs/heads/main'" in expression and "github.event_name != 'pull_request'" in expression,'Protected secret context')
guard=next(s for s in steps if s['name']=='Explain test-only APK availability')
publish=next(s for s in steps if s['name']=='Publish version if it does not already exist')
check("publishable != 'true'" in guard['if'],'Test-only explanation appears without durable signing')
check('::error::' not in guard['run'],'Missing signing is not reported as an APK build error')
check("publishable == 'true'" in publish['if'],'Publishing still requires stable signing')
upload=next(s for s in steps if s['name']=='Upload downloadable build artifacts')
check(upload.get('id')=='apk_artifact' and guard['env'].get('RAMI_APK_ARTIFACT_URL')=='${{ steps.apk_artifact.outputs.artifact-url }}','Summary receives the actual uploaded artifact URL')
with tempfile.TemporaryDirectory(prefix='rami-artifact-summary-') as raw:
    summary=Path(raw)/'summary.md'
    environment=os.environ.copy()
    environment.update({'GITHUB_STEP_SUMMARY':str(summary),'GITHUB_SERVER_URL':'https://github.com','GITHUB_REPOSITORY':'Romuel10/Rami-3D','GITHUB_RUN_ID':'123','RAMI_APK_ARTIFACT_URL':'https://github.com/Romuel10/Rami-3D/actions/runs/123/artifacts/456'})
    explained=subprocess.run(['bash','-euo','pipefail','-c',guard['run']],env=environment,capture_output=True,text=True)
    check(explained.returncode==0,'Successful test build stays successful without release signing')
    report=summary.read_text()
    check('https://github.com/Romuel10/Rami-3D/actions/runs/123' in report and 'rami-3d.apk' in report,'Summary links the correct build and APK file')
    check('https://github.com/Romuel10/Rami-3D/actions/runs/123/artifacts/456' in report,'Summary offers a direct link to the real APK artifact')
    check('ZIP ne s’installe pas' in report and 'autre clé' in report,'Summary explains extraction and update-signature limitation')

with tempfile.TemporaryDirectory(prefix='rami-signing-tests-') as raw:
    temporary=Path(raw); key=temporary/'private/key.jks'
    password=secrets.token_urlsafe(20)
    os.environ['RAMI_TEST_PASSWORD']=password
    gh_calls=[]
    real_run=module.run_private
    def mock_gh(command,**kwargs):
        if command[0]=='gh': gh_calls.append((command,kwargs.get('private_input'))); return
        return real_run(command,**kwargs)
    module.run_private=mock_gh
    real_which=module.shutil.which
    module.shutil.which=lambda name: '/mock/gh' if name=='gh' else real_which(name)
    args=['--repository','Romuel10/Rami-3D','--keystore',str(key),'--password-env','RAMI_TEST_PASSWORD']
    captured=io.StringIO()
    with redirect_stdout(captured):
        result=module.main(args+['--create'])
    check(result==0 and key.is_file(),'Creates valid signing key')
    check(key.stat().st_mode & 0o777==0o600,'Private file mode')
    uploaded={command[3]:stdin for command,stdin in gh_calls if command[1:3]==['secret','set']}
    check(set(uploaded)==set(module.SECRET_NAMES),'Four secrets sent via stdin')
    check(base64.b64decode(uploaded['ANDROID_KEYSTORE_BASE64'])==key.read_bytes(),'Exact keystore bytes uploaded')
    check(uploaded['ANDROID_KEYSTORE_PASSWORD']==password and uploaded['ANDROID_KEY_PASSWORD']==password,'Password mapping')
    check(all(password not in ' '.join(command) for command,_ in gh_calls),'No passwords in command arguments')
    check(password not in captured.getvalue() and uploaded['ANDROID_KEYSTORE_BASE64'] not in captured.getvalue(),'No secret output')
    before=hashlib.sha256(key.read_bytes()).hexdigest()
    gh_calls.clear()
    with redirect_stdout(io.StringIO()): check(module.main(args)==0,'Reuses existing key')
    check(before==hashlib.sha256(key.read_bytes()).hexdigest(),'Reused key not regenerated')
    with redirect_stderr(io.StringIO()):
        try: module.main(args+['--create'])
        except SystemExit as e: check(e.code==2,'Refuses overwrite')
        else: raise AssertionError('Overwritten key')
    check(before==hashlib.sha256(key.read_bytes()).hexdigest(),'Overwrite failure preserved key')
    gh_calls.clear()
    with redirect_stdout(io.StringIO()): check(module.main(args+['--prepare-only'])==0,'Prepare-only validates')
    check(not gh_calls,'Prepare-only makes no GitHub requests')
    os.environ['RAMI_TEST_PASSWORD']=secrets.token_urlsafe(20)
    gh_calls.clear()
    try: module.main(args)
    except RuntimeError: check(not any(command[1:3]==['secret','set'] for command,_ in gh_calls),'Wrong password cannot change secrets')
    else: raise AssertionError('Wrong password accepted')
    os.environ.pop('RAMI_TEST_PASSWORD')

    body=signing['run'].split("python3 - <<'PY_SIGNING'\n",1)[1].rsplit('\nPY_SIGNING',1)[0]
    for kind in ['durable','empty','partial','bad-base64']:
        directory=temporary/kind; directory.mkdir()
        environment=os.environ.copy()
        for name in module.SECRET_NAMES: environment.pop(name,None)
        environment.update({'RUNNER_TEMP':str(directory),'XDG_CONFIG_HOME':str(directory/'config'),'JAVA_HOME':os.environ.get('JAVA_HOME',str(directory/'java')),'RAMI_ANDROID_SDK':os.environ.get('RAMI_ANDROID_SDK',str(directory/'sdk')),'GITHUB_OUTPUT':str(directory/'output'),'GITHUB_ENV':str(directory/'env'),'GITHUB_STEP_SUMMARY':str(directory/'summary')})
        if kind in ['durable','bad-base64']:
            environment.update(dict(zip(module.SECRET_NAMES,[base64.b64encode(key.read_bytes()).decode(),password,'ramisalon',password])))
        if kind=='partial': environment['ANDROID_KEYSTORE_PASSWORD']=password
        if kind=='bad-base64': environment['ANDROID_KEYSTORE_BASE64']='not-base64!'
        done=subprocess.run([sys.executable,'-c',body],env=environment,text=True,capture_output=True)
        check(password not in done.stdout+done.stderr,kind+' does not print password')
        if kind in ['durable','empty']:
            check(done.returncode==0,kind+' config succeeds')
            check(('publishable=true' if kind=='durable' else 'publishable=false') in (directory/'output').read_text(),kind+' publication flag')
            check((directory/'rami-signing.keystore').stat().st_mode & 0o777==0o600,kind+' private key file mode')
            if kind=='durable': check((directory/'rami-signing.keystore').read_bytes()==key.read_bytes(),'CI retains configured key exactly')
        else:
            check(done.returncode!=0,kind+' config rejected')
module.shutil.which=real_which
print('PASS:',checks,'signing configuration and setup checks; no GitHub writes performed')
