module main

import os
import json
import time

struct Repo {
pub:
	name           string
	clone_url      string
	fork           bool
	default_branch string
}

fn sep() {
	println('─'.repeat(60))
}

fn header(t string) {
	sep()
	println('  ${t}')
	sep()
}

fn auth_url(url string, user string, token string) string {
	return url.replace('https://', 'https://' + user + ':' + token + '@')
}

fn expand_url(raw string) string {
	if raw.starts_with('https://') || raw.starts_with('http://') {
		return raw
	}
	return 'https://github.com/' + raw + '.git'
}

fn fetch_repos(user string, token string) ![]Repo {
	mut all := []Repo{}
	mut page := 1
	for {
		cmd := 'curl -s -H "Authorization: token ' + token + '" -H "User-Agent: abrasion" "https://api.github.com/user/repos?type=owner&per_page=100&page=' +
			page.str() + '"'
		r := os.execute(cmd)
		if r.exit_code != 0 {
			return error('curl failed')
		}
		if r.output.contains('"Bad credentials"') {
			return error('Invalid token')
		}
		repos := json.decode([]Repo, r.output) or {
			return error('JSON error: ${err}')
		}
		if repos.len == 0 {
			break
		}
		all << repos
		page++
	}
	return all
}

fn write_filter(old_email string, new_name string, new_email string) !string {
	path := os.join_path(os.temp_dir(), 'abrasion_filter.sh')
	d := '\x24'
	mut s := ''
	s += 'if [ "' + d + 'GIT_COMMITTER_EMAIL" = "' + old_email + '" ]\n'
	s += 'then\n'
	s += '    export GIT_COMMITTER_NAME="' + new_name + '"\n'
	s += '    export GIT_COMMITTER_EMAIL="' + new_email + '"\n'
	s += 'fi\n'
	s += 'if [ "' + d + 'GIT_AUTHOR_EMAIL" = "' + old_email + '" ]\n'
	s += 'then\n'
	s += '    export GIT_AUTHOR_NAME="' + new_name + '"\n'
	s += '    export GIT_AUTHOR_EMAIL="' + new_email + '"\n'
	s += 'fi\n'
	os.write_file(path, s)!
	return path
}

fn backup_repo(repo Repo, user string, token string, backup_dir string) bool {
	dir := os.join_path(backup_dir, repo.name)
	url := auth_url(repo.clone_url, user, token)
	println('    ${repo.name}...')
	r := os.execute('git clone --mirror "' + url + '" "' + dir + '" 2>&1')
	if r.exit_code == 0 {
		println('    OK')
		return true
	}
	println('    FAILED')
	return false
}

fn rewrite_repo(repo Repo, user string, token string, filter string, tmp string) int {
	dir := os.join_path(tmp, repo.name + '.git')
	if os.exists(dir) {
		os.rmdir_all(dir) or {}
	}
	url := auth_url(repo.clone_url, user, token)

	println('  [1/3] Cloning...')
	r1 := os.execute('git clone --bare "' + url + '" "' + dir + '" 2>&1')
	if r1.exit_code != 0 {
		println('  FAILED: clone error')
		return 2
	}
	println('  [2/3] Rewriting history...')
	r2 := os.execute('cd "' + dir + '" && FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --env-filter ". ' +
		filter + '" --tag-name-filter cat -- --branches --tags 2>&1')
	if r2.exit_code != 0 {
		if r2.output.contains('Found nothing to rewrite') {
			println('  SKIP: empty repo')
			os.rmdir_all(dir) or {}
			return 1
		}
		println('  FAILED: rewrite error')
		os.rmdir_all(dir) or {}
		return 2
	}
	if !r2.output.contains('was rewritten') {
		println('  SKIP: no matching email found')
		os.rmdir_all(dir) or {}
		return 1
	}
	println('  [3/3] Force pushing...')
	r3 := os.execute('cd "' + dir + '" && git push --force --tags origin "refs/heads/*" 2>&1')
	if r3.exit_code != 0 {
		println('  FAILED: push error')
		os.rmdir_all(dir) or {}
		return 2
	}
	println('  DONE')
	os.rmdir_all(dir) or {}
	return 0
}

fn cleanup_remote(dir string, keep string) {
	r_branches := os.execute('cd "' + dir + '" && git ls-remote --heads origin')
	if r_branches.exit_code == 0 {
		for line in r_branches.output.split('\n') {
			trimmed := line.trim_space()
			if trimmed.len == 0 {
				continue
			}
			parts := trimmed.split('\t')
			if parts.len < 2 {
				continue
			}
			branch := parts[1].replace('refs/heads/', '')
			if branch != keep {
				os.execute('cd "' + dir + '" && git push origin --delete "' + branch + '" 2>&1')
			}
		}
	}
	r_tags := os.execute('cd "' + dir + '" && git ls-remote --tags origin')
	if r_tags.exit_code == 0 {
		for line in r_tags.output.split('\n') {
			trimmed := line.trim_space()
			if trimmed.len == 0 {
				continue
			}
			parts := trimmed.split('\t')
			if parts.len < 2 {
				continue
			}
			tag := parts[1].replace('refs/tags/', '')
			if !tag.contains('^') {
				os.execute('cd "' + dir + '" && git push origin --delete "refs/tags/' + tag +
					'" 2>&1')
			}
		}
	}
}

fn squash_repo(repo Repo, user string, token string, new_name string, new_email string, tmp string) int {
	dir := os.join_path(tmp, repo.name)
	if os.exists(dir) {
		os.rmdir_all(dir) or {}
	}
	url := auth_url(repo.clone_url, user, token)
	branch := if repo.default_branch.len > 0 { repo.default_branch } else { 'main' }

	println('  [1/5] Cloning...')
	r1 := os.execute('git clone "' + url + '" "' + dir + '" 2>&1')
	if r1.exit_code != 0 {
		println('  FAILED: clone error')
		return 2
	}

	println('  [2/5] Creating clean branch...')
	r2 := os.execute('cd "' + dir + '" && git checkout --orphan _abrasion_clean 2>&1')
	if r2.exit_code != 0 {
		println('  FAILED: orphan error')
		os.rmdir_all(dir) or {}
		return 2
	}

	println('  [3/5] Committing clean state...')
	r3 := os.execute('cd "' + dir + '" && git add -A && git -c user.name="' + new_name +
		'" -c user.email="' + new_email + '" commit -m "Initial commit" 2>&1')
	if r3.exit_code != 0 {
		if r3.output.contains('nothing to commit') {
			println('  SKIP: empty repo')
			os.rmdir_all(dir) or {}
			return 1
		}
		println('  FAILED: commit error')
		os.rmdir_all(dir) or {}
		return 2
	}

	os.execute('cd "' + dir + '" && git branch -D "' + branch + '" 2>&1')
	os.execute('cd "' + dir + '" && git branch -m "' + branch + '" 2>&1')

	println('  [4/5] Force pushing...')
	r4 := os.execute('cd "' + dir + '" && git push -f origin "' + branch + '" 2>&1')
	if r4.exit_code != 0 {
		println('  FAILED: push error')
		os.rmdir_all(dir) or {}
		return 2
	}

	println('  [5/5] Cleaning old branches & tags...')
	cleanup_remote(dir, branch)

	println('  DONE')
	os.rmdir_all(dir) or {}
	return 0
}

fn copy_contents(src string, dst string) ! {
	items := os.ls(src) or { return error('cannot list: ' + src) }
	for item in items {
		if item == '.git' {
			continue
		}
		s := os.join_path(src, item)
		d := os.join_path(dst, item)
		if os.is_dir(s) {
			os.mkdir_all(d) or {}
			copy_contents(s, d)!
		} else {
			os.cp(s, d) or { return error('copy failed: ' + s) }
		}
	}
}

fn find_sensitive(dir string) []string {
	mut found := []string{}
	items := os.ls(dir) or { return found }
	bad_names := ['.env', '.env.local', '.env.production', 'id_rsa', 'id_ed25519', 'id_dsa',
		'.npmrc', '.pypirc', 'credentials', 'htpasswd']
	bad_ext := ['.pem', '.key', '.p12', '.pfx', '.jks', '.keystore']
	bad_words := ['token', 'secret', 'password', 'passwd']

	for item in items {
		if item == '.git' || item == '.gitignore' {
			continue
		}
		full := os.join_path(dir, item)
		if os.is_dir(full) {
			found << find_sensitive(full)
			continue
		}
		lower := item.to_lower()
		mut is_bad := lower in bad_names

		if !is_bad {
			for ext in bad_ext {
				if lower.ends_with(ext) {
					is_bad = true
					break
				}
			}
		}
		if !is_bad {
			for word in bad_words {
				if lower.contains(word) {
					is_bad = true
					break
				}
			}
		}
		if is_bad {
			found << full
		}
	}
	return found
}

fn validate_repo(repo_url string, user string, token string) !string {
	mut owner := ''
	mut name := ''

	clean := repo_url.replace('https://github.com/', '').replace('http://github.com/', '').replace('.git', '').trim('/')

	parts := clean.split('/')
	if parts.len < 2 {
		return error('Invalid repo format. Use: user/repo or https://github.com/user/repo.git')
	}
	owner = parts[0]
	name = parts[1]

	api := 'curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ' + token +
		'" -H "User-Agent: abrasion" "https://api.github.com/repos/' + owner + '/' + name + '"'
	r := os.execute(api)

	if r.exit_code != 0 {
		return error('Network error: cannot reach GitHub API')
	}

	code := r.output.trim_space()
	match code {
		'200' {
			return owner + '/' + name
		}
		'404' {
			return error('Repository not found: ' + owner + '/' + name +
				'\n  Check the URL and make sure the repo exists on GitHub.')
		}
		'401', '403' {
			return error('Access denied to: ' + owner + '/' + name +
				'\n  Check your token has "repo" scope.')
		}
		else {
			return error('GitHub API returned HTTP ' + code + ' for: ' + owner + '/' + name)
		}
	}
}

fn secure_push(path string, repo_url string) {
	println('')
	header('ABRASION v2.0 - Secure Push')
	println('  Push files with zero identity leakage')
	println('')

	if os.execute('git --version').exit_code != 0 {
		eprintln('  ERROR: git not found')
		return
	}
	if os.execute('curl --version').exit_code != 0 {
		eprintln('  ERROR: curl not found')
		return
	}

	real_path := os.real_path(path)
	if !os.exists(real_path) {
		eprintln('  ERROR: path not found: ' + path)
		return
	}

	actual_url := expand_url(repo_url)
	is_dir := os.is_dir(real_path)

	println('  Source: ' + real_path + if is_dir { ' (directory)' } else { ' (file)' })
	println('  Target: ' + actual_url)
	println('')

	user := os.input('  GitHub Username: ').trim_space()
	token := os.input('  GitHub Token (PAT): ').trim_space()

	if user.len == 0 || token.len == 0 {
		eprintln('')
		eprintln('  ERROR: username and token required')
		return
	}

	println('')
	println('  Validating repository...')

	validated := validate_repo(actual_url, user, token) or {
		eprintln('  ERROR: ${err}')
		return
	}
	println('  OK: ' + validated)
	println('')

	new_name := os.input('  Display Name: ').trim_space()
	new_email := os.input('  noreply Email: ').trim_space()
	msg_input := os.input('  Commit Message (enter for "Initial commit"): ').trim_space()

	if new_name.len == 0 || new_email.len == 0 {
		eprintln('')
		eprintln('  ERROR: name and email required')
		return
	}

	commit_msg := if msg_input.len > 0 { msg_input } else { 'Initial commit' }

	if !new_email.contains('noreply') {
		println('')
		println('  WARNING: email does not contain "noreply"')
		println('  This may expose your real email!')
		c := os.input('  Continue anyway? (yes/no): ').trim_space()
		if c != 'yes' {
			println('  Aborted.')
			return
		}
	}

	r_global := os.execute('git config --global user.email')
	global_email := r_global.output.trim_space()
	if global_email.len > 0 && global_email != new_email {
		println('')
		println('  NOTE: global git email: ' + global_email)
		println('  This push will use: ' + new_email)
	}

	println('')
	println('  Commit mode:')
	println('    1) New commit     - add a new commit on top of history')
	println('    2) Amend commit   - overwrite the last commit')
	println('')
	commit_mode := os.input('  Choose (1 or 2): ').trim_space()

	is_amend := commit_mode == '2'

	println('')
	sep()
	println('  Name:    ' + new_name)
	println('  Email:   ' + new_email)
	println('  Message: ' + commit_msg)
	println('  Repo:    ' + validated)
	println('  Mode:    ' + if is_amend { 'AMEND (overwrite last commit)' } else { 'NEW (new commit)' })
	sep()

	confirm := os.input('  Type "yes" to push: ').trim_space()
	if confirm != 'yes' {
		println('  Aborted.')
		return
	}

	stamp := time.now().unix().str()
	tmp := os.join_path(os.temp_dir(), 'abrasion_push_' + stamp)
	os.mkdir_all(tmp) or {
		eprintln('  ERROR: cannot create temp dir')
		return
	}
	dir := os.join_path(tmp, 'repo')
	url := auth_url(actual_url, user, token)

	println('')
	println('  [1/7] Cloning repository...')
	r1 := os.execute('git clone "' + url + '" "' + dir + '" 2>&1')
	is_empty_repo := r1.exit_code != 0
	if is_empty_repo {
		r_empty := os.execute('curl -s -H "Authorization: token ' + token +
			'" -H "User-Agent: abrasion" "https://api.github.com/repos/' + validated + '"')
		if r_empty.output.contains('"size":0') {
			println('  Empty repo detected, initializing...')
			os.mkdir_all(dir) or {}
			os.execute('cd "' + dir + '" && git init 2>&1')
			os.execute('cd "' + dir + '" && git remote add origin "' + url + '" 2>&1')
		} else {
			eprintln('  FAILED: clone error')
			eprintln('  Detail: ' + r1.output.trim_space())
			os.rmdir_all(tmp) or {}
			return
		}
	}

	if is_amend && is_empty_repo {
		eprintln('  ERROR: cannot amend on an empty repo (no previous commit)')
		os.rmdir_all(tmp) or {}
		return
	}

	if is_amend {
		r_has := os.execute('cd "' + dir + '" && git --no-pager log -1 --format=%H 2>&1')
		if r_has.exit_code != 0 || r_has.output.trim_space().len == 0 {
			eprintln('  ERROR: no previous commit to amend')
			os.rmdir_all(tmp) or {}
			return
		}
		r_prev := os.execute('cd "' + dir + '" && git --no-pager log -1 --format="%an <%ae> | %s" 2>&1')
		println('  Previous commit: ' + r_prev.output.trim_space())
	}

	println('  [2/7] Setting LOCAL identity...')
	os.execute('cd "' + dir + '" && git config user.name "' + new_name + '"')
	os.execute('cd "' + dir + '" && git config user.email "' + new_email + '"')

	println('  [3/7] Copying files...')
	if is_dir {
		copy_contents(real_path, dir) or {
			eprintln('  ERROR: ' + err.str())
			os.rmdir_all(tmp) or {}
			return
		}
	} else {
		fname := os.file_name(real_path)
		os.cp(real_path, os.join_path(dir, fname)) or {
			eprintln('  ERROR: copy failed')
			os.rmdir_all(tmp) or {}
			return
		}
	}

	println('  [4/7] Security scan...')
	sensitive := find_sensitive(dir)
	if sensitive.len > 0 {
		println('')
		println('  WARNING: suspicious files detected:')
		for f in sensitive {
			rel := f.all_after(dir + '/')
			println('    ! ' + rel)
		}
		println('')
		sc := os.input('  Push anyway? (yes/no): ').trim_space()
		if sc != 'yes' {
			println('  Aborted.')
			os.rmdir_all(tmp) or {}
			return
		}
	} else {
		println('  Clean. No sensitive files detected.')
	}

	println('  [5/7] Committing...')
	os.execute('cd "' + dir + '" && git add -A 2>&1')

	mut r_commit := os.Result{}
	if is_amend {
		r_commit = os.execute('cd "' + dir + '" && git commit --amend --reset-author -m "' +
			commit_msg + '" 2>&1')
	} else {
		r_commit = os.execute('cd "' + dir + '" && git commit -m "' + commit_msg + '" 2>&1')
	}

	if r_commit.exit_code != 0 {
		if r_commit.output.contains('nothing to commit') {
			if is_amend {
				println('  Amending with same content...')
				r_commit = os.execute('cd "' + dir +
					'" && git commit --amend --reset-author --allow-empty -m "' + commit_msg +
					'" 2>&1')
				if r_commit.exit_code != 0 {
					eprintln('  FAILED: amend error')
					eprintln('  Detail: ' + r_commit.output.trim_space())
					os.rmdir_all(tmp) or {}
					return
				}
			} else {
				println('  SKIP: nothing changed (files already up to date)')
				os.rmdir_all(tmp) or {}
				return
			}
		} else {
			eprintln('  FAILED: commit error')
			eprintln('  Detail: ' + r_commit.output.trim_space())
			os.rmdir_all(tmp) or {}
			return
		}
	}

	println('  [6/7] Verifying identity...')
	r_verify := os.execute('cd "' + dir + '" && git --no-pager log -1 --format=%ae')
	actual_email := r_verify.output.trim_space()
	if actual_email != new_email {
		eprintln('')
		eprintln('  ABORT: identity verification FAILED!')
		eprintln('  Expected: ' + new_email)
		eprintln('  Got:      ' + actual_email)
		eprintln('')
		eprintln('  Push cancelled to protect your identity.')
		os.rmdir_all(tmp) or {}
		return
	}

	r_verify_name := os.execute('cd "' + dir + '" && git --no-pager log -1 --format=%an')
	actual_name := r_verify_name.output.trim_space()
	println('  Verified: ' + actual_name + ' <' + actual_email + '>')

	println('  [7/7] Pushing...')
	r_branch := os.execute('cd "' + dir + '" && git branch --show-current')
	branch := r_branch.output.trim_space()

	mut push_ok := false
	mut push_err := ''

	if is_amend {
		if branch.len > 0 {
			r_push := os.execute('cd "' + dir + '" && git push -f origin "' + branch + '" 2>&1')
			push_ok = r_push.exit_code == 0
			if !push_ok {
				push_err = r_push.output.trim_space()
			}
		}
		if !push_ok {
			os.execute('cd "' + dir + '" && git branch -M main 2>&1')
			r_push2 := os.execute('cd "' + dir + '" && git push -f origin main 2>&1')
			push_ok = r_push2.exit_code == 0
			if !push_ok {
				push_err = r_push2.output.trim_space()
			}
		}
	} else {
		if branch.len > 0 {
			r_push := os.execute('cd "' + dir + '" && git push -u origin "' + branch + '" 2>&1')
			push_ok = r_push.exit_code == 0
			if !push_ok {
				push_err = r_push.output.trim_space()
			}
		}
		if !push_ok {
			os.execute('cd "' + dir + '" && git branch -M main 2>&1')
			r_push2 := os.execute('cd "' + dir + '" && git push -u origin main 2>&1')
			push_ok = r_push2.exit_code == 0
			if !push_ok {
				push_err = r_push2.output.trim_space()
				r_push3 := os.execute('cd "' + dir + '" && git push -f origin main 2>&1')
				push_ok = r_push3.exit_code == 0
				if !push_ok {
					push_err = r_push3.output.trim_space()
				}
			}
		}
	}

	os.rmdir_all(tmp) or {}

	if !push_ok {
		eprintln('')
		eprintln('  FAILED: push error')
		eprintln('  Detail: ' + push_err)
		if push_err.contains('Permission') || push_err.contains('denied')
			|| push_err.contains('403') {
			eprintln('  Hint: token may not have write access to this repo')
		}
		if push_err.contains('not found') || push_err.contains('404') {
			eprintln('  Hint: repo URL may be wrong')
		}
		if push_err.contains('fetch first') || push_err.contains('rejected') {
			eprintln('  Hint: remote has conflicting changes')
		}
		return
	}

	println('')
	header('PUSH COMPLETE')
	println('  Author:  ' + actual_name + ' <' + actual_email + '>')
	println('  Message: ' + commit_msg)
	println('  Target:  ' + actual_url)
	println('  Mode:    ' + if is_amend { 'AMEND' } else { 'NEW COMMIT' })
	println('')
	println('  No real email leaked. You are a ghost.')
	sep()
}

fn interactive_mode() {
	println('')
	header('ABRASION v2.0 - Git Identity Eraser')
	println('  Erase / Backup / Squash')
	println('')

	r_git := os.execute('git --version')
	if r_git.exit_code != 0 {
		eprintln('  ERROR: git not found')
		return
	}
	r_curl := os.execute('curl --version')
	if r_curl.exit_code != 0 {
		eprintln('  ERROR: curl not found')
		return
	}

	user := os.input('  GitHub Username: ').trim_space()
	token := os.input('  GitHub Token (PAT): ').trim_space()
	println('')
	old_email := os.input('  Old Email (to erase): ').trim_space()
	new_name := os.input('  New Display Name: ').trim_space()
	new_email := os.input('  New noreply Email: ').trim_space()

	if user.len == 0 || token.len == 0 || old_email.len == 0 || new_name.len == 0
		|| new_email.len == 0 {
		eprintln('')
		eprintln('  ERROR: all fields required')
		return
	}

	println('')
	header('FETCHING REPOSITORIES')

	repos := fetch_repos(user, token) or {
		eprintln('  ERROR: ${err}')
		return
	}

	owned := repos.filter(!it.fork)

	if owned.len == 0 {
		println('  No non-forked repos found.')
		return
	}

	println('  Found ${owned.len} repos:')
	println('')
	for i, r in owned {
		branch := if r.default_branch.len > 0 { r.default_branch } else { 'main' }
		println('    ${i + 1}. ${r.name} [${branch}]')
	}

	println('')
	sep()
	println('  OPTIONS:')
	println('')

	do_backup := os.input('  Create full backup before changes? (yes/no): ').trim_space()

	println('')
	println('  How to handle commit history:')
	println('    1) Rewrite  - replace email, keep all commits')
	println('    2) Squash   - destroy history, keep only latest code')
	println('')
	mode := os.input('  Choose (1 or 2): ').trim_space()

	println('')
	sep()
	println('  SUMMARY:')
	println('')
	println('  Repos:   ${owned.len}')
	println('  Old:     ${old_email}')
	println('  New:     ${new_name} <${new_email}>')
	println('  Backup:  ${if do_backup == 'yes' { 'YES' } else { 'NO' }}')
	if mode == '2' {
		println('  Mode:    SQUASH (all history will be destroyed!)')
	} else {
		println('  Mode:    REWRITE (email replaced, history kept)')
	}
	println('')

	confirm := os.input('  Type "yes" to start: ').trim_space()
	if confirm != 'yes' {
		println('  Aborted.')
		return
	}

	if do_backup == 'yes' {
		println('')
		header('PHASE 1: BACKUP')

		now := time.now()
		stamp := '${now.year}_${now.month}_${now.day}_${now.hour}${now.minute}${now.second}'
		backup_dir := os.join_path(os.home_dir(), 'abrasion_backup_' + stamp)
		os.mkdir_all(backup_dir) or {
			eprintln('  ERROR: cannot create backup dir')
			return
		}

		println('  Location: ${backup_dir}')
		println('')

		mut b_ok := 0
		mut b_fail := 0
		for repo in owned {
			if backup_repo(repo, user, token, backup_dir) {
				b_ok++
			} else {
				b_fail++
			}
		}

		println('')
		println('  Backup done: ${b_ok} ok, ${b_fail} failed')

		if b_fail > 0 {
			cont := os.input('  Some backups failed. Continue? (yes/no): ').trim_space()
			if cont != 'yes' {
				println('  Aborted.')
				return
			}
		}
	}

	if mode == '2' {
		println('')
		header('PHASE 2: SQUASH')
	} else {
		println('')
		header('PHASE 2: REWRITE')
	}

	tmp := os.join_path(os.temp_dir(), 'abrasion_work')
	os.mkdir_all(tmp) or {}

	mut filter := ''
	if mode != '2' {
		filter = write_filter(old_email, new_name, new_email) or {
			eprintln('  ERROR: ${err}')
			return
		}
	}

	mut ok := 0
	mut skip := 0
	mut fail := 0

	for i, repo in owned {
		println('')
		header('[${i + 1}/${owned.len}] ${repo.name}')

		mut result := 0
		if mode == '2' {
			result = squash_repo(repo, user, token, new_name, new_email, tmp)
		} else {
			result = rewrite_repo(repo, user, token, filter, tmp)
		}

		match result {
			0 { ok++ }
			1 { skip++ }
			else { fail++ }
		}
	}

	if filter.len > 0 {
		os.rm(filter) or {}
	}
	os.rmdir_all(tmp) or {}

	println('')
	header('RESULTS')
	println('  Total:     ${owned.len}')
	if mode == '2' {
		println('  Squashed:  ${ok}')
	} else {
		println('  Rewritten: ${ok}')
	}
	println('  Skipped:   ${skip}')
	println('  Failed:    ${fail}')
	println('')

	if fail == 0 {
		if do_backup == 'yes' {
			println('  Backup saved in ~/abrasion_backup_*')
		}
		println('')
		println('  Your old email has been erased.')
		println('  You are now a ghost.')
	} else {
		println('  Some repos failed. Run again to retry.')
	}
	sep()
}

fn show_usage() {
	println('')
	header('ABRASION v2.0')
	println('')
	println('  Usage:')
	println('')
	println('    abrasion                          Erase email from all repos')
	println('    abrasion push <path> <repo>       Secure push to repo')
	println('')
	println('  Examples:')
	println('')
	println('    v run abrasion.v')
	println('    v run abrasion.v push ./project https://github.com/user/repo.git')
	println('    v run abrasion.v push ./file.txt user/repo')
	println('    v run abrasion.v push ./src https://github.com/user/repo.git')
	println('')
	println('  Short URL format:')
	println('    user/repo  ->  https://github.com/user/repo.git')
	sep()
}

fn main() {
	if os.args.len >= 4 && os.args[1] == 'push' {
		secure_push(os.args[2], os.args[3])
	} else if os.args.len > 1 {
		show_usage()
	} else {
		interactive_mode()
	}
}