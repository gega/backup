#!/bin/bash

CMD=$1
STORAGE=/var/backup
LOCK=/tmp/backup.sh.lock
CONFIG=~/.backup.conf
TAG=backup.sh

fn_terminate_script()
{
  rm -f $LOCK
  exit 0
}

if [ x"$CMD" == x"" ]; then
  echo "Usage: $0 command"
  echo
  echo "       commands:"
  echo "         cron - periodic check for new files"
  echo "         backup - process the collected file list to the target directory"
  echo "       config file: $CONFIG"
  echo "         [where, what, except]"
  echo "         backup targets, one mounted path per line, empty line, backup pathes,"
  echo "         one per line, empty line, exclude regexps, one per line"
  echo "       tips:"
  echo "         - use fcron on desktop"
  echo "         - call '$0 cron' from a daily task (this will take a few minutes per day)"
  echo "         - call '$0 backup' from a one minute cron job or from a udev rule"
  exit 0
fi

if [ ! -d "$STORAGE" ]; then
  echo "$STORAGE not exists, please create as root and give write permission for the user who will execute the script -- or execute $0 as root!"
  exit 1
fi

if [ ! -f $CONFIG ]; then
  echo "$CONFIG file does not exists!"
  echo "Sample config:"
  echo "---cut-here---"
  echo "/run/media/user/0aa95caa-6415-4eb6-a603-3eedad741c8b/backup/"
  echo 
  echo "/home/user/"
  echo "/usr/"
  echo
  echo "*.cache*"
  echo "*~"
  echo "*.Trash-*"
  echo "+lost+found*"
  echo "*__pycache__*"
  echo "---cut-here---"
  exit 1
fi

# read config
TARGETS=()
SOURCES=()
EXCLUDESFIND=()
EXCLUDESRSYNC=()
T=2
while IFS= read -r line; do
  if [ $T -eq 2 ]; then
    if [ x"$line" != x"" ]; then
      TARGETS+=("$(realpath -m "$line")")
    else
      T=1
    fi
  elif [ $T -eq 1 ]; then
    if [ x"$line" != x"" ]; then
      SOURCES+=("$(realpath -m "$line")")
    else
      T=0
    fi
  else
    EXCLUDESFIND+=("-not" "-path" "$line")
    EXCLUDESRSYNC+=("--exclude" "$line")
    EXCLUDESTEXT+=("$line")
  fi
done < $CONFIG
TARGET=""

(
  flock -n -e 200 || exit;

  trap 'fn_terminate_script' EXIT

  if [ x"$CMD" == x"backup" ]; then

    ####################################### backup

    # skip backup temporarily
    if [ -f ~/.nobackup ]; then
      logger -t $TAG "backup temporarily skipped because ~/.nobackup exists"
      exit 0
    fi

    # check if any of the targets are present
    tl=${#TARGETS[@]}
    for e in "${TARGETS[@]}"
    do
      if [ -d "$e" ]; then
        TARGET=$e
        (( $((RANDOM % tl)) < 1 )) && break
      fi
    done

    if [ x"$TARGET" == x"" ]; then
      # no target mounted
      exit 0
    fi

    tsha=$(echo "$TARGET"|sha1sum|cut -d" " -f1)
    stamp=$(date +%s)
    backupname=$(date -d@"$stamp" +%Y%m%d-%H%M%S)

    rm -f "$TARGET"/TOC.tmp
    for src in "${SOURCES[@]}"
    do
      sha=$(echo "$src"|sha1sum|cut -d" " -f1)
      ok=1
      mkdir -p "$TARGET"/$sha/log/
      let TMFILES=TMLINKS=TMDEL=TMEXC=TMSTAT=TMCHK=0
      TOTALBYTES=0
      if [ -L "$TARGET"/$sha/latest ] && [ -f "$TARGET"/$sha/checkpoint ]; then
        # incremental backup from latest
        checkpoint=$(cat "$TARGET"/$sha/checkpoint)
        # check if there're checkpoints after the latest backup
        N=$(find "$STORAGE"/$sha/ -name "[1-9]*_*" -printf "%f\n"|sort -n|awk -F_ '{if($1>'"$checkpoint"') print $0}' | wc -l)
        if [ "$N" -gt 0 ]; then
          renice -n 4 $$
          logger -t $TAG "incremental backup $backupname of $src to $TARGET"
          echo "[ $(date) incremental backup of $src" >>"$TARGET"/$sha/log/$backupname.log
          mkdir -p "$TARGET"/$sha/${backupname}.tmp
          pushd "$STORAGE"/$sha/

          # 1. add missing files
          SECONDS=0
          echo "$(date) Files to add (" >>"$TARGET"/$sha/log/$backupname.log
          srcdir=$(dirname "$src")
          TMP=$(mktemp)
          # method #1 rsync - works but slow
          #find $STORAGE/$sha/ -name "[1-9]*_[ad][de][dl]" -printf "%f\n" | sort -n | awk -F_ '{if($1>'$checkpoint') print $0}' | tee $TMP | \
          #  grep add$ | tr '\n' '\0' | sort -mu --files0-from=- | sed -e "s#^${srcdir}/##g" | \
          #  rsync -v --ignore-missing-args --no-compress -W --files-from=- $srcdir $TARGET/$sha/${backupname}.tmp/ >>$TARGET/$sha/log/$backupname.log 2>&1
          # method #2 tar - works, benchmarking in progress
          find "$STORAGE"/$sha/ -name "[1-9]*_[ade][dex][dlc]" -printf "%f\n" | sort -n | awk -F_ '{if($1>'$checkpoint') print $0}' | tee $TMP | \
            grep add$ | tr '\n' '\0' | sort -mu --files0-from=- | sed -e "s#^${srcdir}/##g" | \
            tar --ignore-failed-read -C "$srcdir" -T - -cf - | tar -C "$TARGET"/$sha/${backupname}.tmp/ -xvf - >>"$TARGET"/$sha/log/$backupname.log 2>&1
          # cat add | sed 's#^/home/##g' | tar --ignore-failed-read -C /home/gega/.. -T - -cf - | tar -tf -
          echo "$(date) Files to add )" >>"$TARGET"/$sha/log/$backupname.log
          TMFILES=$SECONDS

          # 2. create hardlink clone structure
          # different methods benchmarked:
          #   find $src | cpio -pdml $dst/				# 1480s
          #   cp -alT $src/ $dst/					# 1174s
          #   pushd $src; pax -rwlpe . $dst; popd			# 2610s
          #   rsync -av --link-dest="$src" $src/ $dst			# 1370s
          SECONDS=0
          echo "$(date) Hardlink structure (" >>"$TARGET"/$sha/log/$backupname.log
          cp -alTn "$(realpath -m "$TARGET"/$sha/latest/)" "$TARGET"/$sha/${backupname}.tmp/ >>"$TARGET"/$sha/log/$backupname.log 2>&1
          echo "$(date) Hardlink structure )" >>"$TARGET"/$sha/log/$backupname.log
          TMLINKS=$SECONDS

          # 3. remove deleted files
          SECONDS=0
          echo "$(date) Files to delete (" >>"$TARGET"/$sha/log/$backupname.log
          grep "del$" "$TMP"| tr '\n' '\0' | sort -mu --files0-from=- | sed -e "s#^${srcdir}/##g" | \
            tee -a "$TARGET"/$sha/log/$backupname.log | sed -e "s#^#$TARGET/$sha/${backupname}.tmp/#g"|tr '\n' '\0' | xargs -0 rm -f
          echo "$(date) Files to delete )" >>"$TARGET"/$sha/log/$backupname.log
          TMDEL=$SECONDS
          
          # 4. check exclude pattern changes
          SECONDS=0
          if [ -f "$STORAGE"/targets/$tsha/$sha/exc ]; then
            echo "$(date)  (" >>"$TARGET"/$sha/log/$backupname.log
            EXC=()
            # cat new |diff --unchanged-line-format= --old-line-format='%L' --new-line-format= - old
            EXC+=( $(grep "exc$" "$TMP" | tr '\n' '\0' | sort -u --files0-from=- | \
              diff --unchanged-line-format= --old-line-format='%L' --new-line-format= - "$STORAGE"/targets/$tsha/$sha/exc |\
              sed -e 's/^/"/g' -e 's/$/"/g'|tr '\n' ' ') )
            EXCFIND=()
            for e in "${EXC[@]}"
            do
              EXCFIND+=("-path" "$e")
            done
            if [ ${#EXCFIND[@]} -gt 0 ]; then
              echo "$(date)  Exclude pattern update, removing matching files (" >>"$TARGET"/$sha/log/$backupname.log
              find "$TARGET"/$sha/${backupname}.tmp "${EXCFIND[@]}" -exec rm -f {} \; >>"$TARGET"/$sha/log/$backupname.log 2>&1
              echo "$(date)  Exclude pattern update done )" >>"$TARGET"/$sha/log/$backupname.log
            fi
          fi
          TMEXC=$SECONDS

          # 5. statistics
          SECONDS=0
          echo "$(date) largest files copied: " >>"$TARGET"/$sha/log/$backupname.log
          TMP2=$(mktemp)
          grep add$ "$TMP"| tr '\n' '\0' | sort -mu --files0-from=- | tr '\n' '\0' | \
            xargs -0 stat -c "%s %n" 2>/dev/null | tee "$TMP2" | sort -n | tail -5 >>"$TARGET"/$sha/log/$backupname.log
          echo -n "$(date) total data copied: " >>"$TARGET"/$sha/log/$backupname.log
          TOTALBYTES=$(cut -d" " -f1 "$TMP2"|paste -sd+ - |bc)" bytes"
          echo $TOTALBYTES >>"$TARGET"/$sha/log/$backupname.log
          rm -f "$TMP" "$TMP2"
          popd
          TMSTAT=$SECONDS

          ok=0
        else
          # no delta files found between the checkpoints and now, this source is OK
          # this path should be a quick and quiet one, in case the backup volume 
          # remains mounted over a longer period of time
          ok=-1
        fi
      else
        # initial full backup (could be very slow, even days!)
        renice -n 5 $$
        echo "[ $(date) full backup of $src" >>"$TARGET"/$sha/log/$backupname.log
        # check future files in the SRC directory, and notify user!
        SECONDS=0
        echo "$(date) Checking $src ("
        echo "$(date) Future files: "
        TMP=$(mktemp)
        find "$src" -type f -newer "$TMP" >>"$TARGET"/$sha/log/$backupname.log 2>&1
        rm -f "$TMP"
        echo "$(date) Checking source )"
        TMCHK=$SECONDS

        # full copy
        SECONDS=0
        mkdir -p "$TARGET"/$sha/${backupname}.tmp
        logger -t $TAG "initial full backup $backupname of $src to $TARGET"
        rsync -aW "${EXCLUDESRSYNC[@]}" "$src" "$TARGET"/$sha/${backupname}.tmp/ >>"$TARGET"/$sha/log/$backupname.log
        ok=$?
        echo "$tsha $TARGET" >"$TARGET"/TARGET_ID
        TMFILES=$SECONDS
        
        TOTALBYTES=$(df -h --output=used "$src"|tail -1)
      fi
      if [ $ok -ge 0 ]; then
        logger -t $TAG "backup $backupname of $src to $TARGET finished exit code "$ok
        if [ $ok -eq 0 ]; then
          echo "$(date) backup ok!" >>"$TARGET"/$sha/log/$backupname.log
        elif [ $ok -gt 0 ]; then
          echo "$(date) backup failed!" >>"$TARGET"/$sha/log/$backupname.log
        fi
        echo "$sha $src" >>"$TARGET"/TOC.tmp
        
        # speed measurement
        TMALL=$((TMFILES+TMLINKS+TMDEL+TMEXC+TMSTAT+TMCHK))
        echo -e "Speed total: \t$TMALL s\n  adding files:\t$TMFILES s\n  deleting:\t$TMDEL s\n  making links:\t$TMLINKS s\n  exclude:\t$TMEXC s\n  statistics:\t$TMSTAT s\n  source check:\t$TMCHK s" >>"$TARGET"/$sha/log/$backupname.log

        # local log
        echo "$(date) done $backupname of $src to $TARGET. Time: ${TMALL}s Data: ${TOTALBYTES}" >>"$STORAGE"/$sha/log

        # seal
        mkdir -p "$STORAGE"/targets/$tsha/$sha/
        mv "$TARGET"/$sha/${backupname}.tmp "$TARGET"/$sha/${backupname}
        rm -f "$TARGET"/$sha/latest
        ln -fs "$TARGET"/$sha/${backupname} "$TARGET"/$sha/latest
        echo "$stamp" >"$TARGET"/$sha/checkpoint
        cp -a "$TARGET"/$sha/checkpoint "$STORAGE"/targets/$tsha/$sha/
        echo "] $(date)" >>"$TARGET"/$sha/log/$backupname.log
      fi
    done
    if [ -f "$TARGET"/TOC.tmp ]; then
      mv "$TARGET"/TOC.tmp "$TARGET"/TOC
    fi

  elif [ x"$CMD" == x"cron" ]; then

    ####################################### cron

    renice -n 19 $$

    # removing unused targets
    TARGETSHAS=""
    for t in "${TARGETS[@]}"
    do
      sha=$(echo "$t"|sha1sum|cut -d" " -f1)
      TARGETSHAS=$TARGETSHAS" "$sha
      mkdir -p "$STORAGE"/targets/$sha
    done

    pushd "$STORAGE"/targets &>/dev/null
    for t in $(ls -1 "$STORAGE"/targets)
    do
      if [[ ! "$TARGETSHAS" =~ " $t" ]]; then
        logger -t $TAG "unused target '$t'"
        rm -rf "$t"
      fi
    done
    popd &>/dev/null

    for src in "${SOURCES[@]}"
    do
      sha=$(echo "$src"|sha1sum|cut -d" " -f1)
      mkdir -p "$STORAGE"/$sha
      if [ -f "$STORAGE"/$sha/checkpoint ]; then
        touch "$STORAGE"/$sha/checkpoint.tmp
        stamp=$(stat -c %Y "$STORAGE"/$sha/checkpoint.tmp)
        logger -t $TAG "cron checkpoint for '$src'"
        # transition to fixed toc handling
        if [ ! -f "$STORAGE"/$sha/TOC.gz ]; then
          logger -t $TAG "cron rebuilding TOC for '$src'"
          rm -f "$STORAGE"/$sha/toc.gz "$STORAGE"/$sha/toc.tmp.gz
          find "$src" | gzip >"$STORAGE"/$sha/TOC.gz
        fi
        TMP=$(mktemp)
        find "$src" -cnewer "$STORAGE"/$sha/checkpoint "${EXCLUDESFIND[@]}" -printf "%y %h/%f\n" 2>/dev/null >"$TMP"
        grep "^[^d]" "$TMP" | cut -c 3- | sort >"$STORAGE"/$sha/${stamp}_add
        grep "^[d]"  "$TMP" | cut -c 3- | sed -e 's/^/^/g' -e 's#$#/[^/]*$#g' | \
          zgrep -f - "$STORAGE"/$sha/TOC.gz | awk '@load "filefuncs"; {  rc=stat($0,fstat); if(rc!=0) {print $0}}' | sort >"$STORAGE"/$sha/${stamp}_del
        rm -f "$TMP" "$STORAGE"/$sha/TOC.tmp.gz
        ND=$(wc -l --total=only "$STORAGE"/$sha/${stamp}_del|cut -d' ' -f1)
        NA=$(wc -l --total=only "$STORAGE"/$sha/${stamp}_add|cut -d' ' -f1)
        if [ $ND -lt 5000 ] && [ $NA -lt 50000 ]; then # TODO: find out the optimal limits
          if [ $((ND+NA)) -gt 0 ]; then
            sed -e 's/^/^/g' -e 's/$/$/g' "$STORAGE"/$sha/${stamp}_del | zgrep -v -f - "$STORAGE"/$sha/TOC.gz |\
              paste -s -d '\n' "$STORAGE"/$sha/${stamp}_add - | gzip >"$STORAGE"/$sha/TOC.tmp.gz
          fi
        else
          # too many changes, regenerate the toc
          find "$src" | gzip >"$STORAGE"/$sha/TOC.tmp.gz
        fi
        [[ -f "$STORAGE"/$sha/TOC.tmp.gz ]] && mv "$STORAGE"/$sha/TOC.tmp.gz "$STORAGE"/$sha/TOC.gz
        mv "$STORAGE"/$sha/checkpoint.tmp "$STORAGE"/$sha/checkpoint
        printf "%s\n" "${EXCLUDESTEXT[@]}" | sort >"$STORAGE"/$sha/${stamp}_exc
        # remove consumed deltas for this source
        TMP=$(mktemp)
        nt=0
        while IFS= read -r -d '' c
        do
          cp=$(cat "$c")
          find "$STORAGE"/$sha/ -name "[1-9]*_*" -printf "%f\n"|sort -n|awk -F_ '{if($1<'$cp') print $0}' >>"$TMP"
          ((nt+=1))
        done <   <(find "$STORAGE"/targets -type f -name checkpoint -path "*${sha}*" -print0)
        # deltas will appear as many times as many times they were consumed by targets
        sort "$TMP" | uniq -c | awk '{if($1>='$nt') print "'"$STORAGE"/$sha'/" $2}'| tr '\n' '\0' | xargs -0 rm -f
        rm -f "$TMP"
      else
        logger -t $TAG "cron init for '$src'"
        touch "$STORAGE"/$sha/checkpoint.tmp
        find "$src" | gzip >"$STORAGE"/$sha/TOC.gz
        mv "$STORAGE"/$sha/checkpoint.tmp "$STORAGE"/$sha/checkpoint
      fi
    done
  else
    echo "Unknown command"
    exit 1
  fi

) 200>$LOCK
