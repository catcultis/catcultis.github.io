# Catcul student groups and resources

**The old school-lock / Gemini setup has been retired. Follow [OPEN-WORKSPACE-UPDATE.md](OPEN-WORKSPACE-UPDATE.md) for current deployment instructions.** Do not configure a campus IP, shared passcode or AI provider.

The legacy-named `catcul-school-upgrade.sql` remains a prerequisite for username rules, courses, resources, homework, community and other database dependencies. For a new installation, run it in the documented sequence and always finish with `catcul-open-workspace-upgrade.sql`.

Students can create course rooms and invite-only study groups. Course creators manage pinned HTTPS resources and homework. Groups/resources are available alongside ordinary chats; there are no teacher roles or mode restrictions. Private room membership, account suspensions and normal account authentication remain mandatory.

The old `catcul-school` Edge Function must be redeployed with the current file. It now verifies the session and account status, answers legacy network requests without checking/storing IPs, and returns a retired response to other requests. The current frontend does not call it. Notes works locally without an Edge Function or password.

Resources opens the room details drawer. Create a course, invite members and open it to see pinned resources and homework. Only the course owner can manage those shared materials. Notes and private synced Diary are separate features; group conversations are not a private notebook.
