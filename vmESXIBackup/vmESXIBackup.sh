#!/bin/sh

# TODO: add switch to change between offline and online snapshots
# TODO: add integrity check of cloned vmdks (-q or -x)

# ----- Parameters and constants -----
retention_number=3
tmp_snapshot_name="BACKUP-TMP-SNP"
logfile="/opt/vm_full_backup_$(echo $vm_name).log"
tmpfile=$(mktemp /tmp/vm_esxi_backup.XXXXXX)
# --------------------------------------

getVmDirectory() {
  # TODO: fix for a situation if the VM is stored in multiple volumes (multiple datastores), currently supports only single volume
  vmPathName=$(vim-cmd vmsvc/get.summary $vmid | grep vmPathName | sed -n 's/.*"\(.*\)".*/\1/p') #example output: [SSD_480_1] debian-backup-test/debian-backup-test.vmx
  if [ -z "$vmPathName" ]; then
    echo "$(date) - Failed to extract directory location of the specified VM, exiting..." | tee -a $logfile
    exit 1
  fi
  vm_absolute_location="/vmfs/volumes/$(echo "$vmPathName" | awk -F'[][]| |/' '{print $2"/"$4}')"
  echo "$(date) - VMs directory found: $vm_absolute_location" | tee -a $logfile
}

getVmdk() {
  vmdks_to_clone=""
  disks="$(grep -o 'disk[0-9]\+' "$vm_absolute_location/$vm_name.vmsd" | sort -u)"
  echo -e "$(date) - Found following disks: $disks" | tee -a $logfile
  for disk in $disks; do 
    snapshot_disks="$(grep -E "snapshot[0-9]+\.$disk+\.fileName" "$vm_absolute_location/$vm_name.vmsd")"
    echo -e "$(date) - For disk \"$disk, found these snapshots:\n$snapshot_disks, looking for the latest one..." | tee -a $logfile
    latest_snapshot=$(echo -e "$snapshot_disks" | sort | tail -n 1)
    latest_snapshot_disk=$(echo $latest_snapshot | awk -F' = ' '{print $2}' | sed 's/"//g')
    echo "$(date) - Latest snapshot for disk \"$disk\" is: \"$(echo $latest_snapshot | cut -d . -f1)\", cloning based on its disk: $(echo $latest_snapshot_disk)" | tee -a $logfile
    vmdks_to_clone="$vmdks_to_clone $latest_snapshot_disk"
  done
  echo "$(date) - VM will be cloned from following VMDK/s: $vmdks_to_clone" | tee -a $logfile
}

backupVm() {
  # TODO: error checking if the commands are succesfull, if not return 1. Then perform another check in main, where if $?=1, do something
  echo "$(date) - Backing up the VM (.vmdk, .vmx, .nvram)" | tee -a $logfile
  for vmdk in $vmdks_to_clone; do
    vmkfstools -i "$vm_absolute_location/$vmdk" "$backup_instance_directory/$vmdk" -d thin | tee -a $logfile
  done
  cp "$vm_absolute_location/$vm_name.vmx" "$backup_instance_directory/$backup_name.vmx" | tee -a $logfile
  cp "$vm_absolute_location/$vm_name.nvram" "$backup_instance_directory/$backup_name.nvram" | tee -a $logfile
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

checkIfTmpSnapshotExists() {
  if vim-cmd vmsvc/snapshot.get "$vmid" | grep -q $tmp_snapshot_name; then
    echo "$(date) - Snapshot named: $tmp_snapshot_name already exists, cannot continue, exiting..." | tee -a $logfile
    exit 1
  fi
}

createTmpSnapshot() {
  snapshot_description="Temporary snapshot used for backup, created by $0 on $(date +%d_%m_%Y-%H:%M)"
  echo "$(date) - Creating snapshot $tmp_snapshot_name of VM with ID $vmid" | tee -a $logfile
  vim-cmd vmsvc/snapshot.create "$vmid" "$tmp_snapshot_name" "$snapshot_description" | tee -a $logfile
  getSnapshotCreationState
  if [ $? -ne 0 ]; then
    echo "$(date) - Failed to create snapshot temporary snapshot \"$tmp_snapshot_name\" of VM with ID $vmid, exiting..." | tee -a $logfile
    exit 1
  fi
}

deleteTmpSnapshot() {
  while IFS=: read snapshot_name snapshot_id; do
      if [ $snapshot_name = $tmp_snapshot_name ]; then
          echo "$(date) - Deleting snapshot: $tmp_snapshot_name with ID: $snapshot_id" | tee -a $logfile
          vim-cmd vmsvc/snapshot.remove $vmid $snapshot_id | tee -a $logfile
          getSnapshotDeletionState
          if [ $? -ne 0 ]; then
            echo "$(date) - Failed deleting the temporary snapshot, manual action required, exiting..." | tee -a $logfile
            exit 1
          fi
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
        if [ $state = "success" ]; then
          echo "$(date) - Snapshots deleted" | tee -a $logfile
          return 0
        elif [ "$state" = "queued" ] || [ "$state" = "running" ]; then
          echo "$(date) - Snapshots deletion running, waiting..." | tee -a $logfile
        elif [ $state = "error" ]; then
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

getSnapshotCreationState(){
  for task in $(vim-cmd vmsvc/get.tasklist $vmid | grep "VirtualMachine.createSnapshot" | sed -n "s/.*vim.Task:\(.*\)'.*/\1/p"); do
    local timeout=300
    local elapsed=0
    while true; do
      sleep 1
      elapsed=$((elapsed + 1))
      echo "$(date) - Waiting for VMID $vmid to finish creating snapshots... (elapsed time: $elapsed seconds)" | tee -a $logfile
      if [ $elapsed -ge $timeout ]; then
        echo "$(date) - Timeout reached after $timeout seconds." | tee -a $logfile
        exit 1
      else
        state=$(vim-cmd vimsvc/task_info $task | sed -n 's/.*state = "\([^"]*\)".*/\1/p')
        if [ $state = "success" ]; then
          echo "$(date) - Snapshot created" | tee -a $logfile
          return 0
        elif [ "$state" = "queued" ] || [ "$state" = "running" ]; then
          echo "$(date) - Snapshot creation running, waiting..." | tee -a $logfile
        elif [ $state = "error" ]; then
          echo "$(date) - Failed to create snapshot" | tee -a $logfile
          return 1
        else
          echo "$(date) - Unknown state of snapshot creation" | tee -a $logfile
          return 1
        fi
      fi
    done
  done
}

rotateOldBackups(){
  backup_count=$(find "$backup_directory" -maxdepth 1 -type d -name "${vm_name}_*" | wc -l)
  while [ $backup_count -gt $retention_number ]; do
    backup_to_be_deleted=$(find "$backup_directory" -maxdepth 1 -type d -name "${vm_name}_*" | sort -t_ -k2 | head -n 1)
    echo "$(date) - Deleting backup \"$backup_to_be_deleted\"" | tee -a $logfile
    rm -rf $backup_to_be_deleted
    backup_count=$(find "$backup_directory" -maxdepth 1 -type d -name "${vm_name}_*" | wc -l)
  done
}





# ----- Main -----
while getopts "n:b:r" opt; do
    case "$opt" in
        n) vm_name="$OPTARG" ;;
        b) backup_directory="$OPTARG" ;;
        r) retention_number="$OPTARG" ;;
        ?) echo "Usage: $0 -n <vm_name> -b <backup_dir> [-r <retention_number>]" >&2
           exit 1 ;;
    esac
done

shift $((OPTIND - 1))

if [ -z $vm_name ]; then
  echo "Error: VM name is required" >&2
  exit 1
fi

if [ -z $backup_directory ]; then
  echo "Error: Backup directory is required" >&2
  exit 1
fi

if [ ! -d "$backup_directory" ] || [ ! -w "$backup_directory" ]; then
    echo "Error: Backup directory doesn't exist or isn't writable" >&2
    exit 1
fi

case "$backup_directory" in
    */) backup_directory=${backup_directory%/} ;;
esac

backup_name=""$vm_name"_$(date -I)" #eg: debian_2025-11-21
backup_instance_directory="$backup_directory/$backup_name" #eg: /vmfs/volumes/datastore1/backups/debian_2025-11-21

if [ -z $retention_number ]; then
  echo "Retention number not specified, using default ($retention_number)" >&2
fi

echo "########## $(date) ##########" | tee -a $logfile

mkdir -p "$backup_instance_directory"
if [ $? -eq 1 ]; then
  echo "$(date) - Failed to create a subdirectory in the specified backup directory, exiting..."
  exit 1
fi

#get vmid based on the input
if echo $vm_name | grep -Eq '^[0-9]+$'; then
  echo "Provide a valid VM Name"
  exit 1
else
  vmid=$(vim-cmd vmsvc/getallvms | grep -w "$vm_name" | awk '{print $1}')
  if [ -z $vmid ]; then
    echo "$(date) - Failed to retreive vmid based on the provided name of VM: $vm_name" | tee -a $logfile
    exit 1
  elif [ "$(echo $vmid | wc -w)" -gt 1]; then
    echo "$(date) - Failed to retreive vmid based on the provided name of VM (supplied vm_name resolves to multiple vmid's): $vm_name" | tee -a $logfile
    exit 1
  fi
  echo "$(date) - VM Name \"$vm_name\" was resolved to VM ID: $vmid" | tee -a $logfile
fi

echo "----- CREATE TEMPORARY SNAPSHOT -----" | tee -a $logfile
checkIfTmpSnapshotExists
createTmpSnapshot
getSnapshotIdMapping

echo "----- FIND VMs DIRECTORY -----" | tee -a $logfile
getVmDirectory
required_space=$(du -s "$vm_absolute_location" | awk '{print $1}')
available_space=$(df "$backup_directory" | awk 'NR==2 {print $4}')
echo "$(date) - The backup requires $(du -sh "$vm_absolute_location" | awk '{print $1}') of free space. Available space in the target directory: $(df -h "$backup_directory" | awk 'NR==2 {print $4}')"
if [ "$required_space" -gt "$available_space" ]; then
  echo "$(date) - Insufficient disk space for backup, exiting..." | tee -a $logfile
  deleteTmpSnapshot
  exit 1
fi

echo "----- FIND VMs VMDK FILES -----" | tee -a $logfile
getVmdk

echo "----- BACKUP THE VM -----" | tee -a $logfile
backupVm

echo "----- DELETE TEMPORARY SNAPSHOT -----" | tee -a $logfile
deleteTmpSnapshot

echo "----- ROTATE OLD BACKUPS -----" | tee -a $logfile
rotateOldBackups

echo "----- COMPLETED -----" | tee -a $logfile
echo "$(date) - Backup created succesfully."