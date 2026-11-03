> **Latest layout:** [MESSENGER-LAYOUT-UPDATE.md](MESSENGER-LAYOUT-UPDATE.md). The campus masthead is gone; tools use compact navigation and menus. No additional SQL is needed for this layout refresh if the open-workspace update is already installed.

> **Current release:** [OPEN-WORKSPACE-UPDATE.md](OPEN-WORKSPACE-UPDATE.md) takes precedence. Apply its final migration after this one.

# Catcul: shared plans, nearby discovery and installable app

## What is included

- **Shared planning canvas:** tap Plans or swipe left on a non-interactive part of the chat. Create events with date/time and RSVP choices, shared checklists, public meetup pins and visual polls. Members can drag their own avatar onto a poll choice on desktop, or tap a choice on touch/keyboard. One current vote per account. Poll/event cards also appear in chat. Only the creator or room owner can delete a plan. The canvas loads the 100 most recent plans; an older poll/event can be reopened from its chat card.
- **Interactive map:** open the map explicitly, then tap to place a pin. Leaflet is bundled locally. Tiles are requested from OpenStreetMap only after opening the map; the provider receives your IP and the viewed area. Attribution is retained, with no tile prefetch/offline caching. Map rendering needs internet access and provider availability.
- **Nearby within 500 m:** explicit location permission or manually entered coordinates. Search coordinates stay in current page memory and are not stored in Catcul tables. Use Forget search location to clear them. Nearby posts advertise a deliberately supplied public venue—not the author's live position. Posts expire within 24 hours; creation is limited to ten per account per day. Authors can remove posts; students can report them and the owner can moderate them.
- **Student discovery, not identity verification:** any signed-in student account can search. Catcul does not verify campus identity. Coordinates can be searched manually, so a 500 m search is not a security boundary. Do not publish home addresses or private contact details. Walk-together posts do not guarantee safety or monitor a trip. Meet publicly, verify who you are meeting and use local emergency services when needed.
- **Digital bedrooms:** five palettes and up to six manually curated music, watching, gaming or thought cards with optional HTTPS links. Visible to friends/roommates outside not an automatically aggregated feed. Other platforms open separately; no external accounts are connected.
- **Co-presence:** current-room activity indicators for listening, gallery and planning, alongside existing typing indicators. Activity sharing is optional under Vibe. Activity is ephemeral, self-reported and never a real-world location or proof of identity. Hidden/background rooms do not deliberately advertise active viewing.
- **Memory Lane:** a collapsed-by-default dropdown, loaded when opened, with an automatically assembled in-browser reel from up to twelve recent photos, voice notes and short messages in that room, or a year-ago selection. No diary content, outside source material or AI upload. Tap Play reel for an automatic slideshow; voice notes require a separate play gesture. This is not an exported MP4 or a newly generated image collage. Removed messages are excluded when the reel reloads.
- **React Live:** emoji reactions saved against the current whole-second playback position of a voice note. Tap a reaction marker to jump to that time. Up to thirty timestamp reactions per user/note; voice recordings can now last up to sixty seconds.
- **Spark:** a silent, rate-limited “I’m around” signal that fades after ten minutes. It does not send sound or push notifications.
- **Temporary room vibes:** studying, music, tired, happy or quiet backgrounds/badges expire after eight hours. They do not overwrite the saved character design.
- **Catch-up marker:** uses saved last-read time. If the exact boundary is outside the loaded history, the UI says that older context is above rather than inventing a precise stopping point. Skip to latest clears the marker.
- **Installable app:** manifest, original Catcul home-screen icons, standalone display and a small service worker. Only public application files are cached; Supabase responses, messages, diary entries and private media are not cached by the worker.

All of these features are available without a mode lock. Normal account, membership, block and suspension checks remain. Diary is private and available. There are no teacher roles, money features or YouTube integration.

## Files to publish

Upload/replace these static assets on the same HTTPS origin:

- `index.html`, `signup.html`, `signin.html`, `catcul.html`
- `manifest.json`, `sw.js`
- `icons/catcul-192.png`, `icons/catcul-512.png`

Keep your existing filename convention if you deploy the chat as your `index.html`; the workspace filenames were not renamed. Check that your links and manifest shortcuts point to pages you actually publish. The manifest starts at `./` so it opens your deployment's home page.

Do **not** upload the owner-bootstrap SQL, setup/key generator, migrations or private secrets to your public site. `PUSH-KEYS.html` is an optional local setup utility, not a production page. Supabase functions are deployed through Supabase, not through GitHub Pages.

Use the migration order in **OPEN-WORKSPACE-UPDATE.md**; run the final retirement migration last. Do not repeat the existing owner bootstrap. Redeploy school/calls; deploy catcul-admin. School, admin, calls and push use managed Supabase Edge Functions—no user-managed Node/Python production service.

## Enable native Web Push (additional setup)

Installing the icon alone does **not** deliver messages in the background.

1. Open **PUSH-KEYS.html** locally in a modern browser. Click Generate. It creates a VAPID pair and a webhook secret using browser cryptography, without making network requests or saving them in browser storage. Copy values directly into Supabase → Edge Functions → Secrets:
   - `WEB_PUSH_PUBLIC_KEY`
   - `WEB_PUSH_PRIVATE_KEY`
   - `CATCUL_PUSH_HOOK_SECRET`
   - `WEB_PUSH_SUBJECT` — a contact URI such as `mailto:your-contact-email@example.com`
   Keep the private key and webhook secret private. Keep an existing pair if you already have subscribers; changing it requires devices to resubscribe. No keys need to be sent in chat.
2. Deploy **catcul-push** from `supabase/functions/catcul-push/index.ts`. Use `verify_jwt = false` as in `supabase/config.toml`. Browser actions still verify Supabase Auth; the message webhook instead requires the secret header below.
3. Set `ALLOWED_ORIGINS` to your HTTPS website origin (existing functions use the same setting).
4. In Supabase → Database → Webhooks, create a webhook on schema **catcul**, table **messages**, event **INSERT** only:
   - Method: **POST**
   - URL: `https://qrepissmmytfhwyxzfgk.supabase.co/functions/v1/catcul-push?action=dispatch`
   - Header `Content-Type`: `application/json`
   - Header `x-catcul-push-secret`: the exact value of `CATCUL_PUSH_HOOK_SECRET`
   - If the gateway asks for an API key, use your project's **public publishable key** as an `apikey` header, not a service-role key.
   - Keep the standard database webhook payload: the function expects `type`, `schema`, `table` and `record.id`.
5. In Catcul → **App & alerts**, install if desired, then explicitly enable notifications. Safari on iPhone/iPad requires a supported OS and a home-screen-installed app for Web Push. Chrome/Chromium, Firefox and Safari support varies by browser/device. If permission was denied, use browser site settings to reset it.
6. Test with two real accounts on separate devices. Close/background the recipient's tab and send an ordinary message from the other account. Inspect webhook/Edge logs if it does not arrive. Spark does not generate a push.

### Push privacy and delivery behavior

- The server derives recipients from current room membership, not caller-supplied IDs. It excludes the sender, suspended accounts, blocked pairs, muted rooms. Retired mode settings do not filter recipients.
- Push contains a generic new-message alert, never a diary entry or message body. Tapping it opens a room only after the normal signed-in workspace authorization.
- Subscriptions are service-only records. At most ten devices per account. Expired provider subscriptions are removed when the provider rejects them. Successful sends are deduplicated by message/subscription.
- Signing out unsubscribes the browser and clears displayed Catcul notifications where supported. Failed server-record cleanup may leave an inert record until the provider rejects it later.
- Webhooks and push are best effort, not guaranteed instant delivery. Database webhook failures need inspection/retry; this release does not add a scheduled durable notification retry worker. A failure after a provider accepts a message but before the response is recorded can still produce a duplicate.
- Muting a room syncs its push preference when connected. If that sync fails, retry it after reconnecting; old local mute preferences are also copied when push is enabled.

## Checks performed locally

SQL migrations were installed/reapplied on isolated PostgreSQL; security tests cover diary ownership, owner access, suspensions with old JWTs, reported-only moderation, private plans, votes, nearby radius/expiry and lock retirement. Browser tests use isolated fixtures; provider tests stub Auth, LiveKit and Web Push. No real push was sent, no real payment system was connected, and no hosted deployment was performed by the assistant.
