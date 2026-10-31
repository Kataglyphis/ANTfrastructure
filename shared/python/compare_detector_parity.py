#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Compare packaged CPU and GPU detector results for the known two-cats image."""

import argparse
import json
import math
from pathlib import Path
from typing import Any

MIN_IOU = 0.90
MAX_SCORE_DELTA = 0.05
MIN_SCORE = 0.25


def unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def number(value: Any) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def load(path: str | Path) -> dict[str, Any]:
    data = json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=unique)
    if not isinstance(data, dict) or set(data) != {
        "schema_version",
        "width",
        "height",
        "detections",
    }:
        raise ValueError("invalid detector result schema")
    if type(data["schema_version"]) is not int or data["schema_version"] != 1:
        raise ValueError("unsupported detector result schema")
    width, height, detections = data["width"], data["height"], data["detections"]
    if (
        type(width) is not int
        or type(height) is not int
        or not (0 < width <= 16384 and 0 < height <= 16384)
    ):
        raise ValueError("invalid image dimensions")
    if not isinstance(detections, list) or not 1 <= len(detections) <= 300:
        raise ValueError("empty or excessive detections")
    for item in detections:
        if not isinstance(item, dict) or set(item) != {"class", "score", "box"}:
            raise ValueError("invalid detection")
        box, score, cls = item["box"], item["score"], item["class"]
        if (
            type(cls) is not int
            or not 0 <= cls < 80
            or not number(score)
            or not MIN_SCORE <= score <= 1
        ):
            raise ValueError("invalid detection class or score")
        if (
            not isinstance(box, list)
            or len(box) != 4
            or not all(number(x) for x in box)
        ):
            raise ValueError("invalid detection coordinates")
        x1, y1, x2, y2 = box
        if not (
            x1 < x2
            and y1 < y2
            and -0.05 * width < x1 < x2 < 1.05 * width
            and -0.05 * height < y1 < y2 < 1.05 * height
        ):
            raise ValueError("detection box outside the image")
    return data


def iou(left: list[float], right: list[float]) -> float:
    x1, y1 = max(left[0], right[0]), max(left[1], right[1])
    x2, y2 = min(left[2], right[2]), min(left[3], right[3])
    intersection = max(0, x2 - x1) * max(0, y2 - y1)
    area_l = (left[2] - left[0]) * (left[3] - left[1])
    area_r = (right[2] - right[0]) * (right[3] - right[1])
    return intersection / (area_l + area_r - intersection)


def compare(cpu: dict[str, Any], gpu: dict[str, Any]) -> None:
    if (cpu["width"], cpu["height"]) != (gpu["width"], gpu["height"]):
        raise ValueError("image dimensions differ")
    expected, actual = cpu["detections"], gpu["detections"]
    cats = [item for item in expected if item["class"] == 15]
    if not any(
        item["score"] >= 0.8
        and (item["box"][1] + item["box"][3]) / 2 > 0.55 * cpu["height"]
        and any(
            index != other_index and iou(item["box"], other["box"]) < 0.5
            for other_index, other in enumerate(cats)
        )
        for index, item in enumerate(cats)
    ):
        raise ValueError("CPU baseline did not detect both expected cats")
    if any(item["class"] in (0, 16) and item["score"] >= 0.5 for item in expected):
        raise ValueError("CPU baseline misclassified a cat")
    if len(expected) != len(actual):
        raise ValueError("detection counts differ")
    edges = [
        [
            j
            for j, other in enumerate(actual)
            if item["class"] == other["class"]
            and abs(item["score"] - other["score"]) <= MAX_SCORE_DELTA
            and iou(item["box"], other["box"]) >= MIN_IOU
        ]
        for item in expected
    ]
    matched: dict[int, int] = {}

    def assign(index: int, visited: set[int]) -> bool:
        for candidate in edges[index]:
            if candidate in visited:
                continue
            visited.add(candidate)
            if candidate not in matched or assign(matched[candidate], visited):
                matched[candidate] = index
                return True
        return False

    if not all(assign(index, set()) for index in range(len(expected))):
        raise ValueError("CPU and GPU detections do not match within tolerance")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cpu", type=Path)
    parser.add_argument("gpu", type=Path)
    args = parser.parse_args()
    try:
        compare(load(args.cpu), load(args.gpu))
    except (OSError, TypeError, ValueError, OverflowError) as error:
        parser.exit(1, f"Detector parity failed: {error}\n")
    print(
        f"Detector parity passed (IoU >= {MIN_IOU}, score difference <= {MAX_SCORE_DELTA})"
    )


if __name__ == "__main__":
    main()
