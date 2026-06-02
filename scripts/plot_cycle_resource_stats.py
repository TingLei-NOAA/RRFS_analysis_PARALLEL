#!/usr/bin/env python3
"""Plot GSI and JEDI resource usage by cycle from saved workflow outputs.

Example using the default GSI MPI rank count of 480:

    python3 scripts/plot_cycle_resource_stats.py \
        /u/ting.lei/dr-3kmNA-parallel/dr_save_stats

Example overriding the GSI MPI rank count:

    python3 scripts/plot_cycle_resource_stats.py \
        /u/ting.lei/dr-3kmNA-parallel/dr_save_stats \
        --gsi-mpi-ranks 512

By default, the script writes:

    <stats_dir>/plots/cycle_resource_stats.csv
    <stats_dir>/plots/cycle_resource_stats.png

The GSI total-memory line is an estimate:

    GSI reported maximum RSS x --gsi-mpi-ranks
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple


CYCLE_FORMAT = "%Y%m%d%H"
GSI_PATTERN = re.compile(r"^gsi_out_(\d{10})$")
JEDI_NAMES = ("jedi_out{cycle}", "jedi_out_{cycle}")
FLOAT = r"([0-9]+(?:\.[0-9]+)?)"


@dataclass
class CycleStats:
    cycle: datetime
    gsi_file: Path
    jedi_file: Optional[Path]
    gsi_wall_seconds: Optional[float]
    gsi_max_rss_gb: Optional[float]
    jedi_runtime_seconds: Optional[float]
    jedi_total_memory_gb: Optional[float]
    jedi_min_task_memory_gb: Optional[float]
    jedi_max_task_memory_gb: Optional[float]

    @property
    def cycle_text(self) -> str:
        return self.cycle.strftime(CYCLE_FORMAT)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Scan gsi_out_YYYYMMDDHH files, find matching jedi_outYYYYMMDDHH "
            "files, and plot runtime and memory usage by cycle."
        )
    )
    parser.add_argument(
        "stats_dir",
        nargs="?",
        type=Path,
        default=Path("/u/ting.lei/dr-3kmNA-parallel/dr_save_stats"),
        help="Directory containing gsi_out_* and jedi_out* files.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Output directory. Default: <stats_dir>/plots",
    )
    parser.add_argument(
        "--prefix",
        default="cycle_resource_stats",
        help="Prefix for generated CSV and PNG files.",
    )
    parser.add_argument(
        "--max-gap-markers",
        type=int,
        default=3,
        help="Maximum placeholder positions used to display a missing-cycle gap.",
    )
    parser.add_argument(
        "--gsi-mpi-ranks",
        type=int,
        default=480,
        help=(
            "GSI MPI rank count used to estimate total GSI memory as "
            "reported max RSS per process multiplied by this value. Default: 480"
        ),
    )
    return parser.parse_args()


def extract_last_float(text: str, pattern: str) -> Optional[float]:
    matches = re.findall(pattern, text, flags=re.IGNORECASE)
    return float(matches[-1]) if matches else None


def find_jedi_file(stats_dir: Path, cycle: str) -> Optional[Path]:
    for name in JEDI_NAMES:
        candidate = stats_dir / name.format(cycle=cycle)
        if candidate.is_file():
            return candidate
    return None


def parse_cycle_stats(gsi_file: Path, cycle: datetime, jedi_file: Optional[Path]) -> CycleStats:
    gsi_text = gsi_file.read_text(errors="replace")
    gsi_wall_seconds = extract_last_float(
        gsi_text, rf"The total amount of wall time\s*=\s*{FLOAT}"
    )
    gsi_max_rss_kb = extract_last_float(
        gsi_text, rf"The maximum resident set size \(KB\)\s*=\s*{FLOAT}"
    )

    jedi_runtime_seconds = None
    jedi_total_memory_gb = None
    jedi_min_task_memory_gb = None
    jedi_max_task_memory_gb = None
    if jedi_file is not None:
        jedi_text = jedi_file.read_text(errors="replace")
        jedi_runtime_seconds = extract_last_float(
            jedi_text, rf"OOPS_STATS Run end\s+- Runtime:\s*{FLOAT}\s*sec"
        )
        jedi_total_memory_gb = extract_last_float(
            jedi_text, rf"Memory:\s*total:\s*{FLOAT}\s*GB"
        )
        jedi_min_task_memory_gb = extract_last_float(
            jedi_text, rf"per task:\s*min\s*=\s*{FLOAT}\s*GB"
        )
        jedi_max_task_memory_gb = extract_last_float(
            jedi_text, rf"per task:[\s\S]{{0,160}}?max\s*=\s*{FLOAT}\s*GB"
        )

    return CycleStats(
        cycle=cycle,
        gsi_file=gsi_file,
        jedi_file=jedi_file,
        gsi_wall_seconds=gsi_wall_seconds,
        gsi_max_rss_gb=gsi_max_rss_kb / (1024 * 1024) if gsi_max_rss_kb else None,
        jedi_runtime_seconds=jedi_runtime_seconds,
        jedi_total_memory_gb=jedi_total_memory_gb,
        jedi_min_task_memory_gb=jedi_min_task_memory_gb,
        jedi_max_task_memory_gb=jedi_max_task_memory_gb,
    )


def gather_stats(stats_dir: Path) -> List[CycleStats]:
    rows = []
    for path in stats_dir.iterdir():
        match = GSI_PATTERN.match(path.name)
        if not match or not path.is_file():
            continue
        cycle_text = match.group(1)
        cycle = datetime.strptime(cycle_text, CYCLE_FORMAT).replace(tzinfo=timezone.utc)
        rows.append(parse_cycle_stats(path, cycle, find_jedi_file(stats_dir, cycle_text)))
    return sorted(rows, key=lambda row: row.cycle)


def write_csv(rows: List[CycleStats], output_file: Path, gsi_mpi_ranks: int) -> None:
    fields = (
        "cycle",
        "gsi_file",
        "jedi_file",
        "gsi_wall_seconds",
        "jedi_runtime_seconds",
        "gsi_reported_max_rss_gb",
        "gsi_estimated_total_memory_gb",
        "gsi_mpi_ranks_used_for_estimate",
        "jedi_total_memory_gb",
        "jedi_min_task_memory_gb",
        "jedi_max_task_memory_gb",
    )
    with output_file.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    "cycle": row.cycle_text,
                    "gsi_file": row.gsi_file.name,
                    "jedi_file": row.jedi_file.name if row.jedi_file else "",
                    "gsi_wall_seconds": row.gsi_wall_seconds,
                    "jedi_runtime_seconds": row.jedi_runtime_seconds,
                    "gsi_reported_max_rss_gb": row.gsi_max_rss_gb,
                    "gsi_estimated_total_memory_gb": (
                        row.gsi_max_rss_gb * gsi_mpi_ranks
                        if row.gsi_max_rss_gb is not None
                        else None
                    ),
                    "gsi_mpi_ranks_used_for_estimate": gsi_mpi_ranks,
                    "jedi_total_memory_gb": row.jedi_total_memory_gb,
                    "jedi_min_task_memory_gb": row.jedi_min_task_memory_gb,
                    "jedi_max_task_memory_gb": row.jedi_max_task_memory_gb,
                }
            )


def add_gap_positions(
    previous: datetime,
    current: datetime,
    labels: List[str],
    values: Dict[str, List[Optional[float]]],
    max_gap_markers: int,
) -> None:
    missing_hours = int((current - previous).total_seconds() // 3600) - 1
    if missing_hours <= 0:
        return

    marker_count = min(missing_hours, max_gap_markers)
    for marker in range(marker_count):
        if missing_hours <= max_gap_markers:
            label = (previous + timedelta(hours=marker + 1)).strftime(CYCLE_FORMAT)
        elif marker == marker_count // 2:
            label = f"... {missing_hours} missing cycles ..."
        else:
            label = ""
        labels.append(label)
        for series in values.values():
            series.append(None)


def build_plot_series(
    rows: List[CycleStats], max_gap_markers: int
) -> Tuple[List[str], Dict[str, List[Optional[float]]]]:
    labels: List[str] = []
    values: Dict[str, List[Optional[float]]] = {
        "gsi_runtime": [],
        "jedi_runtime": [],
        "gsi_rss": [],
        "jedi_total_memory": [],
    }
    previous = None
    for row in rows:
        if previous is not None:
            add_gap_positions(previous, row.cycle, labels, values, max_gap_markers)
        labels.append(row.cycle_text)
        values["gsi_runtime"].append(row.gsi_wall_seconds)
        values["jedi_runtime"].append(row.jedi_runtime_seconds)
        values["gsi_rss"].append(row.gsi_max_rss_gb)
        values["jedi_total_memory"].append(row.jedi_total_memory_gb)
        previous = row.cycle
    return labels, values


def plot_stats(
    rows: List[CycleStats], output_file: Path, max_gap_markers: int, gsi_mpi_ranks: int
) -> None:
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError as exc:
        raise SystemExit("ERROR: matplotlib is required to create plots") from exc

    labels, values = build_plot_series(rows, max_gap_markers)
    x = list(range(len(labels)))
    fig, axes = plt.subplots(2, 1, figsize=(max(12, len(labels) * 0.38), 9), sharex=True)

    axes[0].plot(x, values["gsi_runtime"], marker="o", label="GSI wall time")
    axes[0].plot(x, values["jedi_runtime"], marker="o", label="JEDI runtime")
    axes[0].set_ylabel("Seconds")
    axes[0].set_title("GSI and JEDI Runtime by Analysis Cycle")
    axes[0].legend()

    gsi_estimated_total_memory = [
        value * gsi_mpi_ranks if value is not None else None
        for value in values["gsi_rss"]
    ]
    axes[1].plot(
        x,
        gsi_estimated_total_memory,
        marker="o",
        label=f"GSI estimated total memory: reported max RSS x {gsi_mpi_ranks} MPI ranks",
    )
    axes[1].plot(
        x,
        values["jedi_total_memory"],
        marker="o",
        label="JEDI reported aggregate memory across MPI tasks",
    )
    axes[1].set_ylabel("GB")
    axes[1].set_title("Total Memory Usage")
    axes[1].legend()
    axes[1].set_xlabel("Cycle (UTC)")

    for axis in axes:
        axis.grid(True, alpha=0.3)
    axes[1].set_xticks(x)
    axes[1].set_xticklabels(labels, rotation=70, ha="right", fontsize=8)
    fig.tight_layout()
    fig.savefig(output_file, dpi=160)
    plt.close(fig)


def main() -> int:
    args = parse_args()
    if args.max_gap_markers < 1:
        print("ERROR: --max-gap-markers must be at least 1", file=sys.stderr)
        return 2
    if args.gsi_mpi_ranks < 1:
        print("ERROR: --gsi-mpi-ranks must be at least 1", file=sys.stderr)
        return 2
    if not args.stats_dir.is_dir():
        print(f"ERROR: stats directory does not exist: {args.stats_dir}", file=sys.stderr)
        return 2

    rows = gather_stats(args.stats_dir)
    if not rows:
        print(f"ERROR: no gsi_out_YYYYMMDDHH files found in {args.stats_dir}", file=sys.stderr)
        return 1

    output_dir = args.output_dir or args.stats_dir / "plots"
    output_dir.mkdir(parents=True, exist_ok=True)
    csv_file = output_dir / f"{args.prefix}.csv"
    png_file = output_dir / f"{args.prefix}.png"
    write_csv(rows, csv_file, args.gsi_mpi_ranks)
    plot_stats(rows, png_file, args.max_gap_markers, args.gsi_mpi_ranks)

    missing_jedi = [row.cycle_text for row in rows if row.jedi_file is None]
    print(f"Parsed {len(rows)} GSI cycle files from {args.stats_dir}")
    print(f"Wrote CSV:  {csv_file}")
    print(f"Wrote plot: {png_file}")
    print(
        "GSI estimated total memory uses reported max RSS x "
        f"{args.gsi_mpi_ranks} MPI ranks"
    )
    if missing_jedi:
        print(f"Missing JEDI counterparts for {len(missing_jedi)} cycle(s): {', '.join(missing_jedi)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
