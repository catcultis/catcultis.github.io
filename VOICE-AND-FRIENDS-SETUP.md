# Catcul — activate friends, groups and voice calls

> **School release — start with [SCHOOL-SETUP.md](SCHOOL-SETUP.md).** Run `catcul-school-upgrade.sql` last, after all earlier scripts. It adds strict Study Mode, custom 3–15 character usernames, courses/resources/homework, Gemini and community. It also changes signed-out chat routing to the landing page. Earlier instructions below describe the preceding features; the school guide takes precedence.

**Character Studio update:** this bundle also includes customizable cat avatars. After the SQL steps below, run `catcul-avatar-upgrade.sql`; see `CHARACTER-STUDIO-SETUP.md`. If you rerun this social migration later, rerun the avatar migration afterward too.

## What is ready, and what is not

The supplied `catcul.html` contains the new interface and real Supabase/LiveKit integrations. **The assistant has not applied this migration to your Supabase project, deployed the function, configured LiveKit, or tested a live call between your accounts.**

You do not need to install or run Node.js, Python, or a local server. Use the Supabase dashboard, LiveKit Cloud dashboard, and your existing HTTPS hosting.

### Included features

- Username search, friend requests, accept/decline/cancel, remove and block/unblock.
- Up to **8 best friends**, manually starred and visible only to you.
- Friend-only private conversations with exactly two participants.
- Named groups, invitation links, owner rename/removal controls, and ownership transfer when the owner leaves.
- Individual and group **internet voice calls** through LiveKit: incoming-call cards, real microphone publishing and remote audio, mute, sound on/off, participant/speaking indicators, minimize, leave/end, and recent call history.
- Existing Supabase messages, reactions, photos, voice notes, receipts, sign-in and custom cursor retained.

These are **app-to-app calls**, not telephone-number/PSTN calls. Friends need Catcul open and signed in. There is no closed-browser push ringing, video, recording, or end-to-end encryption. “Sound off” controls playback; it is not a hardware speaker/earpiece selector.

---

## Step 1 — back up, then run the new SQL

Use the Supabase project for `qrepissmmytfhwyxzfgk`.

1. Keep a backup of your current website files and database before upgrading.
2. Open **SQL Editor → New query**.
3. Since you reported already running the original setup, paste the entire **`catcul-social-upgrade.sql`** and click **Run**.
4. It should finish with: **“Catcul social + voice schema is installed. Configure the Edge Function and LiveKit to activate calls.”**
5. Keep **`catcul`** in **Data API → Exposed schemas**.

For a completely new project, run `catcul-setup.sql` **first**, then `catcul-social-upgrade.sql`. The upgrade preserves existing messages and treats existing rooms as groups. **Never rerun the original setup alone after upgrading**: it contains older function/policy definitions. If you rerun it, immediately rerun the upgrade too.

The upgrade is transactional and rerunnable. It adds five tables: `friendships`, `best_friends`, `user_blocks`, `voice_calls`, and `call_participants`, with RLS enabled. It also extends profiles, rooms and membership records, and registers the new Realtime tables.

In the school release, legacy generated handles must be replaced during onboarding. Users choose 3–15 letters, numbers or underscores; capitalization is preserved and uniqueness is case-insensitive. Friend search shows usernames, display names and colors—not emails.

## Step 2 — create your LiveKit Cloud project

1. Open **https://cloud.livekit.io/** and sign in or create an account.
2. Create a project for Catcul.
3. Find the project's URL and API credentials. Dashboard labels may vary; look for **Settings / API keys**.
4. Keep these three values ready:
   - Project URL, normally `wss://your-project.livekit.cloud`.
   - API key.
   - API secret.

Check the current usage limits and billing for your LiveKit plan. Calls consume LiveKit resources; Supabase also has database, Realtime and function usage limits.

**Do not paste the API secret into this conversation, HTML, a public repository, or your GitHub Pages files.**

## Step 3 — add the server-side secrets in Supabase

Open **Supabase → Edge Functions → Secrets** and save:

| Secret name | Value |
|---|---|
| `LIVEKIT_URL` | Your LiveKit Cloud project URL (`wss://…`) |
| `LIVEKIT_API_KEY` | Your LiveKit API key |
| `LIVEKIT_API_SECRET` | Your LiveKit API secret |
| `ALLOWED_ORIGINS` | `https://catcultis.github.io` |

Use the exact website **origin**: scheme + hostname + optional port, with no path or trailing slash. For multiple real websites, use a comma-separated list. Do not use `*`. If you change domains, update this setting.

Supabase supplies its own server environment variables. The function supports the current `SUPABASE_PUBLISHABLE_KEYS` / `SUPABASE_SECRET_KEYS` dictionaries and the older `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY` variables. **Do not create custom `SUPABASE_…` secrets or copy privileged Supabase keys into the frontend.** [3](https://supabase.com/docs/guides/functions/secrets)

## Step 4 — deploy the included Edge Function using the dashboard

1. In Supabase, open **Edge Functions**.
2. Select **Deploy a new function → Via Editor**. Dashboard deployment does not require a local development environment. [1](https://supabase.com/docs/guides/functions/quickstart-dashboard)
3. Name the function exactly **`catcul-calls`**.
4. Open the included file **`supabase/functions/catcul-calls/index.ts`** on your computer.
5. Copy its **entire contents** into the dashboard editor's `index.ts`, replacing the example code. Keep both `npm:` imports; Supabase resolves them on the server.
6. Deploy the function.
7. In the function's settings, disable the gateway option labelled **Verify JWT** / **Verify JWT with legacy secret**, then save. This delivery validates the bearer token itself using `auth.getUser()` and performs database authorization for every operation. **Do not remove those checks.** The gateway's legacy verifier can otherwise reject requests before the handler runs. [10](https://supabase.com/docs/guides/troubleshooting/edge-function-401-error-response)

The included `supabase/config.toml` records `verify_jwt = false` for CLI deployments; uploading that file to GitHub Pages does **not** deploy or configure the function. Use the dashboard setting above for this dashboard-only workflow.

Expected endpoint:

```text
https://qrepissmmytfhwyxzfgk.supabase.co/functions/v1/catcul-calls
```

Opening this address in a browser is **not** a call test. The endpoint expects a POST request with a signed-in user's access token. The website sends this automatically.

Deploy this function even if you postpone LiveKit setup: the owner's **Remove member** action also uses it. Without LiveKit secrets, friend/chat features can still work, but audio is unavailable. A group without a current call can still have members removed through the deployed function.

## Step 5 — publish the updated website carefully

The workspace filenames have **not** been renamed:

| File | Purpose |
|---|---|
| `index.html` | Landing page |
| `signup.html` | Create an account |
| `signin.html` | Sign in and password reset |
| `catcul.html` | Updated authenticated chat, friends and calls |

If you are using this workspace layout, upload the four HTML files together to your HTTPS hosting. Their CSS, icons, Supabase client, LiveKit client and custom cursor are embedded—no CDN script loading or frontend build is required.

**Your existing live chat was named `index.html`. Do not blindly replace it with this bundle's `index.html`, which is the landing page.** This delivery leaves the workspace layout unchanged, as requested earlier. If you retain your different live layout, the chat filename, home links and sign-in redirects must all be adjusted together; do not rename just one file or merge the two pages accidentally. Keep a backup before publishing.

Do not publicly upload secrets. SQL and setup documents are not needed by GitHub Pages. The TypeScript file belongs in the Supabase function editor, not as a browser script. The old cursor snippet alone does **not** install the social/calling upgrade.

Arena's file preview blocks network access. Test Auth and calls on the actual **HTTPS website**, not the embedded preview or a downloaded `file://` page.

## Step 6 — keep your requested email settings

In Supabase **Authentication → Sign In / Providers → Email**, keep email/password enabled and set **Confirm email = OFF**, then save, if that is still your intended setting.

Supabase Auth enforces email-account uniqueness for email/password accounts; do not create a second homemade user system. With confirmation disabled, signup can sign the user in immediately. **Email ownership is not verified**, so someone can register an address they do not control. Configure SMTP/password recovery and abuse protection appropriately.

Keep the Site URL and allowed redirect URLs pointed at your actual website. For this bundle's root layout, allow:

```text
https://catcultis.github.io/signin.html
https://catcultis.github.io/signin.html?mode=recovery
```

The assistant has not changed or verified these dashboard settings.

## Step 7 — do the real two-device test

Use **two different accounts on two devices**, ideally with headphones. One device can be a laptop and the other a phone. This is the required final validation—not the isolated tests used during development.

1. Sign in on both devices and set memorable usernames in Profile.
2. On account A, open **Friends → Find people**, search B's username, and send a request.
3. On B, open **Friends → Requests → Accept**.
4. Star B as a best friend on A. Confirm B does not see A's private favorites list.
5. Open the private chat. Send text, a reaction and a photo; verify the other device receives them without refreshing.
6. Tap the **phone** icon. Allow microphone access. B should see an incoming-call card while Catcul is open.
7. Join on B. Confirm you hear each other **both ways**. If prompted, tap **“Tap to hear the conversation.”**
8. Test mute/unmute, sound off/on, minimize, and hang up. Verify the browser microphone indicator turns off after leaving.
9. Create a group, share its invitation, and join from B. Test a group call. Add a third account/device to validate multiple simultaneous remote speakers.
10. Test group rename, owner removal, and leaving. After a removal, old invitation links should fail. The owner should create fresh invitations for remaining invitees.
11. Test unfriend/block: old private history should remain, but new messages, reactions, uploads and calls should be blocked. Shared groups remain accessible. Unblocking should **not** restore friendship automatically.
12. Refresh, sign out and back in; verify friends, groups and history persist. Also test a missed/declined call, microphone denial, a temporary network interruption, and a mobile browser.

The app's **Calls → Calling setup & connection help → Check calling setup** verifies that the endpoint reports credentials configured. It does not prove the keys are valid or that audio traverses both devices; only the live audio test does that.

---

## Behavior worth knowing

- Only accepted friends can open/send in a private conversation. Removing a friend or blocking stops new private communication while retaining saved history. Existing downloaded media and already-issued signed URLs cannot be recalled.
- A personal block does not hide shared groups or prevent group interaction. Leave the group or use owner moderation if needed.
- Best friends are manual private favorites, not an automatic ranking or public status.
- Groups permit up to 50 active members; accounts permit up to 50 joined conversations. The Edge Function sets the audio room maximum to 50, subject to provider plan limits and practical device/network constraints. This is not a 50-person load-test claim.
- Any current group member can create an invite. Invitations expire after 7 days or 50 joins. Owner removal **revokes every outstanding invite for that group**, so the removed member cannot immediately reuse an old link. A new invitation can permit rejoining; this is removal, not a permanent group ban.
- Leaving as owner transfers ownership to the earliest remaining member. The last member's departure revokes invites. Stored group history is not automatically deleted.
- Only one live call per conversation and one accepted call per account are allowed. Use one calling tab/device per account; simultaneous sessions share the same LiveKit participant identity.
- Ringing expires after roughly 75 seconds. Call health is checked about every 20 seconds; visible-tab recovery polling runs about every 15 seconds. Missed/stale call cleanup is activity-driven, not a scheduled job, so records can remain stale until somebody opens the app again.
- The starter or current group owner can end a group call for everyone. Other participants can leave without ending it for everyone.
- Call history displays up to 40 recent accessible records from the last seven days; there are no audio recordings.
- Leaving/signing out stops the local microphone. Ending/removing participants also asks LiveKit to revoke tokens and disconnect audio. **If server cleanup fails, the UI reports that it is unconfirmed and offers retry where applicable—retry it rather than assuming remote audio has stopped.** Privilege changes are rechecked; they cannot retroactively recall audio already received.
- The implementation specifically targets **LiveKit Cloud** token revocation and passes an explicit revocation cutoff. Self-hosting LiveKit is not an equivalent drop-in security configuration. [1](https://docs.livekit.io/home/server/managing-participants/)

## Troubleshooting

| Symptom | What to check |
|---|---|
| `list_my_spaces`, `social_state` or another RPC is missing | Run the full social upgrade after the original setup; ensure `catcul` is exposed. Then run `notify pgrst, 'reload schema';` and retry. |
| Database error after publishing | Do not rerun only the original SQL; apply the upgrade again. Review the exact error shown. |
| Function 404 | Deploy the exact name `catcul-calls` to this Supabase project. |
| Gateway `Invalid JWT` / 401 | Check gateway Verify JWT setting, retain handler authentication, then sign out/in to get a current session. |
| 403/origin error | Set `ALLOWED_ORIGINS` to your exact website origin, with no trailing slash or path. |
| “Supabase function environment is incomplete” | Check the function is deployed in the intended project and Supabase has injected its server keys. Do not put them in HTML. |
| “Voice calls are not configured” | Add all three LiveKit secrets to Supabase Edge Function Secrets. |
| Call starts then reports audio-service failure | Verify LiveKit URL/key/secret belong to the same project; check provider status, billing/quotas and Supabase function logs. |
| No microphone / permission denied | Use HTTPS, allow microphone access in browser/OS settings, and check another application is not monopolizing the device. |
| Connected but silent | Check microphone mute, playback mute, browser autoplay prompt, OS volume, device input/output, and network/firewall restrictions. Test another network. |
| Friend is not ringing | They must be signed in with Catcul open, not busy in another call, and must allow any desired notifications. Mobile background tabs can be suspended. |
| Removal/end reports cleanup pending | Database access may already be removed while audio cleanup is unconfirmed. Retry in the dialog and check LiveKit service/secrets. An administrator can also inspect/terminate the room in LiveKit. |
| Group removal button fails | Deploy `catcul-calls`; owner verification runs server-side, even when no audio is active. |

## What was tested locally

- Original schema + upgrade installation and upgrade rerun in PostgreSQL 17 with minimal local Supabase interfaces.
- Original security regression suite plus 43 social/calling checks: friendship lifecycle, DM uniqueness/access, private favorites, blocked messages/reactions/media/topics/tokens, invitations, group membership, owner transfer, outsider denial, call acceptance, late group joining, end-call authorization and anonymous denial.
- Deno type-check of the Edge Function, plus isolated handler tests for authentication, CORS, verified actor identity, real JWT signing/scopes, microphone-only grants, token denial, revocation parameters and cleanup failure reporting.
- Browser tests for friend/search/favorite/profile/group flows, missing-provider setup UI, responsive layouts, cursor, Auth routing and call control/microphone cleanup contracts. Browser provider responses were mocked in tests only; no test contacts or simulated calls are shipped in the application.

**Not yet tested:** hosted authenticated Supabase Realtime across your accounts, real LiveKit media transport between your devices, Safari/iOS device behavior, or large-group load. Complete Step 7 before treating this as ready for real users. Review abuse controls, logs, retention, backups, quotas, and privacy/security before a public launch.
