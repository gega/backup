# backup
local fast incremental backup for multiple targets

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
