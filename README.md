# esxi-backups

This repository provides Shell scripts that help manage virtual machine (VM) backups and snapshots on VMware ESXi hosts, especially in environments where conventional backup solutions can't be used (such as free/unlicensed ESXi installations).

## Included Scripts

- **vmESXIBackup:**  
  Allows manual backups of VMs while running. Uses ESXi's built-in commands to create snapshots and copy VM files. Useful for ad-hoc or scheduled backups.

- **vmESXISnapshot:**  
  Automatically manages snapshots for your VMs. Can be set up using cron to regularly create new snapshots and clean up old ones.

## Getting Started

Download the scripts from their respective folders. Both scripts are designed to be run directly on your ESXi host.

For detailed setup, usage, and options, **please see the README files inside each script's folder**:
- [`vmESXIBackup/README.md`](vmESXIBackup/README.md)
- [`vmESXISnapshot/README.md`](vmESXISnapshot/README.md)

> These scripts are intended for users familiar with the ESXi command line and basic system administration tasks.
