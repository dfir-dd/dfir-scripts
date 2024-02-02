# dfir-scripts

Collection of scripts for automating various forensics tasks.

## `mount_vmdk.sh`
Mount all VMDK files from a given directory

*Required Packages:* 
- afflib-tools (`sudo apt install afflib-tools`)

**Usage**
```
Usage: mount_vmdk.sh <dir with vmdk files>
```


## `windows-timelines.sh`
Extract different windows artefacts from mounted source:
- Execution of [Regripper](https://github.com/keydet89/RegRipper3.0) modules, incl. timeline from registry hives
- Execution of [regdump](https://github.com/dfir-dd/dfir-toolkit/blob/main/doc/regdump.md) for additional timeline 
- Timeline from windows event logs (via [evtx2bodyfile](https://github.com/dfir-dd/dfir-toolkit))
- Windows Event Log Processing with [hayabusa](https://github.com/Yamato-Security/hayabusa)
- Timeline from mft (via [mft2bodyfile](https://github.com/janstarke/mft2bodyfile))

*Required Tools:* <br>
Install the following tools to run the script successfully:
- [dfir-toolkit](https://github.com/dfir-dd/dfir-toolkit) (`cargo install dfir-toolkit`)
- [mft2bodyfile](https://github.com/janstarke/mft2bodyfile) (`cargo install mft2bodyfile`)
- [Regripper](https://github.com/keydet89/RegRipper3.0) -> if necessary adjust the variable "RIP" in the windows_timelines.sh script 
- squashfs (`sudo apt install squashfs-tools`)
<!--- 
- [hayabusa](https://github.com/Yamato-Security/hayabusa) -> in folder hayabusa
-->

**Usage**

Run `cd hayabusa` and `.\hayabusa update-rules` before the first execution :exclamation:
```
Usage: windows-timelines.sh [options] [<windows_mount_dir>] [<output_dir>]

Options:
    -t <timezone>    convert timestamps from UTC to the given timezone
    -e               extract event logs in squshfs container
    -i               switch to case-insensitive
    -m               parse mft
    -l               list available timezones
    -h               show this help information
```

Mounting of the SquashFS container can be done with `sudo mount -t squashfs evtx.sqfs <mnt_dir>`
