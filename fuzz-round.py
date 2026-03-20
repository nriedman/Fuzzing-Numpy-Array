import atheris

with atheris.instrument_imports():
    import numpy as np
    import sys

def TestOneInput(data):
    fdp = atheris.FuzzedDataProvider(data)

    try:
        list_size = fdp.ConsumeIntInRange(0, 5)
        arr = np.array([fdp.ConsumeFloat() for _ in range(list_size)])
        # arr = np.array([12345, 2.3456, 3.4567])
        np.round(arr, fdp.ConsumeIntInRange(-2147483648, 2147483647))
        # np.round(arr, -2147483648)
    except Exception as e:
        print("Caught exception:", e)

atheris.Setup(sys.argv, TestOneInput)
atheris.Fuzz()
