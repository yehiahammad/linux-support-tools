#!/usr/bin/env python3

import sys
import re


def parse_meminfo(lines):
    data = {}
    for line in lines:
        match = re.match(r"^(\S+):\s+(\d+)", line)
        if match:
            key = match.group(1)
            value = int(match.group(2))
            data[key] = value
    return data


def kb_to_gb(kb):
    return kb / (1024 * 1024)


def print_value(label, kb_value, formula):
    print(f"{label:<35}: {kb_to_gb(kb_value):>10.2f} GB")
    print(f"{'':<37}  Calculation: {formula}")


def main():

    if len(sys.argv) > 1:
        with open(sys.argv[1], "r") as f:
            lines = f.readlines()
    else:
        lines = sys.stdin.readlines()

    mem = parse_meminfo(lines)

    # Extract values safely
    mem_total = mem.get("MemTotal", 0)
    mem_free = mem.get("MemFree", 0)
    mem_available = mem.get("MemAvailable", 0)
    buffers = mem.get("Buffers", 0)
    cached = mem.get("Cached", 0)
    sreclaimable = mem.get("SReclaimable", 0)
    shmem = mem.get("Shmem", 0)
    sunreclaim = mem.get("SUnreclaim", 0)
    swap_total = mem.get("SwapTotal", 0)
    swap_free = mem.get("SwapFree", 0)
    hugepages_total = mem.get("HugePages_Total", 0)
    hugepages_size = mem.get("Hugepagesize", 0)

    # Calculations (free-style logic)
    used_free_style = mem_total - mem_available
    buff_cache = buffers + cached + sreclaimable
    swap_used = swap_total - swap_free
    hugepages_allocated_kb = hugepages_total * hugepages_size

    print("\n================= Memory Report =================\n")

    print_value(
        "Total Memory",
        mem_total,
        f"{mem_total} kB / (1024*1024)"
    )

    print_value(
        "Used Memory (free logic)",
        used_free_style,
        f"({mem_total} - {mem_available}) kB / (1024*1024)"
    )

    print_value(
        "Free Memory",
        mem_free,
        f"{mem_free} kB / (1024*1024)"
    )

    print_value(
        "Shared Memory",
        shmem,
        f"{shmem} kB / (1024*1024)"
    )

    print_value(
        "Buffers + Cache",
        buff_cache,
        f"({buffers} + {cached} + {sreclaimable}) kB / (1024*1024)"
    )

    print_value(
        "Available Memory",
        mem_available,
        f"{mem_available} kB / (1024*1024)"
    )

    print("\n--------------- Additional Info ---------------\n")

    print_value(
        "Unreclaimable Slab",
        sunreclaim,
        f"{sunreclaim} kB / (1024*1024)"
    )

    print_value(
        "HugePages Allocated",
        hugepages_allocated_kb,
        f"({hugepages_total} * {hugepages_size}) kB / (1024*1024)"
    )

    print_value(
        "Swap Total",
        swap_total,
        f"{swap_total} kB / (1024*1024)"
    )

    print_value(
        "Swap Used",
        swap_used,
        f"({swap_total} - {swap_free}) kB / (1024*1024)"
    )

    print("\n================================================\n")


if __name__ == "__main__":
    main()
