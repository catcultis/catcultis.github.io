# Catcul School — deployment and administrator guide

> **Latest interface update:** see [STUDY-BOARD-UPDATE.md](STUDY-BOARD-UPDATE.md). The helper is now a notebook-style Study board in the central chat area. Install `catcul-study-groups-upgrade.sql` after the school migration for invite-only study groups.

## Delivery status

The workspace now includes the school dashboard, custom usernames, course rooms, pinned resources, homework, Study Mode with a **server-verified password gate**, Gemini streaming integration, and a signed-in community chat.

**No external Supabase migration, Edge Function deployment, Gemini key configuration, campus IP configuration, or live multi-account test has been performed by the assistant.** The preview on port **5432** serves the updated HTML; it is not a substitute for these backend setup steps.

Your choices for this update:
- **School-wide unlock passcode**, not student-managed passwords.
- **Confirmed school public IP: `129.222.205.220/32`.** Run the separate `catcul-campus-config.sql` after the school migration to add it. This setting has been prepared, not applied to your live database.

Existing custom characters, the cursor On/Off controls, friends, private/groups, voice notes and LiveKit calling remain in the bundle. No user-run Node.js/Python server is required for deployment. The local Node process is only the workspace's static preview server.

---

## 1. Install the school database upgrade

Back up your database and website first. In your existing Supabase project (`qrepissmmytfhwyxzfgk`), open **SQL Editor → New query**.

If all three previous migrations are installed, run only:

```text
catcul-school-upgrade.sql
```

For a new project or an incomplete earlier setup, run in order:

```text
1. catcul-setup.sql
2. catcul-social-upgrade.sql
3. catcul-avatar-upgrade.sql
4. catcul-school-upgrade.sql
5. catcul-study-groups-upgrade.sql
6. catcul-campus-config.sql (your confirmed school IP)
```

Do not rerun an older migration by itself after upgrading; rerun all subsequent migrations too. All four scripts are rerunnable for this release. Keep **`catcul`** in **Data API → Exposed schemas**.

The final school query should say:

> Catcul school workspace installed. Change the default passcode and configure catcul-school secrets and campus CIDRs.

### Database changes

- Profile username validation becomes **3–15 letters, numbers or underscores**, preserving exact capitalization. The unique index remains case-insensitive: `Alex_Smith` and `alex_smith` cannot belong to different accounts.
- Automatically generated/overlong legacy handles become unset. Those accounts must choose a valid username on their next workspace visit. Messages, avatars, friendships and account IDs are retained.
- Signup checks `username_available` and submits the exact username in Auth metadata. A new `auth.users` insertion trigger creates/reserves the profile in the same transaction, closing the race between checking and registering. This trigger expects valid `username` metadata; administrator-created accounts or other Auth providers must supply it too. This release's supported registration view is email/password.
- New tables: `school_config`, `study_settings`, `pinned_resources`, `homework`, `homework_completion`, `study_ai_usage`.
- Rooms gain `purpose` (`social`, `course`, `community`) and an optional course code. Existing rooms remain social; they are not silently relabelled as courses.
- RLS, restrictive function grants and the membership helper enforce Study Mode access for room messages, attachments and room-based actions. Students cannot directly update/delete the persisted lock state or read/change the school passcode configuration.
- The migration installs `pgcrypto` in the `extensions` schema for bcrypt hashing. If your project has a nonstandard pgcrypto installation in another schema, have the administrator review the qualified `extensions.crypt` / `extensions.gen_salt` calls rather than moving a shared extension blindly.

## 2. Change the default Study Mode passcode — before student rollout

The bootstrap passcode is **`unlockcatcul`**, as requested. **It is publicly documented and is not a secure production secret. Change it before students use the app.** There is no passcode or hash in the browser bundle.

Run this as an administrator in Supabase SQL Editor, replacing the placeholder privately:

```sql
update catcul.school_config
set study_password_hash = extensions.crypt(
      'REPLACE_WITH_A_STRONG_PRIVATE_PASSCODE',
      extensions.gen_salt('bf', 10)
    ),
    updated_at = now()
where id = true;
```

Use a passcode no longer than 72 UTF-8 bytes because bcrypt has that input limit. Share it only with people authorized to unlock social features. Do not paste it into chat, the HTML, or a public repository. The SQL editor and its query history are administrator-only operational surfaces; handle them accordingly.

Students cannot change this passcode through their profile or reset it by changing their account password. The **Study Mode passcode is separate from their sign-in password**.

### Gate behavior

- Turning Study Mode **ON** is immediate and needs no passcode.
- When it is ON, clicking the toggle opens **“🔓 Unlock Social Features”**. The switch remains ON.
- A wrong passcode leaves it ON and displays exactly:

  `Incorrect password. You must enter the passcode to exit Study Mode!`

- Five consecutive failures trigger a five-minute per-account cooldown. Even the correct passcode is rejected during the cooldown. Failed attempts are recorded server-side.
- Only the verified unlock RPC can turn a student's stored state OFF. Closing the dialog, reloading, signing out/in or editing localStorage does not reset that state. Another tab receives the authoritative state through Realtime or recovery polling.
- The normal UI stops social calls/recording when entering Study Mode and removes social subscriptions. Already downloaded content cannot be recalled.

**This is an application access gate, not a managed-device/kiosk system.** It does not lock other websites, prevent VPN use, or stop a modified client from drawing its own UI. The server still denies unauthorized persisted state changes and protected room operations. LiveKit is a separate media service; provider/network failures can delay remote cleanup. Existing provider/token caveats in the voice guide still apply.

## 3. Configure the confirmed campus IP

You confirmed **129.222.205.220** as the school's public internet IP. The supplied `catcul-campus-config.sql` adds **129.222.205.220/32** to the administrator-only allowlist. `/32` matches only that single IPv4 address, not a surrounding range.

**This configuration has not been applied to your live Supabase database.** After installing `catcul-school-upgrade.sql`, run `catcul-campus-config.sql` in Supabase SQL Editor. It preserves any existing allowlisted networks and can be rerun without adding duplicates. Confirm the returned `campus_networks` includes `129.222.205.220/32`.

No HTML changes or GitHub uploads are needed for this database-only setting. The `catcul-school` Edge Function must already be deployed. Reopen the workspace while using the school's connection to trigger a fresh network check.

If school IT changes the public IP, or students also use another outbound IPv4/IPv6 address, update the allowlist accordingly. A Wi-Fi name/SSID, private router address, or Wi-Fi password cannot replace the public egress IP.

To disable automatic detection without unlocking existing student sessions:

```sql
update catcul.school_config
set campus_networks = '{}'::cidr[], updated_at = now()
where id = true;
```

### What the check does

At workspace initialization the browser fetches the authenticated `catcul-school` network endpoint. That endpoint reads the IP reported by the Supabase gateway's forwarding headers; it does not accept a student-supplied identity or IP from the request JSON. PostgreSQL compares the normalized address against the administrator-only CIDR list.

If matched, the server turns Study Mode ON and the workspace displays:

> 🏫 School network detected: Study Mode activated automatically.

Leaving the network does **not** silently turn it OFF. A correct passcode is still required. Unlocking while on campus is allowed; opening the workspace again runs the detection check again.

If the network service is unreachable, the client enables persisted Study Mode as a safe fallback. If detection is configured but the gateway address is unavailable, it also stays locked. It does not display the “school detected” banner for an unknown network.

**Verify the reported address against the real school egress before enabling the rule.** Proxies, shared ISP/NAT addresses, IPv6, VPNs, dynamic addresses and forwarding-header behavior can affect detection. This is a convenience signal, not cryptographic proof of Wi-Fi membership or attendance. For a binding school-wide network policy, combine this with school-managed network/device controls.

## 4. Deploy the managed school endpoint and configure Gemini

Use **Supabase → Edge Functions → Deploy a new function → Via Editor**.

1. Name it exactly **`catcul-school`**.
2. Replace the editor contents with **`supabase/functions/catcul-school/index.ts`**.
3. Deploy.
4. Disable the gateway's legacy **Verify JWT** option for this function, matching the included `supabase/config.toml`.
5. Keep the function's explicit `auth.getUser()` check intact. Turning off the gateway verifier does **not** make this endpoint public; the handler rejects missing/invalid user tokens.

In **Edge Functions → Secrets**, add:

| Name | Value |
|---|---|
| `GEMINI_API_KEY` | Your privately obtained Google Gemini API key |
| `GEMINI_MODEL` | Optional model identifier; this release defaults to `gemini-3.8-flash` |
| `ALLOWED_ORIGINS` | `https://catcultis.github.io`, plus any actual preview/custom-domain origins separated by commas |

No live Gemini key has been supplied or installed. `GEMINI_API_KEY` is a **server-side environment lookup**, not a browser variable. Use Supabase's managed secrets; never insert the key into HTML or send it in this chat. Supabase supplies its own service/user API keys to the function environment.

For preview testing, add the exact HTTPS origin shown for port 5432 to `ALLOWED_ORIGINS`—no path or trailing slash. Avoid `*`. This secret is also used by the existing calls function, so keep all legitimate site origins you still need.

Google's current guidance for new Gemini API projects recommends newer models such as 3.8 Flash; availability and billing still depend on your project. Set `GEMINI_MODEL` to a supported model your account can access if needed. [2](https://ai.google.dev/gemini-api/docs/changelog)

### AI behavior and safeguards

- The central Study board tab is available only while Study Mode is ON. It replaces the former sidebar widget.
- The server checks the authenticated user's persisted Study Mode before requesting Gemini.
- Only the question typed into the widget is sent—not the class conversation, student name, email or avatar. Requests are independent questions, not a stored multi-turn AI conversation.
- The server fixes this system prompt; a client cannot replace it:

  > You are a helpful peer tutor inside the Catcul school app. Explain concepts clearly, break down math problems step-by-step, and do not give direct answers if the student is trying to cheat.

- The endpoint uses `streamGenerateContent` SSE and the browser displays arriving Markdown text. Headings, emphasis, lists and code are supported; raw HTML/scripts are escaped, and remote Markdown images are not loaded. Streaming is supported by Google's API. [2](https://ai.google.dev/api)
- The UI provides Stop, aborts when Study Mode is disabled/sign-out occurs, limits question length to 4,000 characters, and handles incomplete/provider-error responses visibly.
- Server limits: 5 requests per minute and 40 per rolling day, per account. Output is bounded; a 90-second server timeout stops stalled requests. Provider billing/quotas still apply.
- `study_ai_usage` stores account ID and timestamp for rate limiting, not question/response content. The provider may have its own retention/usage terms.
- A tutoring prompt is not a guarantee that the model detects all cheating or always produces correct answers. Students should verify important work with their teacher.

**Before enabling AI for students:** have the school approve the provider's eligibility/age requirements, data processing and retention terms, consent/privacy notices and budget controls. Tell students not to submit personal or sensitive information.

## 5. Publish the website and verify authentication routing

The files are still:

| File | View |
|---|---|
| `index.html` | Public landing: “Less scrolling. More us.” |
| `signup.html` | Custom registration including Choose Username |
| `signin.html` | Sign-in and password recovery |
| `catcul.html` | Authenticated App Workspace Dashboard |

The shared central router maintains an **`isAuthenticated` boolean derived from Supabase's session**. It uses full-document transitions between landing/Auth/workspace views, so the landing document is unmounted when the workspace opens and the workspace is unmounted after sign-out. Authentication/authorization is enforced by Supabase—not by that browser boolean.

- Signed-out visits to chat return to the landing page.
- Signed-in visits to the landing page route to the workspace.
- Sign Out stops local call/recording/AI activity, clears account state, signs out locally and returns to landing.
- Sign-in, signup and recovery remain separate accessible pages. Configure their existing Supabase callback URLs for your actual HTTPS domain.

**Filename caution:** your previous live chat was called `index.html`, whereas the workspace bundle uses `index.html` for landing and `catcul.html` for chat. No files were silently renamed. Use all four files as a consistent layout, or adjust all live routes together. Do not overwrite your live chat with the landing page accidentally.

No SQL, secret files or server TypeScript need to be hosted publicly. Upload HTML to your static host and deploy TypeScript through Supabase. The preview server on port 5432 serves only the four public HTML pages, not SQL, secrets or `.work` files.

If email confirmation should remain OFF, keep that setting in Supabase's Email provider. Email/password account uniqueness still comes from Supabase Auth. With confirmation OFF, ownership of an email address is not verified; plan abuse controls accordingly.

## 6. Courses, resources, homework and community

### Courses

Use **New course**, enter its name/code, and share an invite. **Join course** accepts the invitation link/code. Course chat uses the same authenticated durable messaging and Realtime system as the existing app.

The course creator becomes its owner and can add/remove pinned HTTPS resource links and homework. Other course members can read them and mark **their own** homework completion. Other students cannot read course content without membership or change another student's completion.

**There is no teacher verification/role system in this release.** Any signed-in account can create a course and thereby own it. For a curated catalog, school staff should create the official courses and distribute their links; add an institution/role policy before treating arbitrary creators as verified teachers.

### Study Mode workspace

- Left: courses and study groups, join/create controls, and conversation filters.
- Center: Chat / Study board tabs. The board is a private Gemini-powered notebook-style helper, not a shared group document.
- Right: Pinned Resources and Homework Board; use the header's Resources button on smaller screens.
- The header changes to muted gray/blue. Social rooms, friends/best friends, community and casual modules are hidden. Incoming notification sounds are muted. Existing themes, character display and cursor controls remain available where appropriate.

### Campus community

Outside Study Mode, **Campus community** opens a shared durable room. It auto-enrolls signed-in accounts without requiring friendship or an invite. Posts are visible to every signed-in account that opens the community, subject to its Study Mode lock.

Community is chat/media only, not a giant voice-call room. There is no anonymous read access, no member-owned invite/kick control, and it does not replace the private course rooms.

**“Campus” is a label, not verified school membership.** Anyone permitted to create an account can access this shared community. This is one deployment-wide community, not multi-school tenancy. If you need school-only membership, restrict signup/enrollment before rollout. Establish moderation, reporting/incident handling and retention policies before students use a shared public-to-members space.

## 7. School Wi-Fi and degraded connections

Ask IT to permit the intended HTTPS Supabase endpoint and, where allowed, Supabase Realtime WebSockets. Do not bypass school network policies.

When WebSockets fail but HTTPS requests still work, the app switches to **SYNC / polling**: durable message sends continue through Supabase, and the active conversation refreshes about every 15 seconds while visible. A banner explains the fallback. Presence/typing are unavailable in this mode. Polling preserves loaded history and the reader's scroll position.

This is not offline messaging. If HTTPS/Supabase is blocked or the device is offline, messages cannot be confirmed as saved. Gemini needs the managed endpoint to reach Google; LiveKit calls still need their media/network configuration. The cursor and local editor preview do not prove backend access.

## 8. Required live acceptance test

Use two real accounts and at least one real campus connection after deployment:

1. Register with `Alex_Smith` (or another unused custom handle). Confirm no prefix is added; try a case-variant duplicate and verify **Username already in use.**
2. Test landing → signin → workspace → Sign Out → landing. Refresh both signed-in and signed-out views.
3. Create a course, invite the second account, send messages and pin a resource/add homework. Verify outsiders cannot read it and a member cannot edit owner-managed items.
4. Turn Study Mode ON without a password. Try closing its unlock modal, reloading and signing in again; it should remain locked.
5. Enter a wrong passcode and verify the exact error. Enter the correct passcode and verify social modules return. Test the five-failure cooldown using test accounts.
6. Configure the real campus CIDR and load the workspace on campus. Confirm the detected address matches school IT's expected egress, the banner appears and mode becomes ON. Test an off-campus address without a false detection.
7. Ask Gemini an academic question. Verify chunks appear progressively, Stop works, and the helper hides/aborts when unlocked. Check a provider-error or missing-key response rather than accepting a simulated answer.
8. Post to community from A and view it on nonfriend B. Verify anonymous visitors and Study Mode sessions cannot read/post through the API.
9. Test a network with WebSockets disabled but HTTPS allowed. Verify **SYNC** mode can send messages and receive updates within the polling interval. Test a fully offline failure separately.
10. Test a phone, keyboard-only controls, the avatar editor and Cursor On/Off. Recheck individual/group LiveKit calls if you use them.

### Local validation completed

- Original schema and all three upgrades installed; school upgrade rerun in local PostgreSQL 17 with minimal Auth/Storage/Realtime fixtures.
- **35 school checks** plus **78 existing security/feature regression checks** (113 total local SQL checks): username uniqueness, social/course access, community membership, password success/failure/cooldown, direct lock bypass denial, private configuration, campus CIDRs, homework ownership and AI quotas.
- Browser tests with intercepted responses: signup validation/uniqueness/exact-case storage, landing/workspace document transitions, wrong/right passcode behavior, free enable, campus banner, course resources/homework, community, mobile layout, HTTPS sends while WebSockets are blocked, and incremental SSE rendering.
- Deno type-check and isolated school handler tests: authentication, CORS, verified actor, gateway IP source, Study Mode/quotas, fixed tutor prompt, secret isolation, SSE forwarding and missing-key errors.
- Existing avatar/social/call-interface and cursor regression tests.

**Not verified against your live services:** the actual school gateway IP, hosted database/Realtime behavior, Gemini billing/model access/live streaming, actual multi-device media, or managed-device enforcement. The isolated fixtures are tests only and are not shipped in the website.
