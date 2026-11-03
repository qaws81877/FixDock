// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 FixDock contributors

// Holds the Discord webhooks so the app never ships them. The app posts
// {"note": "...", "report": "..."} to /bug or /idea. The report goes to
// Discord as a file and mentions are off, so nothing in it can ping anyone.
// Both webhooks belong to forum channels: each report opens its own post.

const MAX_TEXT = 64 * 1024;
// Korean is 3 bytes per character in UTF-8; JSON adds escapes.
const MAX_BODY = 512 * 1024;
const MAX_PREVIEW = 300;
const MAX_TITLE = 100;

export default {
  async fetch(request, env) {
    const kind = new URL(request.url).pathname.slice(1);
    const webhook = { bug: env.BUG_WEBHOOK, idea: env.IDEA_WEBHOOK }[kind];
    if (request.method !== "POST" || !webhook) return reply(404);
    if (request.headers.get("User-Agent") !== "FixDock") return reply(403);

    if (env.LIMITER) {
      const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
      const { success } = await env.LIMITER.limit({ key: ip });
      if (!success) return reply(429);
    }

    const raw = await readCapped(request, MAX_BODY);
    if (raw === null) return reply(413);
    let note, report;
    try {
      ({ note, report } = JSON.parse(raw));
    } catch {
      return reply(400);
    }
    if (typeof note !== "string" || !note.trim() || note.length > MAX_TEXT
        || typeof report !== "string" || report.length > MAX_TEXT) {
      return reply(400);
    }

    const body = new FormData();
    const label = kind === "bug" ? "[Bug]" : "[Idea]";
    body.append("payload_json", JSON.stringify({
      thread_name: title(label, note),
      content: `\`\`\`\n${clip(note)}\n\`\`\``,
      allowed_mentions: { parse: [] },
    }));
    body.append("files[0]", new Blob([report], { type: "text/plain" }), `${kind}.txt`);

    const sent = await fetch(webhook, { method: "POST", body });
    return reply(sent.ok ? 204 : 502);
  },
};

// Counts the bytes actually read, so a missing or false Content-Length
// cannot get a larger body past the cap.
async function readCapped(request, limit) {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

function clip(note) {
  const plain = note.trim().replaceAll("`", "'");
  return plain.length > MAX_PREVIEW ? plain.slice(0, MAX_PREVIEW) + "…" : plain;
}

function title(label, note) {
  const firstLine = note.trim().split("\n")[0].trim();
  const full = `${label} ${firstLine}`;
  return full.length > MAX_TITLE ? full.slice(0, MAX_TITLE - 1) + "…" : full;
}

function reply(status) {
  return new Response(null, { status });
}
