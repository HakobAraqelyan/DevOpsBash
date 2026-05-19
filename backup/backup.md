mariadb-full-and-incremental-backup.sh

1. Գործարկման mode-եր

Script-ը կարող է աշխատել հետևյալ mode-երով.

full
incr
prepare-full
prepare-incr
chain-prepare
restore
info
cleanup

Եթե mode չես տալիս, script-ը պետք է աշխատի որպես՝

full

Օրինակ՝

./backup_full_and_incremental.sh

նույնն է, ինչ՝

./backup_full_and_incremental.sh full
2. Ընդհանուր backup պարամետրեր
--backup-root PATH

Որտեղ պահել backup-ները։

Default՝

/var/backups/mariadb

Օրինակ՝

--backup-root /var/backups/mariadb

Կամ եթե ուզում ես պահել user-ի home-ում՝

--backup-root /home/mariabackup/backups/mariadb
--target-dir PATH

Օգտագործվում է prepare, restore, info mode-երի ժամանակ՝ նշելու համար կոնկրետ backup directory կամ archive։

Օրինակ՝

--target-dir /var/backups/mariadb/full_2026-05-15_12-00-01.tar.zst

Կամ directory՝

--target-dir /var/backups/mariadb/full_2026-05-15_12-00-01
--incremental-dir PATH

Օգտագործվում է prepare-incr mode-ի ժամանակ, երբ ուզում ես incremental backup-ը apply անել full backup-ի վրա։

Օրինակ՝

--incremental-dir /var/backups/mariadb/inc_2026-05-15_13-00-01.tar.zst
--base-dir PATH

Incremental backup-ի համար ձեռքով նշում ես base backup-ը։

Օրինակ՝

--base-dir /var/backups/mariadb/full_2026-05-15_12-00-01.tar.zst

Եթե չտաս, script-ը կփորձի գտնել վերջին full backup-ը։

--datadir PATH

MariaDB-ի data directory-ն։

Default՝

/var/lib/mysql

Օրինակ՝

--datadir /var/lib/mysql

Restore-ի ժամանակ սա շատ կարևոր է։

--socket PATH

MariaDB socket path-ը։

Default՝

/run/mysqld/mysqld.sock

Օրինակ՝

--socket /run/mysqld/mysqld.sock

Եթե AlmaLinux/CentOS է, կարող է լինել՝

--socket /var/lib/mysql/mysql.sock
--host HOST

TCP connection-ի համար host։

Default՝

localhost

Սովորաբար socket-ով աշխատելու դեպքում սա պետք չէ։

--port PORT

MariaDB port։

Default՝

3306

Օրինակ՝

--port 3306
--user USER

MariaDB backup user։

Default՝

backup

Օրինակ՝

--user mariabackup
--password PASS

MariaDB user-ի password-ը command line-ով։

Օրինակ՝

--password 'StrongPassword'

Խորհուրդ չի տրվում, որովհետև կարող է մնալ shell history-ում։

--password-file PATH

MariaDB user-ի password file։

Օրինակ՝

--password-file /home/mariabackup/scripts/backup/.maria_backup_password

Սա ավելի ճիշտ տարբերակն է։

Ֆայլի permission-ը լավ է լինի՝

chmod 600 /home/mariabackup/scripts/backup/.maria_backup_password
3. Performance պարամետրեր
--parallel N

Քանի thread օգտագործի backup-ի ժամանակ։

Default՝

2

Օրինակ՝

--parallel 4
--use-memory SIZE

Prepare-ի ժամանակ օգտագործվող memory։

Default՝

512M

Օրինակ՝

--use-memory 1G
--tmpdir PATH

Temporary directory, որը փոխանցվում է mariadb-backup-ին։

Default՝

/tmp

Օրինակ՝

--tmpdir /tmp
--open-files-limit N

Բաց ֆայլերի limit։

Default՝

65535

Օրինակ՝

--open-files-limit 65535
--ftwrl-wait-timeout N

Քանի վայրկյան սպասի lock ստանալու համար։

Default՝

30

Օրինակ՝

--ftwrl-wait-timeout 60
--ftwrl-wait-threshold N

Որքան ժամանակից հետո query-ն համարվի երկար աշխատող։

Default՝

10

Օրինակ՝

--ftwrl-wait-threshold 10
--ftwrl-wait-query-type ALL|UPDATE|SELECT

Որ query-ների ավարտին սպասի lock-ից առաջ։

Default՝

ALL

Օրինակ՝

--ftwrl-wait-query-type ALL
4. Archive / compression պարամետրեր
--archive-format tar.zst|tar.gz

Backup-ը ինչ ձևաչափով արխիվացնի և սեղմի։

Default՝

tar.zst

Օրինակ՝

--archive-format tar.zst

կամ՝

--archive-format tar.gz
--keep-uncompressed true|false

Archive անելուց հետո թողնե՞լ uncompressed backup directory-ն։

Default՝

false

Օրինակ՝

--keep-uncompressed false

Եթե false է, backup-ից հետո կմնա միայն .tar.zst կամ .tar.gz archive-ը։

--auto-extract-for-actions true|false

Եթե restore, prepare, info ժամանակ տալիս ես archive, script-ը ավտոմատ բացի՞ archive-ը temporary directory-ի մեջ։

Default՝

true

Օրինակ՝

--auto-extract-for-actions true
--extract-root PATH

Որտեղ extract անել archive-ները ժամանակավոր գործողությունների համար։

Default՝

/var/backups/mariadb/.tmp

Օրինակ՝

--extract-root /var/backups/mariadb/.tmp
--zstd-level N

Zstandard compression level։

Default՝

3

Օրինակ՝

--zstd-level 3

Ավելի մեծ թիվը՝ ավելի ուժեղ compression, բայց ավելի դանդաղ։

--gzip-level N

Gzip compression level։

Default՝

6

Օրինակ՝

--gzip-level 6
5. Cleanup / retention պարամետրեր
--cleanup-after-backup true|false

Backup-ը հաջող ավարտվելուց հետո մաքրի՞ հին backup-ները։

Default՝

false

Օրինակ՝

--cleanup-after-backup true

Կարևոր՝ եթե backup-ը fail է տալիս, cleanup չպետք է կատարվի։

--retention-days N

Քանի օրից հին backup-ները համարվեն ջնջման թեկնածու։

Default՝

7

Օրինակ՝

--retention-days 7

Test-ի համար կարող ես դնել՝

--retention-days 0
--min-full-backups N

Նվազագույն քանի full backup պետք է պահել ամեն դեպքում։

Default՝

3

Օրինակ՝

--min-full-backups 3

Այսինքն եթե full backup-ների քանակը 3 է կամ պակաս, cleanup-ը full backup չի ջնջի՝ նույնիսկ եթե retention-days=0 է։

--cleanup-dry-run true|false

Ջնջելու փոխարեն միայն ցույց տա, թե ինչ կջնջեր։

Default՝

false

Օրինակ՝

--cleanup-dry-run true

Օգտակար է test-ի համար։

6. Restore-ի պարամետրեր
--force-non-empty-directories true|false

Թույլ տալ restore անել ոչ դատարկ datadir-ի վրա։

Default՝

false

Օրինակ՝

--force-non-empty-directories true

Զգույշ օգտագործիր։ Production-ում լավ է նախ datadir-ը մաքրել կամ տեղափոխել։

--stop-service-on-restore true|false

Restore-ի ժամանակ կանգնեցնի՞ MariaDB service-ը։

Default՝

true

Օրինակ՝

--stop-service-on-restore true
--chown-after-restore true|false

Restore-ից հետո ուղղի՞ ownership-ը։

Default՝

true

Օրինակ՝

--chown-after-restore true
--service-name NAME

MariaDB service-ի անունը systemd-ում։

Default՝

mariadb

Օրինակ՝

--service-name mariadb
--mysql-owner USER:GROUP

Restore-ից հետո datadir-ի owner-ը։

Default՝

mysql:mysql

Օրինակ՝

--mysql-owner mysql:mysql
7. SSH / remote backup պարամետրեր

Այս պարամետրերը օգտագործվում են, երբ backup server-ից ուզում ես SSH-ով backup անել DB server-ը։

--ssh-host HOST

SSH host կամ alias։

Օրինակ, եթե կարողանում ես միանալ այսպես՝

ssh test-slave-db-1

ապա script-ում տալիս ես՝

--ssh-host test-slave-db-1

Եթե mode չես տալիս, script-ը default-ով կանի full backup։

--ssh-user USER

SSH user։

Օրինակ՝

--ssh-user admindevops

Եթե .ssh/config-ում արդեն գրված է User, պետք չէ տալ։

--ssh-port PORT

SSH port։

Օրինակ՝

--ssh-port 22

Եթե .ssh/config-ում արդեն գրված է Port, լավ է չտաս։

--ssh-key PATH

SSH private key-ի path։

Օրինակ՝

--ssh-key /home/mariabackup/.ssh/devops/test-slave-db-1

Եթե .ssh/config-ում արդեն գրված է IdentityFile, պետք չէ տալ։

--ssh-config PATH

Կոնկրետ SSH config file օգտագործելու համար։

Օրինակ՝

--ssh-config /home/mariabackup/.ssh/config
--ssh-strict-host-key-checking yes|no|accept-new

SSH host key checking։

Default՝

accept-new

Օրինակ՝

--ssh-strict-host-key-checking accept-new
--ssh-connect-timeout N

SSH connection timeout վայրկյաններով։

Default՝

15

Օրինակ՝

--ssh-connect-timeout 15
--remote-stream-mode true|false

Remote backup անել stream-ով, առանց remote server-ի վրա script ունենալու։

Default՝

true

Օրինակ՝

--remote-stream-mode true

Այս դեպքում DB server-ի վրա պետք է լինի միայն mariadb-backup կամ mariabackup, իսկ script-ը մնում է backup server-ի վրա։

--remote-backup-bin PATH

Remote server-ի վրա mariadb-backup binary-ի path-ը ձեռքով նշելու համար։

Օրինակ՝

--remote-backup-bin /usr/bin/mariadb-backup

Սովորաբար պետք չէ, script-ը փորձում է գտնել ինքնուրույն։

--remote-tmpdir PATH

Remote restore-ի ժամանակ remote server-ում temporary directory։

Default՝

/tmp/mariadb-restore

Օրինակ՝

--remote-tmpdir /tmp/mariadb-restore
--mbstream-bin PATH

Backup server-ում mbstream binary-ի path-ը։

Default՝

mbstream

Օրինակ՝

--mbstream-bin /usr/bin/mbstream
8. Zabbix պարամետրեր
--zbx-enable true|false

Միացնե՞լ Zabbix sender report-ը։

Default՝

false

Օրինակ՝

--zbx-enable true
--zbx-server IP_OR_DNS

Zabbix server-ի IP կամ DNS անուն։

Օրինակ՝

--zbx-server 10.0.1.1
--zbx-host HOST_IN_ZABBIX

Zabbix-ում host-ի ճիշտ անունը։

Օրինակ՝

--zbx-host test-Slabe-db-1

Շատ կարևոր է, որ սա 100% համընկնի Zabbix-ի host name-ի հետ։ Եթե Zabbix-ում գրված է test-Slabe-db-1, ապա հենց այդպես էլ պետք է տալ, նույնիսկ եթե typo կա։

--zbx-sender PATH

zabbix_sender binary-ի path։

Default՝

zabbix_sender

Օրինակ՝

--zbx-sender /usr/bin/zabbix_sender
--zbx-key-prefix PREFIX

Zabbix item key prefix։

Default՝

mariadb.backup

Օրինակ՝

--zbx-key-prefix mariadb.backup

Այդ դեպքում keys կլինեն՝

mariadb.backup.full.status
mariadb.backup.full.message
mariadb.backup.full.last_run
mariadb.backup.full.success_last_run

mariadb.backup.incr.status
mariadb.backup.incr.message
mariadb.backup.incr.last_run
mariadb.backup.incr.success_last_run
--zbx-notify-on-failure true|false

Հին logic-ի համար էր՝ failure-ի ժամանակ Zabbix ուղարկել թե ոչ։

Քո նոր logic-ով լավ է Zabbix-ին միշտ ուղարկել full/incr-ի result-ը, իսկ Telegram-ը կարգավորել Zabbix trigger/action-ներով։

--zbx-notify-full-success true|false

Full success-ի notification logic-ի համար։

Քո setup-ում full success-ը պետք է Zabbix գնա, իսկ Telegram-ը թող որոշի Zabbix Action-ը։

--zbx-notify-incr-success true|false

Incremental success-ի համար Telegram չպետք է գա, բայց Zabbix item-ները պետք է թարմացվեն։

Եթե script-ի should_send_zabbix() ֆունկցիան փոխած է այնպես, որ full/incr միշտ ուղարկի, այս պարամետրը իրականում այլևս կարևոր չէ։

9. Օգտագործման օրինակներ
Local full backup default-ներով
./backup_full_and_incremental.sh

կամ՝

./backup_full_and_incremental.sh full
Local incremental backup
./backup_full_and_incremental.sh incr \
  --user mariabackup \
  --password-file /home/mariabackup/scripts/backup/.maria_backup_password \
  --socket /run/mysqld/mysqld.sock
Remote full backup SSH config-ով

Եթե սա աշխատում է՝

ssh test-slave-db-1

ապա՝

./backup_full_and_incremental.sh \
  --ssh-host test-slave-db-1 \
  --user mariabackup \
  --password-file /home/mariabackup/scripts/backup/.maria_backup_password \
  --socket /run/mysqld/mysqld.sock \
  --zbx-enable true \
  --zbx-server 10.0.1.1 \
  --zbx-host test-Slabe-db-1

Mode չես տվել, այսինքն default-ը full է։

Remote incremental backup
./backup_full_and_incremental.sh incr \
  --ssh-host test-slave-db-1 \
  --user mariabackup \
  --password-file /home/mariabackup/scripts/backup/.maria_backup_password \
  --socket /run/mysqld/mysqld.sock \
  --zbx-enable true \
  --zbx-server 10.0.1.1 \
  --zbx-host test-Slabe-db-1
Full backup cleanup-ով
./backup_full_and_incremental.sh \
  --ssh-host test-slave-db-1 \
  --user mariabackup \
  --password-file /home/mariabackup/scripts/backup/.maria_backup_password \
  --socket /run/mysqld/mysqld.sock \
  --cleanup-after-backup true \
  --retention-days 7 \
  --min-full-backups 3 \
  --zbx-enable true \
  --zbx-server 10.0.1.1 \
  --zbx-host test-Slabe-db-1
Cleanup միայն test mode-ով
./backup_full_and_incremental.sh cleanup \
  --retention-days 0 \
  --min-full-backups 3 \
  --cleanup-dry-run true
Cleanup իրական ջնջումով
./backup_full_and_incremental.sh cleanup \
  --retention-days 7 \
  --min-full-backups 3 \
  --cleanup-dry-run false
Info տեսնել archive-ից
./backup_full_and_incremental.sh info \
  --target-dir /var/backups/mariadb/full_2026-05-15_12-00-01.tar.zst
Prepare full backup
./backup_full_and_incremental.sh prepare-full \
  --target-dir /var/backups/mariadb/full_2026-05-15_12-00-01.tar.zst
Restore local
./backup_full_and_incremental.sh restore \
  --target-dir /var/backups/mariadb/full_2026-05-15_12-00-01.tar.zst
Restore remote server-ի վրա
./backup_full_and_incremental.sh restore \
  --ssh-host test-slave-db-1 \
  --target-dir /var/backups/mariadb/full_2026-05-15_12-00-01.tar.zst \
  --datadir /var/lib/mysql \
  --service-name mariadb \
  --mysql-owner mysql:mysql
10. Քո test cron-ի օրինակ
Full ամեն 2 ժամը մեկ
0 */2 * * * /home/mariabackup/scripts/backup/backup_full_and_incremental.sh --ssh-host test-slave-db-1 --user mariabackup --password-file /home/mariabackup/scripts/backup/.maria_backup_password --socket /run/mysqld/mysqld.sock --zbx-enable true --zbx-server 10.0.1.1 --zbx-host test-Slabe-db-1 --cleanup-after-backup true --retention-days 0 --min-full-backups 3
Incremental ամեն 30 րոպե
*/30 * * * * /home/mariabackup/scripts/backup/backup_full_and_incremental.sh incr --ssh-host test-slave-db-1 --user mariabackup --password-file /home/mariabackup/scripts/backup/.maria_backup_password --socket /run/mysqld/mysqld.sock --zbx-enable true --zbx-server 10.0.1.1 --zbx-host test-Slabe-db-1

Production-ում հետո կդարձնես.

# Full ամեն 3 օրը մեկ
0 2 */3 * * ...

# Incremental ամեն 6 ժամը մեկ
0 */6 * * * ...