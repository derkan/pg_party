# pg_party
Automatic partitioning script for PostgreSQL v9.1+

This single script can automatically add new date range partitions to tables automatically. Only date range partitioning is supported for now.

`pg_party.sh` uses a table(`pg_party_config`) and a function(`pg_party_date_partition`) to add new partitions

## Installing

Copy this script to your system and configure for your db.
```bash
wget pg_party.sh
chmod +x pg_party.sh
vi pg_party.sh

```
You may need to change which DB's will be checked for new partitions:
```bash
PSQL=/bin/psql
DB_USER=postgres
DB_HOST=127.0.0.1
DB_PORT=5432

# Which DB's should be checked for new partitions
DBCHK="NOT IN"
DBLST="'postgres','repmgr'"
``` 
In this configuration all DB's will be checked for new partitions except `postgres','repmgr'` as `DBLST` is set so.

## Configuration
After updating `pg_party.sh` script run it for the first time to create config table(`pg_party_config`) and  function(`pg_party_date_partition`).
```bash
./pg_party.sh
```
And add master tables to table `pg_party_config`. For example to add partitions to table `test_table` in `public` schema on column `log_date` with monthly date range plan for next **3** months:
```bash
psql -d DBNAME -c "INSERT INTO pg_party_config VALUES('public','test_table','log_date','d','month',3);"
```
Table column description:

|Column|Description|Example Value|
|------|-----------|-------------|
|schema_name|Schema name of master table|public|
|master_table|Parent table name|test_table|
|part_col|Timestamp typed column to use as partitioning column| log_date|
|date_plan|Date partitioning plan: `day`, `week`, `month`, `year`| month|
|future_part_count|How many next partitions will be created| 1|

Script uses current timestamp of system to create `future_part_count`s. For example if system date is '2016-11-08', and `future_part_count` is **3** then these partitions will be created for table `test_table`:
```
test_table_201611
test_table_201612
test_table_201701
```
