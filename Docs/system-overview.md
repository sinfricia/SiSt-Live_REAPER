# SiSt-Live: how the system works

For developers. The operator documentation is a separate project. Plan: roadmap.md, rules: design-decisions.md.

## Rig
- One computer (development machine = show machine), portable REAPER install in kDrive.
- Behringer WING = the only audio interface: audio, MIDI, recording, timecode to the lighting desk, all over USB.
  On the WING: snapshots and snippets (not "scenes").
- REAPER automates the WING via MIDI: program changes recall snapshots and snippets, MIDI CC controls a range
  of parameters.
- Some functions may be remote controlled from the WING later. Which MIDI messages trigger what doesn't matter
  for the code until further notice.

## Projects and signal flow
- One ROUTING project (name contains "ROUTING") + one project per song, all open as tabs.
  "Run background projects" must be on.
- Song projects send audio and MIDI into the routing project through REAPER's internal loopbacks
  (audio: loopback channels 1:1; MIDI: loopback devices "LB<n> OUT/IN <function>"). Only the routing project
  talks to the hardware.
- Songs: =START marker (song start, may be after 0), end marker with an action marker that runs one of the
  Project End Handler custom actions. REC folder: the tracks that record in rec mode.

## Show flow
- Start Show: resets every open project (stop, clear time selection and loop points, unmute/unsolo all, go to
  start, clear repeat, playback zoom, remove export tracks, mute hardware outs 1/2), then asks whether to record
  and starts the routing project (recording it in rec mode).
- Start Song: only when stopped, paused or inside the "SONG ANNOUNCEMENT" region: stops the other song projects,
  moves to the song start (=START) and plays or records the active song.
- Project End Handler (three custom actions): normal (stop, switch to the next song's tab and
  prepare it), NO STOP (switches without stopping), move to previous project (plays from 0).
- Playback mode play / rec (ExtState SiSt-Live / playback_mode, toolbar toggle).
- Region Looper (deferred, started by __startup.lua): regions "LOOP <n>" loop n times, "LOOP" until Stop loop
  (then one final pass).

## Modes
- Edit / Show. Show = safe for stage: theme, layouts, screenset, keyboard section SHOW, fullscreen, locking,
  windows (Setlist, Status Display, Toolbar). REAPER always starts in edit mode (__startup.lua).

## Components
- Setlist (song order = project tab order, autosave), Status Display (mode + problems), Toolbar (copy of a
  native floating toolbar), Setup (package entry point), Debug tools (self-test, live test).

## Config parts outside the repo
- __startup.lua, Scripts/SiSt-Local (general scripts; source of truth: Sina's main install),
  reaper-kb.ini (custom actions, shortcuts), reaper-menu.ini (toolbars), S&M_Cyclactions.ini,
  reaper-extstate.ini (saved settings of all scripts).
