# Catcul — more space, simple Notes, no Study Mode

**Start here. This guide supersedes older instructions about study boards, passcodes and campus networks.** The files have been updated locally; no hosted database, Edge Function, secret or website deployment was changed automatically.

## What changed

- A roomier chat layout, larger spacing and controls, and more space for conversations. Resources and room details now open in a drawer rather than permanently squeezing the chat.
- **Memory Lane is a dropdown**, collapsed by default. Open it to load this room’s memories; choose This week / A year ago, or play the existing reel.
- **Notes** instantly opens a plain editable notebook. Press **Alt+N** to switch, or use the Notes button. **Escape / Back** returns to the same workspace. No password in either direction.
- No Study Mode toggle, Gemini board, campus detection, passcode modal, social restriction, or owner school-lock settings. Courses, study groups and resources remain available alongside friends, chats, calls and the social tools.
- Normal account sign-in, private room membership, suspension, admin authorization and private synced Diary are still enforced.

## Apply to your existing Supabase project

Use your existing active project, not a new project. **Do not rerun the owner bootstrap: your owner was already configured at the last check.**

1. Open **SQL Editor → New query**. If you have not yet installed the social canvas, run the full `catcul-social-canvas-upgrade.sql` first. It requires `catcul-student-upgrade.sql`, which was present at the last check.
2. Run the full **`catcul-open-workspace-upgrade.sql` LAST**. This removes server-side locks, clears old lock rows and network settings, and prevents legacy clients from relocking accounts. Uploading HTML alone is not enough.
3. In **Edge Functions → catcul-school → Code**, replace `index.ts` with **`supabase/functions/catcul-school/index.ts`** from this package, then **Deploy updates**. This is now an authenticated retirement/compatibility endpoint, with no IP detection or AI requests. Old AI requests return a retired response.
4. If push is installed, replace and redeploy **catcul-push** using its matching `index.ts`. It no longer filters recipients using retired lock settings. Keep existing VAPID keys and webhook secret.
5. Keep `verify_jwt = false` / the legacy gateway JWT check off for these handlers, as in `supabase/config.toml`. **The handlers still verify the user's token themselves**; the push webhook instead verifies its secret header. Do not remove these checks.
6. If **catcul-admin** or **catcul-calls** have not yet been deployed from the student release, deploy their matching files too. They retain account suspension and authorization checks. No LiveKit secret changes are required for this refresh.
7. Upload the public website files below. Reload open tabs and reopen any installed PWA so the new app/service worker can activate.

You no longer need Gemini secrets for this app. Remove unused `GEMINI_API_KEY` / `GEMINI_MODEL` secrets only if no other function uses them. Revoke any previously exposed provider key in the provider console.

### Public files to upload

- `index.html`, `signup.html`, `signin.html`, `catcul.html`
- `manifest.json`, `sw.js`
- `icons/catcul-192.png`, `icons/catcul-512.png`

Workspace filenames are unchanged. Keep the existing deployment mapping if you publish your chat as `index.html`; check your page links and manifest shortcuts against the files you actually publish. **Do not upload the whole ZIP to a public site.** SQL, setup guides, local key-generation utility and Edge Function source are deployment materials, not public pages. Never publish the private owner-bootstrap script or secrets.

No user-managed Node.js or Python server is needed. Production remains static hosting + managed Supabase + LiveKit for calls.

## Notes: what is and is not saved

- Notes remain in the current page’s memory while you switch back and forth. **They are not synced or stored in localStorage.** Use **Download .txt** to keep a copy.
- New page, sign-out and page exit warn about undownloaded edits where the browser permits. Browser/device termination can still lose unsaved notes.
- Notes are separate from **Diary**, which still syncs privately to your account and is not end-to-end encrypted.
- Opening Notes hides and disables the other app panels, stops ringing, pauses media and cancels an in-progress voice-note recording. An active call’s microphone and speakers are muted; they stay muted on return until you deliberately resume them. Pending microphone permission is handled too.
- This is a **visual quick switch, not a privacy/security boundary**. The browser address/history, installed-app identity, device notifications and network activity can still identify Catcul. The open page suppresses in-app alerts; the service worker avoids native alerts while an app window is visible. Background/device notifications can still appear. Disable App & alerts if you do not want them.

## Fresh installation / reapplying old migrations

Run SQL in this order:

1. `catcul-setup.sql`
2. `catcul-social-upgrade.sql`
3. `catcul-avatar-upgrade.sql`
4. `catcul-school-upgrade.sql` — legacy filename; provides courses/resources and shared database dependencies
5. `catcul-study-groups-upgrade.sql`
6. `catcul-student-upgrade.sql`
7. `catcul-social-canvas-upgrade.sql`
8. **`catcul-open-workspace-upgrade.sql` — always last**

Do not apply the retired campus configuration. Older SQL filenames/helpers are retained for migration compatibility, not as active UI modes. Do not rerun old migrations alone after upgrading. Owner provisioning is a separate trusted, private operation; the existing owner's private bootstrap is not included in this new ZIP.

## Validation and deployment status

Local checks cover database authorization, lock retirement and suspension, private Diary and rooms, legacy endpoint behavior, authenticated Edge contracts, Notes editing/download/audio behavior, Memory Lane disclosure, retained photo/planning/nearby features, mobile layouts and the actual public-only service-worker cache.

Browser/provider contracts use isolated test fixtures, not fake production features. Real hosted multi-account Realtime, LiveKit audio and native push delivery still require testing on your deployed project/devices. No hosted deployment or provider delivery is claimed by this update.
