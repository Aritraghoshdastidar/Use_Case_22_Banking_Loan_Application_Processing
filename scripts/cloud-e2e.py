"""End-to-end check against the CloudHub 2.0 deployment: submit an application and follow it to a decision and an email.
Reads your settings file (default ~/.anypoint-cloud.env, or the path in ANYPOINT_CLOUD_ENV; values are never printed).
Needs: the apps deployed, the samples uploaded (python scripts/setup-cloud.py samples) and Docker (to read the hosted database).
    python scripts\\cloud-e2e.py                 complete-ok folder, expects APPROVED
    python scripts\\cloud-e2e.py missing-payslip expects DOCUMENTS_INCOMPLETE
The accepted documents leave the staging folder, so upload the samples again before running the same folder twice.
"""
import json, os, subprocess, sys, time, urllib.request, urllib.error

cfg = {}
for line in open(os.path.expanduser(os.environ.get('ANYPOINT_CLOUD_ENV', '~/.anypoint-cloud.env')), encoding='utf-8'):
    line = line.strip()
    if '=' in line and not line.startswith('#'):
        k, v = line.split('=', 1)
        cfg[k.strip()] = v.strip()
intake = cfg['CLOUD_INTAKE_API_URL']
folder = sys.argv[1] if len(sys.argv) > 1 else 'complete-ok'
want = {'complete-ok': 'APPROVED', 'missing-payslip': 'DOCUMENTS_INCOMPLETE'}.get(folder, '?')
files = {
    'complete-ok': [('id_proof.pdf', 'ID_PROOF'), ('address_proof.pdf', 'ADDRESS_PROOF'), ('payslip_1.pdf', 'PAYSLIP'), ('payslip_2.pdf', 'PAYSLIP')],
    'missing-payslip': [('id_proof.pdf', 'ID_PROOF'), ('address_proof.pdf', 'ADDRESS_PROOF'), ('payslip_1.pdf', 'PAYSLIP'), ('payslip_2.pdf', 'PAYSLIP')],
}[folder]
fails = 0


def check(name, ok, detail=''):
    global fails
    print(('[PASS] ' if ok else '[FAIL] ') + name + ('' if ok else ' (%s)' % detail))
    if not ok:
        fails += 1


def http(method, url, body=None):
    r = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, method=method, headers={'Content-Type': 'application/json', 'client_id': cfg.get('INTAKE_CLIENT_ID', ''), 'client_secret': cfg.get('INTAKE_CLIENT_SECRET', '')})
    try:
        with urllib.request.urlopen(r, timeout=60) as x:
            return x.status, json.loads(x.read() or b'null')
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b'null')


def sql(q):
    env = dict(os.environ, PGPASSWORD=cfg['PG_PASSWORD'])
    out = subprocess.run(['docker', 'run', '--rm', '-e', 'PGPASSWORD=' + cfg['PG_PASSWORD'], 'postgres:16-alpine', 'psql', 'host=%s port=%s dbname=%s user=%s sslmode=require' % (cfg['PG_HOST'], cfg['PG_PORT'], cfg['PG_DB'], cfg['PG_USER']), '-tAc', q], capture_output=True, text=True)
    return out.stdout.strip()


run = time.strftime('%H%M%S')
body = {
    'requestId': 'CLOUD-%s-%s' % (folder[:4].upper(), run), 'productCode': 'PL', 'amount': 200000, 'tenureMonths': 24,
    'applicant': {'fullName': 'Cloud Check', 'dateOfBirth': '1990-05-15', 'identityRef': 'ABCDE1234F', 'email': 'cloud.check@example.com', 'monthlyIncome': 90000, 'monthlyObligations': 10000, 'employmentMonths': 48},
    'documents': {'folder': folder, 'documentCount': 4, 'documents': [{'fileName': n, 'type': t} for n, t in files]},
}
code, resp = http('POST', intake + '/applications', body)
check('intake accepted the application on CloudHub (202)', code == 202, code)
app = (resp or {}).get('applicationId')
check('an application id came back', bool(app))
print('application', app)
stage = ''
for _ in range(60):
    c, st = http('GET', intake + '/applications/%s/status' % app)
    stage = (st or {}).get('stage') or (st or {}).get('status') or ''
    if stage in ('APPROVED', 'DECLINED', 'REFERRED', 'DOCUMENTS_INCOMPLETE'):
        break
    time.sleep(5)
print('final stage:', stage)
check('reached the expected outcome ' + want, stage == want, stage)
n = sql("select count(*) from notifications where application_id='%s'" % app)
for _ in range(24):
    if sql("select count(*) from notifications where application_id='%s' and status='SENT'" % app) == '1':
        break
    time.sleep(5)
check('exactly one notification row, SENT', sql("select count(*) from notifications where application_id='%s' and status='SENT'" % app) == '1', sql("select status from notifications where application_id='%s'" % app))
check('the audit trail ends with NOTIFIED', sql("select event from decision_audit where application_id='%s' order by id desc limit 1" % app) == 'NOTIFIED')
expected_msgs = '3' if want == 'APPROVED' else '2'
check('each consumer handled its message exactly once (%s claims)' % expected_msgs, sql("select count(*) from processed_messages pm join outbox o on o.id = pm.message_id where o.payload->>'applicationId'='%s'" % app) == expected_msgs, sql("select count(*) from processed_messages pm join outbox o on o.id = pm.message_id where o.payload->>'applicationId'='%s'" % app))
print('audit:', sql("select string_agg(event, ' > ' order by id) from decision_audit where application_id='%s'" % app))
print('FAILED: %d' % fails if fails else 'All cloud checks passed.')
sys.exit(1 if fails else 0)
