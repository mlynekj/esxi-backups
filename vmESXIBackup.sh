#!/bin/sh

logfile="/opt/vm_full_backup.log"
tmpfile=$(mktemp /tmp/vm_esxi_backup.XXXXXX)
retention_number=3
backup_directory="/vmfs/volumes/datastore1/backup-test"

# TODO: switches_
  # TODO: add switch to change between offline and online snapshots
  # TODO: output directory
# TODO: current version is being made only for single disk VMs, test and adjust for multi-disk VMs (in .vmsd -> disk0, disk1, ..., probably also somewhere else)
# TODO: filename sanitazation (spaces in vmdk file names?)
# TODO: add backup rotations


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

createTmpSnapshot() {
  tmp_snapshot_name="BACKUP-TMP-SNP"
  snapshot_description="Temporary snapshot used for backup, created by $0 on $(date +%d_%m_%Y-%H:%M)"
  echo "$(date) - Creating snapshot $tmp_snapshot_name of VM with ID $vmid" | tee -a $logfile
  vim-cmd vmsvc/snapshot.create "$vmid" "$tmp_snapshot_name" "$snapshot_description" | tee -a $logfile
  if [[ $? -eq 0 ]]; then
    echo "$(date) - Snapshot: $tmp_snapshot_name of VM with ID $vmid created" | tee -a $logfile
  else
    echo "$(date) - Failed to create snapshot $tmp_snapshot_name of VM with ID $vmid, exiting" | tee -a $logfile
    exit 1
  fi
}

getVmDirectory() {
  vmPathName=$(vim-cmd vmsvc/get.summary $vmid | grep vmPathName | sed -n 's/.*"\(.*\)".*/\1/p') #example output: [SSD_480_1] debian-backup-test/debian-backup-test.vmx
  if [[ -z $vmPathName ]]; then
    echo "$(date) - Failed to extract directory location of the specified VM, exiting..." | tee -a $logfile
    exit 1
  fi
  vm_absolute_location="/vmfs/volumes/$(echo "$vmPathName" | awk -F'[][]| |/' '{print $2"/"$4}')"
  echo "$(date) - VMs directory found: $vm_absolute_location" | tee -a $logfile
}

getVmdk() {
  snapshot_disks="$(grep -E 'snapshot[0-9]+\.disk[0-9]+\.fileName' "$vm_absolute_location/$vm_name.vmsd")"
  if [[ -z $snapshot_disks ]]; then
    echo "$(date) - No snapshots found for this VM, continuing to backup the base file (The VM must be shutdown!)" | tee -a $logfile
    getVmState()
    if [[ $? -eq 1 ]]; then
      echo "$(date) - VMID $vmid is powered on, cannot continue, exiting..." | tee -a $logfile
      exit 1
    fi
    if ! [[ -f "$vm_absolute_location/$vm_name.vmdk" ]]; then
      echo "$(date) - Failed to find the base file of the VM, exiting..." | tee -a $logfile
      exit 1
    fi
    vmdk_to_clone="$vm_absolute_location/$vm_name.vmdk"
  else
    echo -e "$(date) - Found these snapshots:\n$snapshot_disks" | tee -a $logfile
    latest_snapshot=$(echo -e "$snapshot_disks" | sort | tail -n 1)
    latest_snapshot_disk=$(echo $latest_snapshot | awk -F' = ' '{print $2}' | sed 's/"//g')
    echo "$(date) - Latest snapshot is: $(echo $latest_snapshot | cut -d . -f1)" | tee -a $logfile
    vmdk_to_clone=$latest_snapshot_disk
  fi
  echo "$(date) - VM will be cloned from $vmdk_to_clone" | tee -a $logfile
}

backupVm() {
  echo "$(date) - Backing up the VM (.vmdk, .vmx, .nvram)" | tee -a $logfile
  vmkfstools -i "$vm_absolute_location/$vmdk_to_clone" "$backup_directory/$(date -I)/${vm_name}_$(date -I).vmdk" -d thin | tee -a $logfile
  cp "$vm_absolute_location/$vm_name.vmx" "$backup_directory/$(date -I)/${vm_name}_$(date -I).vmx" | tee -a $logfile
  cp "$vm_absolute_location/$vm_name.nvram" "$backup_directory/$(date -I)/${vm_name}_$(date -I).nvram" | tee -a $logfile
}

getSnapshotIdMapping() {
  vim-cmd vmsvc/snapshot.get $vmid | grep -E "Snapshot Name|Snapshot Id" | awk '
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

deleteTmpSnapshot() {
  while IFS=: read tmp_snapshot_name snapshot_id; do
      if [[ $snapshot_name == $tmp_snapshot_name ]]; then
          echo "$(date) - Deleting snapshot: $tmp_snapshot_name with ID: $snapshot_id" | tee -a $logfile
          vim-cmd vmsvc/snapshot.remove $vmid $snapshot_id
          get_snapshots_deletion_state()
          if [[ $? -ne 1 ]]; then
            echo "$(date) - Failed deleting the temporary snapshot, manual action required..." | tee -a $logfile
            exit 1
          fi
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
vm_name=$1
if [[ -z $input ]]; then
  echo "Usage: $0 <vm_name>"
  exit 1
fi

echo "########## $(date) ##########" | tee -a $logfile

mkdir "$backup_directory/$(date -I)"

#get vmid based on the input
if echo $vm_name | grep -Eq '^[0-9]+$'; then
  echo "Provide a valid VM Name"
  exit 1
else
  vmid=$(vim-cmd vmsvc/getallvms | grep -w "$vm_name" | awk '{print $1}')
  if [[ -z $vmid ]]; then
    echo "$(date) - Failed to retreive vmid based on the provided name of VM: $vm_name" | tee -a $logfile
    exit 1
  fi
  echo "$(date) - VM Name \"$vm_name\" was resolved to VM ID: $vmid" | tee -a $logfile
fi

echo "----- CREATE TEMPORARY SNAPSHOT -----" | tee -a $logfile
createTmpSnapshot()

echo "----- FIND VMs DIRECTORY -----" | tee -a $logfile
getVmDirectory()

echo "----- FIND VMs VMDK FILE -----" | tee -a $logfile
getVmdk()

echo "----- BACKUP THE VM -----" | tee -a $logfile
backupVm()

echo "----- DELETE TEMPORARY SNAPSHOT -----" | tee -a $logfile
deleteTmpSnapshot()