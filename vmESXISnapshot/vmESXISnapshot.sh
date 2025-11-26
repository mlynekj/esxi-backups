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

getVmState() {
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

powerOffVm() {
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
      getVmState
      if [[ $? -eq 0 ]]; then
        echo "$(date) - VMID $vmid is powered off" | tee -a $logfile
        break
      fi
    fi
  done
}

powerOnVm() {
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
      getVmState
      if [[ $? -eq 1 ]]; then
        echo "$(date) - VMID $vmid is powered on" | tee -a $logfile
        break
      fi
    fi
  done
}

createSnapshot() {
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

getSnapshotIdMapping() {
  vim-cmd vmsvc/snapshot.get "$vmid" | grep -E "Snapshot Name|Snapshot Id" | awk '
  {
      match($0, /^-+/)
      level = RLENGTH

      if ($0 ~ /Snapshot Name[[:space:]]*:/) {
          name[level] = substr($0, index($0, ":") + 2)
      }

      if ($0 ~ /Snapshot Id[[:space:]]*:/) {
          if (name[level] != "") {
              print name[level] ":" $NF
          }
      }
  }
  ' > "$tmpfile"
}

deleteOldSnapshots() {
  while IFS=: read snapshot_name snapshot_id; do
      snapshot_age_since_epoch=$(date -d "$snapshot_name" +%s 2>/dev/null)
      if [[ $? -ne 0 ]]; then
          echo "Snapshot's \"$snapshot_name\" name is not a valid date, skipping." | tee -a $logfile
          continue
      fi

      time_delta=$(expr "$today" - "$snapshot_age_since_epoch")
      if [[ $time_delta -gt $retention_period_seconds ]]; then
          echo "$(date) - Deleting snapshot: $snapshot_name with ID: $snapshot_id" | tee -a $logfile
          vim-cmd vmsvc/snapshot.remove $vmid $snapshot_id
          sleep 5
          getSnapshotDeletionState
          if [ $? -ne 0 ]; then
            echo "$(date) - Failed deleting the temporary snapshot, manual action required, exiting..." | tee -a $logfile
            exit 1
          fi
      else
          echo "$(date) - Retaining snapshot: $snapshot_name with ID: $snapshot_id" | tee -a $logfile
      fi
  done < "$tmpfile"
}

getSnapshotDeletionState(){
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
while getopts "n:p:r" opt; do
    case "$opt" in
        n) vm_name="$OPTARG" ;;
        p) power_state="$OPTARG" ;;
        r) retention_period_hours="$OPTARG" ;;
        ?) echo "Usage: $0 -n <vm_name> -p <on|off> [-r <retention_period_seconds (hours)>]" >&2
           exit 1 ;;
    esac
done

shift $((OPTIND - 1))

if [ -z $vm_name ]; then
  echo "Error: VM name is required" >&2
  exit 1
fi

if [ -z $power_state ]; then
  echo "Error: Specify whether the snapshots should be created in ON or OFF mode" >&2
  exit 1
fi

if [ $power_state != "on" ] && [ $power_state != "off" ]; then
  echo "Error: Accepted parameters for -p \"on\" or \"off\"" >&2
  exit 1
fi

if [ -z $retention_period_hours ]; then
  echo "Retention period not specified, using default" >&2
  retention_period_seconds=172800 #48 hours
else
  retention_period_seconds=$((retention_period_hours * 3600))
  echo "Retention period set to $retention_period_seconds seconds ($retention_period_hours hours)"
fi

# ----- Parameters and constants -------
logfile="/opt/vmESXISnapshot_$(echo $vm_name).log"
tmpfile=$(mktemp /tmp/vm_esxi_backup.XXXXXX)
today=$(date +%s)
# --------------------------------------

#get vmid based on the input
if echo $vm_name | grep -Eq '^[0-9]+$'; then
  echo "Provide a valid VM Name"
  exit 1
else
  vmid=$(vim-cmd vmsvc/getallvms | grep -w "$vm_name" | awk '{print $1}')
  if [ -z $vmid ]; then
    echo "$(date) - Failed to retreive vmid based on the provided name of VM: $vm_name" | tee -a $logfile
    exit 1
  elif [ "$(echo $vmid | wc -w)" -gt 1 ]; then
    echo "$(date) - Failed to retreive vmid based on the provided name of VM: $vm_name (supplied vm_name resolves to multiple vmid's)" | tee -a $logfile
    exit 1
  fi
  echo "$(date) - VM Name \"$vm_name\" was resolved to VM ID: $vmid" | tee -a $logfile
fi

echo "########## $(date) ##########" | tee -a $logfile

getVmState
vm_state_before_snapshot=$?
if [ $power_state = "off" ]; then
  if [[ $vm_state_before_snapshot -eq 1 ]]; then
    echo "----- POWER OFF THE VM -----" | tee -a $logfile
    powerOffVm
  fi
fi

echo "----- DELETE OLD SNAPSHOTS -----" | tee -a $logfile
getSnapshotIdMapping
deleteOldSnapshots

echo "----- CREATE A NEW SNAPSHOT -----" | tee -a $logfile
createSnapshot

if [ $power_state = "off" ]; then
  if [[ $vm_state_before_snapshot -eq 1 ]]; then
    echo "----- POWER ON THE VM -----" | tee -a $logfile
    powerOnVm
  fi
fi