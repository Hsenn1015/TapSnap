import hashlib
import json
import pathlib
import pix2tex
import sys


def verify_models(manifest):
    root = pathlib.Path(pix2tex.__file__).parent / 'model' / 'checkpoints'
    for name, expected in json.loads(pathlib.Path(manifest).read_text()).items():
        with (root / name).open('rb') as checkpoint:
            if hashlib.file_digest(checkpoint, 'sha256').hexdigest() != expected:
                raise RuntimeError('Formula model checksum mismatch: ' + name)


if __name__ == '__main__':
    verify_models(sys.argv[1])
    print('MODEL_CHECKSUMS_OK')
