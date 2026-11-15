#!/usr/bin/env python3
"""Summarize braking zones from an APEX Lab CSV without changing the recording."""
import argparse
import csv
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass
class Sample:
    time: float
    progress: float
    speed: float
    pedal: float
    pressure: float
    release: float
    steady_target: Optional[float] = None


def read_samples(path):
    with path.open(encoding="utf-8", newline="") as source:
        rows = csv.DictReader(source)
        columns = set(rows.fieldnames or ())
        needed = {"session_time_s", "track_progress_m", "speed_kph", "brake",
                  "brake_line_pressure", "abs_release"}
        if not needed <= columns:
            raise ValueError("需要 RC21 或更新版本导出的遥测。")
        previous = -math.inf
        for line, row in enumerate(rows, start=2):
            try:
                values = [float(row[key]) for key in (
                    "session_time_s", "track_progress_m", "speed_kph", "brake",
                    "brake_line_pressure", "abs_release")]
                target = float(row["brake_steady_target"]) if "brake_steady_target" in columns else None
            except (ValueError, TypeError) as error:
                raise ValueError(f"第 {line} 行有无法读取的数值。") from error
            if (not all(math.isfinite(v) for v in values) or values[0] <= previous
                    or (target is not None and (not math.isfinite(target) or not 0 <= target <= 1))):
                raise ValueError(f"第 {line} 行时间未递增，或含非有限数值。")
            previous = values[0]
            yield Sample(*values, steady_target=target)


def brake_zones(samples, threshold=0.04):
    segment = []
    for sample in samples:
        if segment and (sample.pressure < threshold or sample.time - segment[-1].time > 0.25):
            if len(segment) >= 3:
                yield segment
            segment = []
        if sample.pressure >= threshold:
            segment.append(sample)
    if len(segment) >= 3:
        yield segment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    parser.add_argument("--minimum-pressure", type=float, default=0.04)
    args = parser.parse_args()
    if not 0 < args.minimum_pressure < 1:
        parser.error("--minimum-pressure 应在 0 和 1 之间")
    try:
        zones = list(brake_zones(read_samples(args.csv), args.minimum_pressure))
    except (OSError, ValueError) as error:
        parser.error(str(error))
    if not zones:
        print("没有达到阈值并持续至少三个样本的制动区。")
        return
    include_target = any(sample.steady_target is not None for zone in zones for sample in zone)
    header = "开始[s]  赛道[m]  车速变化[km/h]  LT峰值  管路峰值  ABS最大卸压"
    print(header + ("  稳态压力目标峰值" if include_target else ""))
    for zone in zones:
        first, last = zone[0], zone[-1]
        pedal = max(sample.pedal for sample in zone)
        pressure = max(sample.pressure for sample in zone)
        release = max(sample.release for sample in zone)
        row = (f"{first.time:7.1f}  {first.progress:7.1f}  {first.speed:6.1f} → {last.speed:6.1f}"
               f"  {pedal:6.0%}  {pressure:8.0%}  {release:9.0%}")
        if include_target:
            target = max(sample.steady_target for sample in zone if sample.steady_target is not None)
            row += f"  {target:15.0%}"
        print(row)


if __name__ == "__main__":
    main()
