GuildTools 3.3.5 (v0.2.0)
===================================

What it does
------------
Command-based tools for officers on WoW 3.3.5 to:
- Link alts to a main using an officer-note token `[MAIN:Name]`
- Show a main+alts group
- Kick a whole group (main + all alts)
- Promote/Demote a whole group to a target rank index
- Export groups to SavedVariables for offline processing
- Revert your last promotegroup action (single-step undo)
- Enforce an "alt rank rule" when promoting a main
- Configure the "Established" and "Member" rank indices the addon uses for the rule

New commands
------------
/gt promotegroup <name> <rankIndex>   - promote/demote main and apply alt-rank rules
/gt revertpromote                     - revert the last promotegroup (single-step undo)
/gt setrank <Established|Member> <i>  - set the rank index for your guild roles
/gt showranks                         - show currently configured rank indexes

Alt rank rules (behaviour)
--------------------------
- You must set the rank indexes the addon uses before relying on the rule:
  /gt setrank Established <index>
  /gt setrank Member <index>

- Logic implemented:
  * If main is promoted ABOVE (numerically smaller) than Established -> alts are set to Established.
  * If main is promoted TO Established -> alts are set to Member.
  * If main is promoted TO Member -> alts are set to Member.
  * If rank rules are not set, the addon falls back to matching the main's rank for alts and prints a reminder.

Revert behaviour
----------------
- Revert stores the previous ranks of the group when you run /gt promotegroup and allows a single undo via /gt revertpromote.
- Only the last promotegroup is kept (no history).

Install
-------
1) Unzip the `GuildTools335_v0.2` folder into `Interface\AddOns\`.
2) Restart the client or `/reload`.
3) Type `/gt` in chat for help.

Notes & limitations
-------------------
- You must be an officer with promote/demote and officer-note edit permissions for most actions to work.
- Promotions/demotions are done by looping GuildPromote/GuildDemote until the desired rank is reached (3.3.5 API limitation).
- Revert will only work if the group members still exist in the guild roster (and you still have permissions).

Testing checklist (in-game)
---------------------------
1) Ensure you have officer permissions (promote/demote and edit officer notes).
2) Set rank rules, e.g. `/gt setrank Established 3` and `/gt setrank Member 4`.
3) Run `/gt show <main>` to verify the group composition.
4) Run `/gt promotegroup <main> <index>` (choose a rank to test the three cases: above Established, equal to Established, equal to Member).
5) Observe chat messages for what ranks the main and alts were set to.
6) Run `/gt revertpromote` to verify all saved ranks are restored.
7) If something doesn't work, collect the output messages and tell me the exact sequence so I can adjust the code.