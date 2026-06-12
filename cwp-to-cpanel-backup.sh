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

usage() {
    cat >&2 <<EOF
Usage:
  $0 <cwp_username> [output_dir]      Back up a single account.
  $0 --all [output_dir]               Back up every CWP account on this server.
  $0 -h | --help                      Show this help.

output_dir defaults to /root/cpmove-backups.
EOF
}

case "${1:-}" in
    -h|--help|"")
        usage
        [[ -z "${1:-}" ]] && exit 1 || exit 0
        ;;
esac

#---------------------------------------------------------------------------
# 0a. --all mode: discover every CWP user and re-invoke ourselves per user.
#---------------------------------------------------------------------------
if [[ "$1" == "--all" ]]; then
    ALL_OUT_DIR="${2:-/root/cpmove-backups}"
    mkdir -p "$ALL_OUT_DIR"

    SCRIPT_PATH="$(readlink -f "$0")"

    # Minimal MySQL hookup so we can query CWP's user table.
    _ALL_MYSQL_OPTS=""
    [[ -f /root/.my.cnf ]] && _ALL_MYSQL_OPTS="--defaults-file=/root/.my.cnf"

    # 1) Preferred source: CWP's own user table.
    USERS="$(mysql $_ALL_MYSQL_OPTS -NB -e "SELECT username FROM root_cwp.user;" 2>/dev/null \
        | awk 'NF' | sort -u)"

    # 2) Fallback: any system account with a /home/<user> directory and a
    #    real login shell (excludes root, system users, nologin accounts).
    if [[ -z "$USERS" ]]; then
        USERS="$(getent passwd \
            | awk -F: '$6 ~ "^/home/" && $7 !~ /(nologin|false|sync|shutdown|halt)$/ {print $1}' \
            | sort -u)"
    fi

    if [[ -z "$USERS" ]]; then
        echo "ERROR: --all could not discover any CWP accounts." >&2
        echo "       Tried root_cwp.user and /home/* with a login shell." >&2
        exit 1
    fi

    TOTAL=$(echo "$USERS" | wc -l)
    echo "==> --all: found $TOTAL account(s) to back up. Output dir: $ALL_OUT_DIR"
    echo "$USERS" | sed 's/^/    - /'
    echo

    SUMMARY_LOG="$ALL_OUT_DIR/cpmove-all-$(date +%Y%m%d-%H%M%S).log"
    OK_COUNT=0
    FAIL_COUNT=0
    FAILED_USERS=()

    # Run each user as a fresh invocation so a failure in one doesn't kill
    # the whole run. Stream output and tee into a summary log.
    for u in $USERS; do
        echo "============================================================" | tee -a "$SUMMARY_LOG"
        echo "[$(date '+%F %T')] Backing up: $u"                              | tee -a "$SUMMARY_LOG"
        echo "============================================================" | tee -a "$SUMMARY_LOG"
        if bash "$SCRIPT_PATH" "$u" "$ALL_OUT_DIR" 2>&1 | tee -a "$SUMMARY_LOG"; then
            OK_COUNT=$((OK_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_USERS+=("$u")
        fi
        echo | tee -a "$SUMMARY_LOG"
    done

    echo "============================================================"
    echo " --all run complete."
    echo "   Accounts processed : $TOTAL"
    echo "   Succeeded          : $OK_COUNT"
    echo "   Failed             : $FAIL_COUNT"
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo "   Failed accounts    : ${FAILED_USERS[*]}"
    fi
    echo "   Summary log        : $SUMMARY_LOG"
    echo "   Archives in        : $ALL_OUT_DIR"
    echo "============================================================"

    [[ $FAIL_COUNT -gt 0 ]] && exit 1
    exit 0
fi

#---------------------------------------------------------------------------
# 0b. Single-account mode.
#---------------------------------------------------------------------------
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

# Detect server flavour / version so we can pick safe mysqldump options.
MYSQL_VER="$(mysql_q "SELECT VERSION();" 2>/dev/null | head -1)"
echo "    MySQL/MariaDB server reports: ${MYSQL_VER:-unknown}"

# --set-gtid-purged=OFF is only valid on MySQL 5.6+ (not MariaDB). Probe it.
GTID_OPT=""
if mysqldump --help 2>/dev/null | grep -q -- '--set-gtid-purged'; then
    GTID_OPT="--set-gtid-purged=OFF"
fi
# --column-statistics was added in MySQL 8.0 client and breaks against older
# servers; disable it when supported.
COLSTATS_OPT=""
if mysqldump --help 2>/dev/null | grep -q -- '--column-statistics'; then
    COLSTATS_OPT="--column-statistics=0"
fi
# --no-tablespaces avoids the PROCESS-privilege requirement on MySQL 8.0+.
NOTBSP_OPT=""
if mysqldump --help 2>/dev/null | grep -q -- '--no-tablespaces'; then
    NOTBSP_OPT="--no-tablespaces"
fi

# Common safety options that materially improve restore reliability:
#   --max-allowed-packet=1G  -> avoids "packet too large" on big BLOB rows
#   --default-character-set=utf8mb4 -> preserves emoji / non-latin text
#   --hex-blob               -> binary-safe BLOB / VARBINARY
#   --add-drop-table         -> idempotent restore (overwrites stray tables)
#   --skip-lock-tables       -> needed when we lack LOCK TABLES on some DBs
MYSQLDUMP_COMMON=(
    $MYSQL_OPTS
    --max-allowed-packet=1G
    --default-character-set=utf8mb4
    --hex-blob
    --add-drop-table
    --skip-lock-tables
    --routines
    --triggers
    --events
    --quick
    $GTID_OPT
    $COLSTATS_OPT
    $NOTBSP_OPT
)

for db in $DB_LIST; do
    echo "    - $db"

    DUMP_ERR="$WORK_DIR/mysqldump_${db}.err"
    DUMP_SUCCESS=0

    # Strategy 1: InnoDB-friendly consistent snapshot
    if mysqldump "${MYSQLDUMP_COMMON[@]}" --single-transaction "$db" \
        > "$STAGE/mysql/${db}.sql" 2>"$DUMP_ERR"; then
        DUMP_SUCCESS=1
    fi

    # Strategy 2: drop --single-transaction (helps with MyISAM-only DBs)
    if [[ $DUMP_SUCCESS -eq 0 ]]; then
        if mysqldump "${MYSQLDUMP_COMMON[@]}" "$db" \
            > "$STAGE/mysql/${db}.sql" 2>"$DUMP_ERR"; then
            DUMP_SUCCESS=1
        fi
    fi

    # Strategy 3: minimal flags – last resort.
    if [[ $DUMP_SUCCESS -eq 0 ]]; then
        if mysqldump $MYSQL_OPTS --max-allowed-packet=1G --hex-blob \
            --skip-lock-tables --add-drop-table $GTID_OPT $COLSTATS_OPT \
            $NOTBSP_OPT "$db" > "$STAGE/mysql/${db}.sql" 2>"$DUMP_ERR"; then
            DUMP_SUCCESS=1
        fi
    fi

    if [[ ! -s "$STAGE/mysql/${db}.sql" ]]; then
        echo "ERROR: mysqldump produced an empty file for '$db'." >&2
        [[ -s "$DUMP_ERR" ]] && sed 's/^/       mysqldump: /' "$DUMP_ERR" >&2
        echo "-- mysqldump failed for $db; see backup log" > "$STAGE/mysql/${db}.sql"
    else
        # Verify completeness. mysqldump appends "-- Dump completed on ..."
        # as its very last lines when it finished cleanly. A truncated dump
        # (network hiccup, disk full, server kill) lacks this marker, even
        # though the exit code can occasionally still be 0.
        if ! tail -5 "$STAGE/mysql/${db}.sql" | grep -q -- '-- Dump completed'; then
            echo "WARNING: dump for '$db' looks truncated (no '-- Dump completed' marker)." >&2
            [[ -s "$DUMP_ERR" ]] && sed 's/^/         mysqldump: /' "$DUMP_ERR" >&2
        fi

        # Cross-check table counts to catch silent partial dumps.
        SRC_TABLES="$(mysql_q "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db' AND TABLE_TYPE='BASE TABLE';" 2>/dev/null)"
        DUMP_TABLES="$(grep -c '^CREATE TABLE ' "$STAGE/mysql/${db}.sql" || true)"
        if [[ -n "$SRC_TABLES" && "$SRC_TABLES" -gt 0 && "$DUMP_TABLES" -lt "$SRC_TABLES" ]]; then
            echo "WARNING: dump for '$db' contains $DUMP_TABLES CREATE TABLE statements but DB has $SRC_TABLES tables." >&2
            [[ -s "$DUMP_ERR" ]] && sed 's/^/         mysqldump: /' "$DUMP_ERR" >&2

            # If mysqld can't write to /tmp (Aria/MyISAM .MAI temp files,
            # Errcode 13), a single bad table aborts the whole-DB dump.
            # Fall back to dumping table-by-table so we salvage what we
            # can and clearly report which tables failed.
            if grep -q "Permission denied\|Errcode: 13\|Couldn't execute" "$DUMP_ERR"; then
                echo "         -> server-side /tmp permission issue detected; retrying table-by-table." >&2
                echo "         -> Fix on server: 'chmod 1777 /tmp' (or set 'tmpdir' in my.cnf to a writable dir)." >&2

                SALVAGE="$STAGE/mysql/${db}.sql.partial"
                FAILED_TABLES=()
                : > "$SALVAGE"
                echo "-- Salvaged table-by-table dump of $db" >> "$SALVAGE"
                echo "SET FOREIGN_KEY_CHECKS=0;" >> "$SALVAGE"

                TABLES="$(mysql_q "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db' AND TABLE_TYPE='BASE TABLE';" 2>/dev/null)"
                while IFS= read -r tbl; do
                    [[ -z "$tbl" ]] && continue
                    TBL_ERR="$WORK_DIR/mysqldump_${db}_${tbl}.err"
                    if mysqldump $MYSQL_OPTS --max-allowed-packet=1G \
                        --default-character-set=utf8mb4 --hex-blob \
                        --skip-lock-tables --add-drop-table --quick \
                        $GTID_OPT $COLSTATS_OPT $NOTBSP_OPT \
                        "$db" "$tbl" >> "$SALVAGE" 2>"$TBL_ERR"; then
                        :
                    else
                        FAILED_TABLES+=("$tbl")
                        echo "         FAILED table: ${db}.${tbl}" >&2
                        [[ -s "$TBL_ERR" ]] && sed 's/^/             /' "$TBL_ERR" >&2
                    fi
                done <<< "$TABLES"

                echo "SET FOREIGN_KEY_CHECKS=1;" >> "$SALVAGE"
                # Replace the truncated full-DB dump with the salvaged one.
                mv "$SALVAGE" "$STAGE/mysql/${db}.sql"

                if [[ ${#FAILED_TABLES[@]} -gt 0 ]]; then
                    echo "WARNING: ${#FAILED_TABLES[@]} table(s) in '$db' could not be dumped: ${FAILED_TABLES[*]}" >&2
                    echo "         These will be MISSING in the cPanel restore until the server-side /tmp issue is fixed." >&2
                fi
            fi
        fi

        # Strip DEFINER=`user`@`host` clauses. These are a very common
        # cause of cPanel restore aborts ("Access denied for definer ...")
        # which leaves the DB created but mostly empty.
        sed -i -E \
            -e 's/DEFINER=`[^`]*`@`[^`]*`//g' \
            -e 's/DEFINER=[^ ]+ //g' \
            -e 's/SQL SECURITY DEFINER/SQL SECURITY INVOKER/g' \
            "$STAGE/mysql/${db}.sql"
    fi

    # ----- .create file -----
    # cPanel's restorepkg looks here for the CREATE DATABASE statement and
    # uses it to (re)create the database before loading <db>.sql. Without
    # a CREATE DATABASE here, cPanel never creates the DB and the restore
    # is reported as "empty".
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

# Detect whether SHOW CREATE USER exists (MySQL 5.7+ / MariaDB 10.2+).
HAVE_SHOW_CREATE_USER=0
if mysql_q "SHOW CREATE USER 'root'@'localhost';" >/dev/null 2>&1; then
    HAVE_SHOW_CREATE_USER=1
fi

# Detect the password column in mysql.user (Password vs authentication_string).
PW_COL="authentication_string"
if ! mysql_q "SELECT authentication_string FROM mysql.user LIMIT 1;" >/dev/null 2>&1; then
    PW_COL="Password"
fi

# Collect every DB user that has privileges on any of this account's DBs,
# deduplicated across databases.
USERS_FILE="$WORK_DIR/db_users.tsv"
: > "$USERS_FILE"
for db in $DB_LIST; do
    mysql_q "SELECT DISTINCT User,Host FROM mysql.db WHERE Db='$db';" 2>/dev/null >> "$USERS_FILE"
done
# Some setups grant via mysql.tables_priv too — include those.
for db in $DB_LIST; do
    mysql_q "SELECT DISTINCT User,Host FROM mysql.tables_priv WHERE Db='$db';" 2>/dev/null >> "$USERS_FILE"
done
# CWP convention: db users are typically named <cpuser>_*. Catch any that
# match the cPanel-user prefix even if no row exists in mysql.db (rare,
# but happens with custom grants).
mysql_q "SELECT DISTINCT User,Host FROM mysql.user WHERE User LIKE '${USER_NAME}\\_%' ESCAPE '\\\\';" 2>/dev/null >> "$USERS_FILE"

# Skip MySQL/MariaDB system accounts.
SYS_USERS_RE='^(root|mysql\.sys|mysql\.session|mysql\.infoschema|mariadb\.sys|debian-sys-maint|cwpsrv|cwpdb)$'

USER_COUNT=0
{
    echo "-- MySQL users and grants for $USER_NAME"
    echo "-- Generated $(date -u +%FT%TZ)"

    # Dedupe (user, host) pairs.
    sort -u "$USERS_FILE" | while IFS=$'\t' read -r u h; do
        [[ -z "$u" ]] && continue
        [[ "$u" =~ $SYS_USERS_RE ]] && continue

        echo ""
        echo "-- ----- ${u}@${h} -----"

        if [[ "$HAVE_SHOW_CREATE_USER" -eq 1 ]]; then
            # SHOW CREATE USER returns the full CREATE USER ... IDENTIFIED ...
            # statement preserving the existing password hash and auth plugin.
            CREATE_STMT="$(mysql $MYSQL_OPTS -NB -e "SHOW CREATE USER \`$u\`@\`$h\`;" 2>/dev/null)"
            if [[ -n "$CREATE_STMT" ]]; then
                # SHOW CREATE USER omits a trailing semicolon; add one.
                # Also convert "CREATE USER" to "CREATE USER IF NOT EXISTS"
                # so the restore is idempotent on cPanel servers that may
                # have a clashing leftover user.
                echo "${CREATE_STMT};" \
                    | sed -E 's/^CREATE USER /CREATE USER IF NOT EXISTS /'
            fi
        else
            # Legacy path: build CREATE USER from the password hash directly.
            PWHASH="$(mysql_q "SELECT ${PW_COL} FROM mysql.user WHERE User='$u' AND Host='$h' LIMIT 1;" 2>/dev/null)"
            if [[ -n "$PWHASH" ]]; then
                echo "CREATE USER IF NOT EXISTS \`$u\`@\`$h\` IDENTIFIED BY PASSWORD '${PWHASH}';"
            else
                echo "CREATE USER IF NOT EXISTS \`$u\`@\`$h\`;"
            fi
        fi

        # GRANT statements. SHOW GRANTS returns one per line, without ';'.
        mysql $MYSQL_OPTS -NB -e "SHOW GRANTS FOR \`$u\`@\`$h\`;" 2>/dev/null \
            | sed 's/$/;/'

        USER_COUNT=$((USER_COUNT + 1))
    done
} > "$STAGE/mysql.sql"

# Count and report so a silent miss is visible in the script output.
EXPORTED_USERS="$(grep -c '^CREATE USER ' "$STAGE/mysql.sql" || true)"
EXPORTED_GRANTS="$(grep -c '^GRANT ' "$STAGE/mysql.sql" || true)"
echo "    Exported ${EXPORTED_USERS} DB user(s), ${EXPORTED_GRANTS} grant(s)."

if [[ "$EXPORTED_USERS" -eq 0 && -n "$DB_LIST" ]]; then
    echo "WARNING: no MySQL users were exported even though databases exist." >&2
    echo "         cPanel will create the databases but they will have no DB users." >&2
fi

# Strip DEFINER clauses here too (rare in grants, but cheap insurance).
sed -i -E \
    -e 's/DEFINER=`[^`]*`@`[^`]*`//g' \
    -e 's/SQL SECURITY DEFINER/SQL SECURITY INVOKER/g' \
    "$STAGE/mysql.sql"

# Ensure mysql.sql is not empty (cPanel tolerates an empty file but a
# comment makes the archive easier to inspect).
if [[ ! -s "$STAGE/mysql.sql" ]]; then
    echo "-- No MySQL users/grants found for $USER_NAME" > "$STAGE/mysql.sql"
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
