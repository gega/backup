# backup
local fast incremental backup for multiple targets

## background

Backup is a highly personal matter so this description will show my
preferences and how I ended up creating this tool.

At first, I don't want to store my backup in the cloud. For three main
reasons: trust issues, bandwidth and internet access problems.

Second, I would like to have a backup which can be read easily without the
same backup tool I am using for creating it.

I also would like to delete any one of the backups without disturbing the
others.

These two requirement points toward the hardlink based backups.

I started to use dirvish and I used it for years until the main developer
died in a terrible accident and the package became unmaintained. I switched
to backintime which is very similar to dirvish.

Both packages based on rsync which makes them rather slow. In my daily
machine, I have 3TB storage at the moment, and the average backup takes
several hours even if almost nothing changes. The result is skipping backups
and spending even more time on them. The last time I used backintime, it
took five hours to finish, which is almost longer than a night.

Simple benchmark on a Thinkpad X1 Carbon gen4, i7-6600U, 16GB ram, Samsung 970 EVO Plus 2TB
with ~52k new files (15.7GB new data) and 60 files to remove:

adding the new files: 663s
creating hardlink structure of unchanged files: 1050s
deleting files: 5s
total: ~29 minutes
largest new file: 1.2GB

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
  1. a hardlink copy of the latest backup is created
  2. new files are copied into the new structure
  3. deleted files are removed from the new directory tree
  4. administrative data are updated (checkpoints, TOC-es, etc)
- the backup process quickly quits when
  1. no target volumes are available
  2. or no deltas were found between the last backup and now
- if multiple targets are mounted at the same time, every backup run chooses one of them randomly
- if the target volume is permanently mounted, the backups happen right after the delta files were generated

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
