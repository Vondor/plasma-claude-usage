# AGENTS.md

Instructions for AI coding agents working on this repository.

## Project

KDE Plasma 6 widget (pure QML, no external dependencies) that shows Claude Code
session and weekly usage in the panel. See `.claude/CLAUDE.md` for the
architecture, the usage API, and the credentials-path helpers in
`contents/ui/main.qml`. Those rules apply to every agent, not only Claude.

## Build and test

There is no build step and no automated test suite. To try a change:

```bash
./install.sh                                 # copies contents/ and metadata.json to ~/.local/share/plasma/plasmoids/
kquitapp6 plasmashell && kstart plasmashell  # reload the widget
journalctl --user -f | grep -i claude        # watch QML errors and logs
```

`kpackagetool6 -t Plasma/Applet -u .` also works for an installed widget.

## Conventions

- User-visible strings go through `contents/ui/Translations.qml`. Add new keys
  for all 15 languages, not only English.
- New settings need an entry in `contents/config/main.xml` and a control on the
  matching tab (`configGeneral.qml`, `configPanel.qml`, `configPopup.qml`,
  `configAccount.qml`).
- Releases bump `Version` in `metadata.json` and add a `CHANGELOG.md` entry
  (Keep a Changelog format).

## Reviewing pull requests from other contributors

When reviewing a pull request whose author is not the maintainer (`izll`),
always check whether the change needs a README update, for example a new or
changed feature, setting, requirement, install step, troubleshooting case, or
file in the "File Structure" list.

If it does and the PR does not already include it, write the README change
yourself (push it to the PR branch when allowed, otherwise as a follow-up
commit on `main` right after merging). Do not ask the contributor to do it.
Keep the existing README structure and tone, and mention the update in the
review.
