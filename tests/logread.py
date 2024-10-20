#!/usr/bin/env python3

import sys
import argparse
from time import sleep
from datetime import datetime, timedelta


class MockLogRead:
    def __init__(self):
        self.lines = []
        self.args = None
        self.ts_first_line = None
        self.ts_start_from = None
        self.ts_apply_delta = None

    def parse_args(self):
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
        try:
            # return int(float(line[26:40]) * 10**9)
            # return float(line[26:40]) * 10**9
            return float(line[26:40])
        except:
            return -float("inf")

    @staticmethod
    def construct_ts_from_line(line: str) -> float:
        try:
            datetime_str = line[0:24]
            dt = datetime.strptime(datetime_str, "%a %b %d %H:%M:%S %Y")
            return dt.timestamp() * 1.0
        except Exception as exc:
            return -float("inf")

    @staticmethod
    def datetime_str_from_ts(ts: float) -> str:
        dt = datetime.fromtimestamp(int(ts))
        return dt.strftime("%a %b %d %H:%M:%S %Y")

    @staticmethod
    def get_msg_from_line(line: str) -> str:
        if line[25] == "[":
            return line[42:]
        return line[25:]

    def load_lines(self):
        with open(self.args.log_file, "r") as file:
            self.lines = file.readlines()

        ts_orig = self.get_ts_existing(self.lines[0])
        ts_constructed = self.construct_ts_from_line(self.lines[0])
        self.ts_first_line = max(ts_orig, ts_constructed)

        self.ts_start_from = datetime.now() - timedelta(hours=1)
        self.ts_apply_delta = self.ts_start_from.timestamp() - self.ts_first_line

    def print_line(self, line: str):
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

        print(new_line, end="", flush=True)

    def print_starting_lines(self, delay=0.0):
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
        last_line = self.lines[-1]
        msg = self.get_msg_from_line(last_line)
        ts_existing = self.get_ts_existing(last_line)
        ts_constructed = self.construct_ts_from_line(last_line)
        ts = max(ts_existing, ts_constructed) + self.ts_apply_delta

        while True:
            ts += 1
            datetime_str = self.datetime_str_from_ts(ts)

            if self.args.extra_timestamp:
                line = f"{datetime_str} [{ts:.03f}] {msg}"
            else:
                line = f"{datetime_str} {msg}"

            print(line, end="", flush=True)
            sleep(delay)

    def run(self):
        try:
            self.parse_args()
            self.load_lines()
            self.print_starting_lines()
            if self.args.follow:
                self.follow()
            return
        except KeyboardInterrupt:
            return 0
        except Exception as exc:
            print(exc)
            return 1


if __name__ == "__main__":
    app = MockLogRead()
    sys.exit(app.run())
