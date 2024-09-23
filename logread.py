#!/usr/bin/env python3

import sys
from time import sleep
from datetime import datetime

lines = []

def load_data():
    with open("ex.txt", "r") as file:
        return file.readlines()

def print_all_log_lines(delay=0.0):
    for line in lines:
        print(line, end="", flush=True)
        if delay > 0:
            sleep(delay)

lines = load_data()

if len(sys.argv) == 1:
    print_all_log_lines()
    sys.exit(0)

last_line = lines[-1]
last_msg = last_line[42:]
ts = int(float(last_line[26:40])*10**9)

if "-tf" in sys.argv:
    if "-l" in sys.argv:
        print_all_log_lines()

    while True:
        ts += 500000000
        d = datetime.fromtimestamp(ts/10**9)
        cts = d.timestamp()
        timestr = d.strftime("%a %b %d %H:%M:%S %Y")
        line = f"{timestr} [{cts:.3f}] {last_msg}"
        print(line, end="", flush=True)
        sleep(0.2)
