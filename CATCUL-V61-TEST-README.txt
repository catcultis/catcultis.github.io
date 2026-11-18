CATCUL TEST PACKAGE v61 — static website, not a full final release

This is a test build for your existing Catcul project. It has NOT been published by the assistant.

Unzip at the root of your existing website, replacing the matching files. Keep your existing other assets and recovery backups; do not delete user files or Supabase objects. This zip includes the pages, manifest, service worker, icons, models, third-party notices, and the three game-link images required by this build. It intentionally does not contain the retired Eaglercraft files or the removed unverified curated franchise wallpapers.

Test in a group chat: Chat menu > Most Likely To, Imposter Cat, Two Truths and a Lie, and Word Chain. Word Chain checks letters and repeats, but does not check a dictionary. Other unfinished games, including Word Bomb, Mafia and Drawing Telephone, are NOT included in this build. Game state is stored on the server, not end-to-end encrypted; follow each game's privacy instructions.

The build points at your existing live Supabase project, even on a preview URL. Test users, messages and game actions may affect real project data. Use a dedicated test group and non-sensitive test content. Depending on your hosting URL, sign-in and redirects may need your existing Supabase configuration; do not turn on mandatory email verification. The service worker updates its cache; close/reopen the app if the old version persists.

Guest voice is NOT enabled in this package. Its authorization, safe disconnection, expiry, worker, and end-to-end tests are incomplete. Regular calling remains as previously configured.

Photo optimization is in progress: local synthetic photo tests passed on Chromium and WebKit. Image encoding can reduce quality; actual resolution depends on original, device, editing and settings. Real devices and all upload paths require further testing. Video transcoding and the planned aggregate storage budget are NOT implemented. Supabase's per-object limits still apply; compression does not guarantee that the 1 GB organization allowance is respected.

Most Likely To, Imposter Cat, Two Truths, Word Chain UI have passed mock browser checks; Word Chain and other applied backends have passed prior rollback database checks. These do not establish real multi-user/device reliability, real call reliability, or concurrency safety. Please report errors with browser/device and steps, without sharing passwords, session tokens, or private data.

No SQL migrations are packaged or need to be rerun for the included game backends; they were already applied to this project. No voice scheduler or issuer is deployed here. Do not apply local DRAFT SQL files.
