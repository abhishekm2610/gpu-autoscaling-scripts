#!/usr/bin/env python3
import os
import sys

print("Python version:", sys.version)
print("Working directory:", os.getcwd())

try:
    import pandas as pd
    print("Pandas version:", pd.__version__)
except ImportError:
    print("Pandas not installed")

try:
    import matplotlib
    print("Matplotlib version:", matplotlib.__version__)
except ImportError:
    print("Matplotlib not installed")

try:
    import numpy as np
    print("NumPy version:", np.__version__)
except ImportError:
    print("NumPy not installed")

try:
    import seaborn as sns
    print("Seaborn version:", sns.__version__)
except ImportError:
    print("Seaborn not installed")

# Try to list experiment directories
print("\nLooking for experiment directories:")
exp_dirs = [d for d in os.listdir('.') if d.startswith('out_')]
for d in exp_dirs:
    print(f"- {d}")

if exp_dirs:
    latest_dir = max(exp_dirs, key=os.path.getmtime)
    print(f"\nLatest experiment directory: {latest_dir}")

    # Check request file
    req_file = os.path.join(latest_dir, 'HPA_ON_requests.csv')
    if os.path.exists(req_file):
        print(f"Found request file: {req_file}")
        print(f"File size: {os.path.getsize(req_file)} bytes")

        # Try to read first few lines
        try:
            with open(req_file, 'r') as f:
                print("\nFirst 5 lines of request file:")
                for i, line in enumerate(f):
                    if i < 5:
                        print(line.strip())
                    else:
                        break
        except Exception as e:
            print(f"Error reading file: {e}")
    else:
        print(f"Request file not found: {req_file}")
