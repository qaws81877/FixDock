# Feedback relay

A Cloudflare Worker between FixDock's feedback sheet and two Discord
forum-channel webhooks (bugs, ideas). Every report opens a new forum post
titled `[Bug]` or `[Idea]` plus the first line of the note (100 characters
at most). The webhooks live only in the Worker's secrets, so
the app and this repository never contain them.

- `POST /bug` and `POST /idea` with `{"note": "...", "report": "..."}`, `User-Agent: FixDock`.
- Answers `204` when Discord accepted it; `400`, `403`, `404`, `413`, `429`
  (5 per minute per IP) or `502` otherwise.
- The report is attached as a `.txt` file with mentions disabled. The post body
  shows the first 300 characters of the note.

Deploy:

```bash
cd Tools/feedback-relay
npx wrangler login
npx wrangler secret put BUG_WEBHOOK
npx wrangler secret put IDEA_WEBHOOK
npx wrangler deploy
```

If a webhook leaks, create a new one in Discord, `wrangler secret put` it
again and delete the old one. The app does not change.
