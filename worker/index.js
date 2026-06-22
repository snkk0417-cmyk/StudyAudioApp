/**
 * Cloudflare Worker — feedback → GitHub Issue bridge.
 *
 * Receives the JSON payload POSTed by the Flutter app (see
 * lib/services/feedback_service.dart) and opens a GitHub Issue server-side using
 * a Personal Access Token that never leaves this Worker.
 *
 * Endpoint (matches the Flutter client): POST /feedback
 *
 * Required environment bindings (set via `wrangler secret` / dashboard):
 *   GITHUB_TOKEN  — secret. PAT with `repo` scope (classic) or `issues:write`
 *                   (fine-grained) on the target repo. NEVER hard-code.
 *   GITHUB_REPO   — plain var, "owner/name" e.g. "snkk0417-cmyk/StudyAudioApp".
 *
 * Contract with the app:
 *   - 201 Created on success (app shows 「送信しました」)
 *   - any non-2xx → app persists locally and retries (offline queue), so we
 *     return 500 on any server/GitHub failure rather than leaking details.
 */

const GITHUB_API = 'https://api.github.com';

export default {
  async fetch(request, env) {
    // Only POST /feedback is meaningful; everything else is a quick reject.
    if (request.method === 'OPTIONS') {
      return cors(new Response(null, { status: 204 }));
    }
    if (request.method !== 'POST') {
      return cors(json(405, { error: 'method_not_allowed' }));
    }

    let payload;
    try {
      payload = await request.json();
    } catch (_) {
      // Malformed body. This is a client error, but the app treats any non-2xx
      // identically (queue + retry); 400 keeps the cause honest in logs.
      return cors(json(400, { error: 'invalid_json' }));
    }

    try {
      const issue = buildIssue(payload);
      const created = await createGitHubIssue(env, issue);
      return cors(json(201, {
        ok: true,
        issue_number: created.number,
        issue_url: created.html_url,
      }));
    } catch (err) {
      // Single funnel for "could not create the issue" — config error, GitHub
      // outage, auth failure, etc. The app only needs to know it failed.
      console.error('feedback worker failure:', err && err.stack ? err.stack : err);
      return cors(json(500, { error: 'issue_creation_failed' }));
    }
  },
};

/**
 * Turn a feedback payload into { title, body, labels }.
 *
 * Title:
 *   lecture → "[category] <topic_jp>"        e.g. "[reading_mistake] RC梁"
 *   general → "[category] General Feedback"  e.g. "[app_bug] General Feedback"
 */
function buildIssue(p) {
  const category = str(p.category) || 'unknown';
  const isLecture = p.type === 'lecture';

  const titleSubject = isLecture
    ? (str(p.topic_jp) || str(p.topic) || 'Lecture')
    : 'General Feedback';
  const title = `[${category}] ${titleSubject}`;

  // Labels let GitHub triage by category + priority. Unknown values still create
  // labels on first use, which is fine.
  const labels = ['feedback', `category:${category}`];
  if (p.priority) labels.push(`priority:${str(p.priority)}`);
  if (p.type) labels.push(`type:${str(p.type)}`);

  const body = buildBody(p);
  return { title, body, labels };
}

/**
 * Render EVERY payload field into the issue body. Required fields are always
 * shown (— when absent); free-text fields are fenced so markdown can't break
 * the layout.
 */
function buildBody(p) {
  const rows = [
    ['category', p.category],
    ['priority', p.priority],
    ['type', p.type],
    ['subject', p.subject],
    ['topic', p.topic],
    ['topic_jp', p.topic_jp],
    ['content_type', p.content_type],
    ['position_seconds', p.position_seconds],
    ['timestamp', p.timestamp],
    ['app_version', p.app_version],
  ];

  const table = [
    '| Field | Value |',
    '| --- | --- |',
    ...rows.map(([k, v]) => `| ${k} | ${cell(v)} |`),
  ].join('\n');

  const parts = ['### Metadata', '', table, ''];

  parts.push('### Comment', '', fence(p.comment), '');

  // Optional in the payload; only emitted when the track had bundled text.
  if (str(p.transcript_excerpt)) {
    parts.push('### Transcript excerpt', '', fence(p.transcript_excerpt), '');
  }

  parts.push(
    '---',
    `_Filed automatically from app v${cell(p.app_version)} via the feedback Worker._`,
  );

  return parts.join('\n');
}

/** POST the issue to GitHub. Throws on any non-2xx so the caller returns 500. */
async function createGitHubIssue(env, issue) {
  const token = env.GITHUB_TOKEN;
  const repo = env.GITHUB_REPO; // "owner/name"
  if (!token) throw new Error('GITHUB_TOKEN binding is missing');
  if (!repo || !repo.includes('/')) {
    throw new Error('GITHUB_REPO must be set as "owner/name"');
  }

  const res = await fetch(`${GITHUB_API}/repos/${repo}/issues`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      // GitHub rejects requests without a User-Agent.
      'User-Agent': 'studyaudioapp-feedback-worker',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      title: issue.title,
      body: issue.body,
      labels: issue.labels,
    }),
  });

  if (res.status < 200 || res.status >= 300) {
    const detail = await res.text().catch(() => '');
    throw new Error(`GitHub API ${res.status}: ${detail.slice(0, 500)}`);
  }
  return res.json();
}

// --- small helpers -------------------------------------------------------

/** Coerce to a trimmed string, or '' for null/undefined. */
function str(v) {
  if (v === null || v === undefined) return '';
  return String(v).trim();
}

/** Table-cell value: em dash for empty, single-line-safe (escape pipes). */
function cell(v) {
  const s = str(v);
  if (!s) return '—';
  return s.replace(/\|/g, '\\|').replace(/\n/g, ' ');
}

/** Fence free text so markdown/HTML in user input can't break the issue body. */
function fence(v) {
  const s = str(v);
  if (!s) return '_(empty)_';
  // Avoid premature fence termination if the text itself contains backticks.
  const fenceMark = s.includes('```') ? '~~~' : '```';
  return `${fenceMark}\n${s}\n${fenceMark}`;
}

function json(status, obj) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/** Permissive CORS — harmless for the mobile client, handy for browser tests. */
function cors(res) {
  res.headers.set('Access-Control-Allow-Origin', '*');
  res.headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.headers.set('Access-Control-Allow-Headers', 'Content-Type');
  return res;
}
