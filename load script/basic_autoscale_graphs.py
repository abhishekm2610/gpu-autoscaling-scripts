#!/usr/bin/env python3
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
from datetime import datetime
import os
import glob
import sys

def parse_iso_time(time_str):
    """Parse ISO timestamp with nanoseconds to datetime"""
    if pd.isna(time_str):
        return None
    # Handle the format with nanoseconds
    try:
        # Remove nanoseconds part and timezone
        cleaned = time_str.split('+')[0].split(',')[0]
        return datetime.fromisoformat(cleaned)
    except (ValueError, AttributeError):
        return None

def basic_plots(experiment_dir, output_dir):
    """Generate basic plots from experiment data"""
    os.makedirs(output_dir, exist_ok=True)

    # Find request CSV
    req_files = glob.glob(os.path.join(experiment_dir, '*_requests.csv'))
    if not req_files:
        print(f"No request files found in {experiment_dir}")
        return

    req_file = req_files[0]
    label = os.path.basename(req_file).replace('_requests.csv', '')
    print(f"Processing {label} from {req_file}")

    # Find replica CSV
    replica_file = os.path.join(experiment_dir, f"{label}_replicas.csv")
    if not os.path.exists(replica_file):
        print(f"No replica file found at {replica_file}")
        has_replicas = False
    else:
        has_replicas = True

    # Load request data
    try:
        df_req = pd.read_csv(req_file)
        df_req['start_time'] = df_req['start_iso'].apply(parse_iso_time)
        df_req['end_time'] = df_req['end_iso'].apply(parse_iso_time)

        # Calculate relative times
        if not df_req.empty and df_req['start_time'].notna().any():
            experiment_start = df_req['start_time'].min()
            df_req['start_time_rel'] = (df_req['start_time'] - experiment_start).dt.total_seconds()
            df_req['end_time_rel'] = (df_req['end_time'] - experiment_start).dt.total_seconds()

        print(f"Loaded {len(df_req)} requests")
    except Exception as e:
        print(f"Error loading request data: {e}")
        return

    # Load replica data if available
    if has_replicas:
        try:
            df_rep = pd.read_csv(replica_file)
            df_rep['time'] = df_rep['timestamp'].apply(parse_iso_time)

            if not df_rep.empty and df_rep['time'].notna().any():
                if 'experiment_start' not in locals():
                    experiment_start = df_rep['time'].min()
                df_rep['time_rel'] = (df_rep['time'] - experiment_start).dt.total_seconds()

            print(f"Loaded {len(df_rep)} replica data points")
        except Exception as e:
            print(f"Error loading replica data: {e}")
            has_replicas = False

    # 1. Basic Latency Plot
    try:
        plt.figure(figsize=(10, 6))
        success_reqs = df_req[df_req['http_code'] == 200]
        failed_reqs = df_req[df_req['http_code'] != 200]

        if len(success_reqs) > 0:
            plt.scatter(success_reqs['start_time_rel'], success_reqs['latency_ms']/1000,
                      alpha=0.5, color='green', label='Successful Requests')

        if len(failed_reqs) > 0:
            plt.scatter(failed_reqs['start_time_rel'], failed_reqs['latency_ms']/1000,
                      alpha=0.5, color='red', label='Failed Requests')

        plt.xlabel('Time (seconds)')
        plt.ylabel('Latency (seconds)')
        plt.title(f'Request Latency Over Time ({label})')
        plt.legend()
        plt.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(os.path.join(output_dir, f"{label}_latency.png"), dpi=300)
        print(f"Created latency plot at {os.path.join(output_dir, f'{label}_latency.png')}")
    except Exception as e:
        print(f"Error creating latency plot: {e}")

    # 2. Replicas plot if available
    if has_replicas:
        try:
            plt.figure(figsize=(10, 6))
            plt.step(df_rep['time_rel'], df_rep['availableReplicas'],
                    color='blue', linewidth=2, where='post', label='Available Replicas')

            # Calculate in-flight requests
            window_size = 5  # seconds
            max_time = max(df_req['end_time_rel'].max(), df_rep['time_rel'].max())
            times = np.linspace(0, max_time, 500)
            in_flight = []

            for t in times:
                count = ((df_req['start_time_rel'] <= t) & (df_req['end_time_rel'] >= t)).sum()
                in_flight.append(count)

            plt.plot(times, in_flight, color='purple', linestyle='--', label='In-flight Requests')

            plt.xlabel('Time (seconds)')
            plt.ylabel('Count')
            plt.title(f'Replicas and In-flight Requests ({label})')
            plt.legend()
            plt.grid(True, alpha=0.3)
            plt.tight_layout()
            plt.savefig(os.path.join(output_dir, f"{label}_replicas.png"), dpi=300)
            print(f"Created replicas plot at {os.path.join(output_dir, f'{label}_replicas.png')}")
        except Exception as e:
            print(f"Error creating replicas plot: {e}")

    # 3. Latency histogram
    try:
        plt.figure(figsize=(10, 6))
        success_reqs = df_req[df_req['http_code'] == 200]

        if len(success_reqs) > 0:
            # Convert to seconds for better readability
            latencies = success_reqs['latency_ms'] / 1000

            # Plot histogram
            plt.hist(latencies, bins=30, alpha=0.7, color='blue')

            # Add percentile lines
            percentiles = [50, 90, 95, 99]
            percentile_values = np.percentile(latencies, percentiles)

            for p, pv in zip(percentiles, percentile_values):
                plt.axvline(pv, color='red', linestyle='--',
                          label=f'p{p}: {pv:.2f}s')

            # Add mean line
            mean_latency = latencies.mean()
            plt.axvline(mean_latency, color='green', linestyle='-',
                      linewidth=2, label=f'Mean: {mean_latency:.2f}s')

            plt.xlabel('Latency (seconds)')
            plt.ylabel('Count')
            plt.title(f'Latency Distribution ({label})')

            # Calculate success rate
            success_rate = len(success_reqs) / len(df_req) * 100

            # Add summary statistics as text
            stats_text = (f"Success rate: {success_rate:.1f}%\n"
                         f"Mean latency: {mean_latency:.2f}s\n"
                         f"Median (p50): {percentile_values[0]:.2f}s\n"
                         f"p90: {percentile_values[1]:.2f}s\n"
                         f"p95: {percentile_values[2]:.2f}s\n"
                         f"p99: {percentile_values[3]:.2f}s")

            plt.text(0.95, 0.95, stats_text, transform=plt.gca().transAxes,
                    verticalalignment='top', horizontalalignment='right',
                    bbox=dict(boxstyle='round', facecolor='white', alpha=0.8))

            plt.legend()
            plt.grid(True, alpha=0.3)
            plt.tight_layout()
            plt.savefig(os.path.join(output_dir, f"{label}_latency_dist.png"), dpi=300)
            print(f"Created latency distribution plot at {os.path.join(output_dir, f'{label}_latency_dist.png')}")
        else:
            print("No successful requests to plot latency distribution")
    except Exception as e:
        print(f"Error creating latency distribution plot: {e}")

    # 4. Throughput over time
    try:
        plt.figure(figsize=(10, 6))

        # Calculate completed requests per time window
        window_size = 5  # seconds
        max_time = df_req['end_time_rel'].max()
        windows = np.arange(0, max_time + window_size, window_size)
        completions = []
        failures = []

        for i in range(len(windows)-1):
            start, end = windows[i], windows[i+1]
            # Count completed requests in this window
            completed = ((df_req['end_time_rel'] >= start) &
                        (df_req['end_time_rel'] < end) &
                        (df_req['http_code'] == 200)).sum()
            failed = ((df_req['end_time_rel'] >= start) &
                      (df_req['end_time_rel'] < end) &
                      (df_req['http_code'] != 200)).sum()
            completions.append(completed)
            failures.append(failed)

        window_centers = windows[:-1] + window_size/2

        # Plot completions and failures as stacked bars
        plt.bar(window_centers, completions, width=window_size*0.9,
               color='green', alpha=0.7, label='Completed Requests')
        plt.bar(window_centers, failures, width=window_size*0.9,
               bottom=completions, color='red', alpha=0.7, label='Failed Requests')

        plt.xlabel('Time (seconds)')
        plt.ylabel('Requests per Window')
        plt.title(f'Throughput Over Time ({label})')
        plt.legend()
        plt.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(os.path.join(output_dir, f"{label}_throughput.png"), dpi=300)
        print(f"Created throughput plot at {os.path.join(output_dir, f'{label}_throughput.png')}")
    except Exception as e:
        print(f"Error creating throughput plot: {e}")

    print("All plots generated successfully!")

if __name__ == "__main__":
    # Find the latest experiment directory if not specified
    exp_dirs = glob.glob('out_*')
    if not exp_dirs:
        print("No experiment directories found.")
        sys.exit(1)

    latest_dir = max(exp_dirs, key=os.path.getmtime)
    print(f"Using latest experiment directory: {latest_dir}")

    # Create output directory
    output_dir = os.path.join(latest_dir, 'graphs')

    # Generate plots
    basic_plots(latest_dir, output_dir)
