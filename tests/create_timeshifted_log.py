#!/usr/bin/env python3
"""
Helper script to create log with timestamp skew emulation
"""

import sys
import random
from logread import MockLogRead


def main():
    """
    Entrypoint
    """
    mlr = MockLogRead()
    mlr.parse_args()
    mlr.load_lines()

    num_lines = len(mlr.lines)
    sync_from_line = random.randrange(
        (num_lines // 3) * 2, (num_lines // 3) * 2 + (num_lines // 3) // 2
    )
    shift_back = (180 * 86400) + (random.randrange(1, 30) * 86400)

    # print(f"loaded {num_lines} lines; making {sync_from_line} the 1st one with synced time")

    for nl, line in enumerate(mlr.lines):
        if nl < sync_from_line:
            msg = mlr.get_msg_from_line(line)
            ts = mlr.get_ts_existing(line)
            ts -= shift_back
            tstr = mlr.datetime_str_from_ts(ts)
            print(f"{tstr} [{ts:.03f}] {msg}")
            continue
        print(line)

    return 0


if __name__ == "__main__":
    sys.exit(main())
