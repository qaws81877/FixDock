// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 FixDock contributors

// Holds the Discord webhooks so the app never ships them. The app posts
// {"note": "...", "report": "..."} to /bug or /idea. The report goes to
// Discord as a file and mentions are off, so nothing in it can ping anyone.
// Both webhooks belong to forum channels: each report opens its own post.

const MAX_TEXT = 64 * 1024;
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

    const declared = Number(request.headers.get("Content-Length") ?? 0);
    if (declared > MAX_TEXT * 2) return reply(413);
    let note, report;
    try {
      ({ note, report } = await request.json());
    } catch {
      return reply(400);
    }
    if (typeof note !== "string" || !note.trim() || typeof report !== "string" || report.length > MAX_TEXT) {
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
