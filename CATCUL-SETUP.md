# Catcul — authenticated Supabase setup

> **Study board & groups refresh:** follow [STUDY-BOARD-UPDATE.md](STUDY-BOARD-UPDATE.md) for the latest interface and the additional `catcul-study-groups-upgrade.sql` migration.

> **School release — start with [SCHOOL-SETUP.md](SCHOOL-SETUP.md).** Run `catcul-school-upgrade.sql` last, after all earlier scripts. It adds strict Study Mode, custom 3–15 character usernames, courses/resources/homework, Gemini and community. It also changes signed-out chat routing to the landing page. Earlier instructions below describe the preceding features; the school guide takes precedence.

## Current release: Character Studio, friends, private/groups and LiveKit voice

**Newest update: [CHARACTER-STUDIO-SETUP.md](CHARACTER-STUDIO-SETUP.md)** adds editable cat characters saved to user profiles. Run `catcul-avatar-upgrade.sql` after the social upgrade.

Use [VOICE-AND-FRIENDS-SETUP.md](VOICE-AND-FRIENDS-SETUP.md) for friends/calls and dashboard-only LiveKit setup.

You reported completing the original SQL installation and exposing the `catcul` schema. This release **does require a new migration**: `catcul-social-upgrade.sql`. Run it after the original setup. It preserves existing messages and turns old rooms into groups. The assistant has not applied SQL or changed your external project settings.

The supplied chat page adds username-based friends, private best-friend pins, friend-only direct messages, groups, owner controls and real LiveKit voice integration. Calls and owner member-removal use the included managed `catcul-calls` Supabase Edge Function. They are not deployed just by uploading the HTML. Live two-account audio verification remains your final setup step.

Your project is configured in `signup.html`, `signin.html`, and `catcul.html`:
- Project: `https://qrepissmmytfhwyxzfgk.supabase.co`
- REST API: `https://qrepissmmytfhwyxzfgk.supabase.co/rest/v1/`
- Application schema: `catcul`
- Browser credential: your existing **public publishable key**

Never put a service-role/secret key or LiveKit API secret into HTML, browser storage, frontend configuration, a public repository, or chat. If you expose a privileged key, rotate it in its provider dashboard.

The website now has **four separate HTML pages**: `index.html` (landing), `signup.html`, `signin.html`, and `catcul.html` (chat). Each page includes its own styles, icons and any scripts it needs. Keep the four files together on one HTTPS website. **No user-run Node.js/Python server or frontend build process is required.** Calling uses a managed Supabase Edge Function and LiveKit Cloud; deploy/configure them through their dashboards. The SQL file is a database installation, not a server to run.

## 1. Install the schema and policies

1. Open the correct Supabase project.
2. Open **SQL Editor → New query**.
3. Paste the entire contents of **`catcul-setup.sql`**.
4. Run it as the project administrator.
5. The original script shows **eight tables**, each with `rls_enabled = true`.
6. Then run **`catcul-social-upgrade.sql`**. It adds five RLS-protected tables and updates helpers/policies. If the original setup is already installed, run just the upgrade. Then run **`catcul-avatar-upgrade.sql`** for Character Studio. Do not rerun older migrations alone after upgrading; rerun subsequent migrations in order.

The script is transactional and rerunnable for this version. It does not drop existing application tables or remove unrelated policies. It reserves the `catcul` schema, `catcul-media` bucket, `catcul:` Realtime topic prefix, and `catcul_*` policy names for this application. If your project already uses those names for something else, review and rename them before running it.

### Objects created

| Table | Purpose |
|---|---|
| `catcul.profiles` | Account-linked names and avatar colors; email remains in Auth |
| `catcul.rooms` | Saved chat rooms |
| `catcul.room_members` | Membership, owner role, last-read marker |
| `catcul.room_invites` | Hashed invitation tokens, expiration, use limits, revocation |
| `catcul.messages` | Text, media references, replies, soft deletion |
| `catcul.attachments` | Private object paths, MIME type, size, uploader |
| `catcul.message_reactions` | Per-user emoji reactions with soft toggles |
| `catcul.message_receipts` | Received/read timestamps tied to authenticated users |

It also creates scoped helper/RPC functions, a private Storage bucket, Storage and private Realtime policies, indexes, and publication entries for the realtime tables.

## 2. Expose the custom schema

In **Project Settings → Data API → Exposed schemas**, add:

```text
catcul
```

Keep your existing exposed schemas. Save the setting. Depending on dashboard version, this setting may be grouped under API settings.

The browser client uses `.schema('catcul')`, which selects this schema through PostgREST's profile headers. It does **not** change the REST URL to `/rest/v1/catcul/`.

The migration sends a schema-cache reload notification. If the dashboard still reports missing functions after exposing the schema, wait briefly and retry. You may run:

```sql
notify pgrst, 'reload schema';
```

## 3. Configure authentication

In **Authentication → Sign In / Providers**, enable email/password sign-in.

**Your requested setting is Confirm email = OFF.** Disable it under the Email provider and save. Supabase still enforces email/password account uniqueness; the site does not create a parallel Auth system. With confirmation off, email ownership is not verified and people can register addresses they do not control. The assistant has not changed this setting. Configure:
- **Site URL**: your actual static HTTPS website root, such as `https://your-domain.example/`.
- **Redirect allowlist**: add `https://your-domain.example/signin.html` and `https://your-domain.example/signin.html?mode=recovery`. If your website lives in a subfolder, include that subfolder in both addresses. These are the confirmation and password-reset callbacks used by the new pages.
- A reliable SMTP provider before inviting a larger audience; default email delivery has limits.

The app uses email/password sign-up and sign-in, email-confirmation redirects, and password-recovery links. It uses PKCE. Open emailed links in the same browser used to request them when possible; after confirming an account elsewhere, returning to sign in with your password can still be necessary.

**Do not enter the example domain literally.** Use the address where you host the file.

An account's profile is created by `ensure_profile()` after sign-in, so existing Auth accounts can use Catcul too. The school upgrade adds a signup trigger on `auth.users` to atomically reserve the chosen username; follow the school guide before registering new accounts.

## 4. Check Storage and Realtime

The SQL creates the **private** `catcul-media` bucket with a 5 MB object limit and an image/audio MIME allowlist. Leave it private.

The app uploads to:

```text
<room UUID>/<authenticated user UUID>/<file UUID>.<extension>
```

The SQL enables these tables in the `supabase_realtime` publication:
- `messages`
- `message_reactions`
- `message_receipts`
- `room_members`
- `profiles`

The social upgrade additionally publishes `rooms`, `friendships`, `best_friends`, `user_blocks`, `voice_calls`, and `call_participants`. Account-scoped private channels use `catcul:user:<UUID>`.

The app uses **private** Realtime channels named `catcul:<room UUID>` for typing and presence. PostgreSQL Changes carries saved content. The migration grants access only to authenticated room members.

The previous guest app's public channels are no longer used. If this project serves only the new Catcul app, you can disable public Realtime access; check other applications before changing that project-wide setting.

Restrictive policies scope Catcul's bucket/topic access even if another app has broad permissive policies. Still audit the complete project configuration before production.

## 5. Open or host the HTML

Download **`catcul-website.zip`**, unzip it, and use the four HTML files together for this workspace layout. **Filename warning:** your live chat was named `index.html`, while this workspace’s `index.html` is a landing page and `catcul.html` is chat. No filenames were renamed. Do not overwrite your live chat with the landing page by accident; see Step 5 of the new guide. SQL, documentation and Edge Function source do not need to be uploaded to the public website.

Navigation: landing → sign-up/sign-in → chat. The chat page redirects signed-out visitors to `signin.html`; signing out returns there. Email confirmation returns to `signin.html`, and password recovery uses `signin.html?mode=recovery`. Room invitation codes are preserved through ordinary sign-up/sign-in navigation. If an email opens in a different tab/device and the invite is not carried over, reopen the original room invitation after signing in.

Downloaded files can be used to inspect the design and navigation. **Use HTTPS hosting for the actual multi-page app**: browser storage for `file://` pages is not consistent across browsers, and email callbacks need real URLs. All four pages need the same scheme, host and port to share the sign-in session.

Arena's embedded file preview blocks network access. It can show the interface, but it cannot sign in or connect to your database. Download/open the file or use your hosted URL.

## 6. Test with two real accounts

1. Create account A and complete email confirmation. Sign in.
2. Create a room. Copy its invitation.
3. In a separate browser/incognito window or another device, create/sign in as account B.
4. Open the invitation, or select **+ → Join a room** and paste its code.
5. Exchange text, a photo and a voice note. Check typing, online status, reactions and receipts.
6. Refresh both windows. Saved messages and media should reload.
7. Sign B out, send another message from A, then sign B back in. The message should be in saved history.
8. Sign in as a third account with no invitation. It must not see the room or its messages.
9. Revoke an invitation from the room owner's **More** menu; an unjoined account should no longer be able to use it.
10. Leave a room. Access should disappear; the owner role passes to the earliest remaining member, if any.

The newest **50 messages** load first. **Load earlier messages** paginates further back. Search queries saved message text; photo galleries and exports show currently loaded messages, not an unlimited full-history export.

## Security and behavior

- No anonymous database access. There is no automatic public lobby.
- Database message identity comes from `auth.uid()`, not a name or sender ID supplied by the client.
- Clients cannot assign arbitrary message timestamps or directly edit room membership/roles.
- Membership creation/join/leave runs through narrowly scoped RPCs.
- Invitation tokens are random, stored as hashes, expire after 7 days, and allow up to 50 new joins. New members can read the room's saved history. Any member can create an invite; the owner can revoke outstanding invites.
- Photos and voice notes use signed URLs, valid for up to one hour. Anyone given a signed URL can use it until it expires. Do not treat those URLs as permanently private after sharing them.
- Removing a message clears its saved text and hides its attachment from new authorized reads. It cannot recall downloads, screenshots, cached content, or unexpired signed URLs.
- Reactions use soft toggles instead of DELETE events to keep Realtime updates row-policy-filterable.
- Guest-version profiles, room codes and local history are not migrated or impersonated as authenticated records.
- Account messages/media are not persisted by the app into localStorage. Supabase's sign-in session and UI preferences are stored by the browser; sign out on shared devices.
- Presence and typing are informational client-authored signals, not security assertions. Actual content and access are enforced by the database.
- TLS protects transport. **Chats are not end-to-end encrypted.** Project administrators can access stored content.
- Notifications work only while the page is open; these are not background push notifications.

## Operational work before a public launch

This is an authenticated chat foundation, not a claim of production certification. Review:
- Email delivery, Auth rate limits, CAPTCHA/abuse protection, and message/upload rate limits.
- Backups, quotas, monitoring, logs, incident response and privacy/retention rules.
- A scheduled administrative cleanup job for unused uploads, soft-deleted media, expired invites and empty rooms. The migration deliberately does not silently erase them.
- Account deletion and moderation workflows. Auth-user deletion needs an intentional content-retention strategy because message/attachment ownership foreign keys preserve attribution.
- Moderation beyond the included owner member-removal and personal blocking. Removal revokes existing group invites but is not a permanent group ban.
- The current limit of 50 rooms per account and Realtime/Storage/database usage at your expected scale.
- Security review of all custom policies and existing project-wide policies.

## Validation performed for this delivery

- Migration executed and rerun against a local PostgreSQL 17 validation database with minimal Auth/Storage/Realtime interface fixtures—not your external Supabase project.
- Checked account profile setup, room creation/joining, private-topic membership checks, history visibility, sender spoofing denial, membership injection denial, invitation secrecy, outsider read/write denial, cross-room reply denial, reaction toggles, read receipts, private-media permissions, message removal, invitation revocation, owner transfer, and anonymous-access denial.
- Browser syntax, authentication screens, responsive layout, and setup/error states were checked.

**End-to-end Auth/Storage/Realtime testing against your external project still needs to be performed after hosting and setting the callback URLs.**

For the separate-page update, local browser checks covered landing-page links, the mobile menu, password validation, password visibility, invite preservation, and the signed-out chat redirect. Isolated tests with intercepted test responses also checked sign-up confirmation, sign-in error handling, session-based navigation, sign-out, and password-reset callback URLs. These are not live-email or live-project integration results; no test accounts were created in your Supabase project.

## Custom cursor update

A self-contained Catcul cursor is embedded in all four supplied pages. It includes hover, click, text-field and media states, a clearly labelled **Cursor: On / Off** button, and accessibility fallbacks. In chat, **Settings → Custom cursor** controls the same preference. Your choice is remembered in this browser across pages, tabs and reloads; no database change is needed. No Supabase changes are needed.

**The old snippet is cursor-only; it does not add the new social/voice features.** If you renamed your live chat file to `index.html`, keep that name when applying only the cursor snippet. To avoid replacing it with this local bundle’s landing page, paste the entire contents of `catcul-cursor-snippet.txt` immediately before the closing `</body>` in each existing live HTML file. See `CURSOR-UPDATE.txt`. No live deployment was performed by the assistant.

## Social and calling validation

See the new guide for the social migration/security checks, Deno type-check, isolated handler/JWT tests and browser contracts. No fixture contacts or simulated calls are included in the delivered app. Real LiveKit media transport and authenticated multi-account Realtime on your project remain unverified until you finish the setup and device checklist.
