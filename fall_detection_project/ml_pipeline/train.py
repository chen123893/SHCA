from __future__ import annotations

import argparse
import json
import os
import random
from collections import Counter
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import tensorflow as tf
from sklearn.metrics import (
    accuracy_score,
    classification_report,
    confusion_matrix,
    f1_score,
    precision_recall_curve,
    precision_score,
    recall_score,
)
from sklearn.utils.class_weight import compute_class_weight

from ml_pipeline.datasets import (
    FEATURE_NAMES,
    SAMPLING_RATE_HZ,
    STEP_SIZE,
    WINDOW_SIZE,
    WindowedDataset,
    build_windowed_dataset,
    make_subject_split,
    split_indices,
)


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PHONE_ROOT = PROJECT_ROOT / "data" / "raw" / "MobiAct_Dataset_v2.0-MobiFall_Dataset_v2.0"
WEARABLE_ROOT = PROJECT_ROOT / "data" / "raw" / "WEDA-FALL-main"
DEFAULT_OUTPUT_ROOT = PROJECT_ROOT / "saved_model" / "deployment"
DEFAULT_CACHE_ROOT = PROJECT_ROOT / "data" / "processed"


def set_determinism(seed: int) -> None:
    os.environ.setdefault("TF_DETERMINISTIC_OPS", "1")
    random.seed(seed)
    np.random.seed(seed)
    tf.keras.utils.set_random_seed(seed)
    try:
        tf.config.experimental.enable_op_determinism()
    except Exception:
        pass


def save_dataset_cache(data: WindowedDataset, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        path,
        x=data.x,
        labels=data.labels,
        subjects=data.subjects,
        recording_ids=data.recording_ids,
        starts_s=data.starts_s,
        labels_ordered=np.asarray(data.labels_ordered),
    )


def load_dataset_cache(path: Path, audit_path: Path) -> WindowedDataset:
    with np.load(path, allow_pickle=False) as arrays:
        return WindowedDataset(
            x=arrays["x"],
            labels=arrays["labels"],
            subjects=arrays["subjects"],
            recording_ids=arrays["recording_ids"],
            starts_s=arrays["starts_s"],
            labels_ordered=[str(item) for item in arrays["labels_ordered"]],
            audit=json.loads(audit_path.read_text(encoding="utf-8")),
        )


def get_dataset(dataset: str, cache_root: Path, rebuild_cache: bool) -> WindowedDataset:
    cache_path = cache_root / f"{dataset}_windows_50hz_128_v3.npz"
    audit_path = cache_root / f"{dataset}_audit.json"
    if cache_path.exists() and audit_path.exists() and not rebuild_cache:
        print(f"[{dataset}] loading cached synchronized windows from {cache_path}", flush=True)
        return load_dataset_cache(cache_path, audit_path)

    raw_root = PHONE_ROOT if dataset == "phone" else WEARABLE_ROOT
    print(f"[{dataset}] auditing and synchronizing raw recordings", flush=True)
    data = build_windowed_dataset(dataset, raw_root, audit_output=audit_path)
    save_dataset_cache(data, cache_path)
    print(f"[{dataset}] cached {len(data.x)} windows at {cache_path}", flush=True)
    return data


def fit_scaler(x_train: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    flat = x_train.reshape(-1, x_train.shape[-1]).astype(np.float64)
    mean = flat.mean(axis=0)
    scale = flat.std(axis=0)
    scale[scale < 1e-8] = 1.0
    return mean.astype(np.float32), scale.astype(np.float32)


def scale_windows(x: np.ndarray, mean: np.ndarray, scale: np.ndarray) -> np.ndarray:
    return ((x - mean) / scale).astype(np.float32)


def build_model(class_count: int) -> tf.keras.Model:
    sensor_window = tf.keras.layers.Input(
        shape=(WINDOW_SIZE, len(FEATURE_NAMES)), name="sensor_window", dtype=tf.float32
    )
    x = tf.keras.layers.GaussianNoise(0.025, name="training_jitter")(sensor_window)
    x = tf.keras.layers.Conv1D(64, 7, padding="same", use_bias=False, name="conv_1")(x)
    x = tf.keras.layers.BatchNormalization(name="bn_1")(x)
    x = tf.keras.layers.Activation("relu", name="relu_1")(x)
    x = tf.keras.layers.MaxPooling1D(2, name="pool_1")(x)

    x = tf.keras.layers.SeparableConv1D(96, 5, padding="same", use_bias=False, name="sepconv_2")(x)
    x = tf.keras.layers.BatchNormalization(name="bn_2")(x)
    x = tf.keras.layers.Activation("relu", name="relu_2")(x)
    x = tf.keras.layers.MaxPooling1D(2, name="pool_2")(x)

    x = tf.keras.layers.SeparableConv1D(128, 3, padding="same", use_bias=False, name="sepconv_3")(x)
    x = tf.keras.layers.BatchNormalization(name="bn_3")(x)
    x = tf.keras.layers.Activation("relu", name="relu_3")(x)

    average = tf.keras.layers.GlobalAveragePooling1D(name="global_average")(x)
    maximum = tf.keras.layers.GlobalMaxPooling1D(name="global_max")(x)
    x = tf.keras.layers.Concatenate(name="temporal_summary")([average, maximum])
    activity_features = tf.keras.layers.Dense(128, activation="relu", name="activity_dense")(x)
    activity_features = tf.keras.layers.Dropout(0.35, name="activity_dropout")(activity_features)
    activity = tf.keras.layers.Dense(class_count, activation="softmax", name="activity")(activity_features)

    # A dedicated fall branch prevents fine-grained activity optimization from
    # weakening the safety-critical binary decision.
    fall_features = tf.keras.layers.Dense(64, activation="relu", name="fall_dense")(x)
    fall_features = tf.keras.layers.Dropout(0.25, name="fall_dropout")(fall_features)
    fall = tf.keras.layers.Dense(1, activation="sigmoid", name="fall")(fall_features)
    return tf.keras.Model(sensor_window, {"activity": activity, "fall": fall}, name="activity_fall_cnn")


def label_ids(labels: np.ndarray, labels_ordered: list[str]) -> np.ndarray:
    lookup = {label: index for index, label in enumerate(labels_ordered)}
    return np.asarray([lookup[str(label)] for label in labels], dtype=np.int32)


def sample_weights(y_activity: np.ndarray, fall_index: int) -> dict[str, np.ndarray]:
    classes = np.unique(y_activity)
    balanced = compute_class_weight(class_weight="balanced", classes=classes, y=y_activity)
    activity_lookup = np.ones(int(np.max(y_activity)) + 1, dtype=np.float32)
    # Full inverse-frequency weighting caused common walking windows to be
    # overwhelmed by short stair/transition classes on unseen subjects. Square-
    # root balancing preserves minority learning without distorting prevalence.
    activity_lookup[classes] = np.clip(np.sqrt(balanced), 0.65, 3.0)
    activity_weights = activity_lookup[y_activity]

    y_fall = (y_activity == fall_index).astype(np.float32)
    positives = max(float(y_fall.sum()), 1.0)
    negatives = max(float(len(y_fall) - y_fall.sum()), 1.0)
    positive_weight = min(np.sqrt(negatives / positives), 5.0)
    fall_weights = np.where(y_fall == 1, positive_weight, 1.0).astype(np.float32)
    return {"activity": activity_weights, "fall": fall_weights}


def compile_model(model: tf.keras.Model) -> None:
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=1e-3),
        loss={
            "activity": tf.keras.losses.SparseCategoricalCrossentropy(),
            "fall": tf.keras.losses.BinaryCrossentropy(),
        },
        loss_weights={"activity": 1.0, "fall": 1.5},
        metrics={
            "activity": [tf.keras.metrics.SparseCategoricalAccuracy(name="accuracy")],
            "fall": [
                tf.keras.metrics.AUC(curve="PR", name="auc_pr"),
                tf.keras.metrics.Precision(name="precision"),
                tf.keras.metrics.Recall(name="recall"),
            ],
        },
    )


def unpack_predictions(predictions: dict | list, class_count: int) -> tuple[np.ndarray, np.ndarray]:
    if isinstance(predictions, dict):
        return np.asarray(predictions["activity"]), np.asarray(predictions["fall"]).reshape(-1)
    outputs = [np.asarray(item) for item in predictions]
    activity = next(item for item in outputs if item.shape[-1] == class_count)
    fall = next(item for item in outputs if item.shape[-1] == 1)
    return activity, fall.reshape(-1)


def choose_fall_threshold(y_true: np.ndarray, probabilities: np.ndarray) -> dict[str, float]:
    precision, recall, thresholds = precision_recall_curve(y_true, probabilities)
    if len(thresholds) == 0:
        return {"threshold": 0.5, "precision": 0.0, "recall": 0.0, "f2": 0.0}
    precision = precision[:-1]
    recall = recall[:-1]
    f1 = 2.0 * precision * recall / np.maximum(precision + recall, 1e-9)
    eligible = np.flatnonzero((recall >= 0.80) & (precision >= 0.80))
    if len(eligible):
        best_f1 = float(np.max(f1[eligible]))
        near_best = eligible[f1[eligible] >= best_f1 - 0.005]
        # Prefer the most conservative threshold whose F1 is effectively tied
        # with the optimum; this reduces nuisance fall prompts on-device.
        best = int(near_best[np.argmax(thresholds[near_best])])
    else:
        best = int(np.argmax(f1))
    return {
        "threshold": float(np.clip(thresholds[best], 0.05, 0.95)),
        "precision": float(precision[best]),
        "recall": float(recall[best]),
        "f1": float(f1[best]),
    }


def simulate_alert_policy(
    y_fall: np.ndarray,
    fall_probabilities: np.ndarray,
    recording_ids: np.ndarray,
    starts_s: np.ndarray,
    threshold: float,
    minimum_positive_windows: int = 2,
    rolling_window_count: int = 3,
    cooldown_seconds: float = 30.0,
) -> dict[str, float | int]:
    grouped: dict[str, list[tuple[float, bool, float]]] = {}
    for actual, probability, recording_id, start_s in zip(
        y_fall, fall_probabilities, recording_ids, starts_s, strict=True
    ):
        grouped.setdefault(str(recording_id), []).append(
            (float(start_s), bool(actual), float(probability))
        )

    fall_events = 0
    detected_fall_events = 0
    false_alerts = 0
    nonfall_hours = 0.0
    for rows in grouped.values():
        rows.sort(key=lambda item: item[0])
        actual_fall = any(item[1] for item in rows)
        if actual_fall:
            fall_events += 1
        else:
            nonfall_hours += (
                rows[-1][0] - rows[0][0] + WINDOW_SIZE / SAMPLING_RATE_HZ
            ) / 3600.0

        history: list[bool] = []
        last_alert_s = -1e12
        detected = False
        for start_s, _, probability in rows:
            history = (history + [probability >= threshold])[-rolling_window_count:]
            if (
                len(history) >= minimum_positive_windows
                and sum(history) >= minimum_positive_windows
                and start_s - last_alert_s >= cooldown_seconds
            ):
                if actual_fall:
                    detected = True
                else:
                    false_alerts += 1
                last_alert_s = start_s
        detected_fall_events += int(detected)

    event_recall = detected_fall_events / fall_events if fall_events else 0.0
    false_alerts_per_hour = false_alerts / nonfall_hours if nonfall_hours else 0.0
    return {
        "threshold": float(threshold),
        "fall_events": fall_events,
        "detected_fall_events": detected_fall_events,
        "fall_event_recall": float(event_recall),
        "false_alerts": false_alerts,
        "nonfall_recording_hours": float(nonfall_hours),
        "false_alerts_per_hour": float(false_alerts_per_hour),
    }


def choose_alert_threshold(
    y_fall: np.ndarray,
    fall_probabilities: np.ndarray,
    recording_ids: np.ndarray,
    starts_s: np.ndarray,
) -> tuple[float, dict]:
    candidates = [
        simulate_alert_policy(y_fall, fall_probabilities, recording_ids, starts_s, float(threshold))
        for threshold in np.arange(0.20, 0.951, 0.025)
    ]
    eligible = [item for item in candidates if item["fall_event_recall"] >= 0.94]
    if not eligible:
        eligible = candidates
    minimum_false_rate = min(item["false_alerts_per_hour"] for item in eligible)
    best_pool = [
        item
        for item in eligible
        if abs(item["false_alerts_per_hour"] - minimum_false_rate) < 1e-9
    ]
    # Event metrics are step-like: many thresholds can produce the same number
    # of detected recordings and false alerts. Prefer the highest threshold in
    # that tied operating region to reduce sensitivity to small probability
    # shifts between devices, without dropping below the required event recall.
    best = max(best_pool, key=lambda item: item["threshold"])
    return float(best["threshold"]), best


def combined_predictions(
    activity_probabilities: np.ndarray,
    fall_probabilities: np.ndarray,
    fall_index: int,
    threshold: float,
) -> np.ndarray:
    nonfall = activity_probabilities.copy()
    nonfall[:, fall_index] = -np.inf
    predicted = np.argmax(nonfall, axis=1)
    predicted[fall_probabilities >= threshold] = fall_index
    return predicted.astype(np.int32)


def evaluate(
    y_activity: np.ndarray,
    activity_probabilities: np.ndarray,
    fall_probabilities: np.ndarray,
    labels_ordered: list[str],
    threshold: float,
) -> tuple[dict, np.ndarray]:
    fall_index = labels_ordered.index("fall")
    y_fall = (y_activity == fall_index).astype(np.int32)
    y_pred = combined_predictions(activity_probabilities, fall_probabilities, fall_index, threshold)
    y_fall_pred = (fall_probabilities >= threshold).astype(np.int32)
    report = classification_report(
        y_activity,
        y_pred,
        labels=list(range(len(labels_ordered))),
        target_names=labels_ordered,
        output_dict=True,
        zero_division=0,
    )
    metrics = {
        "activity_accuracy": float(accuracy_score(y_activity, y_pred)),
        "activity_macro_f1": float(f1_score(y_activity, y_pred, average="macro", zero_division=0)),
        "fall_threshold": float(threshold),
        "fall_precision": float(precision_score(y_fall, y_fall_pred, zero_division=0)),
        "fall_recall": float(recall_score(y_fall, y_fall_pred, zero_division=0)),
        "fall_f1": float(f1_score(y_fall, y_fall_pred, zero_division=0)),
        "classification_report": report,
    }
    matrix = confusion_matrix(y_activity, y_pred, labels=list(range(len(labels_ordered))))
    return metrics, matrix


def save_confusion_matrix(matrix: np.ndarray, labels: list[str], path: Path) -> None:
    size = max(8, int(len(labels) * 0.75))
    fig, ax = plt.subplots(figsize=(size, size))
    image = ax.imshow(matrix, interpolation="nearest", cmap="Blues")
    fig.colorbar(image, ax=ax, fraction=0.046, pad=0.04)
    ax.set(
        xticks=np.arange(len(labels)),
        yticks=np.arange(len(labels)),
        xticklabels=labels,
        yticklabels=labels,
        ylabel="Actual",
        xlabel="Predicted",
        title="Subject-independent test confusion matrix",
    )
    plt.setp(ax.get_xticklabels(), rotation=45, ha="right", rotation_mode="anchor")
    threshold = matrix.max() / 2 if matrix.size else 0
    for row in range(matrix.shape[0]):
        for col in range(matrix.shape[1]):
            ax.text(
                col,
                row,
                str(matrix[row, col]),
                ha="center",
                va="center",
                color="white" if matrix[row, col] > threshold else "black",
                fontsize=8,
            )
    fig.tight_layout()
    fig.savefig(path, dpi=180)
    plt.close(fig)


def export_tflite(model: tf.keras.Model, path: Path) -> bytes:
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]
    flatbuffer = converter.convert()
    path.write_bytes(flatbuffer)
    return flatbuffer


def verify_tflite(
    model: tf.keras.Model,
    tflite_path: Path,
    sample: np.ndarray,
    class_count: int,
) -> dict:
    keras_activity, keras_fall = unpack_predictions(model.predict(sample, verbose=0), class_count)
    interpreter = tf.lite.Interpreter(model_path=str(tflite_path))
    interpreter.allocate_tensors()
    input_info = interpreter.get_input_details()[0]
    output_info = interpreter.get_output_details()
    tflite_outputs: list[np.ndarray] = []
    for item in sample:
        interpreter.set_tensor(input_info["index"], item[np.newaxis].astype(np.float32))
        interpreter.invoke()
        tflite_outputs.append([interpreter.get_tensor(info["index"])[0] for info in output_info])

    by_output = list(zip(*tflite_outputs, strict=True))
    output_arrays = [np.asarray(values) for values in by_output]
    lite_activity = next(item for item in output_arrays if item.shape[-1] == class_count)
    lite_fall = next(item.reshape(-1) for item in output_arrays if item.shape[-1] == 1)
    return {
        "input_shape": input_info["shape"].astype(int).tolist(),
        "input_dtype": str(input_info["dtype"]),
        "outputs": [
            {"index": int(info["index"]), "shape": info["shape"].astype(int).tolist(), "dtype": str(info["dtype"])}
            for info in output_info
        ],
        "max_activity_probability_delta": float(np.max(np.abs(keras_activity - lite_activity))),
        "max_fall_probability_delta": float(np.max(np.abs(keras_fall - lite_fall))),
        "verified_examples": int(len(sample)),
    }


def train_one(
    dataset: str,
    data: WindowedDataset,
    output_root: Path,
    epochs: int,
    batch_size: int,
    seed: int,
) -> dict:
    set_determinism(seed)
    output_dir = output_root / dataset
    output_dir.mkdir(parents=True, exist_ok=True)
    split = make_subject_split(data, dataset=dataset, seed=seed)
    indices = split_indices(data, split)
    y_all = label_ids(data.labels, data.labels_ordered)
    fall_index = data.labels_ordered.index("fall")

    mean, scale = fit_scaler(data.x[indices["train"]])
    x_train = scale_windows(data.x[indices["train"]], mean, scale)
    x_val = scale_windows(data.x[indices["validation"]], mean, scale)
    x_test = scale_windows(data.x[indices["test"]], mean, scale)
    y_train = y_all[indices["train"]]
    y_val = y_all[indices["validation"]]
    y_test = y_all[indices["test"]]

    print(f"[{dataset}] split subjects: {split}", flush=True)
    print(f"[{dataset}] train label counts: {Counter(data.labels[indices['train']])}", flush=True)
    print(f"[{dataset}] validation label counts: {Counter(data.labels[indices['validation']])}", flush=True)
    print(f"[{dataset}] test label counts: {Counter(data.labels[indices['test']])}", flush=True)

    model = build_model(len(data.labels_ordered))
    compile_model(model)
    checkpoint_path = output_dir / "best_model.keras"
    callbacks = [
        tf.keras.callbacks.ModelCheckpoint(
            checkpoint_path,
            monitor="val_loss",
            save_best_only=True,
            verbose=1,
        ),
        tf.keras.callbacks.EarlyStopping(
            monitor="val_loss",
            patience=8,
            restore_best_weights=True,
            verbose=1,
        ),
        tf.keras.callbacks.ReduceLROnPlateau(
            monitor="val_loss",
            factor=0.5,
            patience=4,
            min_lr=1e-5,
            verbose=1,
        ),
    ]
    weights = sample_weights(y_train, fall_index)
    history = model.fit(
        x_train,
        {"activity": y_train, "fall": (y_train == fall_index).astype(np.float32)},
        validation_data=(
            x_val,
            {"activity": y_val, "fall": (y_val == fall_index).astype(np.float32)},
        ),
        sample_weight=weights,
        epochs=epochs,
        batch_size=batch_size,
        callbacks=callbacks,
        verbose=2,
        shuffle=True,
    )

    model = tf.keras.models.load_model(checkpoint_path, compile=False)
    val_activity, val_fall = unpack_predictions(model.predict(x_val, batch_size=batch_size, verbose=0), len(data.labels_ordered))
    threshold_result = choose_fall_threshold((y_val == fall_index).astype(np.int32), val_fall)
    threshold = threshold_result["threshold"]
    alert_threshold, validation_alert_policy = choose_alert_threshold(
        (y_val == fall_index).astype(np.int32),
        val_fall,
        data.recording_ids[indices["validation"]],
        data.starts_s[indices["validation"]],
    )

    test_activity, test_fall = unpack_predictions(model.predict(x_test, batch_size=batch_size, verbose=0), len(data.labels_ordered))
    test_metrics, matrix = evaluate(
        y_test,
        test_activity,
        test_fall,
        data.labels_ordered,
        threshold,
    )
    test_metrics["alert_policy"] = simulate_alert_policy(
        (y_test == fall_index).astype(np.int32),
        test_fall,
        data.recording_ids[indices["test"]],
        data.starts_s[indices["test"]],
        alert_threshold,
    )
    save_confusion_matrix(matrix, data.labels_ordered, output_dir / "confusion_matrix.png")

    tflite_path = output_dir / "activity_fall_model.tflite"
    flatbuffer = export_tflite(model, tflite_path)
    verify_count = min(32, len(x_test))
    verification = verify_tflite(model, tflite_path, x_test[:verify_count], len(data.labels_ordered))

    scaler = {
        "feature_names": FEATURE_NAMES,
        "mean": [float(value) for value in mean],
        "scale": [float(value) for value in scale],
        "formula": "scaled = (raw - mean) / scale",
    }
    (output_dir / "scaler.json").write_text(json.dumps(scaler, indent=2), encoding="utf-8")
    (output_dir / "labels.txt").write_text("\n".join(data.labels_ordered) + "\n", encoding="utf-8")
    (output_dir / "split.json").write_text(json.dumps(split, indent=2), encoding="utf-8")

    result = {
        "dataset": dataset,
        "model_role": "phone/pocket/waist" if dataset == "phone" else "wrist smartwatch",
        "sampling_rate_hz": SAMPLING_RATE_HZ,
        "window_size": WINDOW_SIZE,
        "step_size": STEP_SIZE,
        "window_duration_s": WINDOW_SIZE / SAMPLING_RATE_HZ,
        "step_duration_s": STEP_SIZE / SAMPLING_RATE_HZ,
        "input_shape": [1, WINDOW_SIZE, len(FEATURE_NAMES)],
        "input_dtype": "float32",
        "feature_names": FEATURE_NAMES,
        "labels": data.labels_ordered,
        "fall_label_index": fall_index,
        "fall_threshold": threshold,
        "threshold_selected_on_validation": threshold_result,
        "recommended_alert_policy": {
            "threshold": alert_threshold,
            "minimum_positive_windows": 2,
            "rolling_window_count": 3,
            "user_cancellation_seconds": 15,
            "alert_cooldown_seconds": 30,
            "validation_result": validation_alert_policy,
        },
        "subject_split": split,
        "window_counts": {name: int(len(value)) for name, value in indices.items()},
        "test_metrics": test_metrics,
        "tflite": {
            "file": tflite_path.name,
            "size_bytes": len(flatbuffer),
            "verification": verification,
        },
        "training": {
            "epochs_requested": epochs,
            "epochs_completed": len(history.history["loss"]),
            "batch_size": batch_size,
            "seed": seed,
            "best_validation_loss": float(min(history.history["val_loss"])),
        },
        "limitations": [
            "Use only at the body position represented by this dataset.",
            "Dataset falls are staged; validate on the target Android phone/watch before emergency use.",
            "Activity labels describe the dataset protocol and are not a clinical diagnosis.",
        ],
    }
    (output_dir / "metadata.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(
        f"[{dataset}] test accuracy={test_metrics['activity_accuracy']:.4f}, "
        f"macro_f1={test_metrics['activity_macro_f1']:.4f}, "
        f"fall_precision={test_metrics['fall_precision']:.4f}, "
        f"fall_recall={test_metrics['fall_recall']:.4f}, threshold={threshold:.4f}",
        flush=True,
    )
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train phone and wearable activity/fall models.")
    parser.add_argument("--dataset", choices=["phone", "wearable", "both"], default="both")
    parser.add_argument("--epochs", type=int, default=45)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE_ROOT)
    parser.add_argument("--rebuild-cache", action="store_true")
    parser.add_argument("--audit-only", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    requested = ["phone", "wearable"] if args.dataset == "both" else [args.dataset]
    datasets = {
        name: get_dataset(name, args.cache_root, args.rebuild_cache)
        for name in requested
    }
    for name, data in datasets.items():
        print(f"[{name}] windows={data.x.shape}, labels={Counter(data.labels)}, subjects={len(set(data.subjects))}")
    if args.audit_only:
        return

    args.output_root.mkdir(parents=True, exist_ok=True)
    results = {
        name: train_one(
            name,
            data,
            output_root=args.output_root,
            epochs=args.epochs,
            batch_size=args.batch_size,
            seed=args.seed,
        )
        for name, data in datasets.items()
    }
    (args.output_root / "training_summary.json").write_text(json.dumps(results, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
