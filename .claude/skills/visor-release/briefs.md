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

Read {changes} first: commits since the last release. Then edit only docs/index.html, in place:
- Add a section for each new user-facing feature, in the tab group it belongs to (Agents, Usage, Music, Clipboard, Plugins), copying the markup and tone of the sections next to it. Reuse an existing image only if it shows the feature; otherwise no image.
- Put <span class="tag">New in {version}</span> on the h2 of each new section. A feature that grew gets a short tag like "Worlds new in {version}".
- Tags: remove plain "New" tags and "... new in 0.x" tags older than {previous_minor}; keep tags from {previous_minor}.
- Update "What else is new" with smaller changes, and any version text that names an old version where the current one is meant.

Use `grep -n` to find sections; read only the parts you change and their neighbours. To learn what a feature does, read that commit's diff only.

Rules: no em dashes (use a hyphen or a colon); plain, short sentences in the site's voice; no employer, work or personal names; no new scripts, fonts or external links; don't touch other files; don't commit.

Reply in at most 100 words: sections added, tags changed, and anything you weren't sure of.
```
