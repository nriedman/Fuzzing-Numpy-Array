# Fuzzing Numpy Array

## Setup

It is recommended to install necessary dependencies using a Python `venv`:

```
python3 -m venv .venv & source .venv/bin/activate
```

Once in an environment where packages can be installed, use `requirements.txt` to install the necessary dependencies:

```
pip3 install -r requirements.txt
```

## Usage

See [Using Atheris](https://github.com/google/atheris?tab=readme-ov-file#using-atheris) and [Visualizing Python Coverage](https://github.com/google/atheris?tab=readme-ov-file#visualizing-python-code-coverage) for exmamples of how to write and run fuzzing engines using Atheris. A trivial example can be found here in `test.py`.
