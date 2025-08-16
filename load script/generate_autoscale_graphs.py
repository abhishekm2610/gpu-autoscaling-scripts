#!/usr/bin/env python3
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns
import os
import glob
from datetime import datetime
import matplotlib.dates as mdates
from matplotlib.ticker import MaxNLocator
import argparse

# Set style for publication-quality graphs
plt.style.use('seaborn-v0_8-whitegrid')
sns.set_context("paper", font_scale=1.2)
colors = sns.color_palette("muted")

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

def load_data(experiment_dir):
    """Load all data files from an experiment directory"""
    results = {}

    # Find all request CSVs
    req_files = glob.glob(os.path.join(experiment_dir, '*_requests.csv'))
    for file in req_files:
        label = os.path.basename(file).replace('_requests.csv', '')

        # Load requests data
        df_req = pd.read_csv(file)
        # Convert timestamps to datetime
        df_req['start_time'] = df_req['start_iso'].apply(parse_iso_time)
        df_req['end_time'] = df_req['end_iso'].apply(parse_iso_time)

        # Calculate relative times from experiment start
        if not df_req.empty and df_req['start_time'].notna().any():
            experiment_start = df_req['start_time'].min()
            df_req['start_time_rel'] = (df_req['start_time'] - experiment_start).dt.total_seconds()
            df_req['end_time_rel'] = (df_req['end_time'] - experiment_start).dt.total_seconds()

        # Load corresponding replicas data if available
        replicas_file = os.path.join(experiment_dir, f"{label}_replicas.csv")
        if os.path.exists(replicas_file):
            df_rep = pd.read_csv(replicas_file)
            df_rep['time'] = df_rep['timestamp'].apply(parse_iso_time)

            # Calculate relative times for replicas too
            if not df_rep.empty and df_rep['time'].notna().any():
                if 'experiment_start' not in locals():
                    experiment_start = df_rep['time'].min()
                df_rep['time_rel'] = (df_rep['time'] - experiment_start).dt.total_seconds()

            results[label] = {'requests': df_req, 'replicas': df_rep}
        else:
            results[label] = {'requests': df_req}

    return results

def plot_latency_vs_time(data, output_dir):
    """Plot request latency over time with replicas overlay"""
    for label, dfs in data.items():
        fig, ax1 = plt.subplots(figsize=(10, 6))

        # Plot latency points
        df_req = dfs['requests']
        success_reqs = df_req[df_req['http_code'] == 200]
        failed_reqs = df_req[df_req['http_code'] != 200]

        # Plot successful requests as green, failed as red
        ax1.scatter(success_reqs['start_time_rel'], success_reqs['latency_ms']/1000,
                   alpha=0.5, color='green', label='Successful Requests')
        ax1.scatter(failed_reqs['start_time_rel'], failed_reqs['latency_ms']/1000,
                   alpha=0.5, color='red', label='Failed Requests')

        ax1.set_xlabel('Time (seconds)')
        ax1.set_ylabel('Latency (seconds)')
        ax1.set_title(f'Request Latency Over Time ({label})')

        # Add replica count on secondary y-axis if available
        if 'replicas' in dfs:
            ax2 = ax1.twinx()
            df_rep = dfs['replicas']
            ax2.step(df_rep['time_rel'], df_rep['availableReplicas'],
                    color='blue', linewidth=2, where='post', label='Available Replicas')

            # Calculate moving average of in-flight requests
            window_size = 5  # seconds
            times = np.linspace(0, max(df_req['end_time_rel'].max(), df_rep['time_rel'].max()), 1000)
            in_flight = []

            for t in times:
                count = ((df_req['start_time_rel'] <= t) & (df_req['end_time_rel'] >= t)).sum()
                in_flight.append(count)

            ax3 = ax1.twinx()
            ax3.spines['right'].set_position(('outward', 60))
            ax3.plot(times, in_flight, color='purple', linestyle='--', label='In-flight Requests')
            ax3.set_ylabel('In-flight Requests')
            ax3.yaxis.label.set_color('purple')

            ax2.set_ylabel('Number of Replicas')
            ax2.yaxis.label.set_color('blue')

            # Combine legends
            lines1, labels1 = ax1.get_legend_handles_labels()
            lines2, labels2 = ax2.get_legend_handles_labels()
            lines3, labels3 = ax3.get_legend_handles_labels()
            ax1.legend(lines1 + lines2 + lines3, labels1 + labels2 + labels3, loc='upper left')
        else:
            ax1.legend(loc='upper left')

        # Save the figure
        plt.tight_layout()
        plt.savefig(os.path.join(output_dir, f"{label}_latency_time.png"), dpi=300)
        plt.savefig(os.path.join(output_dir, f"{label}_latency_time.pdf"))
        plt.close()

def plot_replicas_vs_load(data, output_dir):
    """Plot the number of replicas against load over time"""
    for label, dfs in data.items():
        if 'replicas' in dfs:
            fig, ax = plt.subplots(figsize=(10, 6))

            df_req = dfs['requests']
            df_rep = dfs['replicas']

            # Calculate time windows and count requests in each window
            window_size = 5  # seconds
            max_time = max(df_req['end_time_rel'].max(), df_rep['time_rel'].max())
            windows = np.arange(0, max_time + window_size, window_size)
            request_counts = []

            for i in range(len(windows)-1):
                start, end = windows[i], windows[i+1]
                # Count requests that were active in this window
                count = ((df_req['start_time_rel'] <= end) &
                         (df_req['end_time_rel'] >= start)).sum()
                request_counts.append(count)

            window_centers = windows[:-1] + window_size/2

            # Plot request load
            ax.bar(window_centers, request_counts, width=window_size*0.9,
                   alpha=0.5, color='gray', label='Active Requests')

            # Plot replicas as a step function
            ax2 = ax.twinx()
            ax2.step(df_rep['time_rel'], df_rep['availableReplicas'],
                    color='blue', linewidth=2.5, where='post', label='Replicas')

            # Calculate and plot average latency per window
            latencies = []
            for i in range(len(windows)-1):
                start, end = windows[i], windows[i+1]
                window_reqs = df_req[(df_req['start_time_rel'] >= start) &
                                     (df_req['start_time_rel'] < end) &
                                     (df_req['http_code'] == 200)]
                if len(window_reqs) > 0:
                    latencies.append(window_reqs['latency_ms'].mean() / 1000)  # Convert to seconds
                else:
                    latencies.append(np.nan)

            ax3 = ax.twinx()
            ax3.spines['right'].set_position(('outward', 60))
            ax3.plot(window_centers, latencies, color='red', linestyle='-',
                    marker='o', label='Avg Latency')
            ax3.set_ylabel('Latency (seconds)')
            ax3.yaxis.label.set_color('red')

            ax.set_xlabel('Time (seconds)')
            ax.set_ylabel('Number of Active Requests')
            ax2.set_ylabel('Number of Replicas')
            ax2.yaxis.label.set_color('blue')

            # Combine legends
            lines1, labels1 = ax.get_legend_handles_labels()
            lines2, labels2 = ax2.get_legend_handles_labels()
            lines3, labels3 = ax3.get_legend_handles_labels()
            ax.legend(lines1 + lines2 + lines3, labels1 + labels2 + labels3, loc='upper left')

            plt.title(f'Replicas vs Load Over Time ({label})')
            plt.tight_layout()
            plt.savefig(os.path.join(output_dir, f"{label}_replicas_load.png"), dpi=300)
            plt.savefig(os.path.join(output_dir, f"{label}_replicas_load.pdf"))
            plt.close()

def plot_throughput_analysis(data, output_dir):
    """Plot throughput and capacity utilization over time"""
    for label, dfs in data.items():
        fig, ax = plt.subplots(figsize=(10, 6))

        df_req = dfs['requests']

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
        ax.bar(window_centers, completions, width=window_size*0.9,
               color='green', alpha=0.7, label='Completed Requests')
        ax.bar(window_centers, failures, width=window_size*0.9,
               bottom=completions, color='red', alpha=0.7, label='Failed Requests')

        # If replica data available, calculate theoretical capacity
        if 'replicas' in dfs:
            df_rep = dfs['replicas']

            # Estimate capacity based on average completion rate per replica
            # First, find periods with stable replica counts
            stable_periods = []
            if len(df_rep) > 1:
                current_replicas = df_rep.iloc[0]['availableReplicas']
                period_start = df_rep.iloc[0]['time_rel']

                for i in range(1, len(df_rep)):
                    if df_rep.iloc[i]['availableReplicas'] != current_replicas:
                        if df_rep.iloc[i]['time_rel'] - period_start >= 15:  # At least 15 seconds of stability
                            stable_periods.append({
                                'replicas': current_replicas,
                                'start': period_start,
                                'end': df_rep.iloc[i]['time_rel']
                            })
                        current_replicas = df_rep.iloc[i]['availableReplicas']
                        period_start = df_rep.iloc[i]['time_rel']

            # Calculate average throughput during stable periods
            throughputs = []
            for period in stable_periods:
                period_reqs = df_req[(df_req['end_time_rel'] >= period['start']) &
                                     (df_req['end_time_rel'] <= period['end']) &
                                     (df_req['http_code'] == 200)]
                if len(period_reqs) > 0:
                    duration = period['end'] - period['start']
                    throughput = len(period_reqs) / duration * period['replicas']
                    throughputs.append(throughput)

            # Use median throughput per replica if available
            if throughputs:
                capacity_per_replica = np.median(throughputs)
            else:
                # Fallback: just use overall average
                total_success = (df_req['http_code'] == 200).sum()
                total_time = df_req['end_time_rel'].max() - df_req['start_time_rel'].min()
                capacity_per_replica = total_success / total_time

            # Calculate theoretical capacity at each time point
            theoretical_capacity = []
            for t in window_centers:
                # Find closest replica count
                closest_idx = np.argmin(np.abs(df_rep['time_rel'] - t))
                replicas = df_rep.iloc[closest_idx]['availableReplicas']
                capacity = replicas * capacity_per_replica * window_size
                theoretical_capacity.append(capacity)

            # Plot theoretical capacity line
            ax2 = ax.twinx()
            ax2.plot(window_centers, theoretical_capacity, color='blue',
                    linestyle='--', linewidth=2, label=f'Theoretical Capacity')

            # Plot utilization as line
            utilization = [min(c/max(t, 1), 1) * 100 for c, t in zip(completions, theoretical_capacity)]
            ax3 = ax.twinx()
            ax3.spines['right'].set_position(('outward', 60))
            ax3.plot(window_centers, utilization, color='purple', marker='o',
                    label='Utilization (%)')
            ax3.set_ylim(0, 110)
            ax3.set_ylabel('Utilization (%)')
            ax3.yaxis.label.set_color('purple')

            ax2.set_ylabel('Theoretical Capacity (reqs)')
            ax2.yaxis.label.set_color('blue')

            # Combine legends
            lines1, labels1 = ax.get_legend_handles_labels()
            lines2, labels2 = ax2.get_legend_handles_labels()
            lines3, labels3 = ax3.get_legend_handles_labels()
            ax.legend(lines1 + lines2 + lines3, labels1 + labels2 + labels3, loc='upper left')
        else:
            ax.legend(loc='upper left')

        ax.set_xlabel('Time (seconds)')
        ax.set_ylabel('Requests per Window')
        plt.title(f'Throughput Analysis ({label})')
        plt.tight_layout()
        plt.savefig(os.path.join(output_dir, f"{label}_throughput.png"), dpi=300)
        plt.savefig(os.path.join(output_dir, f"{label}_throughput.pdf"))
        plt.close()

def plot_latency_distribution(data, output_dir):
    """Plot latency distribution with percentiles"""
    for label, dfs in data.items():
        fig, ax = plt.subplots(figsize=(10, 6))

        df_req = dfs['requests']
        success_reqs = df_req[df_req['http_code'] == 200]

        if len(success_reqs) > 0:
            # Convert to seconds for better readability
            latencies = success_reqs['latency_ms'] / 1000

            # Plot histogram with KDE
            sns.histplot(latencies, kde=True, stat='density', alpha=0.6, ax=ax)

            # Add percentile lines
            percentiles = [50, 90, 95, 99]
            percentile_values = np.percentile(latencies, percentiles)

            for p, pv in zip(percentiles, percentile_values):
                ax.axvline(pv, color='red', linestyle='--',
                          label=f'p{p}: {pv:.2f}s')

            # Add mean line
            mean_latency = latencies.mean()
            ax.axvline(mean_latency, color='green', linestyle='-',
                      linewidth=2, label=f'Mean: {mean_latency:.2f}s')

            ax.set_xlabel('Latency (seconds)')
            ax.set_ylabel('Density')
            ax.set_title(f'Latency Distribution ({label})')

            # Calculate success rate
            success_rate = len(success_reqs) / len(df_req) * 100

            # Add summary statistics as text
            stats_text = (f"Success rate: {success_rate:.1f}%\n"
                         f"Mean latency: {mean_latency:.2f}s\n"
                         f"Median (p50): {percentile_values[0]:.2f}s\n"
                         f"p90: {percentile_values[1]:.2f}s\n"
                         f"p95: {percentile_values[2]:.2f}s\n"
                         f"p99: {percentile_values[3]:.2f}s")

            plt.text(0.95, 0.95, stats_text, transform=ax.transAxes,
                    verticalalignment='top', horizontalalignment='right',
                    bbox=dict(boxstyle='round', facecolor='white', alpha=0.8))

            ax.legend(loc='upper right')

            plt.tight_layout()
            plt.savefig(os.path.join(output_dir, f"{label}_latency_dist.png"), dpi=300)
            plt.savefig(os.path.join(output_dir, f"{label}_latency_dist.pdf"))
            plt.close()

def plot_scaling_efficiency(data, output_dir):
    """Plot scaling efficiency (replicas vs throughput)"""
    for label, dfs in data.items():
        if 'replicas' in dfs:
            fig, ax = plt.subplots(figsize=(10, 6))

            df_req = dfs['requests']
            df_rep = dfs['replicas']

            # Bin by replica count and calculate throughput
            df_rep = df_rep.sort_values('time_rel')
            replica_changes = []

            # Find time points where replica count changes
            prev_replicas = df_rep.iloc[0]['availableReplicas']
            replica_changes.append((df_rep.iloc[0]['time_rel'], prev_replicas))

            for _, row in df_rep.iterrows():
                if row['availableReplicas'] != prev_replicas:
                    replica_changes.append((row['time_rel'], row['availableReplicas']))
                    prev_replicas = row['availableReplicas']

            # Add the end time point
            replica_changes.append((df_rep['time_rel'].max(), prev_replicas))

            # Calculate throughput for each period
            replica_throughputs = {}
            for i in range(len(replica_changes) - 1):
                start_time, replicas = replica_changes[i]
                end_time = replica_changes[i + 1][0]

                # Only consider periods longer than 10 seconds for stable measurements
                if end_time - start_time > 10:
                    period_reqs = df_req[(df_req['end_time_rel'] >= start_time) &
                                         (df_req['end_time_rel'] <= end_time) &
                                         (df_req['http_code'] == 200)]

                    if len(period_reqs) > 0:
                        duration = end_time - start_time
                        throughput = len(period_reqs) / duration

                        if replicas not in replica_throughputs:
                            replica_throughputs[replicas] = []

                        replica_throughputs[replicas].append(throughput)

            # Calculate average throughput per replica count
            replicas = []
            throughputs = []
            errors = []

            for r, ts in sorted(replica_throughputs.items()):
                if ts:  # Only include if we have measurements
                    replicas.append(r)
                    throughputs.append(np.mean(ts))
                    errors.append(np.std(ts) if len(ts) > 1 else 0)

            # Plot throughput vs replicas with error bars
            ax.errorbar(replicas, throughputs, yerr=errors, fmt='o-',
                       capsize=5, linewidth=2, markersize=8)

            # Calculate and plot ideal scaling (linear)
            if len(replicas) > 1 and replicas[0] > 0:
                base_throughput = throughputs[0] / replicas[0]
                ideal_x = np.array(replicas)
                ideal_y = base_throughput * ideal_x
                ax.plot(ideal_x, ideal_y, 'r--', label='Ideal Linear Scaling')

            ax.set_xlabel('Number of Replicas')
            ax.set_ylabel('Throughput (requests/second)')
            ax.set_title(f'Scaling Efficiency ({label})')

            # Force integer ticks for x-axis
            ax.xaxis.set_major_locator(MaxNLocator(integer=True))

            # Add scaling efficiency if we have multiple replica counts
            if len(replicas) > 1:
                # Calculate efficiency compared to linear scaling
                efficiency = []
                for i in range(len(replicas)):
                    if replicas[i] > 0 and replicas[0] > 0:
                        expected = throughputs[0] * (replicas[i] / replicas[0])
                        actual = throughputs[i]
                        efficiency.append(actual / expected * 100 if expected > 0 else 0)

                # Add annotation for each point
                for i in range(len(replicas)):
                    if i < len(efficiency):
                        ax.annotate(f"{efficiency[i]:.1f}%",
                                   (replicas[i], throughputs[i]),
                                   textcoords="offset points",
                                   xytext=(0,10),
                                   ha='center')

                # Add text box with average efficiency
                if efficiency:
                    avg_efficiency = np.mean(efficiency[1:])  # Skip first point (always 100%)
                    plt.text(0.95, 0.05, f"Avg Scaling Efficiency: {avg_efficiency:.1f}%",
                            transform=ax.transAxes, verticalalignment='bottom',
                            horizontalalignment='right',
                            bbox=dict(boxstyle='round', facecolor='white', alpha=0.8))

            ax.legend()
            plt.tight_layout()
            plt.savefig(os.path.join(output_dir, f"{label}_scaling_efficiency.png"), dpi=300)
            plt.savefig(os.path.join(output_dir, f"{label}_scaling_efficiency.pdf"))
            plt.close()

def compare_conditions(data, output_dir):
    """Generate comparison graphs across different conditions if multiple exist"""
    if len(data) <= 1:
        return  # Need at least two conditions to compare

    # Compare latency distributions
    fig, ax = plt.subplots(figsize=(10, 6))

    p50_values = {}
    p90_values = {}
    p99_values = {}
    success_rates = {}

    for label, dfs in data.items():
        df_req = dfs['requests']
        success_reqs = df_req[df_req['http_code'] == 200]

        if len(success_reqs) > 0:
            # Convert to seconds
            latencies = success_reqs['latency_ms'] / 1000

            # Plot CDF
            x = np.sort(latencies)
            y = np.arange(1, len(x) + 1) / len(x)
            ax.plot(x, y, label=label)

            # Store percentiles for bar chart
            percentiles = np.percentile(latencies, [50, 90, 99])
            p50_values[label] = percentiles[0]
            p90_values[label] = percentiles[1]
            p99_values[label] = percentiles[2]

            # Store success rate
            success_rates[label] = len(success_reqs) / len(df_req) * 100

    ax.set_xlabel('Latency (seconds)')
    ax.set_ylabel('Cumulative Probability')
    ax.set_title('Latency CDF Comparison')
    ax.grid(True, alpha=0.3)
    ax.legend()

    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, "comparison_latency_cdf.png"), dpi=300)
    plt.savefig(os.path.join(output_dir, "comparison_latency_cdf.pdf"))
    plt.close()

    # Bar chart comparison of percentiles
    if p50_values:
        fig, ax = plt.subplots(figsize=(10, 6))
        labels = list(p50_values.keys())
        x = np.arange(len(labels))
        width = 0.25

        ax.bar(x - width, [p50_values[l] for l in labels], width, label='p50')
        ax.bar(x, [p90_values[l] for l in labels], width, label='p90')
        ax.bar(x + width, [p99_values[l] for l in labels], width, label='p99')

        ax.set_ylabel('Latency (seconds)')
        ax.set_title('Latency Percentile Comparison')
        ax.set_xticks(x)
        ax.set_xticklabels(labels)
        ax.legend()

        plt.tight_layout()
        plt.savefig(os.path.join(output_dir, "comparison_latency_percentiles.png"), dpi=300)
        plt.savefig(os.path.join(output_dir, "comparison_latency_percentiles.pdf"))
        plt.close()

    # Success rate comparison
    if success_rates:
        fig, ax = plt.subplots(figsize=(10, 6))
        labels = list(success_rates.keys())

        ax.bar(labels, [success_rates[l] for l in labels])

        ax.set_ylabel('Success Rate (%)')
        ax.set_title('Success Rate Comparison')
        ax.set_ylim(0, 105)  # Add some headroom above 100%

        # Add exact values on top of bars
        for i, v in enumerate([success_rates[l] for l in labels]):
            ax.text(i, v + 1, f"{v:.1f}%", ha='center')

        plt.tight_layout()
        plt.savefig(os.path.join(output_dir, "comparison_success_rate.png"), dpi=300)
        plt.savefig(os.path.join(output_dir, "comparison_success_rate.pdf"))
        plt.close()

def main():
    parser = argparse.ArgumentParser(description='Generate autoscaling graphs from experiment data')
    parser.add_argument('--exp_dir', type=str, default=None,
                        help='Experiment directory containing CSV files (default: latest)')
    parser.add_argument('--out_dir', type=str, default=None,
                        help='Output directory for graphs (default: {exp_dir}/graphs)')
    args = parser.parse_args()

    # Find the latest experiment directory if not specified
    if args.exp_dir is None:
        exp_dirs = glob.glob('out_*')
        if not exp_dirs:
            print("No experiment directories found. Please specify with --exp_dir")
            return
        args.exp_dir = max(exp_dirs, key=os.path.getmtime)
        print(f"Using latest experiment directory: {args.exp_dir}")

    # Set output directory
    if args.out_dir is None:
        args.out_dir = os.path.join(args.exp_dir, 'graphs')

    # Create output directory if it doesn't exist
    os.makedirs(args.out_dir, exist_ok=True)

    # Load data
    data = load_data(args.exp_dir)
    if not data:
        print(f"No data files found in {args.exp_dir}")
        return

    print(f"Generating graphs for {len(data)} conditions: {', '.join(data.keys())}")

    # Generate individual condition graphs
    plot_latency_vs_time(data, args.out_dir)
    plot_replicas_vs_load(data, args.out_dir)
    plot_throughput_analysis(data, args.out_dir)
    plot_latency_distribution(data, args.out_dir)
    plot_scaling_efficiency(data, args.out_dir)

    # Generate comparison graphs if multiple conditions
    compare_conditions(data, args.out_dir)

    print(f"Graphs saved to {args.out_dir}")

if __name__ == "__main__":
    main()
