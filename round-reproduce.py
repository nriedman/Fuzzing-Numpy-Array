import numpy as np

try:
    arr = np.array([12345, 2.3456, 3.4567])
    np.round(arr, -2147483648)
except Exception as e:
    print("Caught exception:", e)