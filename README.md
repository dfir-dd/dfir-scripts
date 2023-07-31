# dfir-scripts

Collection of  scripts for automating various forensics tasks.

## `mount_vmdk.sh`
Mount VMDK files from a given directory

**Usage**
```
Usage: mount_vmdk.sh <dir with vmdk files>
```

## `windows-timeline.sh`
Extract different windows artefacts from mounted source:
- Execution of [Regripper](https://github.com/keydet89/RegRipper3.0) modules, incl. timelines from registry hives
- Timeline from windows event logs (via [evtx2bodyfile](https://github.com/dfir-dd/dfir-toolkit))


**Usage**
```
Usage: windows-timeline.sh [options] <windows_mount_dir>

Options:
    -t <timezone>    convert timestamps from UTC to the given timezone
    -l               list availabel timezones
    -h               show this help information
```