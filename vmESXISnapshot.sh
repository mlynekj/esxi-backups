#!/bin/sh

# ------------------------------------------------------------
# Script for automating management of VM's snapshots in ESXi
#  - creates snapshot when run (in shutdown state of the VM)
#  - deletes snapshots older than specified period of time
#
# Scheduled via cron
#
# Jakub Mlynek, David Kozel
# ------------------------------------------------------------

logfile="/opt/vm_backup.log"
tmpfile="/tmp/vm_esxi_snapshot.tmp"
retention_period=604800 #7 days
today=$(date +%s)

input=$1
if [[ -z $input ]]; then
  echo "Usage: $0 <vmid|vmname>"
  exit 1
fi

echo "########## $(date) ##########" | tee -a $logfile

#get vmid based on the input (vmid|vmname)
if echo $input | grep -Eq '^[0-9]+$'; then
  vmid=$input
else
  vmid=$(vim-cmd vmsvc/getallvms | grep -w "$input" | awk '{print $1}')
  if [[ -z $vmid ]]; then
    echo "Failed to retreive vmid based on the provided name of VM: $input" | tee -a $logfile
    exit 1
  fi
  echo "$(date) - VM Name \"$input\" was resolved to VM ID: $vmid" | tee -a $logfile
fi

get_vm_state() {
  local state=$(vim-cmd vmsvc/power.getstate "$vmid" | tail -1 | awk '{print $2}')
  if [[ $state == "on" ]]; then
    echo "$(date) - VMID $vmid is powered on" | tee -a $logfile
    return 1
  elif [[ $state == "off" ]]; then
    echo "$(date) - VMID $vmid is powered off" | tee -a $logfile
    return 0
  else
    echo "$(date) - VMID $vmid is in an unknown state: $state" | tee -a $logfile
    return 2
  fi
}

power_off_vm() {
  echo "$(date) - Powering off VMID $vmid" | tee -a $logfile
  local timeout=300
  local elapsed=0
  vim-cmd vmsvc/power.shutdown "$vmid" | tee -a $logfile
  sleep 5
  while true; do
    sleep 1
    elapsed=$((elapsed + 1))
    echo "$(date) - Waiting for VMID $vmid to power off... (elapsed time: $elapsed seconds)" | tee -a $logfile
    if [ $elapsed -ge $timeout ]; then
      echo "$(date) - Timeout reached after $timeout seconds." | tee -a $logfile
      exit 1
    else
      get_vm_state
      if [[ $? -eq 0 ]]; then
        echo "$(date) - VMID $vmid is powered off" | tee -a $logfile
        break
      fi
    fi
  done
}

power_on_vm() {
  echo "$(date) - Powering on VMID $vmid" | tee -a $logfile
  vim-cmd vmsvc/power.on "$vmid" | tee -a $logfile
  sleep 5
  local timeout=300
  local elapsed=0
  while true; do
    sleep 1
    elapsed=$((elapsed + 1))
    echo "$(date) - Waiting for VMID $vmid to power on... (elapsed time: $elapsed seconds)" | tee -a $logfile
    if [ $elapsed -ge $timeout ]; then
      echo "$(date) - Timeout reached after $timeout seconds." | tee -a $logfile
      exit 1
    else
      get_vm_state
      if [[ $? -eq 1 ]]; then
        echo "$(date) - VMID $vmid is powered on" | tee -a $logfile
        break
      fi
    fi
  done
}

create_snapshot() {
  snapshot_name=$(date -I)
  snapshot_description="Automatic snapshot created by $0 on $(date +%d_%m_%Y-%H:%M)"
  echo "$(date) - Creating snapshot $snapshot_name of VM with ID $vmid" | tee -a $logfile
  vim-cmd vmsvc/snapshot.create "$vmid" "$snapshot_name" "$snapshot_description" | tee -a $logfile
  if [[ $? -eq 0 ]]; then
    echo "$(date) - Snapshot: $snapshot_name of VM with ID $vmid created" | tee -a $logfile
  else
    echo "$(date) - Failed to create snapshot $snapshot_name of VM with ID $vmid, exiting" | tee -a $logfile
    exit 1
  fi
}

delete_old_snapshots() {
  #get all snapshots for the VM, pair each snapshot name with its ID, store in a tmp file
  vim-cmd vmsvc/snapshot.get $vmid | grep -E "Snapshot Name|Snapshot Id" | awk '
  {
      match($0, /^-+/)
      level = RLENGTH

      if ($0 ~ /Snapshot Name[[:space:]]*:/) {
          name[level] = $NF
      }

      if ($0 ~ /Snapshot Id[[:space:]]*:/) {
          if (name[level] != "") {
              print name[level] ":" $NF
          }
      }
  }
  ' > "$tmpfile"

  #read the tmp file line by line, parse snapshot name and ID, check age, delete if older than $retention_period
  while IFS=: read snapshot_name snapshot_id; do
      snapshot_age_since_epoch=$(date -d "$snapshot_name" +%s 2>/dev/null)
      if [[ $? -ne 0 ]]; then
          echo "Snapshot's \"$snapshot_name\" name is not a valid date, skipping." | tee -a $logfile
          continue
      fi

      time_delta=$(expr "$today" - "$snapshot_age_since_epoch")
      if [[ $time_delta -gt $retention_period ]]; then
          echo "$(date) - Deleting snapshot: $snapshot_name with ID: $snapshot_id" | tee -a $logfile
          vim-cmd vmsvc/snapshot.remove $vmid $snapshot_id
      else
          echo "$(date) - Retaining snapshot: $snapshot_name with ID: $snapshot_id" | tee -a $logfile
      fi
  done < "$tmpfile"
}

get_snapshots_deletion_state(){
  for task in $(vim-cmd vmsvc/get.tasklist $vmid | grep "vm.Snapshot.remove" | sed -n "s/.*vim.Task:\(.*\)'.*/\1/p"); do
    local timeout=300
    local elapsed=0
    while true; do
      sleep 1
      elapsed=$((elapsed + 1))
      echo "$(date) - Waiting for VMID $vmid to finish deleting snapshots... (elapsed time: $elapsed seconds)" | tee -a $logfile
      if [ $elapsed -ge $timeout ]; then
        echo "$(date) - Timeout reached after $timeout seconds." | tee -a $logfile
        exit 1
      else
        state=$(vim-cmd vimsvc/task_info $task | sed -n 's/.*state = "\([^"]*\)".*/\1/p')
        if [[ $state = "success" ]]; then
          echo "$(date) - Snapshots deleted" | tee -a $logfile
          return 0
        elif [[ "$state" = "queued" ]] || [[ "$state" = "running" ]]; then
          echo "$(date) - Snapshots deletion running, waiting..." | tee -a $logfile
        elif [[ $state = "error" ]]; then
          echo "$(date) - Failed to delete snapshots" | tee -a $logfile
          return 1
        else
          echo "$(date) - Unknown state of snapshot deletion" | tee -a $logfile
          return 1
        fi
      fi
    done
  done
}


# ----- Main -----
get_vm_state
vm_state_before_snapshot=$?
if [[ $vm_state_before_snapshot -eq 1 ]]; then
  echo "----- POWER OFF THE VM -----" | tee -a $logfile
  power_off_vm
fi

echo "----- DELETE OLD SNAPSHOTS -----" | tee -a $logfile
delete_old_snapshots
sleep 5
get_snapshots_deletion_state
if [[ $? -ne 0 ]]; then
  echo "$(date) - Failed deleting one or more snapshots" | tee -a $logfile
  exit 1
fi

echo "----- CREATE A NEW SNAPSHOT -----" | tee -a $logfile
create_snapshot

if [[ $vm_state_before_snapshot -eq 1 ]]; then
  echo "----- POWER ON THE VM -----" | tee -a $logfile
  power_on_vm
fi