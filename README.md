# pg_party

Automatic partitioning script for PostgreSQL v9.1+ 

This single script can automatically add new date range partitions to tables automatically. Supported plans are `year`, `month`, `week`, `day`, `hour`.

`pg_party.sh` uses a tables(`pg_party_config, pg_party_config_ddl`) and a functions(`pg_party_date_partition, pg_party_date_partition_native`) to add new partitions

## About PostgreSQL 10 Declarative Partitioning

Starting in PostgreSQL 10, PGSQL have [declarative partitioning](https://www.postgresql.org/docs/10/static/ddl-partitioning.html), bu not automatic creation of new partitions yet.

For PGSQL version 9.x `pg_party` inherits indexes, constraints from master table while creating new partitions. But for PGSQL 10/11 versions, indexes can not be defined on parent table. To be able to auto create needed indexes `pg_party` creates `pg_party_config_ddl` table. You can add your DDL's for new partitions. `pg_party` will execute each DDL on new partition. To be able make your DDLs dynamic you can use following variables in your DDL template:

|Variable|Description|
|--------|-----------|
|${PARTSCHEMA}|Current partition's schema name|
|${PARTNAME}|Current partition's name|
|${PARTPARENT}|Current partition's parent table's name|

For example if you add this DDL to table `pg_party_config_ddl`

```sql
INSERT INTO TABLE pg_party_config_ddl(schema_name,master_table,ddl)
VALUES('public', 'measurements', 'CREATE INDEX ${PARTNAME}_city_id_idx on  ${PARTNAME}(city_id)');
```

`pg_party` will run this DDL template for each new partitions after replacing variables.

## About PostgreSQL 11 Declarative Partitioning

With version 11, PostgreSQL lets you create indexes on parent table and  will automatically create same indexes on all the child tables automatically. So for v11, `pg_party_config_ddl` table is not needed to be configured. `pg_party` will create future partitions and all indexes will be copied to new partitions by PostgreSQL automatically.

## Installing

Copy this script to your system and configure for your db.
```bash
wget https://raw.githubusercontent.com/derkan/pg_party/master/pg_party.sh
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
In this configuration all DB's will be checked for new partitions except `postgres','repmgr'` as `DBLST` is set so. This configuration assumes that you are running this script from `postgres` user to login DB without password. If you are going to run with another user, you should set your DB's `pg_hba.conf` file accordingly.

## Configuration

After updating `pg_party.sh` script run it for the first time to create config tables(`pg_party_config, pg_party_config_ddl`) and  functions(`pg_party_date_partition, pg_party_date_partition_native`).
For example in following log you can see that function and table is created **for each DB**:

```bash
-bash-4.2$ ./pg_party.sh
[2016-11-08 17:16:23.792]: Checking if pg_party table and function is installed to testdb
[2016-11-08 17:16:23.812]: Creating config table
[2016-11-08 17:16:23.814]: Creating function
[2016-11-08 17:16:23.815]: Checking parts in testdb
[2016-11-08 17:16:23.819]: Checking if pg_party table and function is installed to demodb
[2016-11-08 17:16:23.826]: Creating config table
[2016-11-08 17:16:23.845]: Creating function
[2016-11-08 17:16:23.855]: Checking parts in demodb
```

And add master tables to table `pg_party_config`. For example to add partitions to table `test_table` in `public` schema on column `log_date` with monthly date range plan for next **3** months:

```bash
psql -d demodb -c "INSERT INTO pg_party_config VALUES('public','test_table','log_date','d','month',3);"
```

Table column description:

|Column|Description|Example Value|
|------|-----------|-------------|
|schema_name|Schema name of master table|public|
|master_table|Parent table name|test_table|
|part_col|Timestamp typed column to use as partitioning column| log_date|
|date_plan|Date partitioning plan: `day`, `week`, `month`, `year`, `hour` | month|
|future_part_count|How many next partitions will be created| 1|

Partition naming formats

|Plan|Format|
|-----|------|
|Year| `partname`_YYYY |
|Month| `partname`_YYYYMM |
|Week | `partname`_IYYYIW |
|Day| `partname`_YYYYDDD|
|Hour| `partname`_YYYYDDD_HH24MI|

Script uses current timestamp of system to create `future_part_count`s. For example if system date is '2016-11-08', and `future_part_count` is **3** then these partitions will be created for table `test_table`:

```
test_table_201611
test_table_201612
test_table_201701
test_table_201702
```

Following example output is generated when I run script on '2016-11-08' with `pg_party_table` is set for **1** `future_part_count` for table `public.test_table` in `demodb`:

```bash
-bash-4.2$ ./pg_party.sh 
[2016-11-08 17:20:37.401]: Checking if pg_party table and function is installed to testdb
[2016-11-08 17:20:37.419]: Checking parts in testdb
[2016-11-08 17:20:37.427]: Checking if pg_party table and function is installed to demodb
[2016-11-08 17:20:37.444]: Checking parts in demodb
[2016-11-08 17:20:37.451]: Adding parts for public.test_table on col log_date for next 1 months
NOTICE:  Checking for partition public.test_table_201611
NOTICE:  New partition public.test_table_201611 is added to table public.test_table on column log_date
NOTICE:  Checking for partition public.test_table_201612
NOTICE:  New partition public.test_table_201612 is added to table public.test_table on column log_date
[2016-11-08 17:20:37.500]: Added 2 partitions to public.test_table
```

As you see, two partitions are added, one for current month and one for next month.

## Adding to cron

`pg_party.sh` can be any time, because it checks if partitions are already created and not. So you can run it every day for monthly partitioning to be sure that partitions are pre-created.

```bash
-bash-4.2$ crontab -e
00  22  * * * ~/pg_party.sh >> ~/pg_party.log 2>&1
```
## Notes for MS Windows users

I haven't tried, but it is possible to run bash scripts by installing [Windows Subsystem for Linux-WSL](https://msdn.microsoft.com/en-us/commandline/wsl/install_guide). After installing get access to WSL command prompt and install postgresql client:

```bash
 sudo apt-get install postgresql-client
```
And also install pg_party to your home directory  as discussed above and configure it. Then run it on Command Prompt like:

```bash
bash -c "~/pg_party.sh" 
```
