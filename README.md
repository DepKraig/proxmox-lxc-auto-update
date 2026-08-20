# proxmox-lxc-auto-update

Automatically update all your Proxmox LXC containers on a schedule, with
automatic pre-update snapshots, health checks, automatic rollback on
failure, and email alerts. Detects each container's OS/package manager
(Debian/Ubuntu, Alpine, RHEL-family, SUSE, Arch) and its available shell
automatically, so it works across a mixed fleet without editing anything
per-container.

## Features

- Runs on your Proxmox **host**, driving containers via `pct`
- Automatically picks the right pre-update safety net per container based
  on its storage: fast `pct snapshot`/`pct rollback` on snapshot-capable
  storage (ZFS, LVM-thin, RBD, Btrfs), or a `vzdump` backup/restore
  fallback on anything else (e.g. plain `dir` storage) - no manual
  per-container configuration needed
- Detects the container's OS and picks the right update command
  (`apt`, `apk`, `dnf`/`yum`, `zypper`, `pacman`) - unrecognized OSes are
  skipped and reported, never guessed at
- Detects whether `bash` is available inside the container and falls back
  to `sh` automatically
- Reboots the container after a successful update and waits for it to
  actually become responsive (not just "running")
- If the update itself fails, or the container doesn't come back up after
  reboot, automatically rolls back to the pre-update snapshot/backup
- Emails you on every failure, with the likely cause, plus a summary email
  at the end of every run
- Prunes old snapshots/backups after a configurable retention period
- `DRY_RUN` mode to see exactly what it would do first

## Requirements

- Proxmox VE host with the `pct` CLI (standard on any Proxmox install)
- Containers must support LXC snapshots on their storage backend
- `mailutils` + `msmtp` (or any other `sendmail`-compatible MTA) for email
- Bash on the **host** (the script itself needs bash; containers do not)

## Installation

### 1. Get the files onto your Proxmox host

```bash
git clone https://github.com/YOUR_USERNAME/proxmox-lxc-auto-update.git
cd proxmox-lxc-auto-update
```

(No git on the host, or offline? Just copy the files over with `scp`/`sftp`.)

### 2. Set up email alerts

```bash
chmod +x setup-email.sh
./setup-email.sh              # installs msmtp, msmtp-mta, mailutils
cp msmtprc.example /etc/msmtprc
nano /etc/msmtprc              # fill in your email + app password
```
Fill in your real Gmail address and the App Password, then:

```bash
chown root:root /etc/msmtprc
chmod 600 /etc/msmtprc
```

If using Gmail, you need an **App Password**, not your normal password:
1. Enable 2-Step Verification: https://myaccount.google.com/security
2. Create an App Password: https://myaccount.google.com/apppasswords
3. Paste the 16-character code into `/etc/msmtprc`

Using a different provider? Just edit the `host`/`port`/`from`/`user` lines
in `/etc/msmtprc` to match their SMTP settings instead.

Test it:
```bash
echo "test body" | mail -s "Proxmox test" you@example.com
```
Check `/var/log/msmtp.log` if nothing arrives.

### 3. Configure the script

```bash
cp config.example.conf /etc/lxc-auto-update.conf
nano /etc/lxc-auto-update.conf
```

Set at minimum `EMAIL_TO` and `EMAIL_FROM`. See the comments in that file
for every other option (excluded containers, restart timeout, snapshot
retention, dry-run mode).

### 4. Install the script

```bash
cp lxc-auto-update.sh /usr/local/bin/lxc-auto-update.sh
chmod +x /usr/local/bin/lxc-auto-update.sh
```

### 5. Test it

Do a dry run first — set `DRY_RUN=1` in `/etc/lxc-auto-update.conf`, then:

```bash
/usr/local/bin/lxc-auto-update.sh
```

Check the log it prints the path to (under `/var/log/lxc-auto-update/`) and
confirm the plan looks right, then set `DRY_RUN=0` and try it for real
against one non-critical container (temporarily set `EXCLUDE_CTIDS` to
everything else) before trusting it with your whole fleet.

### 6. Schedule it

```bash
crontab -e
```

Add (runs Sunday 5 AM — adjust to land after your existing backups):

```
0 5 * * 0 /usr/local/bin/lxc-auto-update.sh
```

That's it — it'll run weekly, snapshot/update/verify/rollback as needed,
and email you either way.

## Configuration reference

All settings live in `/etc/lxc-auto-update.conf` (see `config.example.conf`
for the full commented list). Anything you don't set falls back to a
built-in default in the script.

| Variable | Default | Purpose |
|---|---|---|
| `EMAIL_TO` | `root@localhost` | Where alerts/summaries are sent |
| `EMAIL_FROM` | `root@localhost` | From address (must match Gmail account if using Gmail relay) |
| `EXCLUDE_CTIDS` | `()` | CTIDs to never touch |
| `RESTART_TIMEOUT` | `120` | Seconds to wait for a container to respond after reboot |
| `RESTART_POLL_INTERVAL` | `5` | Seconds between responsiveness checks |
| `SNAPSHOT_RETENTION_DAYS` | `14` | How long to keep pre-update snapshots |
| `BACKUP_STORAGE` | `local` | Where vzdump backups go for non-snapshot-capable storage |
| `BACKUP_RETENTION_DAYS` | `14` | How long to keep pre-update backups |
| `DRY_RUN` | `0` | Set to `1` to log actions without performing them |

## How the safety net is chosen, and rollback decisions

Each container's storage is checked automatically at run time:

- **Snapshot-capable storage** (ZFS, LVM-thin, RBD, Btrfs) → fast `pct
  snapshot` before the update, `pct rollback` if anything goes wrong
- **Everything else** (e.g. plain `dir` storage) → `vzdump` backup before
  the update (briefly stops the container to do it), `pct restore` if
  anything goes wrong. Slower and needs `BACKUP_STORAGE` configured with
  free space, but works regardless of the container's own storage type.

Rollback triggers:
- **Safety net creation fails** (snapshot or backup) → container is left untouched, update skipped, email sent
- **Package update command exits non-zero** → rolled back immediately, email with the update output
- **Reboot command itself fails** → rolled back, email sent
- **Container doesn't respond within `RESTART_TIMEOUT`** → stopped, rolled back, restarted, email sent noting whether it recovered post-rollback

## Troubleshooting

- **No emails at all**: confirm `mail -s "test" you@example.com` works
  standalone first — that isolates whether the problem is this script or
  your mail relay. Check `journalctl -t msmtp` for the actual error.
- **`535 5.7.8 Username and Password not accepted` (Gmail)**: almost
  always one of: 2-Step Verification isn't enabled on the Gmail account,
  the App Password was mistyped (make sure you strip the spaces Google
  displays it with), or the password expired/was revoked — generate a
  fresh one at https://myaccount.google.com/apppasswords.
- **A container's OS isn't detected**: check `/etc/os-release` inside it.
  If it's missing/nonstandard, add a case for it in `get_update_command()`
  and `detect_os_family()` in `lxc-auto-update.sh` — PRs welcome.
- **Snapshot fails** on storage that should support it: check storage
  health/space with `pvesm status`.
- **Backup fallback fails**: confirm `BACKUP_STORAGE` in your config
  actually exists (`pvesm status`) and has "backup" content enabled
  (Datacenter → Storage → click it → Content), and has free space.

## Contributing

Issues and PRs welcome — especially additional OS family support, or
alternate MTA setup docs (Outlook/O365, self-hosted Postfix relay, etc).

## License

MIT — see [LICENSE](LICENSE).
