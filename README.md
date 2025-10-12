# backup
Fast, local incremental backups that keep working even when your backup disk isn’t connected.

## Overview
Most backup systems assume the storage is always online. This one doesn’t.  
`backup` tracks new and deleted files in the background, and when you eventually plug in one of your target drives, it instantly catches up.  

No cloud. No network. No waiting for a 5-hour rsync run just because one file changed.

- 5–10× faster than rsync-based tools like Dirvish or Back In Time  
- Hardlink-based, human-readable backups  
- Works with multiple rotating drives  
- Can start automatically via cron or udev  
- Designed for multi-TB data sets  

---

## Background
I built this after years of running rsync-based backups that took forever.  
My daily machine has ~3 TB of data, and even a “small” incremental backup could take five hours.  
When backups take that long, you skip them—and skipping backups eventually hurts.  

Cloud options were out for me:
- No trust in remote storage  
- Unreliable bandwidth and access  
- Desire to read backups directly, without any special restore tool  

Hardlink-based backups are ideal for that, but traditional tools still crawl through the whole filesystem every time.  
`backup` splits the process in two:
1. **Delta generation** – runs locally and fast, detecting new and deleted files even when backup drives are absent.  
2. **Backup execution** – when a target disk mounts, only changed files are copied and hardlinks updated.

---

## How it works
There are three operations:
- **generate delta** – collect file changes since the last run (no disk needed)  
- **backup** – apply those deltas to the mounted target  
- **initialize** – create the first full backup on a new target

## how it works

There are three main operations of this backup tool:
- generate delta from a previous checkpoint
- create incremental backup
- initialize new backup target

### delta generation

This step runs regularly by a cronjob (I prefer [fcron](http://fcron.free.fr/) and I choose to execute in every six hours) and collects the newly created and deleted files since the previous run. This operation does not require to have the backup disk mounted and takes just a few seconds or for very large number of files a few minutes. The deltas are generated based on modification time, so in case you have files modified in the future, it needs to be fixed first. The initialize phase will check your sources and notifies you in the logfile if any discrepancies are detected. 

**WARNING:** In case you restore files with fake or archived metadata, those files may not be picked up by this backup tool.

### incremental backup

When one of the backup targets are attached, the backup operation will collect all delta files between now and the last backup on the particular target disk and copies the new files, creates a hardlink structure from the latest backup and removes the meanwhile deleted files. This can be started from an [udev rule](https://unix.stackexchange.com/a/28711) or by a frequent cron job. This operation does not walk through the source directories, just do the job based on the stored intermediate delta files. The delta files stores only filenames to keep them small and the files are copied from the source directories directly.

### initialize target

Before using a new target disk, it needs to be initialized. It is a long operation; creating the initial backup from the source disks. It uses rsync for this and only this operation. It needs to be done once per target/source pairs and in my case it took more than a day to complete.

## benchmark

Simple benchmark on a Thinkpad X1 Carbon gen4, i7-6600U, 16GB ram, Samsung 970 EVO Plus 2TB, backup disk is a TOSHIBA external USB 4TB, 5Gbps:

| action                       | time  | unit    |
| ---------------------------- | ----- | ------- |
| adding the new files         | 663   | seconds |
| creating hardlink structure  | 1050  | seconds |
| deleting files               | 5     | seconds |
| total                        | 29    | minutes |


- total number of files:	5,100,000
- number of new files: 		52,000
- total new data: 		15.7GB
- largest new file: 		1.2GB
- number of files to remove: 	60

## design goals

- hardlink based independent backups
- must be relatively quick even with multi-TB partitions
- backup should automatically start when the backup disk is mounted
- crypto should not be part of the backup tool (LUKS can help)
- multiple target disks should be supported

## assumed workflow

- having multiple external HDDs for storing the backups, at least 20% larger than the amount of data
- there are periodic checks running on the machine to collect new and deleted files, running from cronjobs hourly or daily -- this process takes just minutes
- when one of the target disks are mounted, the backup utility triggered (by frequent periodic cronjob or udev trigger) and processes the delta files between the last backup and now:
  1. new files are copied to the new backup directory
  2. a hardlink copy of the latest backup is created skipping the new files
  3. deleted files are removed from the created directory tree
  4. administrative data are updated (checkpoints, TOC-es, etc)
- the backup process quickly quits when
  1. no target volumes are available
  2. or no deltas were found between the last backup and the current time
- if multiple targets are mounted at the same time, every backup chooses one of them randomly
- if one of the target volume is permanently mounted, backups performed slightly after the delta files were generated if the backup is cron activated

## usage

Usage: backup.sh <command>

       commands:

         cron   - periodic check for new files and generate delta files
                  this command can run without the target volume present
                  should be added as a regular (daily) cronjob
                  runtime measured in minutes
		  
         backup - process the collected delta files to the target directory
                  actual backup, processing the collected delta files
                  multiple targets can be used and the delta files kept
                  until all active targets are up to date
                  this can be added as a more frequent cronjob (every
                  minute) or as an udev rule (don't forget to add the
                  trigger for all configured target volumes)

       config file: ~/.backup.conf

         [where, what, except]

         backup targets, one mounted path per line
         empty line
         backup pathes, one per line,
         empty line,
         exclude regexps, one per line

       sample config

	 /var/run/media/gega/14903f88-47b6-4cf3-8c8c-6d437996e9eb/backup/

	 /home/gega/
	 /usr/

	 *.cache*
	 *~
	 *.Trash-*
	 *lost+found*
	 *__pycache__*
