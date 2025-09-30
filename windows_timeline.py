#!/usr/bin/env python3
import argparse
import logging
import os
import shutil
import sys
from pathlib import Path
import subprocess
from typing import Optional

LOG_FORMAT = '%(levelname)s: %(message)s'


class MissingToolError(Exception):
    def __init__(self, tool_name: str, how_to_install: str):
        self.__tool_name = tool_name
        self.__how_to_install = how_to_install

    def __str__(self):
        return f"missing '{self.__tool_name}', please {self.__how_to_install}"


class Tool(object):
    def __new__(cls, *tool_names: str, how_to_install: str):
        for tool_name in tool_names:
            path = shutil.which(tool_name)
            if path is not None:
                self = super(Tool, cls).__new__(cls)
                self._path = path
                return self
        raise MissingToolError(tool_name=tool_name, how_to_install=how_to_install)

    def __call__(self, *args: str, output=Optional[Path]) -> str:
        args = list(args)
        args.insert(0, self._path)
        completed_process = subprocess.run(args, capture_output=True, encoding="UTF-8")
        if completed_process.returncode != 0:
            logging.error(f"error while running command `{self._path} {args}`:")
            logging.error(completed_process.stderr)
            sys.exit(1)

        if output is None:
            return str(completed_process.stdout)
        else:
            with open(output, "w") as f:
                f.write(completed_process.stdout)


class Toolset(object):
    _instance = None

    def __new__(cls, output_dir: Path):
        if cls._instance is None:
            cls._instance = super(Toolset, cls).__new__(cls)
            cls._rip = None
            cls._mactime2 = None
            cls._mft2bodyfile = None
            cls._regdump = None
            cls._mksquashfs = None
            cls._output_dir = output_dir
        return cls._instance

    def output(self, file_name: Optional[str]) -> Path:
        if file_name is None:
            return None
        else:
            return self._output_dir / file_name

    def rip(self, *args: str, output=Optional[Path]) -> str:
        if self._rip is None:
            self._rip = Tool('rip', 'rip.pl', how_to_install='install RegRipper as `rip`')
        return self._rip(*args, output=self.output(output))

    def mactime2(self, *args: str) -> str:
        if self._mactime2 is None:
            self._mactime2 = Tool('mactime2', how_to_install='run `cargo install dfir-toolkit')
        return self._mactime2(*args)

    def regdump(self, *args: str) -> str:
        if self._regdump is None:
            self._regdump = Tool('regdump', how_to_install='run `cargo install nt_hive2')
        return self._regdump(*args)

    def mft2bodyfile(self, *args: str) -> str:
        if self._mft2bodyfile is None:
            self._mft2bodyfile = Tool('mft2bodyfile', how_to_install='run `cargo install mft2bodyfile')
        return self._mft2bodyfile(*args)

    def mksquashfs(self, *args: str) -> str:
        if self._mksquashfs is None:
            self._mksquashfs = Tool('mksquashfs', how_to_install='run `sudo apt install squashfs-tools')
        return self._mksquashfs(*args)


class WindowsTimeline(object):
    def __new__(cls, windows_mount_dir: Path, output_dir: Path):
        self = super(WindowsTimeline, cls).__new__(cls)
        self._windows_mount_dir = Path(windows_mount_dir)
        self._toolset = Toolset(output_dir)
        self._files = {
            'SYSTEM': self.find_file("Windows/System32/config/SYSTEM"),
            'SOFTWARE': self.find_file("Windows/System32/config/SOFTWARE"),
            'SAM': self.find_file("Windows/System32/config/SAM"),
            'Users': self.find_file("Users")
        }
        return self

    @classmethod
    def list_timezones(cls):
        print(Toolset(None).mactime2("-t", "list"), end="")

    def create(self):
        self.host_info()

        for user_name, ntuser_dat in self.find_user_profiles():
            self.user_info(user_name, ntuser_dat)

    def host_info(self):
        self._toolset.rip("-r", self._files['SYSTEM'], "-p", "compname", output="compname.txt")
        self._toolset.rip("-r", self._files['SYSTEM'], "-p", "timezone", output="timezone.txt")
        self._toolset.rip("-r", self._files['SYSTEM'], "-p", "shutdown", output="shutdown.txt")
        self._toolset.rip("-r", self._files['SYSTEM'], "-p", "ips", output="ips.txt")
        self._toolset.rip("-r", self._files['SYSTEM'], "-p", "usbstor", output="usbstor.txt")
        self._toolset.rip("-r", self._files['SYSTEM'], "-p", "mountdev2", output="mountdev2.txt")

        self._toolset.rip("-r", self._files['SOFTWARE'], "-p", "msis", output="msis.txt")
        self._toolset.rip("-r", self._files['SOFTWARE'], "-p", "winver", output="winver.txt")
        self._toolset.rip("-r", self._files['SOFTWARE'], "-p", "profilelist", output="profilelist.txt")
        self._toolset.rip("-r", self._files['SOFTWARE'], "-p", "lastloggedon", output="lastloggedon.txt")

        self._toolset.rip("-r", self._files['SAM'], "-p", "samparse", output="samparse.txt")

    def user_info(self, user_name: str, ntuser_dat: Path):
        self._toolset.rip("-r", ntuser_dat, "-p", "run", output=f"{user_name}_run.txt")
        self._toolset.rip("-r", ntuser_dat, "-p", "cmdproc", output=f"{user_name}_cmdproc.txt")

    def find_user_profiles(self) -> list[(str, Path)]:
        results = list()
        for d in [x for x in self._files['Users'].iterdir() if x.is_dir()]:
            for nt_user_dat in [x for x in d.iterdir() if x.is_file()]:
                if nt_user_dat.name.lower() == "ntuser.dat":
                    user_name = d.name
                    logging.info(f"found profile directory for user '{user_name}'")
                    results.append((user_name, nt_user_dat))
                    break
        return results


    def find_file(self, expected_path: str, fail_if_missing: bool = True) -> Optional[Path]:
        path = self._windows_mount_dir / Path(expected_path)
        if path.exists():
            logging.info(f"found '{expected_path}' in '{path}'")
            return path
        elif fail_if_missing:
            raise FileNotFoundError(expected_path)
        else:
            logging.warn(f"file not found: '{expected_path}'")
            return None


if __name__ == '__main__':
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

        args = parser.parse_args()
        logging.basicConfig(format=LOG_FORMAT, level=args.loglevel)

        if args.list_timezones:
            WindowsTimeline.list_timezones()
        elif args.windows_mount_dir is None:
            logging.error("missing Windows mount directory")
        elif not args.windows_mount_dir.exists():
            raise NotADirectoryError(args.windows_mount_dir)
        else:
            output_dir = args.output_dir or "output"
            if not os.path.exists(output_dir):
                os.mkdir(output_dir)
            windows_timeline = WindowsTimeline(args.windows_mount_dir, output_dir=Path(output_dir))
            windows_timeline.create()
    except NotADirectoryError as d:
        logging.error(f"not a directory: {d}")
