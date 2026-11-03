> **Typing-bar fix:** the chat now stays within the visible window. The left navigation scrolls independently instead of stretching the chat, and the message composer stays at the bottom. Browser viewport resizing is handled, including reduced visible height. Upload the updated `catcul.html` (or your deployed chat filename) and `sw.js`, then reload/reopen the site. No new SQL or function deployment is needed.

# Catcul — conversation-first layout

This is the latest visual update. It uses a WhatsApp-style messenger structure while keeping Catcul’s identity, green palette, dark theme and existing authenticated features. No WhatsApp integration or assets are used.

## What changed

- Removed the full-width campus header, slogan and Chat / Diary / Admin mode bar.
- Full-height conversation list on the left, conversation on the right; mobile opens one pane at a time.
- Clean chat header, subtle message wallpaper, rounded composer and incoming/outgoing bubbles.
- **Chats → +** opens New chat: message an existing friend, create a group, create a study group/course, or join by invitation. New friends are still added through the authenticated friends flow.
- **Chats → ⋯** contains workspace options, including Notes, profile, call history, theme, settings and sign-out.
- **Conversation → ⋯** contains shared photos, resources, room details, invitations, plans, polls, camera, nearby, vibes, digital room and alerts. The permanent tool strip no longer crowds the conversation.
- Diary and owner-only Admin are compact navigation icons. Notes also has a pencil shortcut in the chat header; Alt+N / Escape still works.
- **Memory Lane is removed from Campus Community**, including its memory fetches. It remains collapsed by default in other rooms. No existing messages or attachments are deleted.
- Custom cursor On/Off remains available, positioned clear of Send and mobile navigation.

## Deploy this refresh

Replace the public files on your existing static host:

- `index.html`, `signup.html`, `signin.html`, `catcul.html`
- `sw.js`, `manifest.json`
- `icons/catcul-192.png`, `icons/catcul-512.png`

The workspace filenames have not changed. If you map `catcul.html` to your deployed `index.html`, retain your existing mapping and verify the links as usual.

Reload your tabs or fully close and reopen the installed app. The service-worker cache is now `catcul-shell-v10`.

**This layout-only refresh needs no new SQL or Edge Function deployment if the preceding Notes/open-workspace update is already installed.** If you have not finished that earlier update, follow `OPEN-WORKSPACE-UPDATE.md` to remove the old server-side locks. Its SQL migration must still run last. Do not repeat owner provisioning.

Only publish the public files above—not the whole ZIP, migrations, setup utilities, private bootstrap or secrets. No hosted project or website was changed automatically.

## Checks

Isolated browser checks cover the absent masthead, private-chat opening and message submission, group creation, navigation menus, community memory suppression, Notes, Diary, owner tools, photo editing, shared plans, nearby, bedrooms, map pins, audio reactions, and mobile widths of 320, 390 and 768 pixels. Light/dark layouts and public-only PWA caching were also checked.

Browser contracts use private test fixtures, not demo data shipped with the website. Hosted Realtime, calls and provider delivery remain dependent on your configured Supabase/LiveKit/push services.
