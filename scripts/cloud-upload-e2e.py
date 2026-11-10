"""Cloud check of the document upload API (API Manager policies, the upload gate, and the path to a decision).
Reads your settings file (default ~/.anypoint-cloud.env, or the path in ANYPOINT_CLOUD_ENV; values are never printed).
Needs: all apps deployed, `python scripts/setup-cloud.py api-manager` done, and Docker (to read the hosted database).
    python scripts\\cloud-upload-e2e.py
What it proves, on CloudHub:
  1. the public upload endpoint refuses calls with no or wrong client credentials (401)
  2. bad requests are refused with 400 and a bad file set with 422 (nothing stored)
  3. a good set uploaded through the public endpoint is stored (201), the application submitted with that folder is verified,
     scored and APPROVED, and the applicant is emailed once
"""
import json, os, subprocess, sys, time, uuid, urllib.request, urllib.error

cfg = {}
for line in open(os.path.expanduser(os.environ.get('ANYPOINT_CLOUD_ENV', '~/.anypoint-cloud.env')), encoding='utf-8'):
    line = line.strip()
    if '=' in line and not line.startswith('#'):
        k, v = line.split('=', 1)
        cfg[k.strip()] = v.strip()
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
samples = os.path.join(root, 'samples', 'documents')
doc = cfg['CLOUD_DOCUMENT_URL'].rstrip('/')
intake = cfg['CLOUD_INTAKE_API_URL'].rstrip('/')
creds = {'client_id': cfg.get('INTAKE_CLIENT_ID', ''), 'client_secret': cfg.get('INTAKE_CLIENT_SECRET', '')}
fails = 0


def check(name, ok, detail=''):
    global fails
    print(('[PASS] ' if ok else '[FAIL] ') + name + ('' if ok else ' (%s)' % detail))
    if not ok:
        fails += 1


def call(method, url, body=None, headers=None):
    h = dict(headers or {})
    data = body
    if isinstance(body, (dict, list)):
        data = json.dumps(body).encode()
        h['Content-Type'] = 'application/json'
    r = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=90) as x:
            raw = x.read()
            return x.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, (json.loads(raw) if raw else None)
        except ValueError:
            return e.code, None


def multipart(paths):
    b = uuid.uuid4().hex
    out = b''
    for i, p in enumerate(paths):
        out += ('--%s\r\nContent-Disposition: form-data; name="f%d"; filename="%s"\r\nContent-Type: application/pdf\r\n\r\n' % (b, i, os.path.basename(p))).encode()
        out += open(p, 'rb').read() + b'\r\n'
    out += ('--%s--\r\n' % b).encode()
    return out, 'multipart/form-data; boundary=' + b


def upload(folder, paths, headers, product='PL'):
    body, ctype = multipart(paths)
    return call('POST', '%s/staging/%s/documents?product=%s' % (doc, folder, product), body, dict(headers, **{'Content-Type': ctype}))


def sql(q):
    out = subprocess.run(['docker', 'run', '--rm', '-e', 'PGPASSWORD=' + cfg['PG_PASSWORD'], 'postgres:16-alpine', 'psql',
                          'host=%s port=%s dbname=%s user=%s sslmode=require' % (cfg['PG_HOST'], cfg['PG_PORT'], cfg['PG_DB'], cfg['PG_USER']), '-tA', '-c', q],
                         capture_output=True, text=True)
    return out.stdout.strip()


run = time.strftime('%H%M%S')
ok_dir = os.path.join(samples, 'complete-ok')
good = [os.path.join(ok_dir, n) for n in sorted(os.listdir(ok_dir))]
bad_dir = os.path.join(samples, 'renamed')
bad = [os.path.join(bad_dir, n) for n in sorted(os.listdir(bad_dir))]

print('--- 1. policies on the public upload endpoint')
c, _ = upload('cloud-%s' % run, good[:1], {})
check('no credentials: 401', c == 401, c)
c, _ = upload('cloud-%s' % run, good[:1], {'client_id': 'nope', 'client_secret': 'nope'})
check('wrong credentials: 401', c == 401, c)

print('--- 2. bad requests are refused')
c, r = upload('ab', good[:1], creds)
check('folder name too short: 400 INVALID_FOLDER', c == 400 and (r or {}).get('code') == 'INVALID_FOLDER', (c, r))
c, r = upload('cloud-%s' % run, good[:1], creds, product='ZZ')
check('unknown product: 400 UNKNOWN_PRODUCT', c == 400 and (r or {}).get('code') == 'UNKNOWN_PRODUCT', (c, r))
c, r = upload('cloudbad-%s' % run, bad, creds)
check('a set with one renamed file: 422, nothing stored', c == 422 and (r or {}).get('code') == 'DOCUMENT_VALIDATION_FAILED', (c, r))

print('--- 3. a good set through the public endpoint, then submit, score, approve, email')
folder = 'cloudup-%s' % run
c, r = upload(folder, good, creds)
check('good set stored: 201 FILES_STAGED', c == 201 and (r or {}).get('code') == 'FILES_STAGED', (c, r))
names = [os.path.basename(p) for p in good]
body = {
    'requestId': 'CLOUD-UPLOAD-%s' % run, 'productCode': 'PL', 'amount': 200000, 'tenureMonths': 24,
    'applicant': {'fullName': 'Cloud Upload', 'dateOfBirth': '1990-05-15', 'identityRef': 'ABCDE1234F', 'email': 'cloud.upload@example.com',
                  'monthlyIncome': 90000, 'monthlyObligations': 10000, 'employmentMonths': 48},
    'documents': {'folder': folder, 'documentCount': len(names), 'documents': [
        {'fileName': n, 'type': 'ID_PROOF' if n.startswith('id_') else 'ADDRESS_PROOF' if n.startswith('address') else 'PAYSLIP'} for n in names]},
}
c, r = call('POST', intake + '/applications', body, creds)
check('intake accepted the application (202)', c == 202, (c, r))
app = (r or {}).get('applicationId')
print('application', app)
stage = ''
for _ in range(60):
    c, st = call('GET', intake + '/applications/%s/status' % app, None, creds)
    stage = (st or {}).get('stage') or ''
    if stage in ('APPROVED', 'DECLINED', 'REFERRED', 'DOCUMENTS_INCOMPLETE'):
        break
    time.sleep(5)
print('final stage:', stage)
check('uploaded documents were verified, scored and the application APPROVED', stage == 'APPROVED', stage)
for _ in range(24):
    if sql("select count(*) from notifications where application_id='%s' and status='SENT'" % app) == '1':
        break
    time.sleep(5)
check('exactly one email sent', sql("select count(*) from notifications where application_id='%s' and status='SENT'" % app) == '1')
check('four documents accepted with a digest each', sql("select count(*) from application_documents where application_id='%s' and status='ACCEPTED' and sha256 is not null" % app) == '4')
print('audit:', sql("select string_agg(event, ' > ' order by id) from decision_audit where application_id='%s'" % app))
print('FAILED: %d' % fails if fails else 'All cloud upload checks passed.')
sys.exit(1 if fails else 0)
