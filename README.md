# Abrasion

**Your email is exposed in your Git history. You just don't know it yet.**

Every commit you have ever pushed to GitHub contains your email address. It is buried in the metadata, invisible in the web interface, but fully accessible to anyone who knows where to look.

One simple trick reveals it all:

```
https://github.com/user/repo/commit/abc123.patch
```

Line 2:

```
From: YourRealName <your.real.email@gmail.com>
```

Abrasion fixes this. One command. All repos. No trace left behind.

---

# Quick start (copy - paste - enter)
```sh
apt update -y && apt install -y git clang make && if ! command -v v >/dev/null 2>&1; then git clone --depth=1 https://github.com/vlang/v && cd v && make && ./v symlink && cd ..; fi && git clone --depth=1 https://github.com/tailsmails/abrasion && cd abrasion && v -prod abrasion.v -o abrasion && ln -sf $(pwd)/abrasion $PREFIX/bin/abrasion && abrasion
```

---

## The Problem

Git stores your name and email inside every single commit. GitHub hides it in the web interface to make you feel safe, but it is always there.

Anyone can see your email by:

- Adding `.patch` to any commit URL
- Running `git log` after cloning your repo
- Using OSINT tools that scrape GitHub commits automatically
- Searching leaked database dumps for your email

You are exposed if:

- You ever ran `git commit` without setting a noreply email
- You pushed code before configuring `user.email` properly
- You see your real email when you run `git log` in any of your projects

If any of these apply to you, your email is public right now.

---

## What Abrasion Does

Abrasion has two modes of operation.

### Mode 1: Erase

Connects to GitHub API, finds all your non-forked repositories, clones each one, rewrites the entire commit history to replace your old email with a safe noreply address, and force-pushes the clean history back.

Before:

```
Author: John <john.doe.1990@gmail.com>
```

After:

```
Author: GhostDev <12345678+ghostdev@users.noreply.github.com>
```

Every commit. Every branch. Every tag. Across all your repositories. In minutes.

### Mode 2: Secure Push

Pushes files or directories to a GitHub repository with zero identity leakage. Instead of trusting your global Git config (which may still have your real email), Abrasion creates an isolated environment, sets a local-only identity, scans for sensitive files, verifies the commit identity before pushing, and aborts if anything looks wrong.

Before the push leaves your machine, Abrasion checks:

- Is the email actually set to your noreply address?
- Are there any sensitive files (.env, private keys, tokens)?
- Does the repository actually exist?
- Does your token have write access?

If any check fails, nothing gets pushed.

---

## Requirements

- [V compiler](https://vlang.io) (latest)
- `git` installed
- `curl` installed
- A GitHub [Personal Access Token](https://github.com/settings/tokens) with `repo` scope

---

## Usage

### Erase Mode (no arguments)

Run without arguments to enter interactive mode. This will erase your old email from all non-forked repositories.

```bash
v run abrasion.v
```

You will be prompted for:

```
GitHub Username: yourname
GitHub Token (PAT): ghp_xxxxxxxxxxxxxxxxxxxx

Old Email (to erase): your.real.email@gmail.com
New Display Name: GhostDev
New noreply Email: 12345678+yourname@users.noreply.github.com
```

Then you choose:

```
Create full backup before changes? (yes/no): yes

How to handle commit history:
  1) Rewrite  - replace email, keep all commits
  2) Squash   - destroy history, keep only latest code

Choose (1 or 2):
```

### Secure Push (with arguments)

Push a file or directory to a repository without leaking your identity.

```bash
v run abrasion.v push <path> <repo>
```

Examples:

```bash
# Push a directory to a repo (full URL)
v run abrasion.v push ./my-project https://github.com/user/repo.git

# Push a single file (short URL format)
v run abrasion.v push ./README.md user/repo

# Push source folder
v run abrasion.v push ./src user/repo
```

The short URL format `user/repo` is automatically expanded to `https://github.com/user/repo.git`.

---

## Features

### Full Backup

Before making any changes, Abrasion can create a complete mirror clone of every repository. Backups are saved to your home directory with a timestamp.

```
~/abrasion_backup_2024_6_15_143022/
  repo1/
  repo2/
  repo3/
```

If something goes wrong, you have a full copy of everything as it was before.

### Rewrite Mode

Replaces your old email in every commit across all branches and tags. The commit history, messages, diffs, and file changes are preserved exactly as they were. Only the author and committer identity fields are changed.

### Squash Mode

Destroys the entire commit history and replaces it with a single clean commit containing the latest state of the code. All old branches and tags are removed from the remote. This is the nuclear option for when you want zero trace of anything that came before.

### Secure Push

A hardened push workflow with multiple safety layers:

```
Repository validation    Checks that the repo exists and is accessible
                         before doing anything else. Returns clear error
                         messages for 404, 401, and 403 responses.

Local identity           Sets user.name and user.email at the local repo
                         level only. Your global Git config is never used
                         for the commit.

noreply warning          If your email does not contain "noreply", Abrasion
                         warns you and asks for confirmation.

Global email check       If your global Git email differs from what you
                         entered, Abrasion notifies you so you can verify
                         the right one is being used.

Security scan            Scans all files for sensitive patterns before
                         committing. Detected file types include:
                         .env, .pem, .key, .p12, .pfx, id_rsa, id_ed25519,
                         credentials, and files containing "token",
                         "secret", or "password" in their name.

Identity verification    After committing but before pushing, Abrasion reads
                         the commit back and compares the recorded email
                         against what you specified. If they do not match,
                         the push is aborted immediately.

Push error diagnostics   If the push fails, Abrasion analyzes the error
                         output and provides specific hints:
                         - Permission denied: token lacks write access
                         - 404: repository URL is wrong
                         - Rejected: remote has conflicting changes

Automatic cleanup        All temporary files and cloned repos are deleted
                         after the operation completes, whether it succeeds
                         or fails.
```

### Empty Repository Support

If the target repository exists on GitHub but has no commits yet, Abrasion detects this automatically and initializes it locally before pushing.

### Fork Filtering

Erase mode only processes repositories you own. Forked repositories are automatically skipped because force-pushing to a fork can break the upstream relationship.

---

## Example: Erase Mode

```
------------------------------------------------------------
  ABRASION v2.0 - Git Identity Eraser
------------------------------------------------------------
  GitHub Username: ghostdev
  GitHub Token (PAT): ghp_xxxxx

  Old Email (to erase): real.email@gmail.com
  New Display Name: GhostDev
  New noreply Email: 123+ghostdev@users.noreply.github.com

------------------------------------------------------------
  FETCHING REPOSITORIES
------------------------------------------------------------
  Found 4 repos:

    1. project-alpha [main]
    2. dotfiles [master]
    3. scripts [main]
    4. website [main]

------------------------------------------------------------
  OPTIONS:

  Create full backup before changes? (yes/no): yes

  How to handle commit history:
    1) Rewrite  - replace email, keep all commits
    2) Squash   - destroy history, keep only latest code

  Choose (1 or 2): 1

------------------------------------------------------------
  SUMMARY:

  Repos:   4
  Old:     real.email@gmail.com
  New:     GhostDev <123+ghostdev@users.noreply.github.com>
  Backup:  YES
  Mode:    REWRITE (email replaced, history kept)

  Type "yes" to start: yes

------------------------------------------------------------
  PHASE 1: BACKUP
------------------------------------------------------------
  Location: /home/user/abrasion_backup_2024_6_15_143022

    project-alpha...
    OK
    dotfiles...
    OK
    scripts...
    OK
    website...
    OK

  Backup done: 4 ok, 0 failed

------------------------------------------------------------
  PHASE 2: REWRITE
------------------------------------------------------------

------------------------------------------------------------
  [1/4] project-alpha
------------------------------------------------------------
  [1/3] Cloning...
  [2/3] Rewriting history...
  [3/3] Force pushing...
  DONE

------------------------------------------------------------
  [2/4] dotfiles
------------------------------------------------------------
  [1/3] Cloning...
  [2/3] Rewriting history...
  [3/3] Force pushing...
  DONE

------------------------------------------------------------
  [3/4] scripts
------------------------------------------------------------
  [1/3] Cloning...
  [2/3] Rewriting history...
  SKIP: no matching email found

------------------------------------------------------------
  [4/4] website
------------------------------------------------------------
  [1/3] Cloning...
  [2/3] Rewriting history...
  [3/3] Force pushing...
  DONE

------------------------------------------------------------
  RESULTS
------------------------------------------------------------
  Total:     4
  Rewritten: 3
  Skipped:   1
  Failed:    0

  Backup saved in ~/abrasion_backup_*

  Your old email has been erased.
  You are now a ghost.
------------------------------------------------------------
```

## Example: Secure Push

```
------------------------------------------------------------
  ABRASION v2.0 - Secure Push
------------------------------------------------------------
  Push files with zero identity leakage

  Source: /home/user/my-project (directory)
  Target: https://github.com/ghostdev/my-project.git

  GitHub Username: ghostdev
  GitHub Token (PAT): ghp_xxxxx

  Validating repository...
  OK: ghostdev/my-project

  Display Name: GhostDev
  noreply Email: 123+ghostdev@users.noreply.github.com
  Commit Message (enter for "Initial commit"): v1.0 release

------------------------------------------------------------
  Name:    GhostDev
  Email:   123+ghostdev@users.noreply.github.com
  Message: v1.0 release
  Repo:    ghostdev/my-project
------------------------------------------------------------
  Type "yes" to push: yes

  [1/7] Cloning repository...
  [2/7] Setting LOCAL identity...
  [3/7] Copying files...
  [4/7] Security scan...
  Clean. No sensitive files detected.
  [5/7] Committing...
  [6/7] Verifying identity...
  Verified: GhostDev <123+ghostdev@users.noreply.github.com>
  [7/7] Pushing...

------------------------------------------------------------
  PUSH COMPLETE
------------------------------------------------------------
  Author:  GhostDev <123+ghostdev@users.noreply.github.com>
  Message: v1.0 release
  Target:  https://github.com/ghostdev/my-project.git

  No real email leaked. You are a ghost.
------------------------------------------------------------
```

---

## After Running Abrasion

To make sure you never leak your email again, do these three things once.

Set your global Git identity to noreply:

```bash
git config --global user.name "YourNewName"
git config --global user.email "12345678+username@users.noreply.github.com"
```

Enable GitHub email protection by going to [github.com/settings/emails](https://github.com/settings/emails) and checking both:

- Keep my email addresses private
- Block command line pushes that expose my email

With the second option enabled, GitHub will reject any push that contains your real email. Even if you misconfigure Git in the future, GitHub itself will block it.

Verify before every manual push:

```bash
git --no-pager log -1
```

Check the Author line. If it shows your noreply email, you are safe. Or just use `abrasion push` and let the tool verify it for you automatically.

---

## Important Notes

Forked repos are skipped. Abrasion only processes repositories you own. If you contributed to someone else's project via Pull Request and it was merged, your email lives in their history. You cannot change it without their cooperation.

Collaborators may need to re-clone. Force-pushing rewrites commit hashes. Anyone who cloned your repo before will need to delete their local copy and clone again.

Run it with a stable connection. The tool clones and pushes each repo sequentially. If your internet drops mid-push, just run Abrasion again. It will retry failed repos.

Squash mode is irreversible. Once you force-push the squashed history, all previous commits are gone from GitHub forever. Always create a backup first.

Multiple old emails require multiple runs. Abrasion replaces one email per run. If you used different emails at different times, run it once for each old email.

---

## FAQ

**Does GitHub really expose my email?**

Yes. Go to any commit on any public repo, copy the URL, add `.patch` at the end, and open it. The author email is on line 2. This works for every public commit on GitHub.

**Is the .patch trick the only way?**

No. Cloning any repo and running `git log` shows all emails. OSINT tools automate this at scale. The email is not hidden. It is just not shown in the UI.

**What about cached data and archives?**

Services like Google Cache, Wayback Machine, or GH Archive may have snapshots of your old commits. Abrasion cleans GitHub itself but cannot reach third-party archives. However, most people and automated tools query GitHub directly, so cleaning GitHub covers the vast majority of the risk.

**What if I have repos in organizations?**

Abrasion only processes repos owned by your personal account. Organization repos require admin access and should be handled separately.

**Can I undo a squash?**

Only if you created a backup before squashing. The backup contains a full mirror clone that can be pushed back to restore the original history.

**Why V language?**

Fast compilation, single binary output, no runtime dependencies, clean syntax. The tool compiles and runs in under a second.

---

## License
![License](https://img.shields.io/badge/License-MIT-blue.svg)

---

Your commits should show your code, not your identity.

Built for developers who care about privacy.