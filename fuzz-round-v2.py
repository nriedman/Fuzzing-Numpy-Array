import atheris
import sys

with atheris.instrument_imports():
    import numpy as np

def TestOneInput(data):
    fdp = atheris.FuzzedDataProvider(data)

    try:
        list_size = fdp.ConsumeIntInRange(0, 5)
        decimals  = fdp.ConsumeIntInRange(-100, 100)
        dtype_choice = fdp.ConsumeIntInRange(0, 3)

        if dtype_choice == 0:
            arr = np.array([fdp.ConsumeFloat() for _ in range(list_size)],
                           dtype=np.float64)
        elif dtype_choice == 1:
            arr = np.array([fdp.ConsumeFloat() for _ in range(list_size)],
                           dtype=np.float32)
        elif dtype_choice == 2:
            # integer array — PyArray_ISINTEGER branch
            arr = np.array([fdp.ConsumeInt(4) for _ in range(list_size)],
                           dtype=np.int64)
        else:
            # complex array — PyArray_ISCOMPLEX branch
            arr = np.array(
                [complex(fdp.ConsumeFloat(), fdp.ConsumeFloat())
                 for _ in range(list_size)],
                dtype=np.complex128)

        np.round(arr, decimals)

    except Exception:
        pass

atheris.Setup(sys.argv, TestOneInput)
atheris.Fuzz()
