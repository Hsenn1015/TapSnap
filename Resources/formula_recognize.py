"""One-shot local formula recognition. Inputs and outputs never use the network."""
import contextlib
import json
import os
from pathlib import Path
import socket
import sys

os.environ['NO_ALBUMENTATIONS_UPDATE'] = '1'
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['TOKENIZERS_PARALLELISM'] = 'false'

# The installer downloads checkpoints separately; inference must work offline.
def no_network(*args, **kwargs):
    raise RuntimeError('Formula recognition has no network access')
socket.socket.connect = no_network
socket.create_connection = no_network


class FormulaSetupError(Exception):
    pass


try:
    with contextlib.redirect_stdout(sys.stderr):
        try:
            from verify_formula_models import verify_models
            verify_models(Path(__file__).with_name('formula-models.json'))
            import torch
            from PIL import Image
            from pix2tex.cli import LatexOCR
        except (ImportError, OSError, ValueError, RuntimeError) as error:
            raise FormulaSetupError(str(error)) from error
        torch.set_num_threads(min(4, os.cpu_count() or 1))
        model = LatexOCR()
        with Image.open(sys.argv[1]) as image:
            latex = model(image.convert('RGB'))
    print(json.dumps({'latex': latex}, ensure_ascii=False), flush=True)
except Exception as error:
    print(json.dumps({'error': str(error), 'needsInstallation': isinstance(error, FormulaSetupError)},
                     ensure_ascii=False), flush=True)
    sys.exit(1)
