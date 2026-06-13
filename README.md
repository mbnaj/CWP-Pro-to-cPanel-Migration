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

### Back up every CWP account at once

Use `--all` to iterate over every CWP account on the server and produce one
`cpmove-<user>.tar.gz` per account:

```bash
sudo ./cwp-to-cpanel-backup.sh --all [output_dir]
```

Example:

```bash
sudo ./cwp-to-cpanel-backup.sh --all /root/backups
# -> /root/backups/cpmove-<user1>.tar.gz
#    /root/backups/cpmove-<user2>.tar.gz
#    ...
#    /root/backups/cpmove-all-YYYYMMDD-HHMMSS.log   (combined run log)
```

Account discovery order:

1. `SELECT username FROM root_cwp.user` (CWP's own database).
2. Fallback: any `/home/<user>` with a real login shell.

Each account is backed up in an isolated invocation, so a failure on one
account does not stop the rest. A summary at the end lists how many
succeeded, how many failed, and which accounts failed.

## Troubleshooting: `./cwp-to-cpanel-backup.sh: No such file or directory`

This error on Linux almost always means one of the following. Try them in order:

### 1. You're not in the directory that contains the script

`./` means "current directory". Verify:

```bash
ls -l cwp-to-cpanel-backup.sh
```

If missing, `cd` to wherever you uploaded it (e.g. `cd /root`) and retry.

### 2. The file isn't executable yet

```bash
chmod +x cwp-to-cpanel-backup.sh
sudo ./cwp-to-cpanel-backup.sh <cwp_username>
```

### 3. Most likely: Windows line endings (CRLF)

If the file was edited / downloaded on Windows, the shebang line becomes
`#!/bin/bash\r`. Linux then tries to run an interpreter literally named
`/bin/bash\r`, which doesn't exist — and prints the misleading message:

```
./cwp-to-cpanel-backup.sh: No such file or directory
```

Confirm with:

```bash
file cwp-to-cpanel-backup.sh
# "...with CRLF line terminators"  => that's the cause
```

Fix it on the server:

```bash
# Option A – using dos2unix
sudo yum install -y dos2unix   # CentOS / CWP7
dos2unix cwp-to-cpanel-backup.sh

# Option B – no extra package needed
sed -i 's/\r$//' cwp-to-cpanel-backup.sh

# Then run it
sudo ./cwp-to-cpanel-backup.sh <cwp_username>
```

## Troubleshooting: cPanel reports the MySQL import as empty

cPanel's `restorepkg` uses `mysql/<db>.create` to find a `CREATE DATABASE`
statement and pre-create the database before loading `mysql/<db>.sql`. If
`.create` does not contain a `CREATE DATABASE` statement, cPanel skips DB
creation and reports an empty import even when `.sql` has data. The current
script writes a proper `CREATE DATABASE` statement into `.create`.

If you generated an archive with an older copy of the script, regenerate
the backup with the latest version and restore again. To verify a generated
archive before uploading:

```bash
tar -tzf cpmove-<user>.tar.gz | grep '^./mysql/'
# Inspect a .create file – it must start with: CREATE DATABASE `<dbname>` ...
tar -xzOf cpmove-<user>.tar.gz ./mysql/<dbname>.create
```

The script also prints explicit errors if `mysqldump` fails or if no
databases match the CWP naming pattern (`<user>_*` or `root_<user>_*`),
so re-run it and read the output if the dump is unexpectedly empty.

## Troubleshooting: "no databases found for `<user>`"

The script discovers databases from multiple sources, in this order:

1. CWP's own bookkeeping tables (`root_cwp.user_databases`, `root_cwp.databases`).
2. Prefix match against `information_schema` (case-insensitive) for
   `<user>_*` and `root_<user>_*`.
3. `mysql.db` grants whose `User` starts with `<user>_`.

If none of these find your DBs, the script prints every database visible
on the server and the prefixes it tried, so you can spot a mismatch.
The most common cause is that the MySQL prefix differs from the system
username (different casing, abbreviated prefix, or a manually-named DB).
Override the prefix with the `CWP_DB_PREFIX` environment variable:

```bash
# System user is "almajdsms" but DBs are named "majdsms_*"
sudo CWP_DB_PREFIX=majdsms ./cwp-to-cpanel-backup.sh almajdsms
```

You can also confirm directly with:

```bash
mysql -NB -e "SHOW DATABASES" | grep -i <user-or-prefix>
```

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
