# dfir-scripts

Collection of  scripts for automating various forensics tasks.

## `mount_vmdk.sh`
Mount all VMDK files from a given directory

*Required Packages:* 
- afflib-tools (`sudo apt install afflib-tools`)

**Usage**
```
Usage: mount_vmdk.sh <dir with vmdk files>
```


## `windows-timeline.sh`
Extract different windows artefacts from mounted source:
- Execution of [Regripper](https://github.com/keydet89/RegRipper3.0) modules, incl. timelines from registry hives
- Timeline from windows event logs (via [evtx2bodyfile](https://github.com/dfir-dd/dfir-toolkit))

*Required Tools:* 
- dfir-toolkit (`cargo install dfir-toolkit`)
- [Regripper](https://github.com/keydet89/RegRipper3.0) 

**Usage**
```
Usage: windows-timeline.sh [options] [<windows_mount_dir>] [<output_dir>]

Options:
    -t <timezone>    convert timestamps from UTC to the given timezone
    -l               list availabel timezones
    -h               show this help information
```