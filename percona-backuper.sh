#!/bin/bash
#
# Put me in cron.daily, cron.hourly or cron.d for your own custom schedule

# Running daily? You'll keep 3 daily backups
# Running hourly? You'll keep 3 hourly backups
NUM_BACKUPS_TO_KEEP=20

# Who wants to know when the backup failed, or
# when the binary logs didn't get applied
EMAIL=example@mail.com
LOG_FILE=/data/nfs/backups/backup.log
# Where you keep your backups
ARG=$1
if [[ $ARG == 'week' ]]; then
	BACKUPDIR=/data/nfs/backups/week
else
	BACKUPDIR=/data/nfs/backups/day
fi

# path to innobackupex
XTRABACKUP=/usr/bin/innobackupex

# The mysql user able to access all the databases
USER=backup
PASS=pass
OPTIONS="--galera-info --user=$USER --password=$PASS"
BINLOG_DIR=/data/bin_logs
ROOT_BACKDIR=/data/nfs/backups
NFS_DIR=/data/nfs
NFS_BINLOG_ID=$(ifconfig  | grep 'inet addr:'| grep -v '127.0.0.1' | cut -d: -f2 | awk '{print $1}' | awk -F. '{print $4}')

# Shouldn't need to change these...
APPLY_LOG_OPTIONS="--apply-log"
BACKUP="$XTRABACKUP $OPTIONS $BACKUPDIR"
APPLY_BINARY_LOG="$XTRABACKUP $OPTIONS $APPLY_LOG_OPTIONS"
TIME=$(date '+%Y-%m-%d %T')
NUM_BACKUPS=`ls -1 $BACKUPDIR | grep 'tar.gz' | wc -l`
echo "$(date +%d-%m-%y/%T) START Backup" >> $LOG_FILE
# flush logs and run a backup
echo "$(date +%d-%m-%y/%T) FLUSH LOGS" >> $LOG_FILE
mysql -u${USER} -p${PASS} -e "FLUSH LOGS"
$BACKUP
if [ $? == 0 ]; then
  echo "$(date +%d-%m-%y/%T) Files backuped OK" >> $LOG_FILE
  # we got a backup, now we need to apply the binary logs
  MOST_RECENT=`ls -rt $BACKUPDIR | tail -n1`
  $APPLY_BINARY_LOG $BACKUPDIR/$MOST_RECENT
  if [ $? == 0 ]; then
    echo "$(date +%d-%m-%y/%T) Apply binary log OK" >> $LOG_FILE
    cd $BACKUPDIR
    tar czvf $BACKUPDIR/$(date +%d-%m-%y_%H-%M-%S)-dump.tar.gz $MOST_RECENT
    if [ $? == 0 ]; then   
       echo "$(date +%d-%m-%y/%T) Archiving OK" >> $LOG_FILE
       rm -rf $BACKUPDIR/$MOST_RECENT
       echo "$(date +%d-%m-%y/%T) Delete temporary directory $BACKUPDIR/$MOST_RECENT" >> $LOG_FILE
       # rsync -a --progress $ROOT_BACKDIR $NFS_DIR
       if [ $? == 0  ]; then
          echo "$(date +%d-%m-%y/%T) Copy arch to nfs OK" >> $LOG_FILE
       else
          echo "$(date +%d-%m-%y/%T) Copy arch to nfs ERROR" >> $LOG_FILE
	  exit 1
       fi
       rsync -a --progress ${BINLOG_DIR}/* ${NFS_DIR}/binlog_${NFS_BINLOG_ID}
       if [ $? == 0  ]; then	  
          mysql -u${USER} -p${PASS} -e "PURGE BINARY LOGS BEFORE '${TIME}'"
          echo "$(date +%d-%m-%y/%T) PURGE BINARY LOGS OK" >> $LOG_FILE
       else
          echo "$(date +%d-%m-%y/%T) Copy binary logs ERROR" >> $LOG_FILE
	  exit 1
       fi
       if [[ $NUM_BACKUPS -ge $NUM_BACKUPS_TO_KEEP ]]; then
          PREV=`ls -rt $BACKUPDIR | grep 'tar.gz' | head -n $(expr $(ls -1 -rt $BACKUPDIR | grep "tar.gz" | wc -l) - $NUM_BACKUPS_TO_KEEP - 1)`
       fi
    else
       echo "$(date +%d-%m-%y/%T) Archiving error" >> $LOG_FILE
       exit 1
    fi
    # only remove if $PREV is set
    if [ -n "$PREV" ]; then
      # remove backups you don't want to keep
      echo "$(date +%d-%m-%y/%T) ${PREV} must be removed" >> $LOG_FILE
      for i in $PREV; do rm -f ${BACKUPDIR}/${i} && echo "$(date +%d-%m-%y/%T) Delete old dump ${i}" >> $LOG_FILE; done
    fi
  else
    echo "Couldn't apply the binary logs to the backup $BACKUPDIR/$MOST_RECENT" | mail $EMAIL -s "Mysql binary log didn't get applied to backup"
    echo "$(date +%d-%m-%y/%T) Couldn't apply the binary logs to the backup $BACKUPDIR/$MOST_RECENT" >> $LOG_FILE
    exit 1
  fi

else
   # problem with initial backup :(
   echo "Couldn't do a mysql backup" | mail $EMAIL -s "Mysql backup failed"
   echo "$(date +%d-%m-%y/%T) Couldn't do a mysql backup" >> $LOG_FILE
   exit 1
fi
echo "$(date +%d-%m-%y/%T) SHUTDOWN" >> $LOG_FILE
