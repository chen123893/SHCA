from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
import tensorflow as tf


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEPLOYMENT_ROOT = PROJECT_ROOT / "saved_model" / "deployment"


def verify_target(target: str) -> dict:
    root = DEPLOYMENT_ROOT / target
    metadata = json.loads((root / "metadata.json").read_text(encoding="utf-8"))
    scaler = json.loads((root / "scaler.json").read_text(encoding="utf-8"))
    model_path = root / "activity_fall_model.tflite"

    assert metadata["input_shape"] == [1, 128, 8]
    assert metadata["sampling_rate_hz"] == 50
    assert len(scaler["mean"]) == len(scaler["scale"]) == 8
    assert np.all(np.asarray(scaler["scale"], dtype=np.float32) > 0)

    interpreter = tf.lite.Interpreter(model_path=str(model_path))
    interpreter.allocate_tensors()
    inputs = interpreter.get_input_details()
    outputs = interpreter.get_output_details()
    assert len(inputs) == 1
    assert inputs[0]["shape"].tolist() == [1, 128, 8]
    assert inputs[0]["dtype"] == np.float32
    output_shapes = {tuple(output["shape"].tolist()) for output in outputs}
    assert (1, len(metadata["labels"])) in output_shapes
    assert (1, 1) in output_shapes

    interpreter.set_tensor(inputs[0]["index"], np.zeros((1, 128, 8), np.float32))
    interpreter.invoke()
    for output in outputs:
        assert np.all(np.isfinite(interpreter.get_tensor(output["index"])))

    return {
        "target": target,
        "model_bytes": model_path.stat().st_size,
        "sha256": hashlib.sha256(model_path.read_bytes()).hexdigest(),
        "input_shape": inputs[0]["shape"].tolist(),
        "output_shapes": [output["shape"].tolist() for output in outputs],
        "labels": metadata["labels"],
        "fall_threshold": metadata["fall_threshold"],
        "alert_threshold": metadata["recommended_alert_policy"]["threshold"],
    }


if __name__ == "__main__":
    print(json.dumps([verify_target(target) for target in ("phone", "wearable")], indent=2))
