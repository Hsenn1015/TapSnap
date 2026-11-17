"""Run the existing pix2tex model offline using Windows image bytes from stdin."""
import contextlib
import io
import json
import os
import socket
import sys

os.environ["NO_ALBUMENTATIONS_UPDATE"] = "1"
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"


def no_network(*args, **kwargs):
    raise RuntimeError("Formula recognition has no network access")


socket.socket.connect = no_network
socket.socket.connect_ex = no_network
socket.create_connection = no_network

try:
    with contextlib.redirect_stdout(sys.stderr):
        import torch
        from PIL import Image
        from pix2tex.cli import LatexOCR

        torch.set_num_threads(min(4, os.cpu_count() or 1))
        with Image.open(io.BytesIO(sys.stdin.buffer.read())) as image:
            latex = LatexOCR()(image.convert("RGB"))
    print(json.dumps({"latex": latex}, ensure_ascii=False), flush=True)
except Exception:
    print(json.dumps({"error": "Local formula recognition failed"}), flush=True)
    sys.exit(1)
