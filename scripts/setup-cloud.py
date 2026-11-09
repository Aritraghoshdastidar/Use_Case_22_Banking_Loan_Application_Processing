#!/usr/bin/env python3
"""Sets up a CloudHub 2.0 deployment of the loan project in YOUR OWN Anypoint and hosted-service accounts.

Reads one settings file outside the repository (default ~/.anypoint-cloud.env, see cloud/anypoint-cloud.env.example).
Nothing secret is ever written into the repository except values encrypted with your own key
(src/main/resources/secure-cloudhub.yaml, which git ignores anyway).

    python scripts/setup-cloud.py config        write config-cloudhub.yaml and secure-cloudhub.yaml for every app
    python scripts/setup-cloud.py db            load db/schema.sql and db/seed.sql into the hosted PostgreSQL
    python scripts/setup-cloud.py broker        create the exchange, queues and bindings on the hosted RabbitMQ
    python scripts/setup-cloud.py samples       upload samples/documents to the hosted bucket (staging/)
    python scripts/setup-cloud.py api-manager   publish the API specs, register both APIs, apply the policies, create a client
    python scripts/setup-cloud.py urls          read the public URLs of the deployed apps and store them in the settings file

Options:  --env PATH  settings file      --app NAME  (config only) one app instead of all
"""
import argparse
import base64
import io
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = 'https://anypoint.mulesoft.com'
APPS = ['loan-system-api', 'loan-intake-exp-api', 'loan-document-proc', 'loan-scoring-proc', 'loan-notification-proc']
POLICY_GROUP = '68ef9520-24e9-4cf2-b2f5-620025690913'   # MuleSoft's own policy templates, the same in every organization
SPECS = {  # app -> (Exchange asset id, RAML file)
    'loan-intake-exp-api': ('loan-intake-api-spec', 'loan-intake-exp-api/src/main/resources/api/loan-intake-exp-api.raml', 'Loan Intake API'),
    'loan-system-api': ('loan-system-api-spec', 'loan-system-api/src/main/resources/api/loan-system-api.raml', 'Loan System API'),
}


# ---------------------------------------------------------------- settings file
class Settings:
    def __init__(self, path):
        self.path = os.path.expanduser(path)
        if not os.path.exists(self.path):
            sys.exit('Settings file not found: %s\nCopy cloud/anypoint-cloud.env.example there and fill it in.' % self.path)
        self.values = {}
        for line in open(self.path, encoding='utf-8'):
            line = line.rstrip('\r\n')
            if '=' in line and not line.lstrip().startswith('#'):
                k, v = line.split('=', 1)
                self.values[k.strip()] = v.strip()

    def get(self, key, default=None):
        return self.values.get(key, default)

    def need(self, *keys):
        missing = [k for k in keys if not self.values.get(k)]
        if missing:
            sys.exit('Missing in %s: %s' % (self.path, ', '.join(missing)))
        return [self.values[k] for k in keys]

    def update(self, updates):
        lines = open(self.path, encoding='utf-8').read().split('\n')
        seen = set()
        for i, line in enumerate(lines):
            if '=' in line and not line.lstrip().startswith('#'):
                k = line.split('=', 1)[0].strip()
                if k in updates:
                    lines[i] = '%s=%s' % (k, updates[k])
                    seen.add(k)
        extra = ['%s=%s' % (k, v) for k, v in updates.items() if k not in seen]
        if extra:
            if lines and lines[-1] == '':
                lines = lines[:-1]
            lines += extra + ['']
        open(self.path, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))
        self.values.update(updates)


# ---------------------------------------------------------------- tiny helpers
def http(method, url, body=None, headers=None, raw=False, timeout=60):
    data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
    h = {'Content-Type': 'application/json'}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            b = r.read()
            return r.status, (b if raw else (json.loads(b) if b else None))
    except urllib.error.HTTPError as e:
        b = e.read()
        try:
            return e.code, json.loads(b)
        except Exception:
            return e.code, b.decode(errors='replace')[:400]


def token(s):
    cid, sec = s.need('ANYPOINT_CLIENT_ID', 'ANYPOINT_CLIENT_SECRET')
    code, r = http('POST', HOST + '/accounts/api/v2/oauth2/token', {'client_id': cid, 'client_secret': sec, 'grant_type': 'client_credentials'})
    if code != 200:
        sys.exit('Could not get a token for the Connected App (HTTP %s). Check ANYPOINT_CLIENT_ID / SECRET and its scopes.' % code)
    return r['access_token']


def auth(t):
    return {'Authorization': 'Bearer ' + t}


def env_id(s, t):
    if s.get('ANYPOINT_ENV_ID'):
        return s.get('ANYPOINT_ENV_ID')
    org, name = s.need('ANYPOINT_ORG_ID', 'ANYPOINT_ENV')
    code, r = http('GET', '%s/accounts/api/organizations/%s/environments' % (HOST, org), headers=auth(t))
    if code == 200:
        for e in r.get('data', []):
            if e.get('name') == name:
                s.update({'ANYPOINT_ENV_ID': e['id']})
                return e['id']
    sys.exit('Could not find the environment "%s". Put its id in ANYPOINT_ENV_ID (Runtime Manager URL, or Access Management > Environments).' % name)


def find_java():
    for c in [os.environ.get('JDK17_HOME'), os.environ.get('JAVA_HOME')]:
        if c and os.path.exists(os.path.join(c, 'bin', 'java.exe')):
            return os.path.join(c, 'bin', 'java.exe')
        if c and os.path.exists(os.path.join(c, 'bin', 'java')):
            return os.path.join(c, 'bin', 'java')
    for c in ['C:\\AnypointStudio\\plugins\\org.mule.tooling.jdk.win32.x86_64_1.4.1']:
        if os.path.exists(os.path.join(c, 'bin', 'java.exe')):
            return os.path.join(c, 'bin', 'java.exe')
    return shutil.which('java') or sys.exit('No java found. Install JDK 17 or set JDK17_HOME.')


# ---------------------------------------------------------------- config
def flatten(lines):
    """Map a key path such as ('amqp', 'host') to the line index of a `key: "value"` line in a two-space YAML file."""
    index, stack = {}, []
    for i, line in enumerate(lines):
        if line.lstrip().startswith('#') or not line.strip():
            continue
        m = re.match(r'^( *)([A-Za-z0-9_.-]+):\s*(.*)$', line)
        if not m:
            continue
        depth = len(m.group(1)) // 2
        stack = stack[:depth] + [m.group(2)]
        if m.group(3) != '':
            index[tuple(stack)] = i
    return index


def apply(text, overrides, header):
    lines = text.replace('\r\n', '\n').split('\n')
    index = flatten(lines)
    for path, value in overrides.items():
        key = tuple(path.split('.'))
        if key in index:
            i = index[key]
            indent = re.match(r'^( *)', lines[i]).group(1)
            lines[i] = '%s%s: "%s"' % (indent, key[-1], value)
    return header + '\n'.join(lines).rstrip('\n') + '\n'


def encrypt(s, value):
    tool, key = s.need('SECURE_PROPS_TOOL', 'SECURE_KEY_CLOUD')
    if not os.path.exists(tool):
        sys.exit('Secure Properties tool not found at %s (SECURE_PROPS_TOOL).' % tool)
    out = subprocess.run([find_java(), '-cp', tool, 'com.mulesoft.tools.SecurePropertiesTool', 'string', 'encrypt', 'AES', 'CBC', key, value], capture_output=True, text=True)
    lines = out.stdout.strip().splitlines()
    if out.returncode != 0 or not lines:
        sys.exit('Encryption failed: %s' % (out.stderr or out.stdout)[:300])
    return lines[-1]


def intake_base(s):
    u = (s.get('CLOUD_INTAKE_API_URL') or '').rstrip('/')
    if not u:
        return ''
    return u if u.endswith('/api') else u + '/api'


def cmd_config(s, only=None):
    sys_url = (s.get('CLOUD_SYSTEM_API_URL') or '').rstrip('/')
    if not sys_url:
        print('Note: CLOUD_SYSTEM_API_URL is not set yet. Apps that call the system API get a placeholder host. '
              'Deploy the system API, run "urls", then run "config" again.')
    sys_host = re.sub(r'^https?://', '', sys_url) or 'SET-AFTER-FIRST-DEPLOY.cloudhub.io'
    common = {'http.listener.port': '8081'}
    for app in APPS:
        if only and app != only:
            continue
        res = os.path.join(ROOT, app, 'src', 'main', 'resources')
        local = os.path.join(res, 'config-local.yaml')
        if not os.path.exists(local):
            print('skip %s (no config-local.yaml)' % app)
            continue
        o = dict(common)
        secure = {}
        if app == 'loan-system-api':
            host, port, name, user = s.need('PG_HOST', 'PG_PORT', 'PG_DB', 'PG_USER')
            o.update({'db.host': host, 'db.port': port, 'db.name': name, 'db.user': user, 'db.urlParams': '?sslmode=require'})
            secure['db'] = ('password', s.need('PG_PASSWORD')[0])
            hosted = 'Neon (Postgres)'
        else:
            o.update({'system.api.host': sys_host, 'system.api.port': '443', 'system.api.protocol': 'HTTPS'})
            hosted = 'CloudAMQP, S3-compatible bucket, SMTP'
        if app in ('loan-document-proc', 'loan-scoring-proc', 'loan-notification-proc'):
            ah, ap, av, au, apw = s.need('AMQP_HOST', 'AMQP_PORT', 'AMQP_VHOST', 'AMQP_USER', 'AMQP_PASSWORD')
            o.update({'amqp.host': ah, 'amqp.port': ap, 'amqp.virtualHost': av, 'amqp.user': au})
            secure['amqp'] = ('password', apw)
        if app == 'loan-document-proc':
            ep, rg, ak, bk, sk = s.need('S3_ENDPOINT', 'S3_REGION', 'S3_ACCESS_KEY', 'S3_BUCKET', 'S3_SECRET_KEY')
            o.update({'store.endpoint': ep, 'store.region': rg, 'store.accessKey': ak, 'store.bucket': bk})
            secure['store'] = ('secretKey', sk)
        if app == 'loan-notification-proc':
            mh, mp, mu, mpw = s.need('SMTP_HOST', 'SMTP_PORT', 'SMTP_USER', 'SMTP_PASSWORD')
            o.update({'mail.host': mh, 'mail.port': mp, 'mail.user': mu, 'sweeper.frequencyMillis': '15000'})
            if intake_base(s):
                o['mail.statusBaseUrl'] = intake_base(s)
            secure['mail'] = ('password', mpw)
        if app == 'loan-intake-exp-api' and intake_base(s):
            o['http.publicBaseUrl'] = intake_base(s)
        header = '# Non-secret settings for CloudHub 2.0, generated by scripts/setup-cloud.py from config-local.yaml. Not committed. Hosted services: %s.\n' % hosted
        text = apply(open(local, encoding='utf-8').read(), o, header)
        api_id = s.get({'loan-system-api': 'SYSTEM_API_ID', 'loan-intake-exp-api': 'INTAKE_API_ID'}.get(app, ''), '') if app in ('loan-system-api', 'loan-intake-exp-api') else ''
        if api_id:
            text += 'api:\n  id: "%s"\n' % api_id
        open(os.path.join(res, 'config-cloudhub.yaml'), 'w', encoding='utf-8', newline='\n').write(text)
        if secure:
            out = '# Secrets for CloudHub, encrypted with the Secure Properties tool (AES / CBC). The key is the application property secure.key set at deployment. Not committed.\n'
            for group, (leaf, value) in secure.items():
                out += '%s:\n  %s: "![%s]"\n' % (group, leaf, encrypt(s, value))
            open(os.path.join(res, 'secure-cloudhub.yaml'), 'w', encoding='utf-8', newline='\n').write(out)
        print('wrote %s%s%s' % (app, ' (with api id)' if api_id else '', ' (autodiscovery needs an api id: run api-manager first)' if app in ('loan-system-api', 'loan-intake-exp-api') and not api_id else ''))


# ---------------------------------------------------------------- hosted services
def cmd_db(s):
    host, port, name, user, pw = s.need('PG_HOST', 'PG_PORT', 'PG_DB', 'PG_USER', 'PG_PASSWORD')
    conn = 'host=%s port=%s dbname=%s user=%s sslmode=require' % (host, port, name, user)
    for f in ('db/schema.sql', 'db/seed.sql'):
        data = open(os.path.join(ROOT, f), 'rb').read()
        r = subprocess.run(['docker', 'run', '--rm', '-i', '-e', 'PGPASSWORD=' + pw, 'postgres:16-alpine', 'psql', conn, '-v', 'ON_ERROR_STOP=1', '-q', '-f', '-'], input=data, capture_output=True)
        print('%s: %s' % (f, 'loaded' if r.returncode == 0 else 'FAILED\n' + r.stderr.decode(errors='replace')[:600]))
        if r.returncode != 0:
            sys.exit(1)


def cmd_broker(s):
    user, pw, vhost = s.need('AMQP_USER', 'AMQP_PASSWORD', 'AMQP_VHOST')
    base = (s.get('AMQP_MGMT_URL') or 'https://%s/api' % s.need('AMQP_HOST')[0]).rstrip('/')
    h = {'Authorization': 'Basic ' + base64.b64encode(('%s:%s' % (user, pw)).encode()).decode()}
    d = json.load(open(os.path.join(ROOT, 'docker', 'rabbitmq', 'definitions.json'), encoding='utf-8'))
    v = urllib.parse.quote(vhost, safe='')
    for e in d['exchanges']:
        code, _ = http('PUT', '%s/exchanges/%s/%s' % (base, v, urllib.parse.quote(e['name'], safe='')), {'type': e['type'], 'durable': e['durable'], 'auto_delete': e['auto_delete'], 'arguments': {}}, h)
        print('exchange %-22s %s' % (e['name'], 'ok' if code in (201, 204) else 'HTTP %s' % code))
    for q in d['queues']:
        code, _ = http('PUT', '%s/queues/%s/%s' % (base, v, urllib.parse.quote(q['name'], safe='')), {'durable': q['durable'], 'auto_delete': q['auto_delete'], 'arguments': {}}, h)
        print('queue    %-22s %s' % (q['name'], 'ok' if code in (201, 204) else 'HTTP %s' % code))
    for b in d['bindings']:
        code, _ = http('POST', '%s/bindings/%s/e/%s/q/%s' % (base, v, urllib.parse.quote(b['source'], safe=''), urllib.parse.quote(b['destination'], safe='')), {'routing_key': b['routing_key'], 'arguments': {}}, h)
        print('binding  %-22s %s' % (b['destination'], 'ok' if code in (201, 204) else 'HTTP %s' % code))


def cmd_samples(s):
    ep, rg, ak, sk, bucket = s.need('S3_ENDPOINT', 'S3_REGION', 'S3_ACCESS_KEY', 'S3_SECRET_KEY', 'S3_BUCKET')
    src = os.path.join(ROOT, 'samples', 'documents')
    if not os.path.isdir(src):
        sys.exit('samples/documents is missing. Run: powershell -File scripts\\make-samples.ps1')
    r = subprocess.run(['docker', 'run', '--rm', '-e', 'AWS_ACCESS_KEY_ID=' + ak, '-e', 'AWS_SECRET_ACCESS_KEY=' + sk, '-e', 'AWS_DEFAULT_REGION=' + rg,
                        '-v', src + ':/data:ro', 'amazon/aws-cli', '--endpoint-url', ep, 's3', 'sync', '/data', 's3://%s/staging/' % bucket], capture_output=True, text=True)
    print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else '', 'uploaded to s3://%s/staging/' % bucket if r.returncode == 0 else 'FAILED: ' + r.stderr[:400])
    if r.returncode != 0:
        sys.exit(1)


# ---------------------------------------------------------------- Anypoint
def cmd_urls(s):
    org = s.need('ANYPOINT_ORG_ID')[0]
    t = token(s)
    env = env_id(s, t)
    base = '%s/amc/application-manager/api/v2/organizations/%s/environments/%s/deployments' % (HOST, org, env)
    code, r = http('GET', base, headers=auth(t))
    if code != 200:
        sys.exit('Could not list deployments (HTTP %s).' % code)
    updates = {}
    for item in r.get('items', []):
        code, d = http('GET', base + '/' + item['id'], headers=auth(t))
        url = d['target']['deploymentSettings'].get('http', {}).get('inbound', {}).get('publicUrl') if code == 200 else None
        print('%-24s %-10s %-10s %s' % (item['name'], item.get('status'), d['application'].get('status') if code == 200 else '?', url))
        if url and item['name'] == 'loan-system-api':
            updates['CLOUD_SYSTEM_API_URL'] = url
        if url and item['name'] == 'loan-intake-exp-api':
            updates['CLOUD_INTAKE_API_URL'] = url.rstrip('/') + '/api'
    if updates:
        s.update(updates)
        print('stored: ' + ', '.join(updates))


def multipart(fields, filename, filebytes):
    b = uuid.uuid4().hex
    parts = [('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' % (b, k, v)).encode() for k, v in fields]
    parts.append(('--%s\r\nContent-Disposition: form-data; name="files.raml.zip"; filename="%s"\r\nContent-Type: application/zip\r\n\r\n' % (b, filename)).encode() + filebytes + b'\r\n')
    parts.append(('--%s--\r\n' % b).encode())
    return b''.join(parts), 'multipart/form-data; boundary=' + b


def cmd_api_manager(s):
    org = s.need('ANYPOINT_ORG_ID')[0]
    t = token(s)
    env = env_id(s, t)
    A = '%s/apimanager/api/v1/organizations/%s/environments/%s/apis' % (HOST, org, env)
    X = '%s/apimanager/xapi/v1/organizations/%s/environments/%s/apis' % (HOST, org, env)
    ids = {}
    # 1. publish both RAML specs to Exchange as API assets
    for app, (asset, raml, title) in SPECS.items():
        path = os.path.join(ROOT, raml)
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, 'w') as z:
            z.write(path, os.path.basename(path))
        fields = [('organizationId', org), ('groupId', org), ('assetId', asset), ('version', '1.0.0'), ('apiVersion', 'v1'), ('name', title), ('classifier', 'raml'),
                  ('mainFile', os.path.basename(path)), ('properties.mainFile', os.path.basename(path)), ('properties.apiVersion', 'v1')]
        body, ctype = multipart(fields, asset + '.zip', buf.getvalue())
        code, r = http('POST', '%s/exchange/api/v2/organizations/%s/assets/%s/%s/1.0.0' % (HOST, org, org, asset), body, {**auth(t), 'Content-Type': ctype, 'x-sync-publication': 'true'})
        print('spec %-22s %s' % (asset, 'published' if code == 201 else ('already there' if code in (400, 409) and 'exist' in json.dumps(r).lower() else 'HTTP %s %s' % (code, str(r)[:160]))))
    # 2. register both APIs (reuse an instance that already exists)
    code, r = http('GET', X, headers=auth(t))
    existing = {i.get('assetId'): i['id'] for i in (r.get('instances', []) if code == 200 else [])}
    for app, (asset, raml, title) in SPECS.items():
        uri = {'loan-system-api': s.get('CLOUD_SYSTEM_API_URL'), 'loan-intake-exp-api': s.get('CLOUD_INTAKE_API_URL')}[app] or 'https://not-deployed-yet.example.com'
        uri = uri if uri.rstrip('/').endswith('/api') else uri.rstrip('/') + '/api'
        if asset in existing:
            ids[app] = existing[asset]
            print('api  %-22s reused, id %s' % (app, ids[app]))
            continue
        body = {'endpoint': {'deploymentType': 'CH2', 'type': 'rest-api', 'uri': uri, 'isCloudHub': False, 'muleVersion4OrAbove': True, 'proxyUri': None, 'referencesUserDomain': False, 'responseTimeout': None},
                'instanceLabel': app, 'spec': {'assetId': asset, 'groupId': org, 'version': '1.0.0'}, 'technology': 'mule4'}
        code, r = http('POST', X, body, auth(t))
        if code not in (200, 201):
            sys.exit('Could not register %s (HTTP %s): %s' % (app, code, str(r)[:300]))
        ids[app] = r['id']
        print('api  %-22s registered, id %s' % (app, ids[app]))
    # 3. policies: client-id enforcement on the public intake API, spike control on both
    spike = {'maximumRequests': 20, 'timePeriodInMilliseconds': 1000, 'delayTimeInMillis': 500, 'delayAttempts': 2, 'queuingLimit': 5, 'useClusterManager': False}
    wanted = {
        'loan-intake-exp-api': [('client-id-enforcement', '1.3.4', {'credentialsOriginHasHttpBasicAuthenticationHeader': 'customExpression', 'clientIdExpression': "#[attributes.headers['client_id']]", 'clientSecretExpression': "#[attributes.headers['client_secret']]"}),
                                ('spike-control', '1.2.3', spike)],
        'loan-system-api': [('spike-control', '1.2.3', dict(spike, maximumRequests=100))],
    }
    for app, items in wanted.items():
        code, r = http('GET', '%s/%s/policies' % (A, ids[app]), headers=auth(t))
        have = json.dumps(r) if code == 200 else ''
        for asset, version, conf in items:
            if asset in have:
                print('policy %-22s %-22s already applied' % (app, asset))
                continue
            code, r = http('POST', '%s/%s/policies' % (A, ids[app]), {'configurationData': conf, 'pointcutData': None, 'groupId': POLICY_GROUP, 'assetId': asset, 'assetVersion': version}, auth(t))
            print('policy %-22s %-22s %s' % (app, asset, 'applied' if code in (200, 201) else 'HTTP %s %s' % (code, str(r)[:200])))
    updates = {'INTAKE_API_ID': str(ids['loan-intake-exp-api']), 'SYSTEM_API_ID': str(ids['loan-system-api'])}
    # 4. a client application with a contract for the intake API
    if not s.get('INTAKE_CLIENT_ID'):
        code, app = http('POST', '%s/exchange/api/v2/organizations/%s/applications' % (HOST, org), {'name': 'loan-portal-demo', 'description': 'Demo client for the Loan Intake API', 'apiEndpoints': False}, auth(t))
        if code in (200, 201) and 'clientId' in app:
            updates.update({'INTAKE_CLIENT_ID': app['clientId'], 'INTAKE_CLIENT_SECRET': app['clientSecret'], 'INTAKE_APP_ID': str(app['id'])})
            code, c = http('POST', '%s/exchange/api/v2/organizations/%s/applications/%s/contracts' % (HOST, org, app['id']),
                           {'apiId': str(ids['loan-intake-exp-api']), 'environmentId': env, 'acceptedTerms': True, 'organizationId': org, 'groupId': org, 'assetId': 'loan-intake-api-spec',
                            'version': '1.0.0', 'versionGroup': 'v1', 'productAPIVersion': 'v1', 'instanceType': 'api'}, auth(t))
            print('client app loan-portal-demo created, contract %s' % ('approved' if code in (200, 201) else 'HTTP %s %s' % (code, str(c)[:200])))
        else:
            print('client app could not be created (HTTP %s): %s' % (code, str(app)[:200]))
    else:
        print('client app: INTAKE_CLIENT_ID already in the settings file, left as it is')
    s.update(updates)
    print('stored api ids and client credentials in %s. Run "config" again so the apps get their api id.' % s.path)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('command', choices=['config', 'db', 'broker', 'samples', 'api-manager', 'urls'])
    p.add_argument('--env', default=os.environ.get('ANYPOINT_CLOUD_ENV', '~/.anypoint-cloud.env'))
    p.add_argument('--app')
    a = p.parse_args()
    s = Settings(a.env)
    {'config': lambda: cmd_config(s, a.app), 'db': lambda: cmd_db(s), 'broker': lambda: cmd_broker(s), 'samples': lambda: cmd_samples(s),
     'api-manager': lambda: cmd_api_manager(s), 'urls': lambda: cmd_urls(s)}[a.command]()


if __name__ == '__main__':
    main()
