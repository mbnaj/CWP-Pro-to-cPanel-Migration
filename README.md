# CWP7 → cPanel Migration Backup

`cwp-to-cpanel-backup.sh` builds a **cpmove** archive from a CWP7 account so it
can be restored on a cPanel/WHM server through
**WHM → Transfers → Restore a Full Backup / cpmove File**.

## Usage

```bash
# Copy the script to your CWP server, then:
chmod +x cwp-to-cpanel-backup.sh
sudo ./cwp-to-cpanel-backup.sh <cwp_username> [output_dir]
```

Example:

```bash
sudo ./cwp-to-cpanel-backup.sh johndoe /root/backups
# -> /root/backups/cpmove-johndoe.tar.gz
```

If `output_dir` is omitted it defaults to `/root/cpmove-backups`.

## What is captured

| Item | Destination in archive |
|------|------------------------|
| Home directory (`/home/<user>`) | `homedir/` |
| MySQL databases (`<user>_*`, `root_<user>_*`) | `mysql/*.sql` + `*.create` |
| MySQL users + grants | `mysql.sql` |
| Primary / addon / sub / parked domains | `userdata/`, `cp/<user>` |
| Email accounts + hashed passwords | `homedir/etc/<domain>/passwd` (+`shadow`) |
| Mailboxes (`/var/vmail/<domain>`) | `homedir/mail/<domain>/` |
| Forwarders / autoresponders | `va/`, `vf/`, `vad/` |
| DNS zone files | `dnszones/` |
| Let's Encrypt SSL certificates | `apache_tls/`, `ssl/` |
| Cron jobs | `cron/<user>` |
| Account metadata (quota, plan, IP, etc.) | `cp/<user>`, `version`, `quota`, `shadow` |

## Restore on cPanel

1. Upload `cpmove-<user>.tar.gz` to `/home/` on the cPanel/WHM server.
2. **WHM → Transfers → Restore a Full Backup/cpmove File**.
3. Enter the username and submit.

Alternative (CLI on the cPanel side):

```bash
cd /home
/scripts/restorepkg <user>
```

## Caveats

CWP and cPanel are not byte-for-byte compatible, so a few details are
approximated and should be verified after restore:

- **Email passwords** — CWP stores Dovecot-style hashes. If users can't log in
  after restore, reset their passwords in cPanel.
- **DNS** — Update nameservers / glue records on the new server before going
  live.
- **PHP versions** — Re-select per-domain PHP versions in MultiPHP Manager.
- **SSL** — Re-issue Let's Encrypt certs via AutoSSL if any are missing.
- **Quotas / plan** — The archive uses an `unlimited` placeholder plan; assign
  the correct package in WHM after restore.

## Requirements

Run as **root** on the CWP server. Needs `mysql`, `mysqldump`, `rsync`, `tar`,
`gzip`, `awk`, `sed` — all standard on a CWP7 install.
