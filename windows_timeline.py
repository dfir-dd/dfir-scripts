#!/usr/bin/env python3
import argparse
import logging
import os
import re
import shutil
import sys
from argparse import ArgumentError
from collections.abc import Callable
from pathlib import Path
import subprocess
from typing import Optional, Tuple

LOG_FORMAT = '%(levelname)s: %(message)s'


class MissingToolError(Exception):
    def __init__(self, tool_name: str, how_to_install: str):
        self.__tool_name = tool_name
        self.__how_to_install = how_to_install

    def __str__(self):
        return f"missing '{self.__tool_name}', please {self.__how_to_install}"


class Tool:
    def __init__(self, *binary_names: str, how_to_install: str):
        if binary_names:
            for tool_name in binary_names:
                path = shutil.which(tool_name)
                if path is not None:
                    self._path = path
                    return
            raise MissingToolError(tool_name=binary_names[0], how_to_install=how_to_install)
        else:
            raise ArgumentError(message="missing tool name", argument=None)

    def __call__(self, *args: str, output: Optional[Path] = None,
                 filter_function: Optional[Callable[[str], str]] = None, input_str: Optional[str] = None) -> Optional[
        str]:
        args = list(args)
        args.insert(0, self._path)
        completed_process = subprocess.run(args, capture_output=True, encoding="UTF-8", input=input_str)
        if completed_process.returncode != 0:
            logging.error(f"error while running command `{args}`:")
            logging.error(completed_process.stderr)
            sys.exit(1)

        result = completed_process.stdout
        if filter_function is not None:
            result = filter_function(result)

        if output is None:
            return str(result)
        else:
            with open(output, "w") as f:
                f.write(result)
            return None


class Toolset:
    def __init__(self, tools: dict[str, Tool]):
        self.__tools = tools

    def __call__(self, cls):
        for name, tool in self.__tools.items():
            def generate_runner(t: Tool):
                def run_tool(self, *args: str, input_str: Optional[str] = None, output: Optional[str] = None,
                         filter_function: Optional[Callable[[str], str]] = None) -> Optional[str]:
                    return t(*args, input_str=input_str, output=self.output(output), filter_function=filter_function)
                return run_tool
            setattr(cls, name, generate_runner(tool))
        return cls


@Toolset({
    'mactime2': Tool('mactime2', how_to_install='run `cargo install dfir-toolkit'),
    'regdump': Tool('regdump', how_to_install='run `cargo install nt_hive2'),
    'rip': Tool('rip', 'rip.pl', how_to_install='install RegRipper as `rip`'),
    #'mft2bodyfile': Tool('mft2bodyfile', how_to_install='run `cargo install mft2bodyfile'),
    #'mksquashfs': Tool('mksquashfs', how_to_install='run `sudo apt install squashfs-tools')
})
class TimelineToolset:
    def __init__(self, output_dir: Path):
        self._output_dir = output_dir

    def output(self, file_name: Optional[str]) -> Optional[Path]:
        if file_name is None:
            return None
        else:
            return self._output_dir / file_name

def tln2csv(content: str, toolset: TimelineToolset) -> str:
    filtered_lines = [line.split("|") for line in content.splitlines() if re.match(r"^\d+\|\w+\|\|\|", line)]
    content = os.linesep.join(
        ["|".join(("0", line[4], "0", "0", "0", "0", "0", "-1", line[0], "-1", "-1")) for line in filtered_lines])
    content = toolset.mactime2("-b", "-", "-d", input_str=content)
    return content


class WindowsTimeline(object):
    def __new__(cls, windows_mount_dir: Path, output_dir: Path):
        self = super(WindowsTimeline, cls).__new__(cls)
        self._windows_mount_dir = Path(windows_mount_dir)
        self._toolset = TimelineToolset(output_dir)
        self._registry_files = {
            'SYSTEM': self.find_file("Windows/System32/config/SYSTEM"),
            'SOFTWARE': self.find_file("Windows/System32/config/SOFTWARE"),
            'SAM': self.find_file("Windows/System32/config/SAM"),
            'AMCACHE': self.find_file("Windows/AppCompat/Programs/Amcache.hve"),
        }
        self._users_dir = self.find_file("Users")
        return self

    @classmethod
    def list_timezones(cls):
        print(TimelineToolset(Path("/")).mactime2("-t", "list"), end="")

    def create(self):
        self.host_info()
        for reg_file in self._registry_files.values():
            self.registry_timeline(reg_file)

        for user_name, ntuser_dat in self.find_user_profiles():
            self.user_info(user_name, ntuser_dat)

    def host_info(self):
        self._toolset.rip("-r", str(self._registry_files['SYSTEM']), "-p", "compname", output="rip_compname.txt")
        self._toolset.rip("-r", str(self._registry_files['SYSTEM']), "-p", "timezone", output="rip_timezone.txt")
        self._toolset.rip("-r", str(self._registry_files['SYSTEM']), "-p", "shutdown", output="rip_shutdown.txt")
        self._toolset.rip("-r", str(self._registry_files['SYSTEM']), "-p", "ips", output="rip_ips.txt")
        self._toolset.rip("-r", str(self._registry_files['SYSTEM']), "-p", "usbstor", output="rip_usbstor.txt")
        self._toolset.rip("-r", str(self._registry_files['SYSTEM']), "-p", "mountdev2", output="rip_mountdev2.txt")

        self._toolset.rip("-r", str(self._registry_files['SOFTWARE']), "-p", "msis", output="rip_msis.txt")
        self._toolset.rip("-r", str(self._registry_files['SOFTWARE']), "-p", "winver", output="rip_winver.txt")
        self._toolset.rip("-r", str(self._registry_files['SOFTWARE']), "-p", "profilelist",
                          output="rip_profilelist.txt")
        self._toolset.rip("-r", str(self._registry_files['SOFTWARE']), "-p", "lastloggedon",
                          output="rip_lastloggedon.txt")

        self._toolset.rip("-r", str(self._registry_files['SAM']), "-p", "samparse", output="rip_samparse.txt")

    def registry_timeline(self, reg_file: Path):
        filename = reg_file.name
        logging.info(f"creating regripper timeline for {filename} hive")
        self._toolset.rip("-r", str(reg_file), "-aT", output=f"tln_{filename}.csv",
                          filter_function=lambda s: tln2csv(s, self._toolset))
        logging.info(f"creating regdump timeline for {filename} hive")
        self._toolset.regdump("-F", "bodyfile", str(reg_file), output=f"regtln_{filename}.csv",
                              filter_function=lambda s: self._toolset.mactime2("-b", "-", "-d", input_str=s))

    def user_info(self, user_name: str, ntuser_dat: Path):
        logging.info(f"creating regripper timeline for user {user_name}")
        self._toolset.rip("-r", str(ntuser_dat), "-p", "run", output=f"rip_{user_name}_run.txt")
        self._toolset.rip("-r", str(ntuser_dat), "-p", "cmdproc", output=f"rip_{user_name}_cmdproc.txt")
        self._toolset.rip("-r", str(ntuser_dat), "-aT", output=f"tln_user_{user_name}.csv",
                          filter_function=lambda s: tln2csv(s, self._toolset))

    def find_user_profiles(self) -> list[Tuple[str, Path]]:
        results = list()
        for d in [x for x in self._users_dir.iterdir() if x.is_dir()]:
            for nt_user_dat in [x for x in d.iterdir() if x.is_file()]:
                if nt_user_dat.name.lower() == "ntuser.dat":
                    user_name = d.name
                    logging.info(f"found profile directory for user '{user_name}'")
                    results.append((user_name, nt_user_dat))
                    break
        return results

    def find_file(self, expected_path: str, fail_if_missing: bool = True) -> Optional[Path]:
        current_path = self._windows_mount_dir
        for part in Path(expected_path).parts:
            found = False
            for item in current_path.iterdir():
                # at first check for exact match
                if part == item.name or part.lower() == item.name.lower():
                    current_path /= item.name
                    found = True
                    break
            if not found:
                if fail_if_missing:
                    raise FileNotFoundError(expected_path)
                else:
                    logging.warn(f"file not found: '{expected_path}'")
                    return None
        return current_path


def main():
    try:
        parser = argparse.ArgumentParser(
            prog='windows_timeline',
            description='collect timeline information from Windows directories')
        # positional argument
        parser.add_argument('-t', '--timezone', help="convert timestamps from UTC to the given timezone")
        parser.add_argument('-e', '--extract-evtx', help="extract win event logs in squashfs container")
        parser.add_argument('-i', '--ignore-case',
                            help="switch to case-insensitive (necessary in case of dissect acquire output)")
        parser.add_argument('-m', '--parse-mft', help="parse mft (expect $MFT in Windows Root)")
        parser.add_argument('-l', '--list-timezones', help="list available timezones", action="store_true")
        parser.add_argument('-H', '--execute-hayabusa', help="execute hayabusa")
        parser.add_argument('-o', '--output-dir', help="output directory", type=Path)
        parser.add_argument('windows_mount_dir', type=Path, nargs='?')
        parser.add_argument('-v', '--verbose', help="Be verbose", action="store_const", dest="loglevel",
                            const=logging.INFO, )

        cli_args = parser.parse_args()
        logging.basicConfig(format=LOG_FORMAT, level=cli_args.loglevel)

        if cli_args.list_timezones:
            WindowsTimeline.list_timezones()
        elif cli_args.windows_mount_dir is None:
            logging.error("missing Windows mount directory")
        elif not cli_args.windows_mount_dir.exists():
            raise NotADirectoryError(cli_args.windows_mount_dir)
        else:
            output_dir = cli_args.output_dir or "output"
            if not os.path.exists(output_dir):
                os.mkdir(output_dir)
            windows_timeline = WindowsTimeline(cli_args.windows_mount_dir, output_dir=Path(output_dir))
            windows_timeline.create()
    except NotADirectoryError as d:
        logging.error(f"not a directory: {d}")


if __name__ == '__main__':
    main()
