# vmESXISnapshot

For automatic snapshot creation and deletion, a simple script was created in Sh. This script takes as an argument either the name of the VM or its VMID. Then everytime the script is run, it:

- shuts down the VM (if its powered on) (and if asked to)
- checks existing snapshots and their age
- deletes all snapshots older than the specified time threshold (default 48 hours)
- creates a new snapshot
- powers the VM back on (if it was powered on before)

## Usage

1. Download the script, put it on the ESXi host (for example in the /opt directory), add execute permissions (`chmod +x`)

2. Schedule a periodic cron job

    - Backup the original crontab:

        ```bash
        cp /var/spool/cron/crontabs/root /var/spool/cron/crontabs/root.old
        ```

    - Add a new entry to the crontab

        ```bash
        vi /var/spool/cron/crontabs/root
        ```

        ```bash
        #min hour day   mon  dow command
        30   0    *     *    0   python ++mem=85,group=host/vim/vmvisor/monitor-vfat /usr/lib/vmware/misc/bin/monitorVFAT.pyc
        1    1    *     *    *   /sbin/tmpwatch.py
        */5  *    *     *    *   python ++group=host/vim/vmvisor/systemStorage,securitydom=systemStorageMonitorDom /sbin/systemStorageMonitor.pyc
        1    *    *     *    *   /sbin/auto-backup.sh ++group=host/vim/vmvisor/auto-backup.sh
        0    *    *     *    *   /usr/lib/vmware/vmksummary/log-heartbeat.py
        */5  *    *     *    *   /bin/hostd-probe.sh ++group=host/vim/vmvisor/hostd-probe/stats/sh,securitydom=hostdProbeDom
        */5  *    *     *    *   /usr/lib/vmware/misc/bin/vmkmemstats.sh ++group=host/vim/vmvisor/vmkmemstats.sh,mem=groupMax
        00   1    *     *    *   localcli ++securitydom=storageDevicePurgeDom storage core device purge
        0    */6  *     *    *   /bin/pam_tally2 --reset
        */10 *    *     *    *   /bin/crx-cli ++securitydom=crxCliGcDom gc
        0    1    */2   *    *   /bin/sh /opt/vmESXISnapshot.sh -n CTSC-VEEAM -p off -r 24
        ```

        see the last line `0    1    */2   *    *   /bin/sh /opt/vmESXISnapshot.sh -n CTSC-VEEAM -p off -r 24`, which runs the script for the VM named `VEEAM-CTSC` every 2 days at 1AM. The snapshots are created in the OFF state, and the retention period is set to 24 hours.

        > It is advised to test the script first by running it directly from the terminal, before scheduling a cron job.

    - Restart cron

        ```bash
        cat /var/run/crond.pid | tee /dev/tty | xargs kill && /usr/lib/vmware/busybox/bin/busybox crond ; cat /var/run/crond.pid
        ```

        If the restart was succesfull, the two printed PID's should differ.

3. Results

  If the script was executed/scheduled properly, new snapshots should be periodically created, while the old ones should be deleted.

  > The scripts prints information of the progress to the terminal when ran directly. When ran via cron, you can check this information in the logfile.

## Useful links

- [Scheduling Tasks in ESXi Using Cron](https://vswitchzero.com/2021/02/17/scheduling-tasks-in-esxi-using-cron/)
- [Broadcom: Performing common virtual machine related tasks via command line utilities](https://knowledge.broadcom.com/external/article/308360/performing-common-virtual-machinerelated.html)
- [vCenter Server Tasks Management](https://blogs.vmware.com/code/2021/03/10/vcenter-server-tasks-management/)
