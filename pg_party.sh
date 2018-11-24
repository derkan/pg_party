#!/bin/bash

#
# pg_party: Adds new parttitions automatically.(Only for date range partitioning for now)
#           Also copies constraints and indexes from parent table to new partition table.
#           At first run creates `pg_party_config` table and `pg_party_date_partitioni` func.
#           After first run add tables to be partitioned to `pg_party_config` like:
#           INSERT INTO pg_party_config VALUES('SCHEMA','TABLE','COLUMN','PARTYP','PLAN',CNT,f);
#               SCHEMA: Schema of parent table to add new partitions
#               TABLE : Parent table name to add new parttions
#               COLUMN: Column name of parent table to be used for partitioning
#               PLAN  : Can be 'month', 'year', 'week' or 'day'
#               PARTYP: Only supported value is 'd' as only date range partitoning is available.
#               CNT   : Count of future partitions to create. For example if set to 3, next
#                       3 month's part is added.
#               NATIVE: can be false or true, only false is supported now
#           Can be run every day, it adds new objects only if they are not already existing.
VERSION="1.1"
# version 1.1 Time based partitioning support and DB version check is added
# version 1.0 Erkan Durmus derkan@gmail.com

set -e
set -u

# ----- Config Begin ----- #

PSQL=/usr/bin/psql
DB_USER=postgres
DB_HOST=127.0.0.1
DB_PORT=5432

# Which DB's should be checked for new partitions
# DBCHK="IN"
# DBLST="'testdb'"
DBCHK="NOT IN"
DBLST="'postgres','repmgr'"

# ----- Config End ------- #
rq () {
  $PSQL -h $DB_HOST -p $DB_PORT -U $DB_USER --single-transaction \
  --set AUTOCOMMIT=off --set ON_ERROR_STOP=on \
  --no-password --no-align -t --field-separator ' ' \
  --quiet --pset footer=off \
  -d $1 -c "$2"
}


log () {
    echo "[$(date '+%Y-%m-%d %T.%3N')]: $*"
}

VERSQL="SELECT current_setting('server_version_num');"
DBSEL="SELECT d.datname, u.usename
         FROM pg_database d
         JOIN pg_user u ON (d.datdba = u.usesysid)
        WHERE d.datistemplate=false
          AND d.datname ${DBCHK} (${DBLST});"
TBLSEL="SELECT schema_name,master_table,part_col,date_plan,future_part_count
          FROM pg_party_config;"
CHKTBL="SELECT to_regclass('public.pg_party_config');"
TBLSQL="CREATE TABLE public.pg_party_config (
   schema_name text NOT NULL,
   master_table text NOT NULL,
   part_col text NOT NULL,
   part_type text NOT NULL default 'd',
   date_plan text NOT NULL DEFAULT 'month',
   future_part_count integer NOT NULL DEFAULT 1,
   is_native bool NOT NULL default false,
   PRIMARY KEY (schema_name, master_table)
);"
TBL10SQL="DO \$\$
BEGIN
  ALTER TABLE public.pg_party_config ADD COLUMN is_native BOOL NOT NULL DEFAULT false;
EXCEPTION
  WHEN duplicate_column THEN RAISE NOTICE 'column is_native already exists';
END
\$\$
"
CHKFNC="select count(*) from pg_proc where proname ='pg_party_date_partition';"
FNCSQL="
CREATE OR REPLACE FUNCTION pg_party_date_partition(
  schema_name       TEXT,
  master_table      TEXT,
  part_col          TEXT,
  date_plan         TEXT,
  future_part_count INT)

  RETURNS INTEGER AS
\$BODY\$
DECLARE
  created_parts     INT;
  is_already_exists BOOL;
  date_format       TEXT;
  cur_time          TIMESTAMP;
  start_time        TIMESTAMP;
  end_time          TIMESTAMP;
  plan_interval     INTERVAL;
  part_owner        TEXT;
  part_name         TEXT;
  part_val          TEXT;
  tmp_sql           TEXT;
  idx_name          TEXT;
  trg_name          TEXT;
  ins_trg_name          TEXT;
  const_name        TEXT;
  if_stmt           TEXT;
  idx               INT;
  version           INT;
BEGIN
  SELECT current_setting('server_version_num') INTO version;
  created_parts := 0;
  date_format := CASE WHEN date_plan = 'month'
    		   THEN 'YYYYMM'
                 WHEN date_plan = 'week'
                   THEN 'IYYYIW'
                 WHEN date_plan = 'day'
                   THEN 'YYYYDDD'
                 WHEN date_plan = 'hour'
                   THEN 'YYYYDDD_HH24MI'
                 WHEN date_plan = 'year'
                   THEN 'YYYY'
                 ELSE 'error'
                 END;

  IF date_format = 'error'
  THEN
    RAISE EXCEPTION 'Plan is invalid: %, (valid values: month/week/day/hour/year)', date_plan;
  END IF;
  cur_time := now() AT TIME ZONE 'utc';
  FOR i IN 1..future_part_count + 1 LOOP
    start_time := (DATE_TRUNC(date_plan, cur_time)) + (i - 1 || ' ' || date_plan) :: INTERVAL;
    plan_interval := (i || ' ' || date_plan) :: INTERVAL;
    end_time := (DATE_TRUNC(date_plan, (cur_time + plan_interval)));
    part_val := TO_CHAR(start_time, date_format);
    part_name := master_table || '_' || part_val;

    RAISE NOTICE 'Checking for partition %.%', schema_name, part_name;
    IF EXISTS(SELECT 1
              FROM information_schema.tables
              WHERE table_schema = schema_name AND table_name = part_name)
    THEN
      RAISE NOTICE 'Partition already created %.%', schema_name, part_name;
      is_already_exists := TRUE;
    ELSE
      -- Get parent table owner.We will use it to set owner of new partition.
      SELECT pg_roles.rolname
      FROM pg_class, pg_namespace, pg_roles
      WHERE relnamespace = pg_namespace.oid
            AND relkind = 'r' :: \"char\"
            AND relowner = pg_roles.oid
            AND relname = master_table
            AND nspname = schema_name
      INTO part_owner;
      -- Now add partition
      EXECUTE 'CREATE TABLE ' || schema_name || '.' || quote_ident(part_name)
              || ' (CHECK ((' || part_col || ' >= TIMESTAMP ''' || start_time || '+00:00'''
              || ' AND ' || part_col || ' < TIMESTAMP ''' || end_time || '+00:00'''
              || '))) INHERITS (' || schema_name || '.' || master_table || ')';
      RAISE NOTICE 'New partition %.% is added to table %.% on column %', schema_name, part_name, schema_name, master_table, part_col;
      is_already_exists := FALSE;
      created_parts := created_parts + 1;
      tmp_sql := 'ALTER TABLE ' || schema_name || '.' || quote_ident(part_name) || ' OWNER TO ' || part_owner;
      EXECUTE tmp_sql;
    END IF;

    -- Create non constraint indexes as just like parent table
    FOR tmp_sql, idx_name IN
    SELECT
      pg_get_indexdef(i.oid),
      i.relname
    FROM pg_index x
      JOIN pg_class c ON c.oid = x.indrelid
      JOIN pg_class i ON i.oid = x.indexrelid
      LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_tablespace t ON t.oid = i.reltablespace
    WHERE NOT x.indisunique
          AND n.nspname = schema_name
          AND c.relname = master_table
    LOOP
      tmp_sql := replace(tmp_sql, 'CREATE INDEX ' || idx_name || ' ON ' || schema_name || '.' || master_table,
                         'CREATE INDEX IF NOT EXISTS ' || idx_name || '_' || part_val || ' ON ' || schema_name || '.' ||
                         part_name);
      EXECUTE tmp_sql;
    END LOOP;

    -- Create constraints as just like parent table
    FOR tmp_sql, const_name IN
    SELECT
      pg_get_constraintdef(c.oid),
      conname
    FROM pg_constraint c
      JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname = schema_name
          AND conrelid :: REGCLASS = (schema_name || '.' || master_table) :: REGCLASS
    ORDER BY conrelid :: REGCLASS :: TEXT, contype DESC
    LOOP
      IF NOT EXISTS(SELECT 1
                    FROM information_schema.constraint_column_usage
                    WHERE table_name = part_name AND constraint_name = REPLACE(const_name, master_table, part_name) AND
                          table_schema = schema_name)
      THEN
        tmp_sql := 'ALTER TABLE ' || schema_name || '.' || quote_ident(part_name) || ' ADD ' || tmp_sql;
        EXECUTE tmp_sql;
      END IF;
    END LOOP;
  END LOOP;

  -- Create or replace trigger on master_table
  IF created_parts > 0
  THEN
    idx := 0;
    ins_trg_name := schema_name || '.' || master_table || '_partition_insert_trg_fn';
    tmp_sql:='CREATE OR REPLACE FUNCTION ' || ins_trg_name || '()
                RETURNS TRIGGER AS \$\$
    BEGIN';
    FOR part_name, start_time IN
    SELECT
      c.relname AS child,
      TO_DATE(REVERSE(LEFT(REVERSE(c.relname), STRPOS(REVERSE(c.relname), '_') - 1)), date_format)
    FROM pg_inherits
      JOIN pg_class AS c ON (inhrelid = c.oid)
      JOIN pg_class AS p ON (inhparent = p.oid)
      JOIN pg_namespace pn ON pn.oid = p.relnamespace
      JOIN pg_namespace cn ON cn.oid = c.relnamespace
    WHERE p.relname = master_table AND pn.nspname = schema_name
    ORDER BY c.relname DESC
    LOOP
      end_time := start_time + ('1 ' || date_plan) :: INTERVAL;
      if_stmt := CASE WHEN idx = 0
        THEN '
       IF'
                 ELSE '
       ELSIF' END;

      tmp_sql:= tmp_sql || if_stmt || ' ( NEW.' || part_col
                || ' >= TIMESTAMP ''' || start_time || '+00:00'' AND NEW.' || part_col || ' < TIMESTAMP '''
                || end_time || '+00:00'' ) THEN
              INSERT INTO ' || schema_name || '.' || part_name || ' VALUES (NEW.*); ';
      idx := idx + 1;
    END LOOP;
    tmp_sql := tmp_sql || '
      ELSE
          RAISE EXCEPTION ''Partition date out of range for ' || schema_name || '.' || master_table ||
               ', date: %s!'', new.' || part_col || ';
      END IF;
      RETURN NULL;
    END;
    \$\$
    LANGUAGE plpgsql;';
    EXECUTE tmp_sql;
    -- Create the trigger that uses the trigger function, if it isn't already created
    trg_name:=master_table || '_insert_trigger';
    IF NOT EXISTS(SELECT 1
                  FROM information_schema.triggers
                  WHERE trigger_name = trg_name)
    THEN
      tmp_sql := 'CREATE TRIGGER ' || trg_name || '
                  BEFORE INSERT ON ' || schema_name || '.' || master_table || '
                  FOR EACH ROW EXECUTE PROCEDURE ' || ins_trg_name || '();';
      EXECUTE tmp_sql;
    END IF;
  END IF;

  RETURN created_parts;
END;
\$BODY\$
LANGUAGE plpgsql VOLATILE
COST 100;
"
rq postgres "${VERSQL}" | \
while read ver ; do
  if [[ "$ver" -lt 90100 ]]; then
	  log "Your DB version(${ver}) is too old"
	  exit 1
  fi
done
rq postgres "${DBSEL}" | \
while read db owner ; do
    log "Checking if pg_party table and function is installed to $db"
    rq $db "${CHKTBL}" | \
    while read tblins ; do
        if [[ -z "$tblins" ]]; then
          log "Creating config table"
          rq $db "${TBLSQL}"
          rq $db "ALTER TABLE public.pg_party_config OWNER TO ${owner};"
        else
          log "Checking pg_party table"
          rq $db "${TBL10SQL}"
        fi
    done
    rq $db "${CHKFNC}" | \
    while read fnc ; do
        ddl_needed=0
        if [[ "$fnc" -eq 0 ]]; then
                log "Creating function"
                ddl_needed=1
	      elif [[ ! -f ./.pg_party_f_${VERSION}.done ]]; then
                log "Updating function"
                ddl_needed=1
	      fi
        if [[ "$ddl_needed" -eq 1 ]]; then
          rq $db "${FNCSQL}"
          rq $db "ALTER FUNCTION pg_party_date_partition( TEXT, TEXT, TEXT, TEXT, INTEGER ) OWNER TO ${owner};"
          touch ./.pg_party_f_${VERSION}.done
        fi
    done

    log "Checking parts in $db"
    rq $db "${TBLSEL}" | \
    while read schema table col plan count; do
        log "Adding parts for ${schema}.${table} on col ${col} for next ${count} months"
        rq $db "SELECT pg_party_date_partition('${schema}','${table}','${col}','${plan}',${count});" | \
        while read added; do
           if [[ $added -ne 0 ]]; then
               log "Added ${added} partitions to ${schema}.${table}"
           else
               log "No partitions added to ${schema}.${table}"
           fi
        done
    done
done
