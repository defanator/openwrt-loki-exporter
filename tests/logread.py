#!/usr/bin/env python3
"""
Mocking imitator of OpenWRT's logread program
"""

import os
import sys
import argparse
from time import sleep
from datetime import datetime, timedelta


class MockLogRead:
    """
    Base class for mocking logread
    """

    def __init__(self):
        self.lines = []
        self.args = None
        self.ts_first_line = None
        self.ts_start_from = None
        self.ts_apply_delta = None

    def parse_args(self):
        """
        Parse command-line arguments
        """
        parser = argparse.ArgumentParser(
            description="OpenWRT's logread mocking imitator",
            formatter_class=argparse.ArgumentDefaultsHelpFormatter,
        )
        parser.add_argument(
            "--log-file",
            type=str,
            default="tests/default.log",
            help="Local filename with pre-seeded log to get entries from",
        )
        parser.add_argument(
            "-t",
            dest="extra_timestamp",
            action="store_true",
            default=False,
            help="Add an extra timestamp",
        )
        parser.add_argument(
            "-l",
            dest="count",
            type=int,
            default=None,
            help="Print only last <COUNT> messages",
        )
        parser.add_argument(
            "-f",
            dest="follow",
            action="store_true",
            default=False,
            help="Follow log messages",
        )
        self.args = parser.parse_args()

    @staticmethod
    def get_ts_existing(line: str) -> float:
        """
        Get existing higher precision timestamp from log line
        """
        try:
            # return int(float(line[26:40]) * 10**9)
            # return float(line[26:40]) * 10**9
            return float(line[26:40])
        except ValueError:
            return -float("inf")

    @staticmethod
    def construct_ts_from_line(line: str) -> float:
        """
        Construct timestamp from log line datetime string
        """
        try:
            datetime_str = line[0:24]
            dt = datetime.strptime(datetime_str, "%a %b %d %H:%M:%S %Y")
            return dt.timestamp() * 1.0
        except ValueError:
            return -float("inf")

    @staticmethod
    def datetime_str_from_ts(ts: float) -> str:
        """
        Construct datetime string from timestamp
        """
        dt = datetime.fromtimestamp(int(ts))
        return dt.strftime("%a %b %d %H:%M:%S %Y")

    @staticmethod
    def get_msg_from_line(line: str) -> str:
        """
        Get payload part of log line (message itself)
        """
        if line[25] == "[":
            return line[42:]
        return line[25:]

    def load_lines(self):
        """
        Load lines from pre-seeded log file
        """
        with open(self.args.log_file, "r", encoding="utf-8") as file:
            self.lines = [line.rstrip() for line in file.readlines()]

        ts_orig = self.get_ts_existing(self.lines[0])
        ts_constructed = self.construct_ts_from_line(self.lines[0])
        self.ts_first_line = max(ts_orig, ts_constructed)

        self.state_file = self.args.log_file + ".state"

        if os.path.isfile(self.state_file):
            with open(self.state_file, "r", encoding="utf-8") as file:
                self.ts_start_from = datetime.fromtimestamp(float(file.readline()))
        else:
            self.ts_start_from = datetime.now() - timedelta(hours=1)
            with open(self.state_file, "w", encoding="utf-8") as file:
                file.write(f"{self.ts_start_from.timestamp()}\n")

        self.ts_apply_delta = self.ts_start_from.timestamp() - self.ts_first_line

    def print_line(self, line: str):
        """
        Print single log line
        """
        ts_existing = self.get_ts_existing(line)
        ts_constructed = self.construct_ts_from_line(line)

        if ts_existing < 0 and ts_constructed < 0:
            raise ValueError(f'invalid log line: "{line}"')

        msg = self.get_msg_from_line(line)

        ts_preferred = max(ts_existing, ts_constructed) + self.ts_apply_delta
        datetime_str = self.datetime_str_from_ts(ts_preferred)

        if self.args.extra_timestamp:
            new_line = f"{datetime_str} [{ts_preferred:.03f}] {msg}"
        else:
            new_line = f"{datetime_str} {msg}"

        print(new_line, flush=True)

    def print_starting_lines(self, delay=0.0):
        """
        Print initial portion of log lines (depending on "-l" and "-f" CLA)
        """
        if self.args.follow and self.args.count is None:
            return

        starting_line = (
            0 if self.args.count is None else len(self.lines) - self.args.count
        )
        starting_line = max(0, starting_line)

        for line in self.lines[starting_line:]:
            self.print_line(line)
            if delay > 0:
                sleep(delay)

    def follow(self, delay=1.0):
        """
        Imitate tailing mode of original logread
        """
        last_line = self.lines[-1]
        msg = self.get_msg_from_line(last_line)
        ts_existing = self.get_ts_existing(last_line)
        ts_constructed = self.construct_ts_from_line(last_line)
        ts = max(ts_existing, ts_constructed) + self.ts_apply_delta

        max_cycles = int(os.environ.get("MAX_FOLLOW_CYCLES", 0))
        n = 1

        while True:
            ts += 1
            datetime_str = self.datetime_str_from_ts(ts)

            if self.args.extra_timestamp:
                line = f"{datetime_str} [{ts:.03f}] {msg} (MOCK)"
            else:
                line = f"{datetime_str} {msg} (MOCK)"

            print(line, flush=True)

            if max_cycles != 0 and n == max_cycles:
                break

            sleep(delay)
            n += 1

    def run(self):
        """
        Entrypoint
        """
        try:
            self.parse_args()
            self.load_lines()
            self.print_starting_lines()
            if self.args.follow:
                self.follow()
            return 0
        except KeyboardInterrupt:
            return 0


if __name__ == "__main__":
    app = MockLogRead()
    sys.exit(app.run())
