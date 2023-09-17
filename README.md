# backup
local fast incremental backup for multiple targets

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
