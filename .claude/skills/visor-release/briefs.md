# visor-release agent briefs

Fill the `{placeholders}` and send the brief as the agent's prompt, with `model: sonnet`. Send both in one message when both run. Give each agent only what its brief lists: never the chat, the notes or other files.

Placeholders: `{version}` the release version (0.9.0), `{previous_minor}` the minor before it (0.8), `{changes}` path to the output of `scripts/release-changes.sh`.

## Docs agent

```
You update Visor's docs for release {version}. Visor is a macOS notch app for people who work with AI agents. Repo: /Users/stevelam/workspace/visor.

Read {changes} first: commits since the last release and the flagged surfaces. Then edit only these files, in place:
- README.md: the Features list (short, grouped) and anything a change made wrong.
- docs/features.md: one section per feature with the fixed labels in this order, leaving out a label with nothing to say: Works with, What you see, How to use, Settings, Good to know, How it works (links to its how-it-works.md section). Add new features to Contents.
- docs/how-it-works.md: where new data comes from, new hosts Visor contacts, new files it writes ("What Visor writes").
- SECURITY.md: "What Visor reads and sends" for new hosts, files, sockets or hooks.
- docs/plugins.md: only if the plugin API changed.

To learn what a feature does, read `git show <commit> --stat` and the commit's diff for that feature only. Don't read whole source files.

Rules: no em dashes (use a hyphen or a colon); plain, short sentences; match each file's existing style and headings; no employer, work or personal names; examples use acme.ghe.com, octocat and /Users/me; don't touch docs/index.html, images or any other file; don't commit.

Reply in at most 100 words: what you changed per file, and anything you weren't sure of.
```

## Website agent

```
You update Visor's website for release {version}. The site is one page: /Users/stevelam/workspace/visor/docs/index.html.

Read {changes} first: commits since the last release. The site draws Visor's notch UI in HTML/CSS/SVG: every `<section class="feat">` has an `.f-text` column with a "Show ... in the MacBook" peek button and an `.f-media` figure with an HTML mock of that panel, and the MacBook demo at the top switches to that panel. Study how two existing sections and the MacBook panels are wired before editing.

First classify every user-facing change, and write the list at the top of your reply:
- NEW UI (a new panel, card, line or list): add a section with text, an `.f-media` figure drawing the real UI, a peek button and a matching MacBook panel, wired like its neighbours. New marks go in the SVG sprite as simple original shapes.
- CHANGED EXISTING UI (something new inside a panel the site already shows): update the existing figures and MacBook panels that show that panel, so the demos match the app.
- NO UI (behaviour only): text in an existing section or "What else is new"; no figure.
Match the real app: use the proof screenshots under `.pm/*/evidence/` named in {changes} or the commit, viewed with the Read tool, when they exist. Fake names only.

Then edit only docs/index.html, in place:
- For new features: as classified above, in the tab group they belong to (Agents, Usage, Music, Clipboard, Plugins), copying the markup and tone of the sections next to it. A section without its drawn UI is not done.
- Put <span class="tag">New in {version}</span> on the h2 of each new section. A feature that grew gets a short tag like "Worlds new in {version}".
- Tags: remove plain "New" tags and "... new in 0.x" tags older than {previous_minor}; keep tags from {previous_minor}.
- Update "What else is new" with smaller changes, and any version text that names an old version where the current one is meant.

Use `grep -n` to find sections; read only the parts you change and their neighbours. To learn what a feature does, read that commit's diff only.

Rules: no em dashes (use a hyphen or a colon); plain, short sentences in the site's voice; no employer, work or personal names; no new scripts, fonts or external links; don't touch other files; don't commit.

Reply in at most 120 words: the classification list, sections and figures added, existing demos updated, tags changed, and anything you weren't sure of.
```
