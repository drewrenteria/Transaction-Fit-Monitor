# Getting this onto GitHub

## One-time setup

If you have never set up git on this machine:

```bash
git config --global user.name  "Andrew Renteria"
git config --global user.email "your@email.com"
```

## Publish the repo

From inside the project folder:

```bash
git init
git add .
git commit -m "Transaction fit monitor: league-wide market board and club fit screening"
```

Then create the remote. Easiest with the GitHub CLI:

```bash
gh auth login                                    # once
gh repo create transaction-fit-monitor --public --source=. --push
```

Without the CLI, make an empty repo on github.com first, then:

```bash
git remote add origin https://github.com/<you>/transaction-fit-monitor.git
git branch -M main
git push -u origin main
```

**Public or private?** Public is fine and better for a portfolio: this uses only
the MLB Stats API and FanGraphs, no club-internal data. The moment you extend it
with internal data, make it private and clear `cache/` first. The `.gitignore`
already keeps `cache/` and `output/` out, so nothing fetched gets committed.

## Let people see the dashboard without running it

GitHub will not render a raw HTML file from the repo view, so the browsable
copies are committed under `docs/`, which is what Pages serves:

```
docs/index.html                  current build, replaced by the daily workflow
docs/snapshot-2026-07-04.html    frozen mid-season example, claim clocks live
docs/preview.png                 the screenshot the README leads with
```

Those are already in the repo. All that is left is **Settings → Pages →
Source: `main`, folder `/docs`**. It goes live at
`https://<you>.github.io/<repo>/` in a minute or two.

Two things worth doing while you are in Settings:

- **About → Website** (the gear beside the description on the repo home page):
  paste the Pages URL so a clickable link sits in the sidebar.
- **Settings → Features**: untick Issues, Projects and Wikis unless you want
  them. On a portfolio repo they are empty tabs.

Pages will only serve while the repo is **public**. On a Free or Pro account
there is no middle setting: a private repo's Pages site is simply off, and
there is no link-only sharing the way Google Drive does it. Access-controlled
Pages exists, but only on GitHub Enterprise Cloud. If the repo must stay
private, send people the HTML file itself instead — it is self-contained and
opens offline.

A live link is worth real money on an application. A hiring manager will click
it; they will not clone a repo and install R.

The README screenshot is a point in time; the daily workflow will move
`index.html` on past it. Regenerate it whenever you want them back in step.

## Keeping it fresh without a server

A scheduled rebuild gets you daily data with nothing to host. Create
`.github/workflows/build.yml`:

```yaml
name: Rebuild dashboard
on:
  schedule:
    - cron: "17 11 * * *"     # 11:17 UTC daily, off the hour on purpose
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: r-lib/actions/setup-r@v2
      - uses: r-lib/actions/setup-r-dependencies@v2
        with:
          packages: jsonlite, dplyr, purrr, tibble, httr2
      - run: Rscript build.R
      - run: |
          mkdir -p docs
          cp output/transaction_fit_dashboard.html docs/index.html
      - uses: stefanzweifel/git-auto-commit-action@v5
        with:
          commit_message: "Daily rebuild"
          file_pattern: docs/index.html
```

For a claim clock that only needs day-level accuracy, a daily rebuild is exactly
the right resolution. No server, no Shiny, no hosting bill.

## A note on commit history

The whole project is going in as one commit, which reads as "appeared fully
formed". If you want the history to show your reasoning, commit in stages that
match how it was actually built: the data layer, then the need thresholds, then
availability, then the brief. Reviewers who look at commits are looking for how
you think, and "fixed a bug where DFA meant Declared Free Agency, not Designated
for Assignment" is a better signal than a clean tree.
