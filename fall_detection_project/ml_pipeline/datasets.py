from __future__ import annotations

import csv
import json
import math
import re
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable

import numpy as np
import pandas as pd


SAMPLING_RATE_HZ = 50
WINDOW_SIZE = 128
STEP_SIZE = 64
FEATURE_NAMES = [
    "acc_x_m_s2",
    "acc_y_m_s2",
    "acc_z_m_s2",
    "gyro_x_rad_s",
    "gyro_y_rad_s",
    "gyro_z_rad_s",
    "acc_magnitude_m_s2",
    "gyro_magnitude_rad_s",
]

PHONE_LABELS = [
    "standing",
    "walking",
    "running",
    "jumping",
    "chair_transition",
    "vehicle_transition",
    "fall",
]

WEARABLE_LABELS = [
    "walking",
    "running",
    "chair_transition",
    "crouching",
    "stumble",
    "jumping",
    "hand_activity",
    "fall",
]

PHONE_CODE_TO_LABEL = {
    "STD": "standing",
    "WAL": "walking",
    "JOG": "running",
    "JUM": "jumping",
    "STU": "walking",
    "STN": "walking",
    "SCH": "chair_transition",
    "CSI": "vehicle_transition",
    "CSO": "vehicle_transition",
    "FOL": "fall",
    "FKL": "fall",
    "BSC": "fall",
    "SDL": "fall",
}

WEARABLE_CODE_TO_LABEL = {
    "D01": "walking",
    "D02": "running",
    "D03": "walking",
    "D04": "chair_transition",
    "D05": "chair_transition",
    "D06": "crouching",
    "D07": "stumble",
    "D08": "jumping",
    "D09": "hand_activity",
    "D10": "hand_activity",
    "D11": "hand_activity",
    "F01": "fall",
    "F02": "fall",
    "F03": "fall",
    "F04": "fall",
    "F05": "fall",
    "F06": "fall",
    "F07": "fall",
    "F08": "fall",
}


@dataclass(frozen=True)
class Recording:
    dataset: str
    recording_id: str
    subject: str
    activity_code: str
    label: str
    acc_path: Path
    gyro_path: Path
    fall_start_s: float | None = None
    fall_end_s: float | None = None


@dataclass
class WindowedDataset:
    x: np.ndarray
    labels: np.ndarray
    subjects: np.ndarray
    recording_ids: np.ndarray
    starts_s: np.ndarray
    labels_ordered: list[str]
    audit: dict


def _parse_mobiact_name(path: Path) -> tuple[str, str, str, str] | None:
    parts = path.stem.split("_")
    if len(parts) != 4:
        return None
    activity, sensor, subject, trial = parts
    if sensor not in {"acc", "gyro"}:
        return None
    return activity, sensor, subject, trial


def discover_mobiact(root: Path) -> tuple[list[Recording], dict]:
    groups: dict[tuple[str, str, str], dict[str, Path]] = defaultdict(dict)
    ignored = 0
    for path in root.rglob("*.txt"):
        parsed = _parse_mobiact_name(path)
        if parsed is None:
            ignored += 1
            continue
        activity, sensor, subject, trial = parsed
        if activity not in PHONE_CODE_TO_LABEL:
            ignored += 1
            continue
        groups[(activity, subject, trial)][sensor] = path

    recordings: list[Recording] = []
    missing_pairs: list[str] = []
    for (activity, subject, trial), sensors in sorted(groups.items()):
        recording_id = f"{activity}/S{int(subject):02d}_R{int(trial):02d}"
        if "acc" not in sensors or "gyro" not in sensors:
            missing_pairs.append(recording_id)
            continue
        recordings.append(
            Recording(
                dataset="phone_mobiact",
                recording_id=recording_id,
                subject=str(int(subject)),
                activity_code=activity,
                label=PHONE_CODE_TO_LABEL[activity],
                acc_path=sensors["acc"],
                gyro_path=sensors["gyro"],
            )
        )

    audit = {
        "discovered_groups": len(groups),
        "paired_recordings": len(recordings),
        "missing_sensor_pairs": missing_pairs,
        "ignored_text_files": ignored,
    }
    return recordings, audit


def _read_fall_intervals(path: Path) -> dict[str, tuple[float, float]]:
    intervals: dict[str, tuple[float, float]] = {}
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            intervals[row["filename"]] = (float(row["start_time"]), float(row["end_time"]))
    return intervals


def discover_wedafall(root: Path) -> tuple[list[Recording], dict]:
    freq_dir = root / "dataset" / "50Hz"
    intervals_path = root / "dataset" / "fall_timestamps.csv"
    intervals = _read_fall_intervals(intervals_path)
    groups: dict[tuple[str, str, str], dict[str, Path]] = defaultdict(dict)

    pattern = re.compile(r"U(\d+)_R(\d+)_(accel|gyro)\.csv$")
    for path in freq_dir.rglob("*.csv"):
        match = pattern.match(path.name)
        if match is None:
            continue
        subject, trial, sensor_raw = match.groups()
        activity = path.parent.name
        if activity not in WEARABLE_CODE_TO_LABEL:
            continue
        sensor = "acc" if sensor_raw == "accel" else "gyro"
        groups[(activity, subject, trial)][sensor] = path

    recordings: list[Recording] = []
    missing_pairs: list[str] = []
    missing_intervals: list[str] = []
    for (activity, subject, trial), sensors in sorted(groups.items()):
        recording_id = f"{activity}/U{int(subject):02d}_R{int(trial):02d}"
        if "acc" not in sensors or "gyro" not in sensors:
            missing_pairs.append(recording_id)
            continue
        fall_start = fall_end = None
        if activity.startswith("F"):
            if recording_id in intervals:
                fall_start, fall_end = intervals[recording_id]
            else:
                missing_intervals.append(recording_id)
        recordings.append(
            Recording(
                dataset="wearable_wedafall",
                recording_id=recording_id,
                subject=str(int(subject)),
                activity_code=activity,
                label=WEARABLE_CODE_TO_LABEL[activity],
                acc_path=sensors["acc"],
                gyro_path=sensors["gyro"],
                fall_start_s=fall_start,
                fall_end_s=fall_end,
            )
        )

    audit = {
        "discovered_groups": len(groups),
        "paired_recordings": len(recordings),
        "missing_sensor_pairs": missing_pairs,
        "fall_intervals_available": len(intervals),
        "fall_recordings_missing_interval": missing_intervals,
    }
    return recordings, audit


def _clean_sensor_array(values: np.ndarray, timestamp_divisor: float) -> tuple[np.ndarray, np.ndarray, dict]:
    original_rows = len(values)
    values = values[np.all(np.isfinite(values), axis=1)]
    finite_rows = len(values)
    order = np.argsort(values[:, 0], kind="stable")
    values = values[order]
    _, unique_indices = np.unique(values[:, 0], return_index=True)
    values = values[np.sort(unique_indices)]
    timestamps = (values[:, 0] - values[0, 0]) / timestamp_divisor
    xyz = values[:, 1:4].astype(np.float32)
    diffs = np.diff(timestamps)
    positive_diffs = diffs[diffs > 0]
    median_hz = float(1.0 / np.median(positive_diffs)) if len(positive_diffs) else 0.0
    effective_hz = (
        float((len(timestamps) - 1) / (timestamps[-1] - timestamps[0]))
        if len(timestamps) > 1 and timestamps[-1] > timestamps[0]
        else 0.0
    )
    max_gap_s = float(np.max(positive_diffs)) if len(positive_diffs) else math.inf
    return timestamps.astype(np.float64), xyz, {
        "original_rows": original_rows,
        "finite_rows": finite_rows,
        "unique_rows": len(values),
        "median_hz": median_hz,
        "effective_hz": effective_hz,
        "max_gap_s": max_gap_s,
    }


def read_mobiact_sensor(path: Path) -> tuple[np.ndarray, np.ndarray, dict]:
    # MobiAct files contain an uncommented ``@DATA`` marker, so conventional
    # CSV readers infer a one-column table. Parse only numeric four-value rows.
    rows: list[np.ndarray] = []
    with path.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            if "," not in line or line.lstrip().startswith(("#", "@")):
                continue
            row = np.fromstring(line, sep=",", dtype=np.float64)
            if row.size >= 4:
                rows.append(row[:4])
    values = np.asarray(rows, dtype=np.float64)
    if values.size == 0:
        raise ValueError(f"No numeric sensor rows found in {path}")
    if values.ndim == 1:
        values = values.reshape(1, -1)
    return _clean_sensor_array(values, timestamp_divisor=1e9)


def read_wedafall_sensor(path: Path) -> tuple[np.ndarray, np.ndarray, dict]:
    frame = pd.read_csv(path, usecols=[0, 1, 2, 3])
    values = frame.apply(pd.to_numeric, errors="coerce").to_numpy(dtype=np.float64)
    return _clean_sensor_array(values, timestamp_divisor=1.0)


def _nearest_sample_distance(grid: np.ndarray, timestamps: np.ndarray) -> np.ndarray:
    right = np.searchsorted(timestamps, grid, side="left")
    left = np.clip(right - 1, 0, len(timestamps) - 1)
    right = np.clip(right, 0, len(timestamps) - 1)
    return np.minimum(np.abs(grid - timestamps[left]), np.abs(grid - timestamps[right]))


def _resample_recording(recording: Recording) -> tuple[np.ndarray, np.ndarray, np.ndarray, dict]:
    reader = read_mobiact_sensor if recording.dataset == "phone_mobiact" else read_wedafall_sensor
    acc_t, acc_xyz, acc_stats = reader(recording.acc_path)
    gyro_t, gyro_xyz, gyro_stats = reader(recording.gyro_path)

    start = max(float(acc_t[0]), float(gyro_t[0]))
    end = min(float(acc_t[-1]), float(gyro_t[-1]))
    if end - start < WINDOW_SIZE / SAMPLING_RATE_HZ:
        raise ValueError(f"Recording is too short after sensor overlap: {recording.recording_id}")

    grid = np.arange(start, end + 1e-9, 1.0 / SAMPLING_RATE_HZ, dtype=np.float64)
    acc_interp = np.column_stack([np.interp(grid, acc_t, acc_xyz[:, axis]) for axis in range(3)])
    gyro_interp = np.column_stack([np.interp(grid, gyro_t, gyro_xyz[:, axis]) for axis in range(3)])
    six_axes = np.concatenate([acc_interp, gyro_interp], axis=1).astype(np.float32)
    # Do not train on synthetic straight lines across sensor dropouts. A 100 ms
    # nearest-sample tolerance is generous at the 50 Hz deployment rate while
    # removing windows that cross the raw datasets' occasional long gaps.
    valid = (_nearest_sample_distance(grid, acc_t) <= 0.10) & (
        _nearest_sample_distance(grid, gyro_t) <= 0.10
    )
    stats = {
        "recording_id": recording.recording_id,
        "subject": recording.subject,
        "activity_code": recording.activity_code,
        "label": recording.label,
        "duration_s": float(grid[-1] - grid[0]),
        "resampled_rows": len(grid),
        "valid_resampled_fraction": float(np.mean(valid)),
        "acc": acc_stats,
        "gyro": gyro_stats,
    }
    return grid, six_axes, valid, stats


def add_magnitude_features(six_axes: np.ndarray) -> np.ndarray:
    acc_mag = np.linalg.norm(six_axes[:, 0:3], axis=1, keepdims=True)
    gyro_mag = np.linalg.norm(six_axes[:, 3:6], axis=1, keepdims=True)
    return np.concatenate([six_axes, acc_mag, gyro_mag], axis=1).astype(np.float32)


def _regular_window_starts(length: int) -> Iterable[int]:
    return range(0, length - WINDOW_SIZE + 1, STEP_SIZE)


def _mobiact_fall_window_starts(six_axes: np.ndarray) -> list[int]:
    """Select impact-centred windows instead of labelling an entire 10 s fall trial."""
    acc_mag = np.linalg.norm(six_axes[:, 0:3], axis=1)
    gyro_mag = np.linalg.norm(six_axes[:, 3:6], axis=1)
    score = np.abs(acc_mag - 9.80665) + 1.5 * gyro_mag
    lo = max(WINDOW_SIZE // 2, int(0.15 * len(score)))
    hi = min(len(score) - WINDOW_SIZE // 2, int(0.85 * len(score)))
    if hi <= lo:
        peak = int(np.argmax(score))
    else:
        peak = lo + int(np.argmax(score[lo:hi]))
    starts = []
    for offset in (-STEP_SIZE // 2, 0, STEP_SIZE // 2):
        start = int(np.clip(peak - WINDOW_SIZE // 2 + offset, 0, len(score) - WINDOW_SIZE))
        starts.append(start)
    return sorted(set(starts))


def _wedafall_positive_window_starts(recording: Recording, grid: np.ndarray) -> list[int]:
    if recording.fall_start_s is None or recording.fall_end_s is None:
        return []
    starts: list[int] = []
    for start in _regular_window_starts(len(grid)):
        window_start = float(grid[start])
        window_end = float(grid[start + WINDOW_SIZE - 1])
        overlap = max(
            0.0,
            min(window_end, recording.fall_end_s) - max(window_start, recording.fall_start_s),
        )
        if overlap / max(window_end - window_start, 1e-6) >= 0.30:
            starts.append(start)
    return starts


def build_windowed_dataset(
    dataset: str,
    root: Path,
    audit_output: Path | None = None,
) -> WindowedDataset:
    if dataset == "phone":
        recordings, discovery_audit = discover_mobiact(root)
        labels_ordered = PHONE_LABELS
    elif dataset == "wearable":
        recordings, discovery_audit = discover_wedafall(root)
        labels_ordered = WEARABLE_LABELS
    else:
        raise ValueError(f"Unknown dataset: {dataset}")

    windows: list[np.ndarray] = []
    labels: list[str] = []
    subjects: list[str] = []
    recording_ids: list[str] = []
    starts_s: list[float] = []
    recording_stats: list[dict] = []
    skipped: dict[str, str] = {}

    for index, recording in enumerate(recordings, start=1):
        try:
            grid, six_axes, valid, stats = _resample_recording(recording)
        except Exception as exc:  # retain a complete audit rather than hiding bad recordings
            skipped[recording.recording_id] = str(exc)
            continue

        recording_stats.append(stats)
        features = add_magnitude_features(six_axes)
        if recording.label != "fall":
            starts = list(_regular_window_starts(len(features)))
        elif dataset == "phone":
            starts = _mobiact_fall_window_starts(six_axes)
        else:
            starts = _wedafall_positive_window_starts(recording, grid)
            if not starts:
                skipped[recording.recording_id] = "No window met the manual fall-overlap criterion"
                continue

        starts = [start for start in starts if bool(np.all(valid[start : start + WINDOW_SIZE]))]
        if not starts:
            skipped[recording.recording_id] = "All candidate windows crossed a raw-sensor dropout"
            continue

        for start in starts:
            windows.append(features[start : start + WINDOW_SIZE])
            labels.append(recording.label)
            subjects.append(recording.subject)
            recording_ids.append(recording.recording_id)
            starts_s.append(float(grid[start]))

        if index % 200 == 0:
            print(f"[{dataset}] processed {index}/{len(recordings)} recordings", flush=True)

    if not windows:
        raise ValueError(f"No windows were created for {dataset}")

    acc_rates = [s["acc"]["effective_hz"] for s in recording_stats]
    gyro_rates = [s["gyro"]["effective_hz"] for s in recording_stats]
    audit = {
        "dataset": dataset,
        "configuration": {
            "sampling_rate_hz": SAMPLING_RATE_HZ,
            "window_size": WINDOW_SIZE,
            "step_size": STEP_SIZE,
            "window_duration_s": WINDOW_SIZE / SAMPLING_RATE_HZ,
            "step_duration_s": STEP_SIZE / SAMPLING_RATE_HZ,
            "feature_names": FEATURE_NAMES,
        },
        "discovery": discovery_audit,
        "processed_recordings": len(recording_stats),
        "skipped_recordings": skipped,
        "subjects": sorted({r.subject for r in recordings}, key=int),
        "recordings_by_activity": dict(sorted(Counter(r.activity_code for r in recordings).items())),
        "windows_by_label": dict(sorted(Counter(labels).items())),
        "sampling_rate_summary_hz": {
            "accelerometer": _summary(acc_rates),
            "gyroscope": _summary(gyro_rates),
        },
        "recording_stats": recording_stats,
    }
    if audit_output is not None:
        audit_output.parent.mkdir(parents=True, exist_ok=True)
        audit_output.write_text(json.dumps(audit, indent=2), encoding="utf-8")

    return WindowedDataset(
        x=np.asarray(windows, dtype=np.float32),
        labels=np.asarray(labels),
        subjects=np.asarray(subjects),
        recording_ids=np.asarray(recording_ids),
        starts_s=np.asarray(starts_s, dtype=np.float32),
        labels_ordered=labels_ordered,
        audit=audit,
    )


def _summary(values: list[float]) -> dict[str, float]:
    array = np.asarray(values, dtype=np.float64)
    return {
        "min": float(np.min(array)),
        "p25": float(np.percentile(array, 25)),
        "median": float(np.median(array)),
        "p75": float(np.percentile(array, 75)),
        "max": float(np.max(array)),
    }


def make_subject_split(data: WindowedDataset, dataset: str, seed: int = 42) -> dict[str, list[str]]:
    all_labels = set(data.labels_ordered)
    labels_by_subject: dict[str, set[str]] = defaultdict(set)
    for subject, label in zip(data.subjects, data.labels, strict=True):
        labels_by_subject[str(subject)].add(str(label))

    complete = sorted(
        [subject for subject, labels in labels_by_subject.items() if labels == all_labels],
        key=int,
    )
    if len(complete) < 6:
        coverage_required = len(all_labels) - 1
        complete = sorted(
            [
                subject
                for subject, labels in labels_by_subject.items()
                if "fall" in labels and len(labels) >= coverage_required
            ],
            key=int,
        )
    if len(complete) < 4:
        raise ValueError(f"Not enough subjects with full activity/fall coverage for {dataset}: {complete}")

    rng = np.random.default_rng(seed)
    core = list(rng.permutation(complete))
    test_subjects = set(core[:2])
    val_subjects = set(core[2:4])

    # WEDA-FALL has elderly participants with ADL only. Put some in validation/test
    # so false alarms are measured on the target age group, while keeping every split
    # strictly subject independent.
    remaining = sorted(set(labels_by_subject) - set(complete), key=int)
    if dataset == "wearable" and len(remaining) >= 4:
        remainder = list(rng.permutation(remaining))
        test_subjects.update(remainder[:2])
        val_subjects.update(remainder[2:4])

    train_subjects = set(labels_by_subject) - val_subjects - test_subjects
    split = {
        "train": sorted(train_subjects, key=int),
        "validation": sorted(val_subjects, key=int),
        "test": sorted(test_subjects, key=int),
    }

    for name, subjects in split.items():
        mask = np.isin(data.subjects, subjects)
        missing = all_labels - set(data.labels[mask])
        if missing:
            raise ValueError(f"{dataset} {name} split is missing labels: {sorted(missing)}")
    return split


def split_indices(data: WindowedDataset, split: dict[str, list[str]]) -> dict[str, np.ndarray]:
    return {
        name: np.flatnonzero(np.isin(data.subjects, subjects))
        for name, subjects in split.items()
    }


def serializable_recording(recording: Recording) -> dict:
    result = asdict(recording)
    result["acc_path"] = str(recording.acc_path)
    result["gyro_path"] = str(recording.gyro_path)
    return result
