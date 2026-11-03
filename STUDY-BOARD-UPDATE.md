# The old study board has been replaced

Follow **[OPEN-WORKSPACE-UPDATE.md](OPEN-WORKSPACE-UPDATE.md)**.

The current release replaces the old board and AI assistant with **Notes**, a plain editable quick-switch screen. No password, campus auto-lock or social restrictions remain after the final migration.

**Study groups are still supported.** `catcul-study-groups-upgrade.sql` remains a database dependency for invite-only group classification and listing. Apply it in the full documented sequence, not as the final migration. Finish with `catcul-open-workspace-upgrade.sql`.

No Gemini configuration is needed. Use Notes / Alt+N, Escape to return, and Download .txt to keep your notes. Notes is page-memory only; Diary is the separate account-synced journal.
