# vmESXIBackup

Script for creating manual backups of VMs on VMWare ESXi hosts. Usefull for unlicensed versions of ESXi, as they are unable to be backed up by conventional methods/solutions.

## Usage

Move the script to the ESXi host and make it executable:

```bash
chmod +x vmESXIBackup.sh
```

Launch the script with two mandatory parameters:

- `-n <name of the VM>`
- `-b <directory where the backup should be stored>`

```bash
sh vmESXIBackup.sh -n debian -b /vmfs/volumes/backups/
```

> [!CAUTION]
> Currently supports only VMs, which are stored on a single volume (meaning all files defining the VM (.vmx and all .vmdk/s) must be stored on the same volume)
