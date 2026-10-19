# Catcul — Study board & study groups update

> **Current release:** YouTube lesson search has been removed. Gemini, study groups and the school password gate remain. No YouTube key or migration is needed. If you deployed the previous YouTube-enabled Edge Function, redeploy the current `supabase/functions/catcul-school/index.ts` to remove its lesson-search action too. This update does not delete hosted tables or revoke stored secrets automatically.

## What changed

- The header now has Catcul branding, a clear Study Mode switch, Resources and Sign Out instead of the generic dashboard title.
- The sidebar has **Your spaces**, dedicated **Study group / Join** controls, course and study-group filters, a distinct community entry, and an expandable Network status at the bottom. The raw IP is no longer always shown above your conversations.
- Gemini answers appear **in the center conversation area**, with a compact question input in the sidebar. While Study Mode is on, use **Chat / Study board** tabs. The board opens by default when Study Mode is activated.
- The board has a restrained notebook layout, question starters and a streaming explanation—not robot icons, glowing effects or oversized AI branding. A small **AI help · Gemini** label and privacy notice remain so students know what generates the answers.
- Switching to the board does not mark hidden chat messages as read. Switching back to Chat retains the conversation and message draft.
- Study groups are invite-only academic conversations, available in Study Mode. The creator can pin resources and add homework. Group members can chat and read resources. Normal course rooms remain distinct.

## Update an existing installation

1. Back up the current website/database.
2. In **Supabase → SQL Editor**, run **`catcul-study-groups-upgrade.sql`** after the existing school migration. It is safe to rerun and does not change the school password or campus IPs.
3. Replace the deployed chat page with the updated **`catcul.html`**. No files need to be deleted first: GitHub uploads with the same paths update them in place. Keep your existing entry-point mapping consistent; this bundle still uses `index.html` for landing and `catcul.html` for chat. It has not silently renamed your live chat file.
4. Refresh the app. Turn Study Mode on, open **Study board**, and create a group with the sidebar's **Study group** button.

No new API secret or Edge Function is required for this visual/group update. The existing `catcul-school` function and server-side `GEMINI_API_KEY` must already be configured for actual AI answers. Existing LiveKit configuration is still required for voice calls.

If you have not installed the school release yet, follow `SCHOOL-SETUP.md` first. Complete migration order:

```text
catcul-setup.sql
catcul-social-upgrade.sql
catcul-avatar-upgrade.sql
catcul-school-upgrade.sql
catcul-study-groups-upgrade.sql
catcul-campus-config.sql       # confirmed school IP: 129.222.205.220/32
```

The campus IP file was prepared earlier; it has **not** been applied to your hosted project by the assistant. The new group migration also has **not** been deployed remotely.

## Using a study group

1. Click **Study group** and enter a name, plus an optional subject.
2. Creation saves a real room and owner membership in Supabase, then opens its invitation.
3. Share the link with classmates. They sign in and open it, or click **Join** and paste the link/code.
4. Members can chat during Study Mode. Resource/homework management belongs to the group owner, following the existing course rules.

There is no public group directory or school-teacher verification in this release. A valid invitation is a bearer link: anyone with the link and an account can join until it expires, is exhausted or is revoked. Share it privately. Invites retain the existing seven-day/50-new-member limits; owners can revoke them through room controls. Joining a study group does not turn Study Mode off.

The new schema uses `rooms.is_study_group` alongside the existing academic `purpose='course'`, so academic membership, RLS, Storage, invitation and calling restrictions continue to apply. `create_study_group` creates only a new academic room—it cannot reclassify a social room to bypass Study Mode. `list_study_spaces` adds classification without changing the old workspace RPC's return type.

Older school databases can still list rooms using the client's fallback RPC. Attempting to create a study group before installing its migration shows a setup error; it does not pretend the group was saved.

## Study board privacy

The board is a **personal study helper**, not a shared editable document. Your questions and answers are not posted to the group. Only the question you submit is sent to the managed Gemini endpoint; the app does not automatically send the group conversation. Questions remain independent requests, not a persisted multi-turn AI chat.

The board's answer is kept in the current browser view, not saved as a group message or a permanent note. Turning Study Mode off clears the answer and stops the request. Signing out also aborts the request and unmounts the workspace. Google service terms, provider retention and the school's consent/eligibility requirements still apply; see the school guide. Students should not submit sensitive information and should check explanations for mistakes.

The password gate, five-attempt cooldown, server-only secrets and AI usage quotas are unchanged. A notebook-style presentation does not make the generated answers human-written.

## Validation

Completed locally:
- All original migrations plus the new group migration installed in PostgreSQL 17; the new migration reapplied successfully.
- **23 new SQL assertions** cover authenticated creation, protected classification, owner rights, invite-only joins, reading/posting during Study Mode, outsider denial, leaving/revoked access and preservation of the confirmed campus setting.
- **113 existing SQL assertions** passed against the updated schema.
- Browser tests cover central placement, Chat/Study board switching, keyboard tab navigation, question starters, incremental SSE rendering, hidden-chat read handling, private-group creation/invite/join/filter controls, missing-migration recovery, wrong/right password unlocking, resource/homework controls, sign-out, desktop/mobile and dark mode.
- Authentication, avatar editor, cursor On/Off, social controls and mocked calling-interface regression tests passed.

All browser/provider fixtures are isolated test code and are not shipped in the HTML. No real Gemini request, hosted multi-account test or external Supabase deployment was performed for this update. The live workspace preview runs on port **5432**; it still needs your real backend setup to function with real accounts.
