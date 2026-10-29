#!/usr/bin/env python3
"""Convert GantMan/nsfw_model (MIT) MobileNetV2 1.4 to a Core ML classifier.

Usage: convert_nsfw_model.py <extracted model dir> <output.mlmodel>

The model takes a 224x224 RGB image scaled to 0..1 and returns five classes:
drawings, hentai, neutral, porn, sexy. Weights are stored as float16.
"""

import sys
import traceback
from pathlib import Path

import coremltools as ct
import tensorflow as tf
import tensorflow_hub as hub
from coremltools.models.neural_network import quantization_utils

LABELS = ["drawings", "hentai", "neutral", "porn", "sexy"]


def load(model_dir):
    attempts = [
        ("h5", lambda: tf.keras.models.load_model(
            str(model_dir / "saved_model.h5"),
            custom_objects={"KerasLayer": hub.KerasLayer}, compile=False)),
        ("saved_model", lambda: tf.keras.models.load_model(
            str(model_dir), custom_objects={"KerasLayer": hub.KerasLayer}, compile=False)),
    ]
    for name, fn in attempts:
        try:
            model = fn()
            print("loaded via", name)
            return model
        except Exception:
            print("load via", name, "failed:")
            traceback.print_exc()
    raise SystemExit("could not load the model")


def main():
    model_dir, out = Path(sys.argv[1]), sys.argv[2]
    model = load(model_dir)
    model.summary()

    mlmodel = ct.convert(
        model,
        source="tensorflow",
        convert_to="neuralnetwork",
        inputs=[ct.ImageType(name="image", shape=(1, 224, 224, 3), scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        classifier_config=ct.ClassifierConfig(LABELS),
    )
    mlmodel = quantization_utils.quantize_weights(mlmodel, nbits=16)
    mlmodel.short_description = "GantMan/nsfw_model MobileNetV2 1.4 (MIT)"
    mlmodel.save(out)
    print("saved", out, Path(out).stat().st_size, "bytes")


if __name__ == "__main__":
    main()
