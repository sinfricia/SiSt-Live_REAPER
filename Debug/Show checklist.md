# SiSt-Live: check after every change

Run after every refactor step / change, before committing. Covers what the automated tests can't see.

## Automated (always)

- [ ] "SiSt-Live: DEBUG Run Self-Test": only the known FAILs.
- [ ] "SiSt-Live: DEBUG Run Live Test": everything passed.

## By hand

- [ ] **Looks in show mode:** theme, layouts, screenset and fullscreen look right; windows are where they
      belong; the Toolbar shows the right buttons.
- [ ] **No pop-ups and no console** during the live test, apart from the expected questions (closing projects,
      recording).
- [ ] **REAPER restart:** starts without errors, in edit mode; the Setlist opens with the saved list; the
      playback mode button is right; no kDrive conflict copies reported.

## Only if the step touched it

- [ ] Recording: playback mode "rec", the REC folder scripts.
- [ ] Rendering / export scripts.
- [ ] Region Looper: start and stop a loop.
