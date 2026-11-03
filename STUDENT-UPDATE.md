# Catcul: photo studio, private diary and owner tools

This release updates the workspace files. It does **not** apply migrations, deploy Edge Functions, change secrets, or grant ownership in your hosted project automatically.

## Update an existing Catcul installation

1. Keep your existing base, social, avatar, school, study-group and campus migrations. In Supabase → SQL Editor, run **catcul-student-upgrade.sql**, then **catcul-social-canvas-upgrade.sql**.
2. Run **catcul-admin-bootstrap.sql privately in SQL Editor**. It now contains the owner email you supplied. That email must already belong to a registered Catcul account with a profile. Refresh after running it.
   - Do not upload this bootstrap script to a public website/repository.
   - Browser metadata, an email in frontend code, and a shared password do not grant admin access.
   - The script refuses to accidentally replace a different existing owner.
3. Deploy the new **catcul-admin** function using `supabase/functions/catcul-admin/index.ts`.
4. Redeploy **catcul-school** and **catcul-calls** from this release. They now check account suspension before performing actions.
5. Use the `verify_jwt = false` settings in `supabase/config.toml`, or disable the legacy gateway JWT check for these functions in the Dashboard. Each handler still verifies the user's token with Supabase Auth. Never remove that verification.
6. Keep `ALLOWED_ORIGINS` set to your actual HTTPS website origin, without a trailing slash; comma-separate additional origins if needed. Existing LiveKit secrets are reused for suspension-related call cleanup.
7. Upload the website files and PWA assets described in **SOCIAL-CANVAS-UPDATE.md**. No user-managed Node.js or Python server is required.

For a new installation, the SQL order is:

1. `catcul-setup.sql`
2. `catcul-social-upgrade.sql`
3. `catcul-avatar-upgrade.sql`
4. `catcul-school-upgrade.sql`
5. `catcul-study-groups-upgrade.sql`
6. `catcul-campus-config.sql`
7. `catcul-student-upgrade.sql`
8. `catcul-social-canvas-upgrade.sql`
9. `catcul-admin-bootstrap.sql` — private, owner-only setup

**Run the two new upgrades last if you rerun older migrations.** The student migration adds guards to existing authenticated SECURITY DEFINER functions, which ordinary RLS alone cannot protect against suspended sessions. The canvas upgrade extends private Realtime topic authorization.

## What changed

### Photo studio

Choose, paste, drop or capture a still photo in chat. The editor provides eight looks, four frame styles, cropping, rotation, draggable/resizable emoji stickers, captions and an optional date stamp. Arrow keys move a selected sticker. Editing happens locally in a real canvas. **Use this photo** stages a compressed JPEG; the existing Send action uploads it to private Supabase Storage. Nothing uploads merely because you open the editor. GIFs become still images. This is not face-tracked AR. Native camera capture depends on the device/browser.

### Diary Mode

Diary entries sync to the signed-in Supabase account. Only that account can read/change them through the app's database policies; the app admin panel has no diary-reading endpoint. Autosave reports success only after the server responds. Revision checks prevent a stale browser from silently overwriting another device's changes. Conflicts offer loading the latest entry or saving a separate copy. Entries can be downloaded as plain text.

**This is not end-to-end encryption.** Supabase project operators with database/service credentials can technically access stored content. Do not describe it as inaccessible to the database operator. No unsaved diary bodies are deliberately persisted in localStorage. Keep the page open, retry or download your draft if offline; browser/tab termination can still lose unsaved work. Sign-out clears diary UI and state.

### Owner panel

The owner sees Admin beside Chat and Diary. It includes current account/room/message/report totals, school passcode and public campus IP configuration, account suspensions/restoration, reported-message review, community moderation, nearby-post moderation and a recent activity log.

- **Change the initial `unlockcatcul` passcode before sharing the app.** New passcodes require 10–72 UTF-8 bytes. Only the hash is stored, never the plaintext in the audit log.
- A report explicitly shares that message's snapshot, reporter identity and available attachment for moderation. It does not grant blanket access to private chats.
- The admin can remove a community post or a reported private message. Other private messages cannot be arbitrarily browsed or removed from this panel.
- Moderation soft-deletes messages. Already downloaded media and unexpired signed URLs cannot be recalled. Normal media links can remain valid for up to one hour; reported-attachment review links last 60 seconds.
- Suspension blocks database reads/writes and RPCs for existing JWTs, then attempts the Auth ban and LiveKit participant/token revocation. The UI reports pending provider synchronization rather than pretending it succeeded. Save the same state again to retry cleanup. Existing active screens normally refresh their status within about 15 seconds; requests already in flight and cached Realtime presence are not guaranteed to vanish instantly.
- Owner/admin accounts are protected from panel suspension. Ownership changes require privileged SQL; there is no student-accessible role-grant endpoint.
- Usage totals are database counts—not analytics visitors, billing data or a count of people currently online.

The app remains students-only. Course rooms and study groups are student-led; no teacher role was added. No YouTube or money/payment functionality was added.

## Validation

Local PostgreSQL security/regression tests, isolated browser contracts and managed-function tests are included in the private development workspace. They are not evidence of deployment to your project or successful real Gemini, LiveKit or push-provider delivery. Test with two real accounts after deploying.
