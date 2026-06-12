#!/bin/bash
#
# cwp-to-cpanel-backup.sh
#
# Generates a cPanel-compatible cpmove archive (cpmove-<user>.tar.gz) from a
# CentOS Web Panel (CWP7) account so it can be restored on a cPanel/WHM server
# via WHM -> "Transfer or Restore a cPanel Account" (Restore a Full Backup /
# cpmove File).
#
# Usage:
#   sudo ./cwp-to-cpanel-backup.sh <cwp_username> [output_dir]
#
# Example:
#   sudo ./cwp-to-cpanel-backup.sh johndoe /root/backups
#
# Requirements (run on the CWP server):
#   - root privileges
#   - mysql / mysqldump in PATH
#   - tar, gzip, awk, sed
#
# What it captures:
#   - /home/<user>            -> homedir/
#   - All MySQL DBs owned by the user (root_<user>_*) -> mysql/*.sql + .create
#   - MySQL users + grants    -> mysql.sql
#   - Addon / subdomain / parked domain data (best-effort from CWP MySQL)
#   - Email accounts + passwords (from /etc/exim/domains and /var/vmail)
#   - Forwarders / autoresponders (best-effort)
#   - DNS zone files          -> dnszones/
#   - SSL certs (if present)  -> apache_tls/ and ssl/
#   - Cron jobs               -> cron/<user>
#   - cPanel user file        -> cp/<user>  + userdata/main
#
# NOTE: CWP and cPanel are not identical, so a few items are approximated.
# After restore on the cPanel side, verify domains, email accounts, and
# database users. Re-set passwords for email accounts if hashes are not
# compatible (cPanel expects $6$ SHA-512 crypt hashes in shadow).
#
# NOTE: intentionally NOT using `set -u` — bash 4.2 (CentOS 7 / CWP7) treats
# expansion of an empty array (e.g. "${ALL_DOMAINS[@]}") as an unbound
# variable, which would abort the script on accounts with no addon domains.
set -o pipefail

#---------------------------------------------------------------------------
# 0. Argument parsing & sanity checks
#---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run as root." >&2
    exit 1
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <cwp_username> [output_dir]" >&2
    exit 1
fi

USER_NAME="$1"
OUT_DIR="${2:-/root/cpmove-backups}"

if ! id "$USER_NAME" &>/dev/null; then
    echo "ERROR: system user '$USER_NAME' does not exist." >&2
    exit 1
fi

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_SHELL="$(getent passwd "$USER_NAME" | cut -d: -f7)"
USER_UID="$(id -u "$USER_NAME")"
USER_GID="$(id -g "$USER_NAME")"

if [[ ! -d "$USER_HOME" ]]; then
    echo "ERROR: home directory '$USER_HOME' missing." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
WORK_DIR="$(mktemp -d -t cpmove-${USER_NAME}-XXXX)"
STAGE="$WORK_DIR/cpmove-$USER_NAME"
mkdir -p "$STAGE"

echo "==> Working directory: $WORK_DIR"
echo "==> Staging archive at: $STAGE"

#---------------------------------------------------------------------------
# 1. Discover MySQL root credentials (CWP stores them in /root/.my.cnf)
#---------------------------------------------------------------------------
MYSQL_OPTS=""
if [[ -f /root/.my.cnf ]]; then
    MYSQL_OPTS="--defaults-file=/root/.my.cnf"
fi

mysql_q() { mysql $MYSQL_OPTS -NB -e "$1" 2>/dev/null; }

#---------------------------------------------------------------------------
# 2. Discover the user's primary domain and addon/sub/parked domains
#---------------------------------------------------------------------------
PRIMARY_DOMAIN=""
ADDON_DOMAINS=()
SUB_DOMAINS=()
PARKED_DOMAINS=()
ALL_DOMAINS=()

# CWP main domain lookup
PRIMARY_DOMAIN="$(mysql_q "SELECT domain FROM root_cwp.user WHERE username='$USER_NAME' LIMIT 1;" || true)"

if [[ -z "$PRIMARY_DOMAIN" ]]; then
    # Fallback: scan apache vhost conf for ServerName under user
    PRIMARY_DOMAIN="$(grep -rls "DocumentRoot $USER_HOME/public_html" /usr/local/apache/conf.d/vhosts 2>/dev/null \
        | head -1 | xargs -r grep -m1 -E '^\s*ServerName' 2>/dev/null \
        | awk '{print $2}' | head -1)"
fi

if [[ -z "$PRIMARY_DOMAIN" ]]; then
    echo "WARNING: could not determine primary domain. Using '${USER_NAME}.local' as placeholder."
    PRIMARY_DOMAIN="${USER_NAME}.local"
fi
echo "==> Primary domain: $PRIMARY_DOMAIN"

# Addon / sub / parked domains (best effort against CWP schema)
while IFS=$'\t' read -r d t; do
    [[ -z "$d" ]] && continue
    case "$t" in
        addon)  ADDON_DOMAINS+=("$d") ;;
        sub|subdomain) SUB_DOMAINS+=("$d") ;;
        park|parked|alias) PARKED_DOMAINS+=("$d") ;;
    esac
    ALL_DOMAINS+=("$d")
done < <(mysql_q "
    SELECT domain, type FROM root_cwp.domains
    WHERE user='$USER_NAME' AND domain <> '$PRIMARY_DOMAIN';" 2>/dev/null || true)

ALL_DOMAINS=("$PRIMARY_DOMAIN" "${ALL_DOMAINS[@]}")

#---------------------------------------------------------------------------
# 3. Create cpmove directory skeleton
#---------------------------------------------------------------------------
mkdir -p "$STAGE"/{cp,homedir,mysql,mysql-timestamps,dnszones,va,vad,vf,cron,ssl,apache_tls,logs,userdata,httpfiles,meta,pds,suspended,suspendinfo,addons,bandwidth}

# version marker so WHM treats the archive as modern format
echo "11.96.0.0" > "$STAGE/version"

#---------------------------------------------------------------------------
# 4. cPanel "cp/<user>" account metadata file
#---------------------------------------------------------------------------
CP_FILE="$STAGE/cp/$USER_NAME"
{
    echo "DNS=$PRIMARY_DOMAIN"
    echo "DOMAIN=$PRIMARY_DOMAIN"
    echo "USER=$USER_NAME"
    echo "OWNER=root"
    echo "PLAN=default"
    echo "IP=$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "HASCGI=1"
    echo "MAXPOP=unlimited"
    echo "MAXFTP=unlimited"
    echo "MAXLST=unlimited"
    echo "MAXSUB=unlimited"
    echo "MAXPARK=unlimited"
    echo "MAXADDON=unlimited"
    echo "MAXSQL=unlimited"
    echo "BWLIMIT=unlimited"
    echo "DISK_BLOCK_LIMIT=unlimited"
    echo "FEATURELIST=default"
    echo "LANG=english"
    echo "STARTDATE=$(date +%s)"
    echo "SUSPENDED=0"
} > "$CP_FILE"

# Create suspension data (SDS) stub files - cPanel expects these
echo "reason:" > "$STAGE/suspended/$USER_NAME"
echo "time:" > "$STAGE/suspendinfo/$USER_NAME"

# userdata/main – maps primary, addon, sub, parked domains
{
    echo "---"
    echo "main_domain: $PRIMARY_DOMAIN"
    echo "addon_domains:"
    for d in "${ADDON_DOMAINS[@]}"; do echo "  $d: $d"; done
    echo "sub_domains:"
    for d in "${SUB_DOMAINS[@]}"; do echo "  - $d"; done
    echo "  - $PRIMARY_DOMAIN"
    echo "parked_domains:"
    for d in "${PARKED_DOMAINS[@]}"; do echo "  - $d"; done
} > "$STAGE/userdata/main"

# Per-domain userdata stubs
for d in "${ALL_DOMAINS[@]}"; do
    docroot="$USER_HOME/public_html"
    [[ -d "$USER_HOME/$d" ]] && docroot="$USER_HOME/$d"
    {
        echo "---"
        echo "documentroot: $docroot"
        echo "group: $USER_NAME"
        echo "homedir: $USER_HOME"
        echo "ip: $(hostname -I 2>/dev/null | awk '{print $1}')"
        echo "owner: root"
        echo "port: 80"
        echo "user: $USER_NAME"
        echo "servername: $d"
        echo "serveralias: www.$d"
        echo "serveradmin: webmaster@$d"
    } > "$STAGE/userdata/$d"
done

# Create addon domain stubs if they exist
if [[ ${#ADDON_DOMAINS[@]} -gt 0 ]]; then
    for d in "${ADDON_DOMAINS[@]}"; do
        mkdir -p "$STAGE/addons/$d"
        echo "$d" > "$STAGE/addons/$d/addon_name"
    done
fi

#---------------------------------------------------------------------------
# 5. shadow / passwd entries for the account (with password compatibility)
#---------------------------------------------------------------------------
getent passwd "$USER_NAME" > "$STAGE/passwd" 2>/dev/null || true
echo "$USER_HOME" > "$STAGE/homedir_paths"

# Convert shadow file password to cPanel-compatible format
# cPanel only accepts: $1$ (MD5), $2y$ (bcrypt), $6$ (SHA-512), or ! (disabled)
SHADOW_ENTRY="$(getent shadow "$USER_NAME" 2>/dev/null || true)"
if [[ -n "$SHADOW_ENTRY" ]]; then
    SHADOW_USER="$(echo "$SHADOW_ENTRY" | cut -d: -f1)"
    SHADOW_HASH="$(echo "$SHADOW_ENTRY" | cut -d: -f2)"
    SHADOW_REST="$(echo "$SHADOW_ENTRY" | cut -d: -f3-)"
    
    # Check if hash is cPanel-compatible
    if [[ "$SHADOW_HASH" =~ ^\$[126y]$ ]] || [[ "$SHADOW_HASH" = "!" ]] || [[ "$SHADOW_HASH" = "*" ]]; then
        # Already compatible, use as-is
        echo "$SHADOW_ENTRY" > "$STAGE/shadow"
    else
        # Incompatible hash format (yescrypt $y$, scrypt $7$, etc.)
        # Replace with disabled password - cPanel will require password reset on first login
        echo "${SHADOW_USER}:!:${SHADOW_REST}" > "$STAGE/shadow"
        echo "WARNING: Replaced incompatible password hash for $USER_NAME (likely yescrypt/scrypt). User will reset password on first cPanel login." >&2
    fi
else
    echo "WARNING: Could not read shadow file for $USER_NAME" >&2
fi

# quota (best effort)
quota -u "$USER_NAME" 2>/dev/null | tail -n +3 > "$STAGE/quota" || true

#---------------------------------------------------------------------------
# 6. Home directory (largest piece). Excludes caches/tmp.
#---------------------------------------------------------------------------
echo "==> Copying home directory..."
rsync -a \
    --exclude='.cache/' \
    --exclude='tmp/' \
    --exclude='.cpanel/' \
    --exclude='.cphorde/' \
    --exclude='logs/' \
    --exclude='*/cache/' \
    "$USER_HOME"/ "$STAGE/homedir"/

#---------------------------------------------------------------------------
# 7. MySQL: databases, users, grants
#---------------------------------------------------------------------------
echo "==> Dumping MySQL databases..."

# Sanity-check the MySQL connection so we don't silently produce empty dumps.
if ! mysql $MYSQL_OPTS -NB -e "SELECT 1" >/dev/null 2>"$WORK_DIR/mysql_conn.err"; then
    echo "ERROR: cannot connect to MySQL as root. mysqldump will be skipped." >&2
    echo "       Details: $(cat "$WORK_DIR/mysql_conn.err")" >&2
    echo "       Ensure /root/.my.cnf has working [client] credentials, then retry." >&2
fi

# CWP convention: dbs prefixed with <username>_  (sometimes root_<username>_)
DB_LIST="$(mysql_q "SHOW DATABASES;" | grep -E "^(${USER_NAME}_|root_${USER_NAME}_)" || true)"

if [[ -z "$DB_LIST" ]]; then
    echo "    (no databases found matching ${USER_NAME}_* or root_${USER_NAME}_*)"
fi

for db in $DB_LIST; do
    echo "    - $db"

    DUMP_ERR="$WORK_DIR/mysqldump_${db}.err"
    DUMP_SUCCESS=0

    # Strategy 1: InnoDB-friendly (consistent snapshot, no locks)
    if mysqldump $MYSQL_OPTS --routines --triggers --events --single-transaction \
        --skip-lock-tables --quick --hex-blob "$db" \
        > "$STAGE/mysql/${db}.sql" 2>"$DUMP_ERR"; then
        DUMP_SUCCESS=1
    fi

    # Strategy 2: MyISAM-friendly (no --single-transaction)
    if [[ $DUMP_SUCCESS -eq 0 ]]; then
        if mysqldump $MYSQL_OPTS --routines --triggers --events --quick --hex-blob "$db" \
            > "$STAGE/mysql/${db}.sql" 2>"$DUMP_ERR"; then
            DUMP_SUCCESS=1
        fi
    fi

    # Strategy 3: bare-minimum dump
    if [[ $DUMP_SUCCESS -eq 0 ]]; then
        if mysqldump $MYSQL_OPTS "$db" > "$STAGE/mysql/${db}.sql" 2>"$DUMP_ERR"; then
            DUMP_SUCCESS=1
        fi
    fi

    if [[ ! -s "$STAGE/mysql/${db}.sql" ]]; then
        echo "ERROR: mysqldump produced an empty file for '$db'." >&2
        if [[ -s "$DUMP_ERR" ]]; then
            echo "       mysqldump said: $(head -1 "$DUMP_ERR")" >&2
        fi
        # Keep an obvious marker so cPanel doesn't silently 'succeed' on garbage.
        echo "-- mysqldump failed for $db; see CWP server logs" > "$STAGE/mysql/${db}.sql"
    fi

    # ----- .create file -----
    # cPanel's restorepkg looks here for the CREATE DATABASE statement and
    # uses it to (re)create the database before loading <db>.sql. If this
    # file does NOT contain a CREATE DATABASE statement, cPanel never
    # creates the DB and the restore is reported as "empty".
    DB_CHARSET="$(mysql_q "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db';" 2>/dev/null)"
    DB_COLLATE="$(mysql_q "SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db';" 2>/dev/null)"
    [[ -z "$DB_CHARSET" ]] && DB_CHARSET="utf8mb4"
    [[ -z "$DB_COLLATE" ]] && DB_COLLATE="utf8mb4_general_ci"
    printf 'CREATE DATABASE `%s` /*!40100 DEFAULT CHARACTER SET %s COLLATE %s */;\n' \
        "$db" "$DB_CHARSET" "$DB_COLLATE" > "$STAGE/mysql/${db}.create"

    # timestamp file (cPanel touches these; empty is fine)
    : > "$STAGE/mysql-timestamps/${db}"
done

# MySQL users + grants linked to those DBs -> mysql.sql
echo "==> Exporting MySQL users / grants..."
{
    echo "-- MySQL users and grants for $USER_NAME"
    for db in $DB_LIST; do
        # find users with any privilege on this db
        USERS="$(mysql_q "SELECT DISTINCT User,Host FROM mysql.db WHERE Db='$db';" 2>/dev/null)"
        while IFS=$'\t' read -r u h; do
            [[ -z "$u" ]] && continue
            CREATE_STMT="$(mysql_q "SHOW CREATE USER \`$u\`@\`$h\`\G;" 2>/dev/null | sed 's/$/;/')"
            [[ -n "$CREATE_STMT" ]] && echo "$CREATE_STMT" || true
            mysql_q "SHOW GRANTS FOR \`$u\`@\`$h\`;" 2>/dev/null | sed 's/$/;/' || true
        done <<< "$USERS"
    done
} > "$STAGE/mysql.sql"

# Ensure mysql.sql is not empty; create minimal stub if needed
if [[ ! -s "$STAGE/mysql.sql" ]] || [[ $(wc -l < "$STAGE/mysql.sql") -le 1 ]]; then
    echo "-- No MySQL users/grants found; cPanel will create defaults" > "$STAGE/mysql.sql"
fi

#---------------------------------------------------------------------------
# 8. Email accounts, forwarders, autoresponders (exim/dovecot on CWP)
#---------------------------------------------------------------------------
echo "==> Collecting mail data..."
mkdir -p "$STAGE/homedir/etc" "$STAGE/homedir/mail"

for d in "${ALL_DOMAINS[@]}"; do
    # Mailbox dirs
    if [[ -d "/var/vmail/$d" ]]; then
        rsync -a "/var/vmail/$d"/ "$STAGE/homedir/mail/$d"/ 2>/dev/null || true
    fi

    # CWP stores passwd-style files per domain
    if [[ -f "/etc/exim/domains/$d/passwd" ]]; then
        mkdir -p "$STAGE/homedir/etc/$d"
        cp "/etc/exim/domains/$d/passwd"  "$STAGE/homedir/etc/$d/passwd"  2>/dev/null || true
        cp "/etc/exim/domains/$d/shadow"  "$STAGE/homedir/etc/$d/shadow"  2>/dev/null || true
        # quota stub
        awk -F: '{print $1":0"}' "/etc/exim/domains/$d/passwd" \
            > "$STAGE/homedir/etc/$d/quota" 2>/dev/null || true
    fi

    # Forwarders
    if [[ -f "/etc/exim/domains/$d/aliases" ]]; then
        cp "/etc/exim/domains/$d/aliases" "$STAGE/va/$d" 2>/dev/null || true
        cp "/etc/exim/domains/$d/aliases" "$STAGE/vf/$d" 2>/dev/null || true
    fi

    # Autoresponders
    if [[ -d "/etc/exim/domains/$d/autoresponder" ]]; then
        rsync -a "/etc/exim/domains/$d/autoresponder"/ "$STAGE/vad/$d"/ 2>/dev/null || true
    fi
done

#---------------------------------------------------------------------------
# 9. DNS zone files
#---------------------------------------------------------------------------
echo "==> Copying DNS zones..."
for d in "${ALL_DOMAINS[@]}"; do
    for candidate in \
        "/var/named/$d.db" \
        "/var/named/chroot/var/named/$d.db" \
        "/etc/namedb/$d.db"
    do
        if [[ -f "$candidate" ]]; then
            cp "$candidate" "$STAGE/dnszones/$d.db"
            break
        fi
    done
done

#---------------------------------------------------------------------------
# 10. SSL certificates (best effort)
#---------------------------------------------------------------------------
echo "==> Collecting SSL certs..."
for d in "${ALL_DOMAINS[@]}"; do
    # Let's Encrypt path used by CWP
    LE_DIR="/etc/letsencrypt/live/$d"
    if [[ -d "$LE_DIR" ]]; then
        mkdir -p "$STAGE/apache_tls/$d"
        cp -L "$LE_DIR/cert.pem"     "$STAGE/apache_tls/$d/cert"   2>/dev/null || true
        cp -L "$LE_DIR/privkey.pem"  "$STAGE/apache_tls/$d/key"    2>/dev/null || true
        cp -L "$LE_DIR/chain.pem"    "$STAGE/apache_tls/$d/cabundle" 2>/dev/null || true
        # cPanel also looks in ssl/certs and ssl/keys
        cp -L "$LE_DIR/cert.pem"    "$STAGE/ssl/${d}.crt" 2>/dev/null || true
        cp -L "$LE_DIR/privkey.pem" "$STAGE/ssl/${d}.key" 2>/dev/null || true
    fi
done

#---------------------------------------------------------------------------
# 11. Cron jobs
#---------------------------------------------------------------------------
echo "==> Copying cron..."
if [[ -f "/var/spool/cron/$USER_NAME" ]]; then
    cp "/var/spool/cron/$USER_NAME" "$STAGE/cron/$USER_NAME"
fi

#---------------------------------------------------------------------------
# 12. Build the tarball
#---------------------------------------------------------------------------
ARCHIVE="$OUT_DIR/cpmove-${USER_NAME}.tar.gz"
echo "==> Creating archive: $ARCHIVE"
tar -C "$STAGE" -czf "$ARCHIVE" .

# Cleanup staging
rm -rf "$WORK_DIR"

SIZE="$(du -h "$ARCHIVE" | awk '{print $1}')"
echo
echo "============================================================"
echo " Backup complete."
echo "   File : $ARCHIVE"
echo "   Size : $SIZE"
echo "============================================================"
echo
echo "Restore on cPanel/WHM:"
echo "  1) Upload \"$ARCHIVE\" to /home on the cPanel server."
echo "  2) WHM -> Transfers -> Restore a Full Backup/cpmove File."
echo "  3) Enter user: $USER_NAME  and submit."
echo
echo "After restore, please verify:"
echo "  - Domain DNS records and SSL certificates."
echo "  - Email account passwords (rehash if accounts don't accept logins)."
echo "  - MySQL users/grants and any custom PHP versions."
