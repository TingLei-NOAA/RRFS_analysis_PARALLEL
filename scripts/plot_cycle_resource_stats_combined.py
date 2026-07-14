#!/usr/bin/env python3
"""Plot GSI and JEDI runtime and total memory in one figure.

Example using the default GSI MPI rank count of 480:

    python3 scripts/plot_cycle_resource_stats_combined.py \
        /u/ting.lei/dr-3kmNA-parallel/dr_save_stats

Example overriding the GSI MPI rank count:

    python3 scripts/plot_cycle_resource_stats_combined.py \
        /u/ting.lei/dr-3kmNA-parallel/dr_save_stats \
        --gsi-mpi-ranks 512

Example plotting only the most recent 7 days of cycles:

    python3 scripts/plot_cycle_resource_stats_combined.py \
        /u/ting.lei/dr-3kmNA-parallel/dr_save_stats \
        --last-days 7

By default, the script writes:

    <stats_dir>/plots/cycle_resource_stats_combined.csv
    <stats_dir>/plots/cycle_resource_stats_combined.png

Axis design: every completed cycle takes one equal step on the x-axis
(an ordinal "irregular" time axis), so long outages do not stretch the
figure or hide the overall behavior. Missing periods are still shown
honestly: short gaps appear as thin dashed vertical lines, and outages
of a day or more appear as shaded bands labeled with the missing
duration. Only a handful of x tick labels are drawn no matter how many
cycles are plotted.

Line conventions:

    JEDI: solid lines
    GSI:  dotted lines
    Runtime: blue lines, left vertical axis
    Memory:  orange lines, right vertical axis

The GSI total-memory line is an estimate:

    GSI reported maximum RSS x --gsi-mpi-ranks
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

from plot_cycle_resource_stats import CYCLE_FORMAT, gather_stats, write_csv


def parse_cycle_arg(text: str) -> datetime:
    try:
        return datetime.strptime(text, CYCLE_FORMAT).replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"expected cycle in YYYYMMDDHH format, got {text!r}"
        ) from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Plot GSI and JEDI runtime and total memory in one figure using "
            "separate left and right vertical axes."
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
        default="cycle_resource_stats_combined",
        help="Prefix for generated CSV and PNG files.",
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
    parser.add_argument(
        "--start",
        type=parse_cycle_arg,
        help="Only plot cycles at or after this cycle (YYYYMMDDHH).",
    )
    parser.add_argument(
        "--end",
        type=parse_cycle_arg,
        help="Only plot cycles at or before this cycle (YYYYMMDDHH).",
    )
    parser.add_argument(
        "--last-days",
        type=float,
        help="Only plot cycles within this many days of the newest cycle.",
    )
    return parser.parse_args()


def filter_rows(
    rows,
    start: Optional[datetime],
    end: Optional[datetime],
    last_days: Optional[float],
):
    if last_days is not None and rows:
        cutoff = rows[-1].cycle - timedelta(days=last_days)
        rows = [row for row in rows if row.cycle >= cutoff]
    if start is not None:
        rows = [row for row in rows if row.cycle >= start]
    if end is not None:
        rows = [row for row in rows if row.cycle <= end]
    return rows


def infer_cycle_interval(rows) -> timedelta:
    """Most common spacing between consecutive cycles (the cadence)."""
    diffs = [
        rows[i].cycle - rows[i - 1].cycle
        for i in range(1, len(rows))
        if rows[i].cycle > rows[i - 1].cycle
    ]
    if not diffs:
        return timedelta(hours=1)
    return Counter(diffs).most_common(1)[0][0]


def find_gaps(rows, interval: timedelta) -> List[Tuple[int, timedelta]]:
    """Return (index, missing duration) for each break in the cycling.

    ``index`` is the position of the first cycle after the gap; the gap
    sits between samples ``index - 1`` and ``index`` on the ordinal axis.
    """
    gaps = []
    for i in range(1, len(rows)):
        diff = rows[i].cycle - rows[i - 1].cycle
        if diff > 1.5 * interval:
            gaps.append((i, diff - interval))
    return gaps


def format_duration(delta: timedelta) -> str:
    hours = delta.total_seconds() / 3600
    if hours < 48:
        return f"{hours:.0f} h"
    return f"{hours / 24:.1f} d"


def broken_series(
    values: Sequence[Optional[float]], gap_indices: Sequence[int]
) -> Tuple[List[float], List[Optional[float]]]:
    """Ordinal x/y arrays with a None inserted at each gap to break the line."""
    gap_set = set(gap_indices)
    xs: List[float] = []
    ys: List[Optional[float]] = []
    for i, value in enumerate(values):
        if i in gap_set:
            xs.append(i - 0.5)
            ys.append(None)
        xs.append(float(i))
        ys.append(value)
    return xs, ys


def marker_size(sample_count: int) -> float:
    """Shrink markers as the cycle count grows so dense plots stay readable."""
    if sample_count <= 60:
        return 6.0
    if sample_count <= 200:
        return 3.5
    return 2.0


def tick_positions(sample_count: int, max_ticks: int = 12) -> List[int]:
    step = max(1, (sample_count - 1) // (max_ticks - 1)) if sample_count > 1 else 1
    positions = list(range(0, sample_count, step))
    if positions[-1] != sample_count - 1:
        positions.append(sample_count - 1)
    return positions


def plot_combined(rows, output_file: Path, gsi_mpi_ranks: int) -> None:
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError as exc:
        raise SystemExit("ERROR: matplotlib is required to create plots") from exc

    n = len(rows)
    interval = infer_cycle_interval(rows)
    gaps = find_gaps(rows, interval)
    gap_indices = [index for index, _ in gaps]
    total_missing = sum((missing for _, missing in gaps), timedelta(0))
    size = marker_size(n)
    title_size = 22
    label_size = 20
    tick_size = 14
    legend_size = 16

    series = {
        "jedi_runtime": [row.jedi_runtime_seconds for row in rows],
        "gsi_runtime": [row.gsi_wall_seconds for row in rows],
        "jedi_memory": [row.jedi_total_memory_gb for row in rows],
        "gsi_memory": [
            row.gsi_max_rss_gb * gsi_mpi_ranks if row.gsi_max_rss_gb is not None else None
            for row in rows
        ],
    }

    fig, runtime_axis = plt.subplots(figsize=(16, 7.5))
    memory_axis = runtime_axis.twinx()

    def draw(axis, key, color, linestyle, marker, label):
        xs, ys = broken_series(series[key], gap_indices)
        return axis.plot(
            xs,
            ys,
            color=color,
            linestyle=linestyle,
            linewidth=1.2,
            marker=marker,
            markersize=size,
            label=label,
        )[0]

    jedi_runtime_line = draw(runtime_axis, "jedi_runtime", "tab:blue", "-", "o", "JEDI runtime")
    gsi_runtime_line = draw(runtime_axis, "gsi_runtime", "tab:blue", ":", "o", "GSI wall time")
    jedi_memory_line = draw(
        memory_axis, "jedi_memory", "tab:orange", "-", "s", "JEDI reported aggregate memory"
    )
    gsi_memory_line = draw(
        memory_axis,
        "gsi_memory",
        "tab:orange",
        ":",
        "s",
        f"GSI estimated total memory: max RSS x {gsi_mpi_ranks} ranks",
    )

    # Mark missing periods: thin dashed line for short gaps, shaded band
    # with a duration label for outages of a day or more.
    for index, missing in gaps:
        boundary = index - 0.5
        if missing >= timedelta(hours=24):
            runtime_axis.axvspan(index - 1, index, color="gray", alpha=0.15, zorder=0)
            runtime_axis.text(
                boundary,
                0.99,
                f"missing {format_duration(missing)}",
                transform=runtime_axis.get_xaxis_transform(),
                rotation=90,
                va="top",
                ha="center",
                fontsize=11,
                color="dimgray",
            )
        else:
            runtime_axis.axvline(
                boundary, color="gray", linestyle="--", linewidth=0.8, alpha=0.6, zorder=0
            )

    fig.suptitle(
        "GSI and JEDI Runtime and Total Memory by Analysis Cycle",
        fontsize=title_size,
    )
    coverage = (
        f"{n} cycles, {rows[0].cycle:%Y-%m-%d %HZ} to {rows[-1].cycle:%Y-%m-%d %HZ} "
        f"(cadence {format_duration(interval)})"
    )
    if gaps:
        coverage += f" — {len(gaps)} gap(s), {format_duration(total_missing)} missing"
    runtime_axis.set_title(coverage, fontsize=14, color="dimgray")

    runtime_axis.set_xlabel(
        "Completed cycles, equally spaced (UTC labels)", fontsize=label_size
    )
    runtime_axis.set_ylabel("Clock time (seconds)", color="tab:blue", fontsize=label_size)
    memory_axis.set_ylabel("Memory usage (GB)", color="tab:orange", fontsize=label_size)
    runtime_axis.tick_params(axis="both", labelsize=tick_size)
    runtime_axis.tick_params(axis="y", colors="tab:blue")
    memory_axis.tick_params(axis="y", colors="tab:orange", labelsize=tick_size)
    runtime_axis.grid(True, axis="y", alpha=0.3)
    runtime_axis.set_xlim(-1, n)

    positions = tick_positions(n)
    multi_year = rows[0].cycle.year != rows[-1].cycle.year
    label_format = "%Y-%m-%d %HZ" if multi_year else "%m-%d %HZ"
    runtime_axis.set_xticks(positions)
    runtime_axis.set_xticklabels(
        [rows[i].cycle.strftime(label_format) for i in positions],
        rotation=30,
        ha="right",
        fontsize=tick_size,
    )

    runtime_axis.legend(
        handles=[
            jedi_runtime_line,
            gsi_runtime_line,
            jedi_memory_line,
            gsi_memory_line,
        ],
        loc="upper center",
        bbox_to_anchor=(0.5, 0.92),
        ncol=2,
        frameon=True,
        fontsize=legend_size,
    )

    fig.tight_layout()
    fig.savefig(output_file, dpi=160)
    plt.close(fig)


def main() -> int:
    args = parse_args()
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
    total_rows = len(rows)
    rows = filter_rows(rows, args.start, args.end, args.last_days)
    if not rows:
        print("ERROR: no cycles remain after applying --start/--end/--last-days", file=sys.stderr)
        return 1

    output_dir = args.output_dir or args.stats_dir / "plots"
    output_dir.mkdir(parents=True, exist_ok=True)
    csv_file = output_dir / f"{args.prefix}.csv"
    png_file = output_dir / f"{args.prefix}.png"
    write_csv(rows, csv_file, args.gsi_mpi_ranks)
    plot_combined(rows, png_file, args.gsi_mpi_ranks)

    missing_jedi = [row.cycle_text for row in rows if row.jedi_file is None]
    if len(rows) != total_rows:
        print(f"Plotting {len(rows)} of {total_rows} parsed cycles after time filtering")
    else:
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
