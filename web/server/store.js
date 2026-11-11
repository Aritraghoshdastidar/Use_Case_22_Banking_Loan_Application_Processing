// The site's own small database: accounts, sessions, which application belongs to which customer, and what staff did.
// The loan system itself has no user accounts, so this lives here and never touches the Mule apps' database.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { DATA_DIR } from './config.js';

fs.mkdirSync(DATA_DIR, { recursive: true });
export const db = new DatabaseSync(path.join(DATA_DIR, 'web.db'));
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL UNIQUE COLLATE NOCASE,
    name TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('customer','underwriter','ops')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
  );
  CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS applications (
    env TEXT NOT NULL,
    application_id TEXT NOT NULL,
    user_id INTEGER NOT NULL REFERENCES users(id),
    folder TEXT NOT NULL,
    product TEXT NOT NULL,
    amount REAL NOT NULL,
    tenure INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    PRIMARY KEY (env, application_id)
  );
  CREATE TABLE IF NOT EXISTS actions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    user_id INTEGER NOT NULL,
    env TEXT NOT NULL,
    application_id TEXT,
    action TEXT NOT NULL,
    detail TEXT
  );
`);

export const q = {
  userByEmail: db.prepare('SELECT * FROM users WHERE email = ?'),
  userById: db.prepare('SELECT id, email, name, role FROM users WHERE id = ?'),
  insertUser: db.prepare('INSERT INTO users (email, name, password_hash, role) VALUES (?, ?, ?, ?)'),
  countUsers: db.prepare('SELECT COUNT(*) AS n FROM users'),
  insertSession: db.prepare('INSERT INTO sessions (token_hash, user_id, expires_at) VALUES (?, ?, ?)'),
  sessionUser: db.prepare('SELECT u.id, u.email, u.name, u.role FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ?'),
  deleteSession: db.prepare('DELETE FROM sessions WHERE token_hash = ?'),
  purgeSessions: db.prepare('DELETE FROM sessions WHERE expires_at <= ?'),
  upsertApp: db.prepare('INSERT INTO applications (env, application_id, user_id, folder, product, amount, tenure) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (env, application_id) DO NOTHING'),
  appsOf: db.prepare('SELECT * FROM applications WHERE env = ? AND user_id = ? ORDER BY created_at DESC LIMIT 50'),
  appById: db.prepare('SELECT a.*, u.name AS owner_name, u.email AS owner_email FROM applications a JOIN users u ON u.id = a.user_id WHERE a.env = ? AND a.application_id = ?'),
  insertAction: db.prepare('INSERT INTO actions (user_id, env, application_id, action, detail) VALUES (?, ?, ?, ?, ?)'),
  recentActions: db.prepare('SELECT a.id, a.at, a.env, a.application_id, a.action, a.detail, u.name AS who FROM actions a JOIN users u ON u.id = a.user_id ORDER BY a.id DESC LIMIT 40'),
};

export function logAction(userId, env, applicationId, action, detail) {
  q.insertAction.run(userId, env, applicationId || null, action, detail ? String(detail).slice(0, 400) : null);
}

export const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
