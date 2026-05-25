"""
Review generated profile files over an i/j window and summarize values at one vertical level.

Expected profile format from sample_profiles_from_fv3.py:
  line 1: comment
  line 2: "<subdomain_index> <nlevels> <i> <j>"   (1-based i/j)
  later:  "# now the complete profile with fillled values"
  then:   "<k> <value>" rows for the complete profile
"""

from __future__ import annotations

import argparse
from pathlib import Path


def parse_profile_metadata_and_level(path: Path, k_target: int) -> tuple[int, int, int, float]:
    subdomain_index = None
    i_idx = None
    j_idx = None
    in_complete = False
    level_value = None

    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            if "complete profile" in line.lower():
                in_complete = True
            continue

        parts = line.split()
        if subdomain_index is None:
            if len(parts) < 4:
                raise SystemExit(f"Bad metadata line in {path}")
            subdomain_index = int(parts[0])
            i_idx = int(parts[2])
            j_idx = int(parts[3])
            continue

        if in_complete:
            if len(parts) < 2:
                continue
            k_val = int(parts[0])
            if k_val == k_target:
                level_value = float(parts[1])
                break

    if subdomain_index is None or i_idx is None or j_idx is None:
        raise SystemExit(f"Missing metadata in {path}")
    if level_value is None:
        raise SystemExit(f"Vertical level k={k_target} not found in complete profile of {path}")

    return subdomain_index, i_idx, j_idx, level_value


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Summarize generated profile values at one vertical level over an i/j subdomain."
    )
    parser.add_argument("--profiles-dir", type=Path, required=True, help="Directory containing profile_subdomain_*.txt")
    parser.add_argument("--k", type=int, required=True, help="1-based vertical level from the complete profile section")
    parser.add_argument("--i-start", type=int, required=True, help="1-based start i")
    parser.add_argument("--i-end", type=int, required=True, help="1-based end i")
    parser.add_argument("--j-start", type=int, required=True, help="1-based start j")
    parser.add_argument("--j-end", type=int, required=True, help="1-based end j")
    parser.add_argument("--top-n", type=int, default=10, help="How many largest/smallest points to report")
    args = parser.parse_args()

    files = sorted(args.profiles_dir.glob("profile_subdomain_*.txt"))
    if not files:
        raise SystemExit(f"No profile files found in {args.profiles_dir}")

    matches: list[tuple[float, int, int, int, Path]] = []
    for path in files:
        subdomain_index, i_idx, j_idx, value = parse_profile_metadata_and_level(path, args.k)
        if args.i_start <= i_idx <= args.i_end and args.j_start <= j_idx <= args.j_end:
            matches.append((value, subdomain_index, i_idx, j_idx, path))

    if not matches:
        print(
            f"No profile files found inside window i=[{args.i_start},{args.i_end}], "
            f"j=[{args.j_start},{args.j_end}] at k={args.k}."
        )
        return

    matches_sorted = sorted(matches, key=lambda x: x[0])
    min_item = matches_sorted[0]
    max_item = matches_sorted[-1]

    print(
        f"Found {len(matches)} profiles inside window i=[{args.i_start},{args.i_end}], "
        f"j=[{args.j_start},{args.j_end}] at k={args.k}."
    )
    print(
        f"Minimum value: {min_item[0]:.10g} at subdomain={min_item[1]}, i={min_item[2]}, j={min_item[3]}, "
        f"file={min_item[4]}"
    )
    print(
        f"Maximum value: {max_item[0]:.10g} at subdomain={max_item[1]}, i={max_item[2]}, j={max_item[3]}, "
        f"file={max_item[4]}"
    )

    print("\nSmallest values:")
    print("# rank value subdomain_index i j profile_file")
    for rank, item in enumerate(matches_sorted[: args.top_n], start=1):
        print(f"{rank} {item[0]:.10g} {item[1]} {item[2]} {item[3]} {item[4]}")

    print("\nLargest values:")
    print("# rank value subdomain_index i j profile_file")
    for rank, item in enumerate(reversed(matches_sorted[-args.top_n:]), start=1):
        print(f"{rank} {item[0]:.10g} {item[1]} {item[2]} {item[3]} {item[4]}")


if __name__ == "__main__":
    main()
