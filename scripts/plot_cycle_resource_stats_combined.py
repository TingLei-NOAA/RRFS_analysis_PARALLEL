#!/usr/bin/env python3
"""Plot GSI and JEDI runtime and total memory in one figure.

Example using the default GSI MPI rank count of 480:

    python3 scripts/plot_cycle_resource_stats_combined.py \
        /u/ting.lei/dr-3kmNA-parallel/dr_save_stats

Example overriding the GSI MPI rank count:

    python3 scripts/plot_cycle_resource_stats_combined.py \
        /u/ting.lei/dr-3kmNA-parallel/dr_save_stats \
        --gsi-mpi-ranks 512

By default, the script writes:

    <stats_dir>/plots/cycle_resource_stats_combined.csv
    <stats_dir>/plots/cycle_resource_stats_combined.png

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
from pathlib import Path

from plot_cycle_resource_stats import build_plot_series, gather_stats, write_csv


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


def plot_combined(rows, output_file: Path, max_gap_markers: int, gsi_mpi_ranks: int) -> None:
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError as exc:
        raise SystemExit("ERROR: matplotlib is required to create plots") from exc

    labels, values = build_plot_series(rows, max_gap_markers)
    x = list(range(len(labels)))
    gsi_estimated_total_memory = [
        value * gsi_mpi_ranks if value is not None else None
        for value in values["gsi_rss"]
    ]

    fig, runtime_axis = plt.subplots(figsize=(max(12, len(labels) * 0.38), 7))
    memory_axis = runtime_axis.twinx()

    jedi_runtime_line = runtime_axis.plot(
        x,
        values["jedi_runtime"],
        color="tab:blue",
        linestyle="-",
        marker="o",
        label="JEDI runtime",
    )[0]
    gsi_runtime_line = runtime_axis.plot(
        x,
        values["gsi_runtime"],
        color="tab:blue",
        linestyle=":",
        marker="o",
        label="GSI wall time",
    )[0]
    jedi_memory_line = memory_axis.plot(
        x,
        values["jedi_total_memory"],
        color="tab:orange",
        linestyle="-",
        marker="s",
        label="JEDI reported aggregate memory",
    )[0]
    gsi_memory_line = memory_axis.plot(
        x,
        gsi_estimated_total_memory,
        color="tab:orange",
        linestyle=":",
        marker="s",
        label=f"GSI estimated total memory: max RSS x {gsi_mpi_ranks} ranks",
    )[0]

    runtime_axis.set_title("GSI and JEDI Runtime and Total Memory by Analysis Cycle")
    runtime_axis.set_xlabel("Cycle (UTC)")
    runtime_axis.set_ylabel("Clock time (seconds)", color="tab:blue")
    memory_axis.set_ylabel("Memory usage (GB)", color="tab:orange")
    runtime_axis.tick_params(axis="y", colors="tab:blue")
    memory_axis.tick_params(axis="y", colors="tab:orange")
    runtime_axis.grid(True, alpha=0.3)

    runtime_axis.set_xticks(x)
    runtime_axis.set_xticklabels(labels, rotation=70, ha="right", fontsize=8)
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
    )

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
    plot_combined(rows, png_file, args.max_gap_markers, args.gsi_mpi_ranks)

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
