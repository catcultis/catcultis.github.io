# Catcul Character Studio

An original rounded Catcul character that each person can customize and save. It uses the same general idea of a dress-up avatar, but the artwork and editor are original—not Wayground/Qbit assets.

## What people can customize

- **Body:** soft square, round puff or little bean.
- **Fur:** preset colors or any color from the color picker; solid, tabby, tuxedo or patches.
- **Face:** bright, sleepy, winking or starry eyes; expressions; rosy cheeks or freckles.
- **Cat features:** pointed, rounded, folded or no ears; curly, fluffy, long or no tail; optional whiskers.
- **Style:** hoodie, overalls, scarf or no outfit; glasses, bow, headphones, crown or no accessory.
- **Backdrop and accent:** presets or custom colors.
- **Editing:** live preview, Surprise me, Undo, Reset to your saved look, Cancel and Save.

All included choices are available to everyone—no coins or unlocks. This is a mix-and-match editor for the included parts, not an AI generator or a freehand/imported-image editor. Adding entirely new item types later requires new artwork/code and an expanded database allowlist.

## Activate it on your site

### 1. Run the avatar migration

If you already installed both previous Catcul SQL files:

1. Open your Supabase project's **SQL Editor → New query**.
2. Paste all of **`catcul-avatar-upgrade.sql`**.
3. Click **Run**.
4. Look for **“Catcul character profiles are ready. Publish the updated chat page.”**

For a fresh setup, or if you have not yet applied the friends/calls upgrade, run in this order:

```text
1. catcul-setup.sql
2. catcul-social-upgrade.sql
3. catcul-avatar-upgrade.sql
```

The new migration preserves your existing users, chats, messages and friends. It adds a validated `avatar` JSON column to `catcul.profiles`, grants users permission to update only their own profile under the existing row policies, and includes avatar data in username discovery, friend lists and call metadata.

The script is transactional and rerunnable. **If you rerun an older migration, rerun every later migration in order as well.** Earlier scripts contain older function definitions. Keep `catcul` in your project's exposed Data API schemas.

No new storage bucket, image upload service, or secret key is needed. Character artwork is rendered from validated settings inside the HTML. Do not modify RLS or expose service keys to make saving work.

### 2. Publish the updated HTML

Use the updated **`catcul.html`** in `catcul-website.zip`. It contains the character artwork, editor, CSS and all existing chat features. All four supplied HTML pages retain the custom cursor.

**Filenames are unchanged:** the workspace's `index.html` is the landing page and `catcul.html` is chat. You previously used `index.html` for chat on your live site. Do not overwrite that live chat with this bundle's landing page by mistake. Keep your live routing consistent; see the filename notes in `VOICE-AND-FRIENDS-SETUP.md`.

### 3. If you already deployed calling

Redeploy the updated **`supabase/functions/catcul-calls/index.ts`** through the Supabase dashboard. It now includes the saved character in authenticated LiveKit participant metadata, so voice participants can render it even before their profile has been cached.

No new LiveKit credentials or secrets are required for this update. Character customization and profile saving do **not** require LiveKit. Voice calling still requires the provider configuration described in the existing voice guide.

## How to use it

1. Sign in to Catcul on your real HTTPS website.
2. Click your profile avatar/name.
3. Choose **Make your character yours**.
4. Explore **Body**, **Face**, **Cat bits**, **Style** and **Backdrop**.
5. Select **Save my character**.

The saved character appears on your profile, beside messages, in friends/best-friends lists, private-chat headers, group-member lists, and call participants. New accounts start with a default cat; users who have not customized it use their starter color.

**Reset** restores the saved look; **Undo** reverses a recent editor change. **Cancel**, Escape or closing the editor discards changes that have not been saved. Saving requires a signed-in account and a network connection—this is not a browser-only avatar pretending to be saved online.

Profile changes use authenticated Realtime updates, with periodic profile/friend refreshes while the app is open. A recipient may need to wait briefly or refresh after reconnecting.

## Confirm it works on your project

1. Customize account A and save.
2. Refresh and sign back in. Verify the same character returns.
3. On account B, view A in a friend list and a chat. Verify the saved character appears there too.
4. Test changing ears, tail, custom colors and an outfit. Confirm Preview and Save agree.
5. Test Cancel and Reset; they should not overwrite the saved profile.
6. Try a mobile browser and a group/individual call after the calling setup is active.

Arena's embedded file preview cannot connect to Supabase. Use the deployed HTTPS site for account saving and multi-user tests.

## If Save fails

- **“Run catcul-avatar-upgrade.sql…”**: install this migration in the same Supabase project used by the website, then retry. The editor keeps your draft after a save error.
- **Missing `find_people_with_avatars` RPC**: run the avatar migration and, if necessary, execute `notify pgrst, 'reload schema';` in SQL Editor.
- **Permission/session error**: sign out and back in. Do not disable row-level security.
- **Other people see an older/default look**: confirm the migration, updated chat page and refreshed browser cache. Redeploy the updated Edge Function for the voice metadata fallback.

## Validation and deployment status

Checked locally:

- PostgreSQL 17 installation and migration rerun; 18 avatar/security checks covering persistence, discovery, calls, blocking, ownership restrictions, valid parameters and malicious/invalid input rejection.
- The existing base and 43 social/security regression checks.
- Browser checks for choices, custom colors, randomize/undo/reset, save/reload contracts, failure handling, keyboard tabs, mobile layouts, dark mode and profile-change rendering.
- Existing Auth, social/call interface and custom cursor regressions; Deno type-check and isolated Edge Function/JWT tests.

Browser account/provider responses were intercepted in isolated tests; test contacts are not shipped in the website. **The assistant has not applied SQL, published your site, or verified real two-account persistence/Realtime on your external project.** Finish the checklist above after deployment.
