// Configuration: which backend the site talks to. Nothing here is sent to the browser except labels.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
export const PORT = Number(process.env.PORT || 3000);
export const DATA_DIR = process.env.WEB_DATA_DIR || path.join(ROOT, 'data');
export const SECURE_COOKIE = process.env.WEB_SECURE_COOKIE === '1';

function readEnvFile(file) {
  const out = {};
  try {
    for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
      const t = line.trim();
      if (!t || t.startsWith('#')) continue;
      const i = t.indexOf('=');
      if (i > 0) out[t.slice(0, i).trim()] = t.slice(i + 1).trim();
    }
  } catch { /* no settings file: only the local environment is offered */ }
  return out;
}

// Same settings file the cloud scripts use (outside the repository). Values are read here, on the server only.
const s = { ...readEnvFile(process.env.ANYPOINT_CLOUD_ENV || path.join(os.homedir(), '.anypoint-cloud.env')), ...process.env };
const api = (u) => {
  if (!u) return null;
  const t = u.replace(/\/+$/, '');
  return t.endsWith('/api') ? t : t + '/api';
};

export const environments = {
  local: {
    id: 'local',
    label: 'Local',
    note: 'Docker stack and one Mule runtime on this machine',
    urls: {
      system: 'http://localhost:8701/api',
      intake: 'http://localhost:8702/api',
      document: 'http://localhost:8703/api',
      scoring: 'http://localhost:8704/api',
      notification: 'http://localhost:8705/api',
    },
    headers: {},
    mq: { base: 'http://localhost:15672/api', user: 'loan', pass: 'loan', vhost: '/' },
    mail: 'http://localhost:8625/api/v2',
    chaos: process.env.WEB_CHAOS !== '0',
  },
};

if (s.CLOUD_INTAKE_API_URL && s.CLOUD_SYSTEM_API_URL) {
  const creds = { client_id: s.INTAKE_CLIENT_ID || '', client_secret: s.INTAKE_CLIENT_SECRET || '' };
  environments.cloud = {
    id: 'cloud',
    label: 'CloudHub',
    note: 'CloudHub 2.0 shared space, 0.1 vCore per app',
    urls: {
      system: api(s.CLOUD_SYSTEM_API_URL),
      intake: api(s.CLOUD_INTAKE_API_URL),
      document: api(s.CLOUD_DOCUMENT_URL),
      scoring: api(s.CLOUD_SCORING_URL),
      notification: api(s.CLOUD_NOTIFICATION_URL),
    },
    headers: { intake: creds, document: creds },
    mq: s.AMQP_HOST ? { base: `https://${s.AMQP_HOST}/api`, user: s.AMQP_USER, pass: s.AMQP_PASSWORD, vhost: s.AMQP_VHOST } : null,
    mail: null,
    chaos: false,
  };
}

export const defaultEnv = process.env.WEB_ENV && environments[process.env.WEB_ENV] ? process.env.WEB_ENV : (environments.cloud ? 'cloud' : 'local');
