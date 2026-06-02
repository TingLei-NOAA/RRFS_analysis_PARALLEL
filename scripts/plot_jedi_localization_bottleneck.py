#!/usr/bin/env python3
"""Plot the JEDI localization bottleneck across cycles.

Example:

    python3 scripts/plot_jedi_localization_bottleneck.py \
        /u/ting.lei/dr-3kmNA-parallel/dr_save_stats

By default, the script writes:

    <stats_dir>/plots/jedi_localization_bottleneck.csv
    <stats_dir>/plots/jedi_localization_bottleneck.png

Cycles with total JEDI runtime greater than 4000 seconds are skipped by default.
Override the threshold if needed:

    python3 scripts/plot_jedi_localization_bottleneck.py \
        /u/ting.lei/dr-3kmNA-parallel/dr_save_stats \
        --max-runtime-seconds 5000

The timer hierarchy is inclusive:

    JEDI total runtime
      saber::Localization::multiply
        saber::mgbf::Covariance::multiply

The nested MGBF timer is included within the localization timer. Do not add the
localization and MGBF lines together.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from plot_cycle_resource_stats import add_gap_positions


CYCLE_FORMAT = "%Y%m%d%H"
JEDI_PATTERN = re.compile(r"^jedi_out_?(\d{10})$")
NUMBER = re.compile(r"[0-9]+(?:\.[0-9]+)?")
RUN_END = re.compile(r"OOPS_STATS Run end\s+- Runtime:\s*([0-9]+(?:\.[0-9]+)?)\s*sec")
LOCALIZATION_TIMER = "saber::Localization::multiply"
MGBF_TIMER = "saber::mgbf::Covariance::multiply"


@dataclass
class JediCycleStats:
    cycle: datetime
    jedi_file: Path
    total_runtime_seconds: Optional[float]
    localization_multiply_seconds: Optional[float]
    mgbf_multiply_seconds: Optional[float]

    @property
    def cycle_text(self) -> str:
        return self.cycle.strftime(CYCLE_FORMAT)

    @property
    def localization_percent_of_total(self) -> Optional[float]:
        return percentage(self.localization_multiply_seconds, self.total_runtime_seconds)

    @property
    def mgbf_percent_of_total(self) -> Optional[float]:
        return percentage(self.mgbf_multiply_seconds, self.total_runtime_seconds)

    @property
    def mgbf_percent_of_localization(self) -> Optional[float]:
        return percentage(self.mgbf_multiply_seconds, self.localization_multiply_seconds)


def percentage(numerator: Optional[float], denominator: Optional[float]) -> Optional[float]:
    if numerator is None or denominator in (None, 0):
        return None
    return 100.0 * numerator / denominator


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Plot JEDI total runtime, inclusive saber localization multiply "
            "runtime, and nested MGBF covariance multiply runtime by cycle."
        )
    )
    parser.add_argument(
        "stats_dir",
        nargs="?",
        type=Path,
        default=Path("/u/ting.lei/dr-3kmNA-parallel/dr_save_stats"),
        help="Directory containing jedi_outYYYYMMDDHH files.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Output directory. Default: <stats_dir>/plots",
    )
    parser.add_argument(
        "--prefix",
        default="jedi_localization_bottleneck",
        help="Prefix for generated CSV and PNG files.",
    )
    parser.add_argument(
        "--max-runtime-seconds",
        type=float,
        default=4000.0,
        help="Skip cycles whose total JEDI runtime exceeds this value. Default: 4000",
    )
    parser.add_argument(
        "--max-gap-markers",
        type=int,
        default=3,
        help="Maximum placeholder positions used to display a missing-cycle gap.",
    )
    return parser.parse_args()


def extract_last_runtime(text: str) -> Optional[float]:
    matches = RUN_END.findall(text)
    return float(matches[-1]) if matches else None


def extract_parallel_average_timer_seconds(text: str, timer_name: str) -> Optional[float]:
    """Use the final parallel-summary average, with rank-local total as fallback."""
    matching_lines = [line for line in text.splitlines() if timer_name in line]
    if not matching_lines:
        return None

    values = NUMBER.findall(matching_lines[-1].split(":", 1)[-1])
    if len(values) >= 5:
        return float(values[2]) / 1000.0
    if len(values) >= 3:
        return float(values[0]) / 1000.0
    return None


def parse_jedi_file(path: Path, cycle: datetime) -> JediCycleStats:
    text = path.read_text(errors="replace")
    return JediCycleStats(
        cycle=cycle,
        jedi_file=path,
        total_runtime_seconds=extract_last_runtime(text),
        localization_multiply_seconds=extract_parallel_average_timer_seconds(
            text, LOCALIZATION_TIMER
        ),
        mgbf_multiply_seconds=extract_parallel_average_timer_seconds(text, MGBF_TIMER),
    )


def gather_stats(stats_dir: Path) -> List[JediCycleStats]:
    rows = []
    for path in stats_dir.iterdir():
        match = JEDI_PATTERN.match(path.name)
        if not match or not path.is_file():
            continue
        cycle = datetime.strptime(match.group(1), CYCLE_FORMAT).replace(tzinfo=timezone.utc)
        rows.append(parse_jedi_file(path, cycle))
    return sorted(rows, key=lambda row: row.cycle)


def write_csv(
    rows: List[JediCycleStats],
    output_file: Path,
    max_runtime_seconds: float,
) -> None:
    fields = (
        "cycle",
        "jedi_file",
        "included_in_plot",
        "exclusion_reason",
        "total_runtime_seconds",
        "localization_multiply_seconds",
        "mgbf_multiply_seconds",
        "localization_percent_of_total",
        "mgbf_percent_of_total",
        "mgbf_percent_of_localization",
    )
    with output_file.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            reason = exclusion_reason(row, max_runtime_seconds)
            writer.writerow(
                {
                    "cycle": row.cycle_text,
                    "jedi_file": row.jedi_file.name,
                    "included_in_plot": not reason,
                    "exclusion_reason": reason,
                    "total_runtime_seconds": row.total_runtime_seconds,
                    "localization_multiply_seconds": row.localization_multiply_seconds,
                    "mgbf_multiply_seconds": row.mgbf_multiply_seconds,
                    "localization_percent_of_total": row.localization_percent_of_total,
                    "mgbf_percent_of_total": row.mgbf_percent_of_total,
                    "mgbf_percent_of_localization": row.mgbf_percent_of_localization,
                }
            )


def exclusion_reason(row: JediCycleStats, max_runtime_seconds: float) -> str:
    if row.total_runtime_seconds is None:
        return "missing total JEDI runtime"
    if row.total_runtime_seconds > max_runtime_seconds:
        return f"total JEDI runtime exceeds {max_runtime_seconds:g} seconds"
    if row.localization_multiply_seconds is None:
        return f"missing {LOCALIZATION_TIMER}"
    if row.mgbf_multiply_seconds is None:
        return f"missing {MGBF_TIMER}"
    return ""


def build_plot_series(
    rows: List[JediCycleStats], max_gap_markers: int
) -> Tuple[List[str], Dict[str, List[Optional[float]]]]:
    labels: List[str] = []
    values: Dict[str, List[Optional[float]]] = {
        "total_runtime": [],
        "localization_multiply": [],
        "mgbf_multiply": [],
    }
    previous = None
    for row in rows:
        if previous is not None:
            add_gap_positions(previous, row.cycle, labels, values, max_gap_markers)
        labels.append(row.cycle_text)
        values["total_runtime"].append(row.total_runtime_seconds)
        values["localization_multiply"].append(row.localization_multiply_seconds)
        values["mgbf_multiply"].append(row.mgbf_multiply_seconds)
        previous = row.cycle
    return labels, values


def plot_stats(rows: List[JediCycleStats], output_file: Path, max_gap_markers: int) -> None:
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError as exc:
        raise SystemExit("ERROR: matplotlib is required to create plots") from exc

    labels, values = build_plot_series(rows, max_gap_markers)
    x = list(range(len(labels)))
    fig, axis = plt.subplots(figsize=(max(12, len(labels) * 0.38), 7))

    axis.plot(x, values["total_runtime"], marker="o", label="JEDI total runtime")
    axis.plot(
        x,
        values["localization_multiply"],
        marker="o",
        label="Inclusive saber::Localization::multiply",
    )
    axis.plot(
        x,
        values["mgbf_multiply"],
        marker="o",
        linestyle="--",
        label="Nested saber::mgbf::Covariance::multiply",
    )
    axis.set_title("JEDI Localization Bottleneck by Analysis Cycle")
    axis.set_xlabel("Cycle (UTC)")
    axis.set_ylabel("Clock time (seconds)")
    axis.grid(True, alpha=0.3)
    axis.legend(title="MGBF is included within Localization")
    axis.set_xticks(x)
    axis.set_xticklabels(labels, rotation=70, ha="right", fontsize=8)

    fig.tight_layout()
    fig.savefig(output_file, dpi=160)
    plt.close(fig)


def main() -> int:
    args = parse_args()
    if args.max_runtime_seconds <= 0:
        print("ERROR: --max-runtime-seconds must be positive", file=sys.stderr)
        return 2
    if args.max_gap_markers < 1:
        print("ERROR: --max-gap-markers must be at least 1", file=sys.stderr)
        return 2
    if not args.stats_dir.is_dir():
        print(f"ERROR: stats directory does not exist: {args.stats_dir}", file=sys.stderr)
        return 2

    all_rows = gather_stats(args.stats_dir)
    if not all_rows:
        print(f"ERROR: no jedi_outYYYYMMDDHH files found in {args.stats_dir}", file=sys.stderr)
        return 1

    included_rows = [
        row for row in all_rows if not exclusion_reason(row, args.max_runtime_seconds)
    ]
    if not included_rows:
        print("ERROR: no JEDI cycles remain after filtering", file=sys.stderr)
        return 1

    output_dir = args.output_dir or args.stats_dir / "plots"
    output_dir.mkdir(parents=True, exist_ok=True)
    csv_file = output_dir / f"{args.prefix}.csv"
    png_file = output_dir / f"{args.prefix}.png"
    write_csv(all_rows, csv_file, args.max_runtime_seconds)
    plot_stats(included_rows, png_file, args.max_gap_markers)

    excluded_rows = [
        (row.cycle_text, exclusion_reason(row, args.max_runtime_seconds))
        for row in all_rows
        if exclusion_reason(row, args.max_runtime_seconds)
    ]
    print(f"Parsed {len(all_rows)} JEDI cycle files from {args.stats_dir}")
    print(f"Included {len(included_rows)} cycle(s) in the plot")
    print(f"Wrote CSV:  {csv_file}")
    print(f"Wrote plot: {png_file}")
    if excluded_rows:
        print(f"Skipped {len(excluded_rows)} cycle(s):")
        for cycle, reason in excluded_rows:
            print(f"  {cycle}: {reason}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
