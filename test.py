import atheris

with atheris.instrument_imports():
    import numpy as np
    import sys

def TestOneInput(data):
    np.ndarray([3])

atheris.Setup(sys.argv, TestOneInput)
atheris.Fuzz()
