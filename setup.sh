#!/usr/bin/env bash
# Recreates the whole Studio project in ./aihub, then run: cd aihub && npm install && npm start
set -e
mkdir -p aihub && cd aihub
cat > '.env.example' <<'AIHUB_EOF_7f3a'
# From console.higgsfield.ai (shown once at creation)
HF_API_KEY_ID=
HF_API_KEY_SECRET=

# Protects the manual credit-grant endpoint until Stripe is wired in
ADMIN_TOKEN=change-me

PORT=3000

# Leave Higgsfield keys blank (or set HF_MOCK=1) to run in mock mode
HF_MOCK=1

# Stripe: test keys are free (dashboard.stripe.com/test/apikeys)
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=
BASE_URL=http://localhost:3000
AIHUB_EOF_7f3a
cat > '.gitignore' <<'AIHUB_EOF_7f3a'
uploads/
aihub.db*
.env
node_modules/
AIHUB_EOF_7f3a
cat > 'README.md' <<'AIHUB_EOF_7f3a'
# Studio (MVP)

Express + SQLite app that sells AI generations for credits.

## Run (works with no accounts)
    cp .env.example .env     # HF_MOCK=1 is already set
    npm install
    npm start                # http://localhost:3000

Sign up, tap a credit pack (fake payment in dev), generate. Mock jobs go
queued -> in_progress -> completed in ~8s. Put "fail-test" in a prompt to see an automatic refund.

## Switching on the real services
- Higgsfield: fill HF_API_KEY_ID / HF_API_KEY_SECRET, remove HF_MOCK, then paste each video
  model's `path` and check its request fields in lib/models.js (from console.higgsfield.ai).
- Stripe: add test keys, then `stripe listen --forward-to localhost:3000/api/stripe/webhook`
  and copy the signing secret into STRIPE_WEBHOOK_SECRET. Set NODE_ENV=production on the live site
  (it disables fake payments).
- Storage: lib/storage.js saves to ./uploads; swap persist() for S3/R2 when you deploy.

## Face and voice permissions
Flow: verify account identity -> create a permission (voice/face, own or someone else's) ->
the person records a live statement with a one-time code -> review -> approved -> usable.
- Someone else's likeness: you get a link (/consent.html?t=...) to send them. They record
  and tick their own boxes, and can withdraw permission from the same link at any time.
- Face/voice models refuse to run without an approved, un-withdrawn permission of the right kind.
- Every step is logged in consent_events. Recordings are kept in ./evidence (never served publicly).
- Dev: identity and review auto-approve. Production: both FAIL CLOSED until you wire them up:
  identity (e.g. Stripe Identity) via POST /api/identity/start, and review via the admin queue:
    GET  /api/admin/consents/pending                 (header x-admin-token)
    GET  /api/admin/consents/:id/evidence
    POST /api/admin/consents/:id/approve | reject
- Face swap also needs a face-match step (uploaded face = consented face) before production;
  it stays disabled in production until FACE_MATCH_PROVIDER is set and implemented.
- Voice cloning should use the approved consent recording as the only voice sample.
- Camera/mic capture needs HTTPS on a real domain (localhost is fine for testing).

## Before launch
- Real moderation API, rate limits, HTTPS, report-abuse flow
- Finish and legally review TERMS-DRAFT.md
- Face swap / voice cloning only after consent + identity verification exist
AIHUB_EOF_7f3a
cat > 'TERMS-DRAFT.md' <<'AIHUB_EOF_7f3a'
# Terms of Service and Acceptable Use — DRAFT
*Starting template only. Have a lawyer review it for your jurisdiction before launch. Replace [bracketed] items.*

## 1. The service
[Company] ("we") provides tools that generate images, video and audio using third-party AI models. You pay with prepaid credits. Outputs are generated automatically and may be inaccurate or unexpected.

## 2. Accounts
You must be 18 or older and give accurate information. You are responsible for activity on your account. Keep your password secure.

## 3. Credits and refunds
Credits are bought in advance and used per generation at the price shown before you generate. If a generation fails or is blocked by content rules, the credits for it are returned automatically. Purchased credits are otherwise [non-refundable / refundable within X days] and expire [after 12 months].

## 4. Acceptable use
You may not use the service to:
- Create sexual content involving minors, or any sexual content depicting a real person without their consent.
- Impersonate any person, or create content intended to deceive others about who said or did something.
- Commit fraud, harassment, stalking, extortion, or to bypass identity or security checks.
- Create content that is illegal, or that promotes violence or hatred against people.
- Upload anyone's face, voice or likeness without their clear, informed permission.
- Try to bypass moderation, or resell access without our written agreement.

## 5. Face and voice features
Face swap and voice cloning are available only after you confirm you have the permission of every person whose likeness you upload, and complete any verification we require. We keep records linking each generation to an account, may add watermarks or content credentials to outputs, and may refuse, remove or report content.

## 6. Your content and outputs
You keep the rights you have in what you upload. You grant us permission to process it to run the service. Subject to these terms and the providers' terms, you may use outputs, including commercially. You are responsible for making sure your use of an output is lawful and does not infringe others' rights.

## 7. Enforcement
We may suspend or close accounts, withhold credits tied to abuse, and cooperate with law enforcement where we believe a law has been broken.

## 8. Reporting
Report abuse or a likeness used without permission at [email]. We will review reports promptly and remove content where appropriate.

## 9. Disclaimers and liability
The service is provided "as is". To the extent the law allows, we are not liable for indirect or consequential losses, and our total liability is limited to the amount you paid us in the previous [12] months. [Lawyer to adapt for your jurisdiction.]

## 10. Changes and contact
We may update these terms and will notify you of material changes. Contact: [email]. Governing law: [jurisdiction].
AIHUB_EOF_7f3a
mkdir -p 'lib'
cat > 'lib/consent.js' <<'AIHUB_EOF_7f3a'
// Consent and verification rules for voice cloning and face swap.
// Principle: nothing runs on a likeness unless (1) the account is identity-verified and
// (2) that specific person recorded a live consent statement that passed review, and
// (3) the consent has not been revoked. Every step is written to consent_events.
import crypto from "node:crypto";
import fs from "node:fs";
import { db } from "./db.js";

export const EVIDENCE_DIR = "evidence"; // private: never served statically
const PROD = process.env.NODE_ENV === "production";
const MIME_EXT = { "video/webm": "webm", "video/mp4": "mp4", "audio/webm": "webm", "audio/mp4": "m4a", "audio/ogg": "ogg" };
const MAX_BYTES = 12 * 1024 * 1024;

export const OWNER_ATTEST = {
  self: ["is_me", "no_deception", "adult", "terms"],
  other: ["asked_permission", "not_public_figure", "no_deception", "adult", "terms"],
};
export const SUBJECT_ATTEST = ["is_me", "permission", "adult", "understand", "terms"];

const now = () => Date.now();

export function logEvent(consentId, event, detail = null) {
  db.prepare("INSERT INTO consent_events (consent_id, event, detail, created_at) VALUES (?,?,?,?)")
    .run(consentId, event, detail, now());
}

function requireAll(given, needed) {
  for (const k of needed) if (!given || given[k] !== true) throw new Error("Tick every box to continue.");
}

const newChallenge = () =>
  `I agree to the use of my likeness for this account. My code is ${crypto.randomInt(1000, 10000)}.`;

export function createConsent({ userId, kind, relation, subjectName, attest }) {
  if (!["voice", "face"].includes(kind)) throw new Error("Choose voice or face.");
  if (!["self", "other"].includes(relation)) throw new Error("Choose whose likeness this is.");
  const name = String(subjectName || "").trim().slice(0, 80);
  if (!name) throw new Error("Enter the person's name.");
  requireAll(attest, OWNER_ATTEST[relation]);
  const token = relation === "other" ? crypto.randomBytes(24).toString("hex") : null;
  const id = db
    .prepare(
      `INSERT INTO consents (user_id, kind, relation, subject_name, subject_token, challenge, status, owner_attest, created_at)
       VALUES (?,?,?,?,?,?,?,?,?)`
    )
    .run(userId, kind, relation, name, token, newChallenge(), "awaiting_capture", JSON.stringify(attest), now()).lastInsertRowid;
  logEvent(id, "created", `${kind}/${relation}`);
  return db.prepare("SELECT * FROM consents WHERE id = ?").get(id);
}

export function saveEvidence(consent, { data, mime, still }, subjectAttest) {
  if (consent.status !== "awaiting_capture") throw new Error("This consent is no longer waiting for a recording.");
  const type = String(mime || "").split(";")[0];
  const ext = MIME_EXT[type];
  if (!ext) throw new Error("Unsupported recording format.");
  const buf = Buffer.from(String(data || ""), "base64");
  if (buf.length < 2000) throw new Error("The recording is too short. Record yourself reading the statement.");
  if (buf.length > MAX_BYTES) throw new Error("The recording is too large. Keep it under 25 seconds.");

  fs.mkdirSync(EVIDENCE_DIR, { recursive: true });
  const base = `${consent.id}-${crypto.randomBytes(6).toString("hex")}`;
  fs.writeFileSync(`${EVIDENCE_DIR}/${base}.${ext}`, buf);
  let stillPath = null;
  if (consent.kind === "face" && still) {
    const sbuf = Buffer.from(String(still), "base64");
    if (sbuf.length > 0 && sbuf.length < 3 * 1024 * 1024) {
      stillPath = `${EVIDENCE_DIR}/${base}.jpg`;
      fs.writeFileSync(stillPath, sbuf);
    }
  }
  // Dev convenience only. In production every recording waits for human or provider review.
  const auto = !PROD && process.env.CONSENT_AUTO_APPROVE !== "0";
  db.prepare(
    "UPDATE consents SET evidence_path=?, still_path=?, subject_attest=?, status=?, captured_at=?, reviewed_at=? WHERE id=?"
  ).run(`${EVIDENCE_DIR}/${base}.${ext}`, stillPath, subjectAttest ? JSON.stringify(subjectAttest) : null,
        auto ? "approved" : "pending_review", now(), auto ? now() : null, consent.id);
  logEvent(consent.id, "captured", auto ? "auto-approved (dev)" : "sent to review");
}

export function review(consentId, approve, note) {
  const c = db.prepare("SELECT * FROM consents WHERE id = ?").get(consentId);
  if (!c || c.status !== "pending_review") throw new Error("Nothing to review.");
  db.prepare("UPDATE consents SET status=?, reviewed_at=? WHERE id=?").run(approve ? "approved" : "rejected", now(), consentId);
  logEvent(consentId, approve ? "approved" : "rejected", note || null);
}

export function revoke(consentId, who) {
  const r = db.prepare("UPDATE consents SET status='revoked', revoked_at=? WHERE id=? AND status!='revoked'").run(now(), consentId);
  if (r.changes) logEvent(consentId, "revoked", who);
}

// The gate used by /api/generate.
export function assertUsable(userId, consentId, kind) {
  const user = db.prepare("SELECT identity_status FROM users WHERE id = ?").get(userId);
  if (user?.identity_status !== "verified") return { ok: false, error: "Verify your identity before using face or voice tools." };
  const c = db.prepare("SELECT * FROM consents WHERE id = ? AND user_id = ?").get(Number(consentId) || 0, userId);
  if (!c || c.kind !== kind) return { ok: false, error: "Choose an approved permission for this tool." };
  if (c.status === "revoked") return { ok: false, error: "That permission was withdrawn." };
  if (c.status !== "approved") return { ok: false, error: "That permission isn't approved yet." };
  // Fail closed: matching an uploaded face to the consented person needs a face-match provider.
  if (kind === "face" && PROD && !process.env.FACE_MATCH_PROVIDER)
    return { ok: false, error: "Face swap isn't available yet." };
  return { ok: true, consent: c };
}

const maskEmail = (e) => e.replace(/^(.).*(@.*)$/, "$1***$2");

export function ownerView(c) {
  return {
    id: c.id, kind: c.kind, relation: c.relation, subjectName: c.subject_name, status: c.status,
    challenge: c.status === "awaiting_capture" && c.relation === "self" ? c.challenge : undefined,
    link: c.relation === "other" && c.status === "awaiting_capture" ? `/consent.html?t=${c.subject_token}` : undefined,
  };
}

export function subjectView(c) {
  const u = db.prepare("SELECT email FROM users WHERE id = ?").get(c.user_id);
  return {
    kind: c.kind, subjectName: c.subject_name, status: c.status, requester: maskEmail(u?.email || ""),
    challenge: c.status === "awaiting_capture" ? c.challenge : undefined,
  };
}
AIHUB_EOF_7f3a
mkdir -p 'lib'
cat > 'lib/consentRoutes.js' <<'AIHUB_EOF_7f3a'
import express from "express";
import fs from "node:fs";
import { db } from "./db.js";
import * as C from "./consent.js";

const hits = new Map();
const limit = (max = 20, windowMs = 60000) => (req, res, next) => {
  const t = Date.now();
  const h = (hits.get(req.ip) || []).filter((x) => t - x < windowMs);
  h.push(t); hits.set(req.ip, h);
  if (h.length > max) return res.status(429).json({ error: "Too many requests. Try again in a minute." });
  next();
};
const adminOnly = (req, res, next) =>
  process.env.ADMIN_TOKEN && req.headers["x-admin-token"] === process.env.ADMIN_TOKEN ? next() : res.status(403).end();
const bySubjectToken = (t) => db.prepare("SELECT * FROM consents WHERE subject_token = ?").get(String(t));
const fail = (res, e, code = 400) => res.status(code).json({ error: e.message || String(e) });

export default function consentRouter({ requireUser }) {
  const r = express.Router();
  r.use(express.json({ limit: "20mb" })); // recordings arrive as base64

  // ----- account identity verification -----
  r.get("/api/identity", requireUser, (req, res) => {
    res.json({ status: db.prepare("SELECT identity_status s FROM users WHERE id=?").get(req.user.id).s });
  });
  r.post("/api/identity/start", requireUser, (req, res) => {
    // Production fails closed until a real provider (e.g. Stripe Identity) sets this via its webhook.
    if (process.env.NODE_ENV === "production") return res.status(503).json({ error: "Identity checks aren't set up yet." });
    db.prepare("UPDATE users SET identity_status='verified' WHERE id=?").run(req.user.id); // dev only
    res.json({ status: "verified" });
  });

  // ----- owner side -----
  r.post("/api/consents", requireUser, (req, res) => {
    const v = db.prepare("SELECT identity_status s FROM users WHERE id=?").get(req.user.id).s;
    if (v !== "verified") return fail(res, new Error("Verify your identity first."), 403);
    try { res.json(C.ownerView(C.createConsent({ userId: req.user.id, ...req.body }))); } catch (e) { fail(res, e); }
  });
  r.get("/api/consents", requireUser, (req, res) => {
    res.json(db.prepare("SELECT * FROM consents WHERE user_id=? ORDER BY id DESC").all(req.user.id).map(C.ownerView));
  });
  r.post("/api/consents/:id/capture", requireUser, (req, res) => {
    const c = db.prepare("SELECT * FROM consents WHERE id=? AND user_id=?").get(Number(req.params.id), req.user.id);
    if (!c || c.relation !== "self") return fail(res, new Error("Not found."), 404);
    try {
      for (const k of C.SUBJECT_ATTEST) if (req.body.attest?.[k] !== true) throw new Error("Tick every box to continue.");
      C.saveEvidence(c, req.body, req.body.attest);
      res.json(C.ownerView(db.prepare("SELECT * FROM consents WHERE id=?").get(c.id)));
    } catch (e) { fail(res, e); }
  });
  r.post("/api/consents/:id/revoke", requireUser, (req, res) => {
    const c = db.prepare("SELECT id FROM consents WHERE id=? AND user_id=?").get(Number(req.params.id), req.user.id);
    if (!c) return fail(res, new Error("Not found."), 404);
    C.revoke(c.id, "owner");
    res.json({ ok: true });
  });

  // ----- the person being cloned or swapped (no account needed) -----
  r.get("/api/subject/:token", limit(), (req, res) => {
    const c = bySubjectToken(req.params.token);
    if (!c) return fail(res, new Error("This link isn't valid."), 404);
    res.json(C.subjectView(c));
  });
  r.post("/api/subject/:token/capture", limit(10), (req, res) => {
    const c = bySubjectToken(req.params.token);
    if (!c) return fail(res, new Error("This link isn't valid."), 404);
    try {
      for (const k of C.SUBJECT_ATTEST) if (req.body.attest?.[k] !== true) throw new Error("Tick every box to continue.");
      C.saveEvidence(c, req.body, req.body.attest);
      res.json(C.subjectView(db.prepare("SELECT * FROM consents WHERE id=?").get(c.id)));
    } catch (e) { fail(res, e); }
  });
  r.post("/api/subject/:token/decline", limit(), (req, res) => {
    const c = bySubjectToken(req.params.token);
    if (!c) return fail(res, new Error("This link isn't valid."), 404);
    C.revoke(c.id, "subject-declined");
    res.json({ ok: true });
  });
  r.post("/api/subject/:token/revoke", limit(), (req, res) => {
    const c = bySubjectToken(req.params.token);
    if (!c) return fail(res, new Error("This link isn't valid."), 404);
    C.revoke(c.id, "subject");
    res.json({ ok: true });
  });

  // ----- admin review queue -----
  r.get("/api/admin/consents/pending", adminOnly, (_req, res) => {
    res.json(db.prepare(
      `SELECT c.id, c.kind, c.relation, c.subject_name, c.challenge, c.captured_at, u.email
       FROM consents c JOIN users u ON u.id = c.user_id WHERE c.status='pending_review' ORDER BY c.id`
    ).all());
  });
  r.get("/api/admin/consents/:id/evidence", adminOnly, (req, res) => {
    const c = db.prepare("SELECT evidence_path FROM consents WHERE id=?").get(Number(req.params.id));
    if (!c?.evidence_path || !fs.existsSync(c.evidence_path)) return res.status(404).end();
    res.sendFile(c.evidence_path, { root: process.cwd() });
  });
  r.post("/api/admin/consents/:id/:decision", adminOnly, (req, res) => {
    try { C.review(Number(req.params.id), req.params.decision === "approve", req.body?.note); res.json({ ok: true }); }
    catch (e) { fail(res, e); }
  });
  return r;
}
AIHUB_EOF_7f3a
mkdir -p 'lib'
cat > 'lib/db.js' <<'AIHUB_EOF_7f3a'
import Database from "better-sqlite3";

export const db = new Database("aihub.db");
db.pragma("journal_mode = WAL");

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  salt TEXT NOT NULL,
  pass_hash TEXT NOT NULL,
  credits INTEGER NOT NULL DEFAULT 0,   -- stored in cents
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
  token TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS jobs (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL,
  model_key TEXT NOT NULL,
  prompt TEXT NOT NULL,
  request_id TEXT,
  status_url TEXT,
  status TEXT NOT NULL,                 -- queued | in_progress | completed | failed | nsfw | canceled
  cost INTEGER NOT NULL,                -- cents charged
  output_url TEXT,
  refunded INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS payments (
  session_id TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL,
  cents INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS consents (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL,
  kind TEXT NOT NULL,                    -- voice | face
  relation TEXT NOT NULL,                -- self | other
  subject_name TEXT NOT NULL,
  subject_token TEXT UNIQUE,             -- only for relation = other
  challenge TEXT NOT NULL,
  status TEXT NOT NULL,                  -- awaiting_capture | pending_review | approved | rejected | revoked
  evidence_path TEXT,
  still_path TEXT,
  owner_attest TEXT NOT NULL,
  subject_attest TEXT,
  created_at INTEGER NOT NULL,
  captured_at INTEGER,
  reviewed_at INTEGER,
  revoked_at INTEGER
);
CREATE TABLE IF NOT EXISTS consent_events (
  id INTEGER PRIMARY KEY,
  consent_id INTEGER NOT NULL,
  event TEXT NOT NULL,
  detail TEXT,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ledger (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL,
  delta INTEGER NOT NULL,
  reason TEXT NOT NULL,
  job_id INTEGER,
  created_at INTEGER NOT NULL
);
`);

const now = () => Date.now();

// Atomically take credits. Returns false if the balance is too low.
export function charge(userId, cents, jobId, reason) {
  const tx = db.transaction(() => {
    const r = db
      .prepare("UPDATE users SET credits = credits - ? WHERE id = ? AND credits >= ?")
      .run(cents, userId, cents);
    if (r.changes !== 1) return false;
    db.prepare("INSERT INTO ledger (user_id, delta, reason, job_id, created_at) VALUES (?,?,?,?,?)")
      .run(userId, -cents, reason, jobId ?? null, now());
    return true;
  });
  return tx();
}

export function grant(userId, cents, reason, jobId) {
  db.transaction(() => {
    db.prepare("UPDATE users SET credits = credits + ? WHERE id = ?").run(cents, userId);
    db.prepare("INSERT INTO ledger (user_id, delta, reason, job_id, created_at) VALUES (?,?,?,?,?)")
      .run(userId, cents, reason, jobId ?? null, now());
  })();
}

// Refund a job exactly once.
export function refundJob(jobId) {
  db.transaction(() => {
    const job = db.prepare("SELECT * FROM jobs WHERE id = ?").get(jobId);
    if (!job || job.refunded) return;
    db.prepare("UPDATE jobs SET refunded = 1 WHERE id = ?").run(jobId);
    grant(job.user_id, job.cost, "refund", jobId);
  })();
}

// Lightweight migrations for columns added after first release.
const addCol = (table, col, ddl) => {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);
  if (!cols.includes(col)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${col} ${ddl}`);
};
addCol("users", "identity_status", "TEXT NOT NULL DEFAULT 'none'");
addCol("jobs", "consent_id", "INTEGER");
AIHUB_EOF_7f3a
mkdir -p 'lib'
cat > 'lib/higgsfield.js' <<'AIHUB_EOF_7f3a'
// Thin client for the Higgsfield API (docs.higgsfield.ai).
// Auth header format: "Key <id>:<secret>". Generation is async: submit -> poll status_url.
const BASE = "https://api.higgsfield.ai";

function authHeader() {
  const id = process.env.HF_API_KEY_ID;
  const secret = process.env.HF_API_KEY_SECRET;
  if (!id || !secret) throw new Error("Missing HF_API_KEY_ID / HF_API_KEY_SECRET");
  return `Key ${id}:${secret}`;
}

export async function submit(path, body, idempotencyKey) {
  const res = await fetch(`${BASE}/${path}`, {
    method: "POST",
    headers: {
      Authorization: authHeader(),
      "Content-Type": "application/json",
      ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}),
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`Higgsfield submit failed: ${res.status} ${await res.text()}`);
  return res.json(); // { status, request_id, status_url, cancel_url }
}

// Always use the status_url returned by submit; don't build it by hand.
export async function getStatus(statusUrl) {
  const res = await fetch(statusUrl, { headers: { Authorization: authHeader() } });
  if (!res.ok) throw new Error(`Higgsfield status failed: ${res.status}`);
  return res.json();
}

export function extractOutput(result) {
  return result.video?.url || result.images?.[0]?.url || result.audio?.url || null;
}
AIHUB_EOF_7f3a
mkdir -p 'lib'
cat > 'lib/models.js' <<'AIHUB_EOF_7f3a'
// Catalog of what your users can run. `price` is what YOU charge, in cents.
// Higgsfield list prices (blog, Sep 2026): Soul 2 ≈ $0.0032/image, Kling 3.0 ≈ $0.112/sec.
// Keep your price comfortably above cost, and re-check rates on the model pages.
//
// `path` comes from the model's page in console.higgsfield.ai. Soul 2 is confirmed in the
// docs; the video entries are left null on purpose — paste the endpoint and check the
// request fields from each model's API page, then they switch on automatically.
import { MOCK } from "./provider.js";

export const MODELS = [
  {
    key: "soul-v2",
    label: "Soul 2 (image)",
    type: "image",
    path: "higgsfield-ai/soul/v2/standard",
    price: 2,
    body: ({ prompt }) => ({ prompt }),
  },
  {
    key: "kling-3-i2v",
    label: "Kling 3.0 (video, 5s)",
    type: "video",
    path: null, // TODO: paste from console.higgsfield.ai
    price: 90,  // ~5s × $0.112 = $0.56 cost → $0.90 price
    body: ({ prompt, imageUrl }) => ({ prompt, image_url: imageUrl, duration: 5 }), // verify field names
  },
  {
    key: "seedance-2-5",
    label: "Seedance 2.5 (video, 5s)",
    type: "video",
    path: null, // TODO
    price: 60,
    body: ({ prompt }) => ({ prompt, duration: 5 }), // verify field names
  },
  {
    key: "voice-clone",
    label: "Voice clone (speech)",
    type: "audio",
    path: null, // TODO: provider endpoint. Clone from the VERIFIED consent recording only.
    price: 40,
    needsConsent: "voice",
    body: ({ prompt }) => ({ text: prompt }),
  },
  {
    key: "face-swap",
    label: "Face swap (image)",
    type: "image",
    path: null, // TODO: provider endpoint
    price: 30,
    needsConsent: "face",
    body: ({ imageUrl }) => ({ target_image_url: imageUrl }),
  },
];

export const publicCatalog = () =>
  MODELS.map(({ key, label, type, price, path, needsConsent }) => ({ key, label, type, price, needsConsent: needsConsent || null, enabled: !!path || MOCK }));

export const findModel = (key) => MODELS.find((m) => m.key === key && (m.path || MOCK));
AIHUB_EOF_7f3a
mkdir -p 'lib'
cat > 'lib/moderation.js' <<'AIHUB_EOF_7f3a'
// First-line prompt screening. This is NOT sufficient on its own: Higgsfield also returns
// status "nsfw" for rejected inputs/outputs, and you should add a real moderation API
// (e.g. OpenAI moderation endpoint or similar) before opening signups.
const BLOCK = [/\bchild\b.*\b(nude|sex|naked)/i, /\b(minor|underage|teen)\b.*\b(nude|sex|naked)/i, /\bcsam\b/i];

export function screenPrompt(prompt) {
  if (!prompt || prompt.length > 2000) return { ok: false, reason: "Prompt is empty or too long." };
  if (BLOCK.some((re) => re.test(prompt))) return { ok: false, reason: "This prompt isn't allowed." };
  return { ok: true };
}
AIHUB_EOF_7f3a
mkdir -p 'lib'
cat > 'lib/payments.js' <<'AIHUB_EOF_7f3a'
// Stripe Checkout via plain HTTPS (no SDK). Works with test keys (sk_test_...).
import crypto from "node:crypto";

export const PACKS = [500, 1000, 2500]; // cents; 1 cent paid = 1 cent of credit
export const stripeEnabled = () => !!process.env.STRIPE_SECRET_KEY;

export async function createCheckout({ userId, cents, baseUrl }) {
  const p = new URLSearchParams({
    mode: "payment",
    success_url: `${baseUrl}/?paid=1`,
    cancel_url: `${baseUrl}/`,
    "line_items[0][quantity]": "1",
    "line_items[0][price_data][currency]": "usd",
    "line_items[0][price_data][unit_amount]": String(cents),
    "line_items[0][price_data][product_data][name]": `$${(cents / 100).toFixed(2)} credits`,
    "metadata[user_id]": String(userId),
    "metadata[cents]": String(cents),
  });
  const r = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: { Authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: p,
  });
  if (!r.ok) throw new Error("Stripe error: " + (await r.text()));
  return (await r.json()).url;
}

// Verifies the Stripe-Signature header against the RAW request body.
export function verifyWebhook(rawBody, header, secret) {
  if (!header || !secret) return false;
  const parts = header.split(",").map((s) => s.split("="));
  const t = parts.find(([k]) => k === "t")?.[1];
  const sigs = parts.filter(([k]) => k === "v1").map(([, v]) => v);
  if (!t || Math.abs(Date.now() / 1000 - Number(t)) > 300) return false;
  const expected = crypto.createHmac("sha256", secret).update(`${t}.${rawBody}`).digest("hex");
  return sigs.some((s) => s.length === expected.length && crypto.timingSafeEqual(Buffer.from(s), Buffer.from(expected)));
}
AIHUB_EOF_7f3a
mkdir -p 'lib'
cat > 'lib/provider.js' <<'AIHUB_EOF_7f3a'
// Picks the real Higgsfield client or a mock. Mock is used when HF_MOCK=1 or no keys are set,
// so the whole app (credits, polling, refunds, UI) can be exercised without spending anything.
import crypto from "node:crypto";
import * as hf from "./higgsfield.js";

export const MOCK =
  process.env.HF_MOCK === "1" || !(process.env.HF_API_KEY_ID && process.env.HF_API_KEY_SECRET);

export const extractOutput = hf.extractOutput;

const placeholder = (text) => {
  const safe = String(text).slice(0, 80).replace(/[<>&"]/g, "");
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="768" height="432"><rect width="100%" height="100%" fill="#2f5d50"/>` +
    `<text x="50%" y="46%" fill="#fff" font-family="Georgia" font-size="22" text-anchor="middle">Mock output</text>` +
    `<text x="50%" y="56%" fill="#cfe3dc" font-family="Georgia" font-size="16" text-anchor="middle">${safe}</text></svg>`;
  return "data:image/svg+xml;utf8," + encodeURIComponent(svg);
};

const mockJobs = new Map();

export async function submit(path, body, idempotencyKey) {
  if (!MOCK) return hf.submit(path, body, idempotencyKey);
  const id = crypto.randomUUID();
  mockJobs.set(id, { t: Date.now(), prompt: body.prompt });
  return { status: "queued", request_id: id, status_url: `mock://${id}` };
}

export async function getStatus(url) {
  if (!url.startsWith("mock://")) return hf.getStatus(url);
  const job = mockJobs.get(url.slice(7));
  const age = Date.now() - (job?.t ?? 0);
  if (job && /fail-test/i.test(job.prompt || "")) return { status: age < 5000 ? "in_progress" : "failed" };
  if (age < 3000) return { status: "queued" };
  if (age < 8000) return { status: "in_progress" };
  return { status: "completed", images: [{ url: placeholder(job?.prompt || "") }] };
}
AIHUB_EOF_7f3a
mkdir -p 'lib'
cat > 'lib/storage.js' <<'AIHUB_EOF_7f3a'
// Copies finished outputs into storage you control. Local disk for now.
// To move to S3/R2 later, replace the body of persist() and keep its signature.
import fs from "node:fs/promises";
import crypto from "node:crypto";

export const UPLOAD_DIR = "uploads";
const EXT = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/svg+xml": "svg", "video/mp4": "mp4", "audio/mpeg": "mp3" };

export async function persist(url, jobId) {
  try {
    await fs.mkdir(UPLOAD_DIR, { recursive: true });
    let buf, ext;
    if (url.startsWith("data:")) {
      const comma = url.indexOf(",");
      buf = Buffer.from(decodeURIComponent(url.slice(comma + 1)));
      ext = "svg";
    } else {
      const r = await fetch(url);
      if (!r.ok) throw new Error("download " + r.status);
      buf = Buffer.from(await r.arrayBuffer());
      const type = (r.headers.get("content-type") || "").split(";")[0];
      ext = EXT[type] || new URL(url).pathname.split(".").pop().slice(0, 4) || "bin";
    }
    const name = `${jobId}-${crypto.randomBytes(6).toString("hex")}.${ext}`;
    await fs.writeFile(`${UPLOAD_DIR}/${name}`, buf);
    return `/files/${name}`;
  } catch (e) {
    console.error("persist failed, keeping provider URL:", e.message);
    return url;
  }
}
AIHUB_EOF_7f3a
cat > 'package.json' <<'AIHUB_EOF_7f3a'
{
  "name": "aihub",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "better-sqlite3": "^11.0.0",
    "dotenv": "^16.4.5",
    "express": "^4.19.2"
  }
}
AIHUB_EOF_7f3a
mkdir -p 'public'
cat > 'public/consent.html' <<'AIHUB_EOF_7f3a'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Permission request</title>
<style>
  :root { --ink:#1b1f24; --paper:#f7f6f3; --line:#d9d6cf; --accent:#2f5d50; --warn:#9b2c2c; }
  * { box-sizing: border-box; }
  body { margin:0; font:16px/1.5 Georgia, "Times New Roman", serif; color:var(--ink); background:var(--paper); }
  main { max-width: 560px; margin: 0 auto; padding: 24px 16px 64px; }
  h1 { font-size: 26px; margin: 0 0 8px; }
  .statement { border:1px solid var(--line); background:#fff; border-radius:6px; padding:12px 14px; font-size:18px; margin:12px 0; }
  .check { display:flex; gap:10px; align-items:flex-start; margin:10px 0; }
  .check input { width:20px; height:20px; margin-top:3px; flex:none; }
  button { font:inherit; width:100%; padding:10px 12px; margin-top:12px; border:1px solid var(--accent); background:var(--accent); color:#fff; border-radius:6px; cursor:pointer; }
  button.ghost { background:transparent; color:var(--ink); border-color:var(--line); }
  button:disabled { opacity:.5; cursor:default; }
  button:focus-visible, input:focus-visible { outline:3px solid #7aa89b; outline-offset:2px; }
  video { width:100%; border-radius:6px; background:#000; margin-top:8px; }
  .err { color:var(--warn); min-height:1.5em; }
  .hidden { display:none; }
</style>
</head>
<body>
<main>
  <h1 id="title">Permission request</h1>
  <p id="lead"></p>
  <section id="form" class="hidden">
    <p>Read this statement aloud when you start recording:</p>
    <div class="statement" id="statement"></div>
    <video id="preview" class="hidden" muted playsinline></video>
    <div id="boxes"></div>
    <button id="rec">Start recording</button>
    <button id="stop" class="hidden">Stop recording</button>
    <button id="send" class="hidden">Send my permission</button>
    <button id="decline" class="ghost">I don't give permission</button>
  </section>
  <section id="done" class="hidden">
    <p id="donemsg"></p>
    <button id="revoke" class="ghost hidden">Withdraw my permission</button>
  </section>
  <p class="err" id="err" role="alert"></p>
</main>
<script src="recorder.js"></script>
<script>
const $ = (id) => document.getElementById(id);
const token = new URLSearchParams(location.search).get("t");
const call = async (path, body) => {
  const r = await fetch(`/api/subject/${token}${path}`, body ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : {});
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(d.error || "Something went wrong.");
  return d;
};
const BOXES = {
  is_me: "I am the person who will be recorded, and this is my own likeness.",
  permission: "I am giving this permission freely. No one pressured or paid me to tick these boxes unless I understand the arrangement.",
  adult: "I am 18 or older.",
  understand: "I understand my %KIND% can be used to create new media, and that I can withdraw permission at any time using this link.",
  terms: "I have read the acceptable use rules and agree not to use this to deceive or harm anyone.",
};
let recorder, result, view;

function show(v) {
  view = v;
  $("title").textContent = v.kind === "voice" ? "Voice permission request" : "Face permission request";
  $("lead").textContent = `${v.requester} asked to use ${v.kind === "voice" ? "your voice" : "your face"} for AI-generated media on their account. Only continue if you know this person and agree.`;
  const open = v.status === "awaiting_capture";
  $("form").classList.toggle("hidden", !open);
  $("done").classList.toggle("hidden", open);
  if (open) {
    $("statement").textContent = v.challenge;
    $("boxes").innerHTML = Object.entries(BOXES).map(([k, t]) =>
      `<label class="check"><input type="checkbox" data-k="${k}"> <span>${t.replace("%KIND%", v.kind === "voice" ? "voice" : "face")}</span></label>`).join("");
    if (v.kind === "face") $("preview").classList.remove("hidden");
  } else {
    const msgs = {
      pending_review: "Thank you. Your recording was received and will be checked before anything is generated.",
      approved: "Your permission is recorded and active.",
      rejected: "This request wasn't approved. Nothing will be generated.",
      revoked: "This permission is withdrawn. Nothing will be generated from your likeness.",
    };
    $("donemsg").textContent = msgs[v.status] || "";
    $("revoke").classList.toggle("hidden", !["approved", "pending_review"].includes(v.status));
  }
}

$("rec").onclick = async () => {
  $("err").textContent = "";
  try {
    recorder = makeRecorder($("preview"), view.kind === "face");
    await recorder.start();
    $("rec").classList.add("hidden"); $("stop").classList.remove("hidden");
  } catch { $("err").textContent = "Allow camera and microphone access to continue."; }
};
$("stop").onclick = async () => {
  result = await recorder.stop();
  $("stop").classList.add("hidden"); $("send").classList.remove("hidden");
  $("rec").classList.remove("hidden"); $("rec").textContent = "Record again";
};
$("send").onclick = async () => {
  const attest = {};
  document.querySelectorAll("#boxes input").forEach((b) => (attest[b.dataset.k] = b.checked));
  try {
    const data = await blobToBase64(result.blob);
    const still = result.still;
    show(await call("/capture", { data, mime: result.blob.type, still, attest }));
  } catch (e) { $("err").textContent = e.message; }
};
$("decline").onclick = async () => { await call("/decline", {}); show({ ...view, status: "revoked" }); };
$("revoke").onclick = async () => { await call("/revoke", {}); show({ ...view, status: "revoked" }); };

if (!token) $("lead").textContent = "This link isn't valid.";
else call("").then(show).catch((e) => { $("lead").textContent = e.message; });
</script>
</body>
</html>
AIHUB_EOF_7f3a
mkdir -p 'public'
cat > 'public/index.html' <<'AIHUB_EOF_7f3a'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Studio</title>
<style>
  :root { --ink:#1b1f24; --paper:#f7f6f3; --line:#d9d6cf; --accent:#2f5d50; --warn:#9b2c2c; }
  * { box-sizing: border-box; }
  body { margin:0; font:16px/1.5 Georgia, "Times New Roman", serif; color:var(--ink); background:var(--paper); }
  main { max-width: 640px; margin: 0 auto; padding: 24px 16px 64px; }
  h1 { font-size: 28px; margin: 0 0 4px; }
  .sub { color:#5b6168; margin:0 0 24px; }
  label { display:block; font-weight:bold; margin:16px 0 6px; }
  input, select, textarea, button { font:inherit; width:100%; padding:10px 12px; border:1px solid var(--line); border-radius:6px; background:#fff; }
  textarea { min-height: 96px; resize: vertical; }
  button { background:var(--accent); color:#fff; border-color:var(--accent); cursor:pointer; margin-top:16px; }
  button.ghost { background:transparent; color:var(--ink); border-color:var(--line); }
  button:focus-visible, input:focus-visible, select:focus-visible, textarea:focus-visible { outline:3px solid #7aa89b; outline-offset:2px; }
  .bar { display:flex; justify-content:space-between; align-items:center; margin-bottom:16px; }
  .bar button { width:auto; margin:0; }
  .err { color:var(--warn); min-height:1.5em; }
  .job { border-top:1px solid var(--line); padding:16px 0; }
  .job img, .job video { width:100%; border-radius:6px; margin-top:8px; }
  .meta { color:#5b6168; font-size:14px; }
  .hidden { display:none; }
  details { border:1px solid var(--line); border-radius:6px; padding:10px 12px; margin-top:16px; background:#fff; }
  summary { cursor:pointer; font-weight:bold; }
  .statement { border:1px solid var(--line); border-radius:6px; padding:10px 12px; margin:8px 0; background:var(--paper); }
  .check { display:flex; gap:10px; align-items:flex-start; margin:8px 0; }
  .check input { width:20px; height:20px; margin-top:3px; flex:none; }
  .crow { border-top:1px solid var(--line); padding:10px 0; }
  .crow button { width:auto; margin:6px 8px 0 0; padding:6px 10px; }
  #cpreview { width:100%; border-radius:6px; background:#000; }
</style>
</head>
<body>
<main>
  <h1>Studio</h1>
  <p class="sub">Generate images and video from a prompt.</p>

  <section id="auth">
    <label for="email">Email</label>
    <input id="email" type="email" autocomplete="email">
    <label for="pw">Password</label>
    <input id="pw" type="password" autocomplete="current-password">
    <button id="login">Log in</button>
    <button id="signup" class="ghost">Create account</button>
    <p class="err" id="autherr" role="alert"></p>
  </section>

  <section id="app" class="hidden">
    <p class="meta hidden" id="mockbanner">Test mode: outputs are placeholders and nothing is charged.</p>
    <div class="bar"><span id="credits"></span><button class="ghost" id="logout">Log out</button></div>
    <label>Add credits</label>
    <div id="packs" style="display:flex;gap:8px"></div>
    <details id="likeness">
      <summary>Face and voice permissions</summary>
      <p class="meta" id="idstatus"></p>
      <button class="ghost" id="verify">Verify my identity</button>
      <div id="consents"></div>
      <label for="ckind">Create a permission</label>
      <select id="ckind"><option value="voice">Voice</option><option value="face">Face</option></select>
      <select id="crel" style="margin-top:8px"><option value="self">My own</option><option value="other">Someone else's</option></select>
      <input id="cname" placeholder="Full name of the person" style="margin-top:8px">
      <div id="cboxes"></div>
      <button id="ccreate">Create permission</button>
      <div id="capture" class="hidden">
        <p>Read this aloud when you start recording:</p>
        <div class="statement" id="cstatement"></div>
        <video id="cpreview" class="hidden" muted playsinline></video>
        <div id="cboxes2"></div>
        <button id="crec">Start recording</button>
        <button id="cstop" class="hidden">Stop recording</button>
        <button id="csend" class="hidden">Submit recording</button>
      </div>
      <p class="err" id="cerr" role="alert"></p>
    </details>

    <label for="model">Model</label>
    <select id="model"></select>
    <div id="consentpick" class="hidden">
      <label for="consentsel">Permission to use</label>
      <select id="consentsel"></select>
      <div id="imgwrap" class="hidden">
        <label for="imageurl">Image to swap the face onto (link)</label>
        <input id="imageurl" inputmode="url">
      </div>
    </div>
    <label for="prompt">Prompt</label>
    <textarea id="prompt" maxlength="2000"></textarea>
    <button id="go">Generate</button>
    <p class="err" id="generr" role="alert"></p>
    <div id="jobs"></div>
  </section>
</main>
<script src="recorder.js"></script>
<script>
const $ = (id) => document.getElementById(id);
let token = localStorage.getItem("token");
const api = async (path, opts = {}) => {
  const r = await fetch("/api" + path, {
    ...opts,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: "Bearer " + token } : {}) },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || "Something went wrong.");
  return data;
};

async function auth(kind) {
  try {
    const d = await api("/" + kind, { method: "POST", body: { email: $("email").value, password: $("pw").value } });
    token = d.token; localStorage.setItem("token", token); boot();
  } catch (e) { $("autherr").textContent = e.message; }
}
$("login").onclick = () => auth("login");
$("signup").onclick = () => auth("signup");
$("logout").onclick = () => { localStorage.removeItem("token"); token = null; location.reload(); };

$("go").onclick = async () => {
  $("generr").textContent = "";
  try {
    await api("/generate", { method: "POST", body: { model: $("model").value, prompt: $("prompt").value, consentId: $("consentsel").value || undefined, imageUrl: $("imageurl").value || undefined } });
    $("prompt").value = ""; refresh();
  } catch (e) { $("generr").textContent = e.message; }
};

const msg = { queued:"Waiting to start", in_progress:"Generating", failed:"Failed. Credits refunded.", nsfw:"Blocked by content rules. Credits refunded.", canceled:"Canceled. Credits refunded." };
async function refresh() {
  const { jobs, credits } = await api("/jobs");
  $("credits").textContent = "Credits: $" + (credits / 100).toFixed(2);
  $("jobs").innerHTML = "";
  for (const j of jobs) {
    const d = document.createElement("div"); d.className = "job";
    const t = document.createElement("div"); t.textContent = j.prompt;
    const m = document.createElement("div"); m.className = "meta"; m.textContent = j.model_key + " · " + (msg[j.status] || "Done");
    d.append(t, m);
    if (j.output_url) {
      const isVideo = /\.(mp4|mov|webm)(\?|$)/i.test(j.output_url);
      const el = document.createElement(isVideo ? "video" : "img");
      el.src = j.output_url; if (isVideo) { el.controls = true; } else { el.alt = j.prompt; }
      d.append(el);
    }
    $("jobs").append(d);
  }
}

$("packs").onclick = async (e) => {
  const cents = e.target.dataset?.cents; if (!cents) return;
  try {
    const d = await api("/checkout", { method: "POST", body: { cents: Number(cents) } });
    if (d.url) location.href = d.url; else refresh();
  } catch (err) { $("generr").textContent = err.message; }
};

// ---------- face and voice permissions ----------
let models = [], consents = [], activeConsent = null, crecorder, cresult;
const OWNER = {
  self: { is_me: "This is my own likeness.", no_deception: "I won't use it to deceive or impersonate anyone.", adult: "I am 18 or older.", terms: "I accept the acceptable use rules." },
  other: { asked_permission: "I asked this person and they agreed to be recorded.", not_public_figure: "They are not a public figure, or I hold their written agreement.", no_deception: "I won't use it to deceive or impersonate anyone.", adult: "This person is 18 or older.", terms: "I accept the acceptable use rules." },
};
const SUBJ = { is_me: "I am the person being recorded.", permission: "I give this permission freely.", adult: "I am 18 or older.", understand: "I understand I can withdraw it at any time.", terms: "I accept the acceptable use rules." };
const boxes = (el, defs) => { el.innerHTML = Object.entries(defs).map(([k, t]) => `<label class="check"><input type="checkbox" data-k="${k}"><span>${t}</span></label>`).join(""); };
const read = (el) => { const o = {}; el.querySelectorAll("input").forEach((b) => (o[b.dataset.k] = b.checked)); return o; };
const STATUS = { awaiting_capture: "Waiting for recording", pending_review: "Being reviewed", approved: "Approved", rejected: "Not approved", revoked: "Withdrawn" };

async function loadLikeness() {
  const id = await api("/identity");
  $("idstatus").textContent = id.status === "verified" ? "Identity verified." : "Verify your identity before you can create a permission.";
  $("verify").classList.toggle("hidden", id.status === "verified");
  consents = await api("/consents");
  $("consents").innerHTML = "";
  for (const c of consents) {
    const d = document.createElement("div"); d.className = "crow";
    d.textContent = `${c.kind === "voice" ? "Voice" : "Face"}: ${c.subjectName} (${STATUS[c.status]})`;
    if (c.status === "awaiting_capture" && c.relation === "self") {
      const b = document.createElement("button"); b.textContent = "Record now"; b.onclick = () => openCapture(c); d.append(document.createElement("br"), b);
    }
    if (c.link) {
      const p = document.createElement("div"); p.className = "meta"; p.textContent = "Send this link to " + c.subjectName + ": " + location.origin + c.link; d.append(p);
    }
    if (c.status !== "revoked") {
      const r = document.createElement("button"); r.className = "ghost"; r.textContent = "Withdraw"; r.onclick = async () => { await api(`/consents/${c.id}/revoke`, { method: "POST", body: {} }); loadLikeness(); }; d.append(r);
    }
    $("consents").append(d);
  }
  updateConsentPick();
}
function updateConsentPick() {
  const m = models.find((x) => x.key === $("model").value);
  const need = m?.needsConsent;
  $("consentpick").classList.toggle("hidden", !need);
  $("imgwrap").classList.toggle("hidden", need !== "face");
  if (!need) { $("consentsel").innerHTML = ""; return; }
  const ok = consents.filter((c) => c.kind === need && c.status === "approved");
  $("consentsel").innerHTML = ok.length ? ok.map((c) => `<option value="${c.id}">${c.subjectName}</option>`).join("") : `<option value="">No approved permission yet</option>`;
}
$("model").onchange = updateConsentPick;
$("verify").onclick = async () => { try { await api("/identity/start", { method: "POST", body: {} }); loadLikeness(); } catch (e) { $("cerr").textContent = e.message; } };
const renderCboxes = () => boxes($("cboxes"), OWNER[$("crel").value]);
$("crel").onchange = renderCboxes; renderCboxes();
$("ccreate").onclick = async () => {
  $("cerr").textContent = "";
  try {
    const c = await api("/consents", { method: "POST", body: { kind: $("ckind").value, relation: $("crel").value, subjectName: $("cname").value, attest: read($("cboxes")) } });
    $("cname").value = ""; await loadLikeness();
    if (c.relation === "self") openCapture(c);
  } catch (e) { $("cerr").textContent = e.message; }
};
function openCapture(c) {
  activeConsent = c; cresult = null;
  $("capture").classList.remove("hidden");
  $("cstatement").textContent = c.challenge;
  $("cpreview").classList.toggle("hidden", c.kind !== "face");
  boxes($("cboxes2"), SUBJ);
  $("crec").classList.remove("hidden"); $("cstop").classList.add("hidden"); $("csend").classList.add("hidden");
  $("capture").scrollIntoView({ behavior: "smooth" });
}
$("crec").onclick = async () => {
  $("cerr").textContent = "";
  try { crecorder = makeRecorder($("cpreview"), activeConsent.kind === "face"); await crecorder.start(); $("crec").classList.add("hidden"); $("cstop").classList.remove("hidden"); }
  catch { $("cerr").textContent = "Allow camera and microphone access to continue."; }
};
$("cstop").onclick = async () => { cresult = await crecorder.stop(); $("cstop").classList.add("hidden"); $("csend").classList.remove("hidden"); $("crec").classList.remove("hidden"); $("crec").textContent = "Record again"; };
$("csend").onclick = async () => {
  try {
    const data = await blobToBase64(cresult.blob);
    await api(`/consents/${activeConsent.id}/capture`, { method: "POST", body: { data, mime: cresult.blob.type, still: cresult.still, attest: read($("cboxes2")) } });
    $("capture").classList.add("hidden"); loadLikeness();
  } catch (e) { $("cerr").textContent = e.message; }
};

async function boot() {
  if (!token) return;
  try {
    models = await api("/models");
    $("model").innerHTML = models.map(m => `<option value="${m.key}" ${m.enabled ? "" : "disabled"}>${m.label} · $${(m.price/100).toFixed(2)}${m.enabled ? "" : " (coming soon)"}</option>`).join("");
    const cfg = await api("/config");
    $("mockbanner").classList.toggle("hidden", !cfg.mock);
    $("packs").innerHTML = cfg.packs.map(c => `<button class="ghost" style="margin:0" data-cents="${c}">$${c/100}</button>`).join("");
    $("auth").classList.add("hidden"); $("app").classList.remove("hidden");
    refresh(); loadLikeness(); setInterval(refresh, 5000); setInterval(loadLikeness, 15000);
  } catch { localStorage.removeItem("token"); token = null; }
}
boot();
</script>
</body>
</html>
AIHUB_EOF_7f3a
mkdir -p 'public'
cat > 'public/recorder.js' <<'AIHUB_EOF_7f3a'
// Shared by index.html and consent.html. Records a short clip from the camera/mic.
window.makeRecorder = function (previewEl, wantVideo) {
  let stream, rec, done, stillB64 = null;
  const chunks = [];
  const pickMime = () => {
    const list = wantVideo ? ["video/webm", "video/mp4"] : ["audio/webm", "audio/mp4", "audio/ogg"];
    return list.find((m) => window.MediaRecorder && MediaRecorder.isTypeSupported(m));
  };
  const grabStill = () => {
    if (!wantVideo || !previewEl.videoWidth) return;
    const c = document.createElement("canvas");
    c.width = previewEl.videoWidth; c.height = previewEl.videoHeight;
    c.getContext("2d").drawImage(previewEl, 0, 0);
    stillB64 = c.toDataURL("image/jpeg", 0.9).split(",")[1];
  };
  return {
    async start() {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: wantVideo ? { facingMode: "user" } : false });
      if (wantVideo) { previewEl.srcObject = stream; await previewEl.play(); }
      rec = new MediaRecorder(stream, pickMime() ? { mimeType: pickMime() } : undefined);
      done = new Promise((res) => {
        rec.ondataavailable = (e) => e.data.size && chunks.push(e.data);
        rec.onstop = () => {
          stream.getTracks().forEach((t) => t.stop());
          previewEl.srcObject = null;
          res({ blob: new Blob(chunks, { type: rec.mimeType }), still: stillB64 });
        };
      });
      rec.start();
      setTimeout(grabStill, 1500);
      setTimeout(() => rec.state === "recording" && rec.stop(), 25000); // hard stop at 25s
    },
    stop() { if (rec && rec.state === "recording") rec.stop(); return done; },
  };
};
window.blobToBase64 = (blob) =>
  new Promise((res, rej) => {
    const r = new FileReader();
    r.onload = () => res(String(r.result).split(",")[1]);
    r.onerror = rej;
    r.readAsDataURL(blob);
  });
AIHUB_EOF_7f3a
cat > 'server.js' <<'AIHUB_EOF_7f3a'
import "dotenv/config";
import crypto from "node:crypto";
import express from "express";
import { db, charge, grant, refundJob } from "./lib/db.js";
import { submit, getStatus, extractOutput, MOCK } from "./lib/provider.js";
import { persist, UPLOAD_DIR } from "./lib/storage.js";
import consentRouter from "./lib/consentRoutes.js";
import { assertUsable, logEvent } from "./lib/consent.js";
import { PACKS, stripeEnabled, createCheckout, verifyWebhook } from "./lib/payments.js";
import { publicCatalog, findModel } from "./lib/models.js";
import { screenPrompt } from "./lib/moderation.js";

const app = express();
// Stripe webhook needs the raw body, so it is registered before express.json().
app.post("/api/stripe/webhook", express.raw({ type: "application/json" }), (req, res) => {
  const raw = req.body.toString("utf8");
  if (!verifyWebhook(raw, req.headers["stripe-signature"], process.env.STRIPE_WEBHOOK_SECRET))
    return res.status(400).end();
  const event = JSON.parse(raw);
  const s = event.data?.object;
  if (event.type === "checkout.session.completed" && s?.payment_status === "paid") {
    const userId = Number(s.metadata?.user_id);
    const cents = Number(s.metadata?.cents);
    try {
      db.prepare("INSERT INTO payments (session_id, user_id, cents, created_at) VALUES (?,?,?,?)").run(s.id, userId, cents, Date.now());
      grant(userId, cents, "stripe:" + s.id);
    } catch { /* duplicate delivery: already credited */ }
  }
  res.json({ received: true });
});

app.use(consentRouter({ requireUser }));
app.use(express.json({ limit: "1mb" }));
app.use("/files", express.static(UPLOAD_DIR));
app.use(express.static("public"));

const now = () => Date.now();
const hashPw = (pw, salt) => crypto.scryptSync(pw, salt, 64).toString("hex");

// ---------- auth ----------
function startSession(userId) {
  const token = crypto.randomBytes(32).toString("hex");
  db.prepare("INSERT INTO sessions (token, user_id, created_at) VALUES (?,?,?)").run(token, userId, now());
  return token;
}

function requireUser(req, res, next) {
  const token = (req.headers.authorization || "").replace("Bearer ", "");
  const row = token && db.prepare("SELECT user_id FROM sessions WHERE token = ?").get(token);
  if (!row) return res.status(401).json({ error: "Please log in." });
  req.user = db.prepare("SELECT id, email, credits FROM users WHERE id = ?").get(row.user_id);
  next();
}

app.post("/api/signup", (req, res) => {
  const { email, password } = req.body || {};
  if (!email || !password || password.length < 8)
    return res.status(400).json({ error: "Enter an email and a password of at least 8 characters." });
  const salt = crypto.randomBytes(16).toString("hex");
  try {
    const r = db
      .prepare("INSERT INTO users (email, salt, pass_hash, created_at) VALUES (?,?,?,?)")
      .run(email.toLowerCase(), salt, hashPw(password, salt), now());
    res.json({ token: startSession(r.lastInsertRowid) });
  } catch {
    res.status(409).json({ error: "That email is already registered." });
  }
});

app.post("/api/login", (req, res) => {
  const { email, password } = req.body || {};
  const u = db.prepare("SELECT * FROM users WHERE email = ?").get((email || "").toLowerCase());
  const ok =
    u && crypto.timingSafeEqual(Buffer.from(hashPw(password || "", u.salt)), Buffer.from(u.pass_hash));
  if (!ok) return res.status(401).json({ error: "Wrong email or password." });
  res.json({ token: startSession(u.id) });
});

app.get("/api/me", requireUser, (req, res) => res.json(req.user));
app.get("/api/config", (_req, res) =>
  res.json({ mock: MOCK, packs: PACKS, fakePayments: !stripeEnabled() && process.env.NODE_ENV !== "production" })
);

app.post("/api/checkout", requireUser, async (req, res) => {
  const cents = Number(req.body?.cents);
  if (!PACKS.includes(cents)) return res.status(400).json({ error: "Choose a listed amount." });
  if (stripeEnabled()) {
    try {
      const base = process.env.BASE_URL || `http://localhost:${process.env.PORT || 3000}`;
      return res.json({ url: await createCheckout({ userId: req.user.id, cents, baseUrl: base }) });
    } catch (e) {
      console.error(e);
      return res.status(502).json({ error: "Checkout couldn't start. Try again." });
    }
  }
  if (process.env.NODE_ENV === "production") return res.status(503).json({ error: "Payments aren't set up." });
  grant(req.user.id, cents, "fake-payment"); // dev only: no Stripe keys configured
  res.json({ granted: true });
});

app.get("/api/models", (_req, res) => res.json(publicCatalog()));

// ---------- generation ----------
app.post("/api/generate", requireUser, async (req, res) => {
  const { model: modelKey, prompt, imageUrl, consentId } = req.body || {};
  const model = findModel(modelKey);
  if (!model) return res.status(400).json({ error: "That model isn't available yet." });

  const screen = screenPrompt(prompt);
  if (!screen.ok) return res.status(400).json({ error: screen.reason });

  if (model.needsConsent) {
    const gate = assertUsable(req.user.id, consentId, model.needsConsent);
    if (!gate.ok) return res.status(403).json({ error: gate.error });
    if (model.needsConsent === "face" && !imageUrl) return res.status(400).json({ error: "Add the image to swap onto." });
  }

  // 1. Create the job row, 2. take credits, 3. call the provider. Refund if step 3 throws.
  const jobId = db
    .prepare(
      "INSERT INTO jobs (user_id, model_key, prompt, status, cost, created_at, updated_at, consent_id) VALUES (?,?,?,?,?,?,?,?)"
    )
    .run(req.user.id, model.key, prompt, "queued", model.price, now(), now(), model.needsConsent ? Number(consentId) : null).lastInsertRowid;
  if (model.needsConsent) logEvent(Number(consentId), "used", `job ${jobId}`);

  if (!charge(req.user.id, model.price, jobId, `generate:${model.key}`)) {
    db.prepare("DELETE FROM jobs WHERE id = ?").run(jobId);
    return res.status(402).json({ error: "Not enough credits." });
  }

  try {
    const r = await submit(model.path, model.body({ prompt, imageUrl }), `job-${jobId}`);
    db.prepare("UPDATE jobs SET request_id=?, status_url=?, status=?, updated_at=? WHERE id=?")
      .run(r.request_id, r.status_url, r.status, now(), jobId);
    res.json({ jobId });
  } catch (e) {
    console.error(e);
    db.prepare("UPDATE jobs SET status='failed', updated_at=? WHERE id=?").run(now(), jobId);
    refundJob(jobId);
    res.status(502).json({ error: "Generation couldn't start. You weren't charged." });
  }
});

app.get("/api/jobs", requireUser, (req, res) => {
  const jobs = db
    .prepare(
      "SELECT id, model_key, prompt, status, output_url, created_at FROM jobs WHERE user_id = ? ORDER BY id DESC LIMIT 50"
    )
    .all(req.user.id);
  res.json({ jobs, credits: req.user.credits });
});

// ---------- poller: settles jobs and refunds failures ----------
const TERMINAL_FAIL = new Set(["failed", "nsfw", "canceled"]);
let polling = false;
setInterval(async () => {
  if (polling) return;
  polling = true;
  try {
    const active = db
      .prepare("SELECT * FROM jobs WHERE status IN ('queued','in_progress') AND status_url IS NOT NULL")
      .all();
    for (const job of active) {
      try {
        const r = await getStatus(job.status_url);
        if (r.status === job.status) continue;
        const out = r.status === "completed" ? extractOutput(r) : null;
        const stored = out ? await persist(out, job.id) : null;
        db.prepare("UPDATE jobs SET status=?, output_url=?, updated_at=? WHERE id=?")
          .run(r.status, stored, now(), job.id);
        if (TERMINAL_FAIL.has(r.status)) refundJob(job.id);
      } catch (e) {
        console.error("poll error", job.id, e.message);
      }
    }
  } finally {
    polling = false;
  }
}, 4000);

// ---------- manual credits until Stripe is added ----------
app.post("/api/admin/grant", (req, res) => {
  if (req.headers["x-admin-token"] !== process.env.ADMIN_TOKEN) return res.status(403).end();
  const u = db.prepare("SELECT id FROM users WHERE email = ?").get((req.body.email || "").toLowerCase());
  if (!u) return res.status(404).json({ error: "No such user." });
  grant(u.id, Math.round(req.body.cents), "admin-grant");
  res.json({ ok: true });
});

app.listen(process.env.PORT || 3000, () => console.log("Running on :" + (process.env.PORT || 3000)));
AIHUB_EOF_7f3a
echo "Done. Next: cd aihub && npm install && npm start"
