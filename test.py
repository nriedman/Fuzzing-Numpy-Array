import atheris

with atheris.instrument_imports():
    import numpy as np
    import sys



def TestOneInput(data):
    fdp = atheris.FuzzedDataProvider(data)

    a = None
    b = None

    for i in range(10):  # todo: vary loop size
        legal_operations = [
            "init_a",
            "init_b"
        ]
        if a is not None:
            legal_operations.append("inc_a")

        inst = fdp.PickValueInList(legal_operations)

        if inst == "init_a":
            a = np.array(fdp.ConsumeIntList(10, 2))
            a_initialized = True
        elif inst == "init_b":
            b = np.array(fdp.ConsumeIntList(10, 2))
            b_initialized = True
        elif inst == "inc_a":
            a += a

        return True


atheris.Setup(sys.argv, TestOneInput)
atheris.Fuzz()
