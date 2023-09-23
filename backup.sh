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

if [ ! -d $STORAGE ]; then
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
      TARGETS+=("$(realpath -m $line)")
    else
      T=1
    fi
  elif [ $T -eq 1 ]; then
    if [ x"$line" != x"" ]; then
      SOURCES+=("$(realpath -m $line)")
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
    backupname=$(date -d@$stamp +%Y%m%d-%H%M%S)

    rm -f $TARGET/TOC.tmp
    for src in "${SOURCES[@]}"
    do
      sha=$(echo "$src"|sha1sum|cut -d" " -f1)
      ok=1
      mkdir -p $TARGET/$sha/log/
      if [ -L $TARGET/$sha/latest ] && [ -f $TARGET/$sha/checkpoint ]; then
        # incremental backup from latest
        checkpoint=$(cat $TARGET/$sha/checkpoint)
        # check if there're checkpoints after the latest backup
        N=$(find $STORAGE/$sha/ -name "[1-9]*_*" -printf "%f\n"|sort -n|awk -F_ '{if($1>'$checkpoint') print $0}' | wc -l)
        if [ $N -gt 0 ]; then
          renice -n 4 $$
          logger -t $TAG "incremental backup $backupname of $src to $TARGET"
          echo "[ "$(date)" incremental backup of $src" >>$TARGET/$sha/log/$backupname.log
          mkdir -p $TARGET/$sha/${backupname}.tmp
          pushd $STORAGE/$sha/

          # 1. add missing files
          echo $(date)" Files to add (" >>$TARGET/$sha/log/$backupname.log
          srcdir=$(dirname $src)
          TMP=$(mktemp)
          # method #1 rsync - works but slow
          #find $STORAGE/$sha/ -name "[1-9]*_[ad][de][dl]" -printf "%f\n" | sort -n | awk -F_ '{if($1>'$checkpoint') print $0}' | tee $TMP | \
          #  grep add$ | tr '\n' '\0' | sort -mu --files0-from=- | sed -e "s#^${srcdir}/##g" | \
          #  rsync -v --ignore-missing-args --no-compress -W --files-from=- $srcdir $TARGET/$sha/${backupname}.tmp/ >>$TARGET/$sha/log/$backupname.log 2>&1
          # method #2 tar - works, benchmarking in progress
          find $STORAGE/$sha/ -name "[1-9]*_[ad][de][dl]" -printf "%f\n" | sort -n | awk -F_ '{if($1>'$checkpoint') print $0}' | tee $TMP | \
            grep add$ | tr '\n' '\0' | sort -mu --files0-from=- | sed -e "s#^${srcdir}/##g" | \
            tar --ignore-failed-read -C "$srcdir" -T - -cf - | tar -C $TARGET/$sha/${backupname}.tmp/ -xvf - >>$TARGET/$sha/log/$backupname.log 2>&1
          # cat add | sed 's#^/home/##g' | tar --ignore-failed-read -C /home/gega/.. -T - -cf - | tar -tf -
          echo $(date)" Files to add )" >>$TARGET/$sha/log/$backupname.log

          # 2. create hardlink clone structure (slowest part)
          # different methods benchmarked:
          #   find $src | cpio -pdml $dst/				# 1480s
          #   cp -alT $src/ $dst/					# 1174s
          #   pushd $src; pax -rwlpe . $dst; popd			# 2610s
          #   rsync -av --link-dest="$src" $src/ $dst			# 1370s
          echo $(date)" Hardlink structure (" >>$TARGET/$sha/log/$backupname.log
          cp -alTn $(realpath -m $TARGET/$sha/latest/) $TARGET/$sha/${backupname}.tmp/ >>$TARGET/$sha/log/$backupname.log 2>&1
          echo $(date)" Hardlink structure )" >>$TARGET/$sha/log/$backupname.log

          # 3. remove deleted files
          echo $(date)" Files to delete (" >>$TARGET/$sha/log/$backupname.log
          cat $TMP | grep "del$" | tr '\n' '\0' | sort -mu --files0-from=- | sed -e "s#^${srcdir}/##g" | \
            tee -a $TARGET/$sha/log/$backupname.log | sed -e "s#^#$TARGET/$sha/${backupname}.tmp/#g"|tr '\n' '\0' | xargs -0 rm -f
          echo $(date)" Files to delete )" >>$TARGET/$sha/log/$backupname.log
          # 4. statistics
          echo $(date)" largest files copied: " >>$TARGET/$sha/log/$backupname.log
          TMP2=$(mktemp)
          cat $TMP | grep add$ | tr '\n' '\0' | sort -mu --files0-from=- | tr '\n' '\0' | \
            xargs -0 stat -c "%s %n" 2>/dev/null | tee $TMP2 | sort -n | tail -5 >>$TARGET/$sha/log/$backupname.log
          echo -n $(date)" total number of bytes copied: " >>$TARGET/$sha/log/$backupname.log
          cat $TMP2 | cut -d" " -f1|paste -sd+ - |bc >>$TARGET/$sha/log/$backupname.log
          rm -f $TMP
          rm -f $TMP2
          popd
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
        echo "[ "$(date)" full backup of $src" >>$TARGET/$sha/log/$backupname.log
        mkdir -p $TARGET/$sha/${backupname}.tmp
        logger -t $TAG "initial full backup $backupname of $src to $TARGET"
        rsync -aW "${EXCLUDESRSYNC[@]}" $src $TARGET/$sha/${backupname}.tmp/ >>$TARGET/$sha/log/$backupname.log
        echo "$tsha $TARGET" >$TARGET/TARGET_ID
        ok=$?
      fi
      if [ $ok -ge 0 ]; then
        logger -t $TAG "backup $backupname of $src to $TARGET finished exit code "$ok
        if [ $ok -eq 0 ]; then
          echo $(date)" backup ok!" >>$TARGET/$sha/log/$backupname.log
        elif [ $ok -gt 0 ]; then
          echo $(date)"backup failed!" >>$TARGET/$sha/log/$backupname.log
        fi
        echo "$sha $src" >>$TARGET/TOC.tmp
        mv $TARGET/$sha/${backupname}.tmp $TARGET/$sha/${backupname}
        rm -f $TARGET/$sha/latest
        ln -fs $TARGET/$sha/${backupname} $TARGET/$sha/latest
        echo "$stamp" >$TARGET/$sha/checkpoint
        mkdir -p $STORAGE/targets/$tsha/$sha/
        cp -a $TARGET/$sha/checkpoint $STORAGE/targets/$tsha/$sha/
        echo "] "$(date) >>$TARGET/$sha/log/$backupname.log
      fi
    done
    if [ -f $TARGET/TOC.tmp ]; then
      mv $TARGET/TOC.tmp $TARGET/TOC
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
      mkdir -p $STORAGE/targets/$sha
    done

    pushd $STORAGE/targets &>/dev/null
    for t in $(ls -1 $STORAGE/targets)
    do
      if [[ ! "$TARGETSHAS" =~ " $t" ]]; then
        logger -t $TAG "unused target '$t'"
        rm -rf $t
      fi
    done
    popd &>/dev/null

    for src in "${SOURCES[@]}"
    do
      sha=$(echo "$src"|sha1sum|cut -d" " -f1)
      mkdir -p $STORAGE/$sha
      if [ -f $STORAGE/$sha/checkpoint ]; then
        touch $STORAGE/$sha/checkpoint.tmp
        stamp=$(stat -c %Y $STORAGE/$sha/checkpoint.tmp)
        logger -t $TAG "cron checkpoint for '$src'"
        TMP=$(mktemp)
        find $src -cnewer $STORAGE/$sha/checkpoint "${EXCLUDESFIND[@]}" -printf "%y %h/%f\n" 2>/dev/null >$TMP
        cat $TMP | grep "^[^d]" | cut -c 3- | sort >$STORAGE/$sha/${stamp}_add
        cat $TMP | grep "^[d]"  | cut -c 3- | sed -e 's/^/^/g' -e 's#$#/[^/]*$#g' | \
          zgrep -f - $STORAGE/$sha/toc.gz | awk '@load "filefuncs"; {  rc=stat($0,fstat); if(rc!=0) {print $0}}' >$STORAGE/$sha/${stamp}_del
        rm -f $TMP
        D=$(wc -l $STORAGE/$sha/${stamp}_del|cut -d' ' -f1)
        if [ $D -lt 5000 ]; then
          if [ $D -gt 0 ]; then
            sed -e 's/^/^/g' -e 's/$/$/g' $STORAGE/$sha/${stamp}_del | zgrep -v -f - $STORAGE/$sha/toc.gz | gzip >$STORAGE/$sha/toc.tmp.gz
          fi
        else
          # too many deletion, regenerate the toc
          find $src | gzip >$STORAGE/$sha/toc.tmp.gz
        fi
        [[ -f $STORAGE/$sha/toc.tmp.gz ]] && mv $STORAGE/$sha/toc.tmp.gz $STORAGE/$sha/toc.gz
        mv $STORAGE/$sha/checkpoint.tmp $STORAGE/$sha/checkpoint
        printf "%s\n" "${EXCLUDESTEXT[@]}" >$STORAGE/$sha/${stamp}_exc
        # remove consumed deltas for this source
        TMP=$(mktemp)
        nt=0
        for c in $(find $STORAGE/targets -type f -name checkpoint -path "*${sha}*")
        do
          cp=$(cat "$c")
          find $STORAGE/$sha/ -name "[1-9]*_*" -printf "%f\n"|sort -n|awk -F_ '{if($1<'$cp') print $0}' >>$TMP
          ((nt+=1))
        done
        # deltas will appear as many times as many times they were consumed by targets
        cat $TMP | sort | uniq -c | awk '{if($1>='$nt') print "'$STORAGE/$sha'/" $2}'| tr '\n' '\0' | xargs -0 rm -f
        rm -f $TMP
      else
        logger -t $TAG "cron init for '$src'"
        touch $STORAGE/$sha/checkpoint.tmp
        find $src | gzip >$STORAGE/$sha/toc.gz
        mv $STORAGE/$sha/checkpoint.tmp $STORAGE/$sha/checkpoint
      fi
    done
  else
    echo "Unknown command"
    exit 1
  fi

) 200>$LOCK
