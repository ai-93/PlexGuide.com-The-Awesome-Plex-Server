############################################################################
# INIT
############################################################################
source rcloneupload.sh
source init.sh
source settings.conf
source /opt/appdata/plexguide/supertransfer/usersettings.conf
#dbug=on

# check to make sure filepaths are there
[[ -e $gdsaDB ]] || touch $gdsaDB
[[ -e $uploadHistory ]] || touch $uploadHistory
[[ -d $jsonPath ]] || mkdir $jsonPath
[[ -d $logDir ]] || mkdir $logDir
[[ ! -e $userSettings ]] && echo -e "[$(date +%m/%d\ %H:%M)] [FAIL]\tNo User settings found in $userSettings. Exiting." && exit 1


init_DB(){
  [[ $gdsaImpersonate == 'your@email.com' ]] \
    && echo -e "[$(date +%m/%d\ %H:%M)] [FAIL]\tNo Email Configured. Please edit $userSettings" \
    && exit 1

  # get list of avail gdsa accounts
  gdsaList=$(rclone listremotes | sed 's/://' | egrep '^GDSA[0-9]+$')
  if [[ -n $gdsaList ]]; then
      numGdsa=$(echo $gdsaList | wc -w)
      maxDailyUpload=$(python3 -c "print(round($numGdsa * 750 / 1000, 3))")
      echo -e "[$(date +%m/%d\ %H:%M)] [INFO]\tInitializing $numGdsa Service Accounts:\t${maxDailyUpload}TB Max Daily Upload"
      echo -e "[$(date +%m/%d\ %H:%M)] [INFO]\tValidating Domain Wide Impersonation:\t$gdsaImpersonate"
  else
      echo -e "[$(date +%m/%d\ %H:%M)] [FAIL]\tNo Valid SA accounts found! Is Rclone Configured With GDSA## remotes?"
      exit 1
  fi

  # reset existing logs & db
  echo '' > /tmp/SA_error.log
  #echo '' > $gdsaDB
  # test for working gdsa's and init gdsaDB
  for gdsa in $gdsaList; do
    s=0
    rclone touch --drive-impersonate $gdsaImpersonate ${gdsa}:/.test &>/tmp/.SA_error.log.tmp && s=1
    if [[ $s == 1 ]]; then
      echo -e "[$(date +%m/%d\ %H:%M)] [ OK ]\tGDSA Impersonation Success:\t ${gdsa}"
      egrep -q ^${gdsa}=. $gdsaDB || echo "${gdsa}=0" >> $gdsaDB
    else
      echo -e "[$(date +%m/%d\ %H:%M)] [WARN]\tGDSA Impersonation Failure:\t ${gdsa}"
      cat /tmp/.SA_error.log.tmp >> /tmp/SA_error.log
      ((gdsaFail++))
    fi
  done

  [[ -n $gdsaFail ]] \
    && echo -e "[$(date +%m/%d\ %H:%M)] [WARN]\t$gdsaFail Failure(s)."

}
[[ $@ =~ --skip ]] || init_DB

############################################################################
# Least Usage Load Balancing of GDSA Accounts
############################################################################

# needs work.
# break the fileLock for stale files
touch $fileLock
staleFiles=$(find $localDir -mindepth 2 -amin +${staleFileTime} -type d)
while read -r line; do
  egrep ^"${line}"$ $fileLock && \
  cat $fileLock | egrep -v ^${line}$ > ${fileLock}.tmp && \
  mv ${fileLock}.tmp ${fileLock} && \
  echo -e "[$(date +%m/%d\ %H:%M)] [WARN]\tBreaking fileLock on $line"
done <<<$staleFiles


echo -e "[$(date +%m/%d\ %H:%M)] [INFO]\tStarting File Monitor."
while true; do
# purge empty folders
find $localDir -mindepth 2 -type d -empty -delete

# iterate through uploadQueueBuffer and update gdsaDB, incrementing usage values
find $localDir -mindepth 2 -mmin +${modTime} -type d \
  -exec du -s {} \; | sort -gr | awk -F'\t' '{print $1":"$2 }' > /tmp/uploadQueueBuffer

  while read -r line; do

    gdsaLeast=$(sort -gr -k2 -t'=' ${gdsaDB} | egrep ^GDSA[0-9]+=. | tail -1 | cut -f1 -d'=')
    if [[ -z $gdsaLeast ]]; then
      echo -e "[$(date +%m/%d\ %H:%M)] [FAIL]\tFailed To get gdsaLeast. Exiting."
      exit 1
    fi

    # skip on files currently being uploaded,
    # or if more than # of rclone uploads exceeds $maxConcurrentUploads
    numCurrentTransfers=$(grep -c "$localDir" $fileLock)
    file=$(awk -F':' '{print $2}' <<< ${line})
    if [[ ! $(cat $fileLock | egrep ^${file}$ ) && $numCurrentTransfers -le $maxConcurrentUploads && -n $line ]]; then
      flag=1
      fileSize=$(awk -F':' '{print $1}' <<< ${line})
      [[ -n $dbug ]] && echo -e "[$(date +%m/%d\ %H:%M)] [DBUG]\tSupertransfer rclone_upload input: "${file}""
      rclone_upload $gdsaLeast "${file}" $remoteDir &
      sleep 0.5
      # add timestamp & log
      # load latest usage value from db
      oldUsage=$(egrep -m1 ^$gdsaLeast=. $gdsaDB | awk -F'=' '{print $2}')
      Usage=$(( oldUsage + fileSize ))
      [[ -n $dbug ]] && echo -e "[$(date +%m/%d\ %H:%M)] [DBUG]\t$gdsaLeast\tUsage: $Usage"
      # update gdsaUsage file with latest usage value
      sed -i '/'^$gdsaLeast'=/ s/=.*/='$Usage'/' $gdsaDB
      source $gdsaDB
    fi
  done </tmp/uploadQueueBuffer
  [[ -n $dbug && flag == 1 ]] && echo -e "[$(date +%m/%d\ %H:%M)] [DBUG]\tNo Files Found in ${localDir}. Sleeping." && flag=0
  sleep 5
done


echo "script end"
