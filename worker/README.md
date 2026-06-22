# Feedback Worker

A Cloudflare Worker that receives feedback JSON from the Flutter app and opens a
GitHub Issue server-side. The GitHub Personal Access Token (PAT) lives only as a
Worker secret — it is never shipped in the app.

```
Flutter app  ──POST /feedback (JSON)──▶  Cloudflare Worker  ──GitHub API──▶  Issue
                                         (holds the PAT)
```

- **201 Created** → app shows 「送信しました」
- any **non-2xx** → app saves locally and auto-retries (offline queue)

The Worker maps the payload to an issue as follows:

| Payload `type` | Issue title                         | Example                        |
| -------------- | ----------------------------------- | ------------------------------ |
| `lecture`      | `[<category>] <topic_jp>`            | `[reading_mistake] RC梁`        |
| `general`      | `[<category>] General Feedback`     | `[app_bug] General Feedback`   |

The issue body renders **every** payload field (category, priority, type,
subject, topic, topic_jp, content_type, position_seconds, timestamp,
app_version) as a metadata table, plus the comment and the optional
transcript excerpt in fenced blocks. Labels `feedback`, `category:<…>`,
`priority:<…>`, `type:<…>` are attached for triage.

---

## Files

| File             | Purpose                                              |
| ---------------- | ---------------------------------------------------- |
| `index.js`       | Worker entry point (`export default { fetch }`).     |
| `wrangler.toml`  | Worker config (create per step 2 below).             |

---

## Prerequisites

- A [Cloudflare account](https://dash.cloudflare.com/sign-up) (free tier is fine).
- Node.js + the Wrangler CLI: `npm install -g wrangler` (or use `npx wrangler`).
- A GitHub PAT (see step 3).

---

## Deployment

### 1. Authenticate Wrangler with Cloudflare

```bash
wrangler login
```

This opens a browser to authorize the CLI. (In a headless session, run it
yourself via the `! wrangler login` prompt.)

### 2. Create `worker/wrangler.toml`

```toml
name = "studyaudioapp-feedback"
main = "index.js"
compatibility_date = "2024-11-01"

# Public, non-secret config. The repo to file issues into.
[vars]
GITHUB_REPO = "snkk0417-cmyk/StudyAudioApp"

# GITHUB_TOKEN is NOT here — it is a secret, set in step 4.
```

> Do **not** put `GITHUB_TOKEN` in `wrangler.toml` or any committed file. It is a
> secret and goes in via `wrangler secret put` only.

### 3. Create a GitHub Personal Access Token

Pick one:

- **Fine-grained** (recommended): GitHub → Settings → Developer settings →
  Fine-grained tokens. Scope it to **only** `snkk0417-cmyk/StudyAudioApp`, with
  **Repository permissions → Issues: Read and write**.
- **Classic**: scope `repo` (or `public_repo` if the repo is public).

Copy the token once — GitHub won't show it again.

### 4. Store the token as a Worker secret

```bash
cd worker
wrangler secret put GITHUB_TOKEN
# paste the PAT when prompted
```

The secret is encrypted at rest and injected as `env.GITHUB_TOKEN` at runtime.

### 5. Deploy

```bash
wrangler deploy
```

Wrangler prints the live URL, e.g.:

```
https://studyaudioapp-feedback.<your-subdomain>.workers.dev
```

Your endpoint is that URL **plus `/feedback`**:

```
https://studyaudioapp-feedback.<your-subdomain>.workers.dev/feedback
```

### 6. Smoke-test before touching the app

Lecture feedback (expect HTTP 201 + a new issue):

```bash
curl -i -X POST \
  https://studyaudioapp-feedback.<your-subdomain>.workers.dev/feedback \
  -H 'Content-Type: application/json' \
  -d '{
    "type": "lecture",
    "category": "reading_mistake",
    "priority": "high",
    "app_version": "1.0.0",
    "subject": "structure",
    "topic": "rc_beam",
    "topic_jp": "RC梁",
    "content_type": "deep",
    "position_seconds": 220,
    "timestamp": "3:40",
    "transcript_excerpt": "梁の主筋は…",
    "comment": "「はり」を「うつばり」と誤読しています"
  }'
```

General feedback:

```bash
curl -i -X POST \
  https://studyaudioapp-feedback.<your-subdomain>.workers.dev/feedback \
  -H 'Content-Type: application/json' \
  -d '{
    "type": "general",
    "category": "app_bug",
    "priority": "medium",
    "app_version": "1.0.0",
    "comment": "再生位置が時々リセットされます"
  }'
```

A `201` with `{"ok":true,"issue_number":…,"issue_url":…}` and a freshly opened
issue in the repo means the backend is live.

### 7. Point the app at it (separate task — not done yet)

Once verified, update `defaultEndpoint` in
`lib/services/feedback_service.dart` to the `/feedback` URL from step 5 and ship.
**The Flutter code is intentionally left unchanged for now.**

---

## Local development

```bash
cd worker
wrangler dev          # serves on http://localhost:8787
```

`wrangler dev` reads secrets from a local `.dev.vars` file (git-ignored):

```
GITHUB_TOKEN=ghp_xxx
```

Then POST to `http://localhost:8787/feedback`.

---

## Troubleshooting

| Symptom (response)            | Likely cause                                            |
| ----------------------------- | ------------------------------------------------------- |
| `500 issue_creation_failed`   | Missing/invalid `GITHUB_TOKEN`, wrong `GITHUB_REPO`, or token lacks Issues write. Check `wrangler tail` logs. |
| `400 invalid_json`            | Body wasn't valid JSON.                                 |
| `405 method_not_allowed`      | Used GET instead of POST.                               |
| GitHub `403` in logs          | Token scope/permissions or rate limit.                  |
| GitHub `404` in logs          | `GITHUB_REPO` wrong, or fine-grained token not granted on that repo. |

Stream live logs while testing:

```bash
wrangler tail
```
