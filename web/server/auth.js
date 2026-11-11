// Passwords, sessions and the first-start staff accounts.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { DATA_DIR, SECURE_COOKIE } from './config.js';
import { q, sha } from './store.js';

const COOKIE = 'mf_session';
const SESSION_MS = 8 * 60 * 60 * 1000;

export function hashPassword(password) {
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync(password, salt, 64);
  return `scrypt$${salt.toString('hex')}$${hash.toString('hex')}`;
}

export function checkPassword(password, stored) {
  const [kind, saltHex, hashHex] = String(stored).split('$');
  if (kind !== 'scrypt' || !saltHex || !hashHex) return false;
  const expected = Buffer.from(hashHex, 'hex');
  const actual = crypto.scryptSync(password, Buffer.from(saltHex, 'hex'), expected.length);
  return crypto.timingSafeEqual(actual, expected);
}

export function parseCookies(header) {
  const out = {};
  for (const part of String(header || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

export function startSession(res, userId) {
  const token = crypto.randomBytes(32).toString('hex');
  q.insertSession.run(sha(token), userId, Date.now() + SESSION_MS);
  res.setHeader('Set-Cookie', `${COOKIE}=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${SESSION_MS / 1000}${SECURE_COOKIE ? '; Secure' : ''}`);
}

export function endSession(req, res) {
  const token = parseCookies(req.headers.cookie)[COOKIE];
  if (token) q.deleteSession.run(sha(token));
  res.setHeader('Set-Cookie', `${COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0`);
}

export function userFrom(req) {
  const token = parseCookies(req.headers.cookie)[COOKIE];
  if (!token) return null;
  return q.sessionUser.get(sha(token), Date.now()) || null;
}

// Simple in-memory brake against password guessing: 8 misses per address+email in 10 minutes.
const misses = new Map();
export function tooManyMisses(key) {
  const now = Date.now();
  const list = (misses.get(key) || []).filter((t) => now - t < 600000);
  misses.set(key, list);
  return list.length >= 8;
}
export function recordMiss(key) { misses.set(key, [...(misses.get(key) || []), Date.now()]); }
export function clearMisses(key) { misses.delete(key); }

/** First start: create the staff accounts with random passwords (or WEB_STAFF_PASSWORD) and write them to a git-ignored file. */
export function seedStaff() {
  if (q.countUsers.get().n > 0) return null;
  const fixed = process.env.WEB_STAFF_PASSWORD;
  const accounts = [
    { email: 'priya.raman@marigold.example', name: 'Priya Raman', role: 'underwriter' },
    { email: 'ops@marigold.example', name: 'Operations desk', role: 'ops' },
  ];
  const lines = ['Staff accounts created on first start. Change them by deleting web.db before the next start.', ''];
  for (const a of accounts) {
    const password = fixed || crypto.randomBytes(9).toString('base64url');
    q.insertUser.run(a.email, a.name, hashPassword(password), a.role);
    lines.push(`${a.role.padEnd(12)} ${a.email}  ${password}`);
  }
  const file = path.join(DATA_DIR, 'initial-credentials.txt');
  fs.writeFileSync(file, lines.join('\n') + '\n', { mode: 0o600 });
  return file;
}
