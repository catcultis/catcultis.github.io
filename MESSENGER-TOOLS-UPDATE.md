# Catcul Messenger Tools Update

This release adds the smooth-chat feature set on top of the WhatsApp-style layout from `MESSENGER-LAYOUT-UPDATE.md`:

## What students get

- **Conversation management** — 📌 pin up to 5 chats to the top, archive quiet chats (an `Archived` filter appears), and mark a chat as **unread** to come back to it.
- **Message editing** — fix typos in your own text messages or document captions within 24 hours. An *edited* tag shows automatically. History is visible to the writer; platform admins only if you enable it in Settings.
- **Documents** — the **+** button now opens a menu: Photo, **Document**, Camera. PDF, DOC/DOCX, PPT/PPTX, XLS/XLSX, TXT, CSV or ZIP up to **25 MB**, delivered as a file card with size and download.
- **Voice notes, WhatsApp-style** — press and hold the mic, **slide left to cancel, slide up to lock** hands-free, tap to finish. Listeners get a playback-speed button (1× → 1.25× → 1.5× → 2×).
- **Better search** — search this chat or all chats, filter by text, **links**, **documents** or **mentions of you**, and jump to a **specific date**.
- **Unread navigation** — an unread chip jumps to the first new message; a scroll-to-latest button shows a counter while you're reading history. Unsent text waits in the composer for the session (never saved to disk).
- **Per-chat notifications** — All messages / **Mentions only** / Muted (1 hour, 8 hours, 1 week, always), plus **message previews on/off**. Muted or mention-only chats are also respected by push notifications.
- **@mentions** — typing `@FirstName` highlights the mention in the bubble.
- **Wallpapers & labels** — every chat can have your own background (plain, mint, sand, rose, sky, night) and a private label. Only you see them.
- **Pinned messages** — group owners/admins pin up to 3 messages; a banner above the chat cycles through them.
- **Group settings & lifecycle** (owner) — admins-only posting, allow photos & voice notes, allow documents, **approve new messages** before members see them, **approve join** requests, auto-archive on a date, keep messages for 7–365 days (or forever), transfer ownership, merge one group into another, archive a room.
- **Archived rooms are read-only** server-side; merges move members, revoke old invitations and leave a system message in the destination.

## Deploy (your Supabase project)

1. **Database** — in Supabase SQL Editor run **`catcul-chat-tools-upgrade.sql`** once. Run it after `catcul-open-workspace-upgrade.sql`. Safe to run twice.
2. **Push function** — redeploy `supabase/functions/catcul-push` so notification previews & mentions/ mute rules take effect:
   - Supabase Dashboard → Edge Functions → `catcul-push` → paste `index.ts` → Deploy.
   - Keep `verify_jwt = false` as before, and the same secrets. No secret changes needed.
3. **Static files** — upload `index.html`, `signup.html`, `signin.html`, `catcul.html`, `sw.js`, `manifest.json` and the `icons/` folder. The service worker is now **`catcul-shell-v11`**; old caches are dropped on activation.
4. Reload once; installed apps pick up v11 automatically next launch.

If you never installed the earlier updates, run the full chain first: `catcul-setup.sql` → `catcul-social-upgrade.sql` → `catcul-avatar-upgrade.sql` → `catcul-school-upgrade.sql` → `catcul-study-groups-upgrade.sql` → `catcul-student-upgrade.sql` → `catcul-social-canvas-upgrade.sql` → `catcul-open-workspace-upgrade.sql` → **then** this one, and redeploy `catcul-calls`, `catcul-admin`, `catcul-school` and `catcul-push`.

## Quality gates (this release)

- **73 SQL assertions**: preference privacy, pin limits, edit window/history/24h + admin visibility toggle, document MIME/size enforcement, pin permissions, admins-only posting trigger, approval queue visibility, join approval flow, ownership transfer rules, merge audit, retention & auto-archive sweeps, rate-limit privacy. Idempotency re-run passes.
- **Browser suite**: pin/archive/unread ordering, muted + preview preferences, wallpaper & label, document staging/upload/card, edit + history, pins, approval queue, group settings, global search (links/files/mentions/jump-to-date), unread jump, voice gestures + playback speed. Existing messenger regression suite (Notes, Diary, photos, plans, nearby, bedrooms, calls, dark mode, mobile) still passes, plus the composer-visibility suite (27 viewport checks).
- **PWA**: real service-worker registration on `catcul-shell-v11`, public-only cache, private SQL still 404.

Limits: voice notes ≤ 60 s / 1 MB; documents ≤ 25 MB; message edits ≤ 30/hour; merges ≤ 6/day; join requests ≤ 20/day. Edit history is never deleted by clients.
