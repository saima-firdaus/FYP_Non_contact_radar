"""
Through-the-Wall UWB Radar Signal Processing
MTI, SVD, and Matched Filtering Implementation for Raspberry Pi 3

Author: Your Name
Date: 2026
Description: Process CIR (Channel Impulse Response) frames to detect humans behind walls
"""

import numpy as np
import matplotlib.pyplot as plt
from scipy import signal
from scipy.linalg import svd
import warnings
warnings.filterwarnings('ignore')

# ============================================================================
# SECTION 1: GENERATE SYNTHETIC CIR DATA (for testing without real hardware)
# ============================================================================

def generate_synthetic_cir_data(num_frames=100, num_samples=512, snr_db=0):
    """
    Generate synthetic Channel Impulse Response data for testing.
    
    This simulates what your DW1000 receiver would give you.
    
    Parameters:
    -----------
    num_frames : int
        How many radar pulses to simulate (time frames)
    num_samples : int
        Samples per pulse (range bins)
    snr_db : float
        Signal-to-noise ratio in decibels
    
    Returns:
    --------
    cir_data : ndarray (num_frames x num_samples)
        Radar data matrix ready for processing
    """
    
    # Create range axis (like distance bins from your receiver)
    range_bins = np.arange(num_samples)
    
    # Initialize data storage
    cir_data = np.zeros((num_frames, num_samples))
    
    # ---- WALL REFLECTION (the clutter we want to remove) ----
    # Wall is at range bin 50, very strong signal
    wall_position = 50
    wall_strength = 1.0  # Normalized to 1.0
    
    for frame in range(num_frames):
        # Wall reflection is almost identical each frame (it's stationary)
        wall_pulse = wall_strength * np.exp(-((range_bins - wall_position)**2) / 20)
        cir_data[frame, :] += wall_pulse
    
    # ---- HUMAN REFLECTION (the target we want to detect) ----
    # Human is at range bin 100, weaker than wall
    human_position = 100
    human_base_strength = 0.15  # Weaker than wall
    
    for frame in range(num_frames):
        # Simulate breathing: human reflection changes slightly with each frame
        # Breathing frequency around 0.3 Hz at typical radar PRF
        breathing_modulation = 0.05 * np.sin(2 * np.pi * 0.3 * frame / num_frames)
        human_strength = human_base_strength + breathing_modulation
        
        human_pulse = human_strength * np.exp(-((range_bins - human_position)**2) / 30)
        cir_data[frame, :] += human_pulse
    
    # ---- ADD NOISE ----
    # Convert SNR from dB to linear scale
    snr_linear = 10 ** (snr_db / 10)
    
    # Calculate noise power needed to achieve target SNR
    signal_power = np.mean(cir_data ** 2)
    noise_power = signal_power / snr_linear
    
    # Add Gaussian noise
    noise = np.sqrt(noise_power) * np.random.randn(num_frames, num_samples)
    cir_data = cir_data + noise
    
    return cir_data


def load_real_cir_data(filepath):
    """
    Load real CIR data from your Raspberry Pi.
    
    This is where you'll connect to actual DW1000 hardware output.
    Expects a CSV or binary file with shape (num_frames, num_samples).
    
    For now, this is a placeholder.
    """
    print("Note: Implement this function to load your actual DW1000 CIR data")
    print("Expected format: (num_frames, num_samples) matrix")
    print("Each row = one radar frame")
    print("Each column = one range bin")
    pass


# ============================================================================
# SECTION 2: ALGORITHM 1 - MTI (Moving Target Indication)
# ============================================================================

class MTI_Filter:
    """
    Moving Target Indication: Remove stationary clutter by frame subtraction.
    
    How it works:
    1. Take current frame
    2. Subtract previous frame
    3. Stationary objects (wall) → 0
    4. Moving objects (humans) → stays visible
    """
    
    def __init__(self, num_difference_frames=1):
        """
        Initialize MTI filter.
        
        Parameters:
        -----------
        num_difference_frames : int
            How many frames back to subtract (usually 1 for adjacent frames)
        """
        self.num_diff = num_difference_frames
        self.previous_frame = None
    
    def process_frame(self, current_frame):
        """
        Process a single frame with MTI.
        
        Returns the current frame with stationary clutter removed.
        """
        if self.previous_frame is None:
            # First frame: nothing to subtract from
            self.previous_frame = current_frame.copy()
            return np.zeros_like(current_frame)
        
        # Subtract previous frame from current
        # This cancels out anything that hasn't changed
        mti_output = current_frame - self.previous_frame
        
        # Store current for next iteration
        self.previous_frame = current_frame.copy()
        
        return mti_output
    
    def process_all_frames(self, cir_data):
        """
        Process all frames at once.
        
        Parameters:
        -----------
        cir_data : ndarray (num_frames x num_samples)
            Raw CIR data
        
        Returns:
        --------
        mti_output : ndarray (num_frames x num_samples)
            MTI-filtered data
        """
        mti_output = np.zeros_like(cir_data)
        
        for frame_idx in range(1, cir_data.shape[0]):
            # Subtract consecutive frames
            mti_output[frame_idx, :] = cir_data[frame_idx, :] - cir_data[frame_idx - 1, :]
        
        return mti_output


# ============================================================================
# SECTION 3: ALGORITHM 2 - SVD (Singular Value Decomposition)
# ============================================================================

class SVD_Filter:
    """
    Singular Value Decomposition: Decompose radar data and remove dominant components.
    
    How it works:
    1. Take all radar frames as a matrix
    2. Break it into "layers" using SVD (singular values)
    3. Biggest layers = wall reflection (remove these)
    4. Smaller layers = human signals (keep these)
    5. Reconstruct without the wall layers
    
    Why it's powerful:
    - Works mathematically to separate strong and weak signals
    - Doesn't require motion (unlike MTI)
    - But requires more computation
    """
    
    def __init__(self, num_singular_values_to_remove=5):
        """
        Initialize SVD filter.
        
        Parameters:
        -----------
        num_singular_values_to_remove : int
            How many strongest "layers" to remove (start with 5, tune later)
            Higher = more aggressive clutter removal
            Lower = preserve more weaker signals
        """
        self.num_remove = num_singular_values_to_remove
    
    def process(self, cir_data):
        """
        Apply SVD clutter suppression.
        
        Parameters:
        -----------
        cir_data : ndarray (num_frames x num_samples)
            Raw CIR data matrix
        
        Returns:
        --------
        svd_output : ndarray (num_frames x num_samples)
            SVD-filtered data with strong clutter removed
        singular_values : ndarray
            All singular values (useful for plotting/tuning)
        """
        
        # Center the data (remove mean from each range bin)
        # This helps SVD focus on variations, not absolute values
        data_centered = cir_data - np.mean(cir_data, axis=0)
        
        # Perform SVD decomposition
        # U: what varies across time frames
        # S: strength of each variation (singular values)
        # Vh: what varies across range bins
        U, singular_values, Vh = svd(data_centered, full_matrices=False)
        
        # Keep only the singular values we want
        # Set the first N largest to zero (removing wall clutter)
        singular_values_filtered = singular_values.copy()
        singular_values_filtered[:self.num_remove] = 0
        
        # Reconstruct the data without the wall components
        # This is where the magic happens: we rebuild without the clutter
        svd_output = U @ np.diag(singular_values_filtered) @ Vh
        
        # Un-center the data (add mean back)
        svd_output = svd_output + np.mean(cir_data, axis=0)
        
        return svd_output, singular_values


# ============================================================================
# SECTION 4: ALGORITHM 3 - MATCHED FILTERING
# ============================================================================

class MatchedFilter:
    """
    Matched Filtering: Correlate known human signature with received data.
    
    How it works:
    1. Create a "template" of what human breathing looks like
    2. Slide this template across your data
    3. Wherever it matches well, humans are present
    4. Similar to pattern matching in images
    
    Why it works:
    - Human breathing has predictable pattern
    - When template matches, SNR improves significantly
    - Standard technique in radar and communications
    """
    
    def __init__(self, template_type='gaussian', template_length=64):
        """
        Initialize matched filter.
        
        Parameters:
        -----------
        template_type : str
            Type of template: 'gaussian' or 'chirp'
        template_length : int
            Length of the template (should match pulse width)
        """
        self.template = self._create_template(template_type, template_length)
    
    def _create_template(self, template_type, length):
        """Create the matched filter template."""
        
        if template_type == 'gaussian':
            # Gaussian pulse (typical UWB pulse shape)
            x = np.linspace(-3, 3, length)
            template = np.exp(-x**2)
            
        elif template_type == 'chirp':
            # Chirp/LFM pulse
            t = np.linspace(0, 1, length)
            template = np.sin(2 * np.pi * (t + 0.5 * t**2))
            
        else:
            raise ValueError("Unknown template type")
        
        # Normalize template
        template = template / np.linalg.norm(template)
        
        return template
    
    def process_frame(self, frame):
        """
        Apply matched filter to a single range bin series.
        
        Parameters:
        -----------
        frame : ndarray (num_samples,)
            Single radar frame (all range bins, single time)
        
        Returns:
        --------
        filtered : ndarray
            Matched filter output
        """
        # Correlate frame with template
        # 'valid' mode: only output valid correlation regions
        filtered = signal.correlate(frame, self.template, mode='same')
        
        return filtered
    
    def process_all_frames(self, cir_data):
        """
        Apply matched filter to all frames.
        
        Parameters:
        -----------
        cir_data : ndarray (num_frames x num_samples)
            Raw CIR data
        
        Returns:
        --------
        filtered_data : ndarray (num_frames x num_samples)
            Matched filtered data
        """
        filtered_data = np.zeros_like(cir_data)
        
        for frame_idx in range(cir_data.shape[0]):
            filtered_data[frame_idx, :] = self.process_frame(cir_data[frame_idx, :])
        
        return filtered_data


# ============================================================================
# SECTION 5: SIGNAL-TO-NOISE RATIO (SNR) CALCULATION
# ============================================================================

def calculate_snr(signal_region, noise_region):
    """
    Calculate Signal-to-Noise Ratio.
    
    SNR tells you how much stronger your target signal is compared to noise.
    Higher SNR = easier to detect humans.
    
    Parameters:
    -----------
    signal_region : ndarray
        Data region containing the target (human) signal
    noise_region : ndarray
        Data region containing only noise/clutter
    
    Returns:
    --------
    snr_db : float
        SNR in decibels (dB)
    """
    
    # Power = mean of squared values
    signal_power = np.mean(signal_region ** 2)
    noise_power = np.mean(noise_region ** 2)
    
    # Avoid division by zero
    if noise_power < 1e-10:
        return 0
    
    # SNR ratio
    snr_ratio = signal_power / noise_power
    
    # Convert to decibels
    snr_db = 10 * np.log10(snr_ratio)
    
    return snr_db


def analyze_processing_effectiveness(raw_data, processed_data, 
                                     target_start=90, target_end=110,
                                     clutter_start=40, clutter_end=60):
    """
    Compare SNR before and after processing.
    
    This shows you how much the algorithms improved detection.
    
    Parameters:
    -----------
    raw_data, processed_data : ndarray
        Before and after processing
    target_start, target_end : int
        Range bin indices for human target
    clutter_start, clutter_end : int
        Range bin indices for wall clutter
    
    Returns:
    --------
    dict : SNR values before and after
    """
    
    # Extract target and clutter regions
    raw_target = raw_data[:, target_start:target_end]
    raw_clutter = raw_data[:, clutter_start:clutter_end]
    
    processed_target = processed_data[:, target_start:target_end]
    processed_clutter = processed_data[:, clutter_start:clutter_end]
    
    # Calculate SNRs
    snr_raw = calculate_snr(raw_target, raw_clutter)
    snr_processed = calculate_snr(processed_target, processed_clutter)
    
    snr_improvement = snr_processed - snr_raw
    
    return {
        'raw_snr_db': snr_raw,
        'processed_snr_db': snr_processed,
        'improvement_db': snr_improvement,
        'improvement_factor': 10 ** (snr_improvement / 10)
    }


# ============================================================================
# SECTION 6: VISUALIZATION FUNCTIONS
# ============================================================================

def plot_radar_processing_results(raw_data, mti_data, svd_data, matched_data, 
                                  title="Radar Signal Processing Comparison"):
    """
    Create comprehensive visualization of all processing methods.
    
    This shows you how each algorithm changes the data.
    """
    
    fig, axes = plt.subplots(2, 3, figsize=(16, 8))
    fig.suptitle(title, fontsize=14, fontweight='bold')
    
    # Time-range representation (heatmap)
    vmin, vmax = np.percentile(raw_data, [5, 95])
    
    # Row 1: Signal level
    im0 = axes[0, 0].imshow(raw_data.T, aspect='auto', cmap='jet', 
                            vmin=vmin, vmax=vmax, origin='lower')
    axes[0, 0].set_title('Raw CIR Data')
    axes[0, 0].set_xlabel('Time Frame')
    axes[0, 0].set_ylabel('Range Bin')
    plt.colorbar(im0, ax=axes[0, 0], label='Amplitude')
    
    im1 = axes[0, 1].imshow(mti_data.T, aspect='auto', cmap='jet', origin='lower')
    axes[0, 1].set_title('MTI Filtered')
    axes[0, 1].set_xlabel('Time Frame')
    axes[0, 1].set_ylabel('Range Bin')
    plt.colorbar(im1, ax=axes[0, 1], label='Amplitude')
    
    im2 = axes[0, 2].imshow(svd_data.T, aspect='auto', cmap='jet', origin='lower')
    axes[0, 2].set_title('SVD Filtered')
    axes[0, 2].set_xlabel('Time Frame')
    axes[0, 2].set_ylabel('Range Bin')
    plt.colorbar(im2, ax=axes[0, 2], label='Amplitude')
    
    # Row 2: Range profiles (single frame)
    frame_to_plot = raw_data.shape[0] // 2  # Plot middle frame
    range_bins = np.arange(raw_data.shape[1])
    
    axes[1, 0].plot(range_bins, np.abs(raw_data[frame_to_plot, :]), 'b-', linewidth=2)
    axes[1, 0].axvspan(40, 60, alpha=0.2, color='red', label='Wall clutter')
    axes[1, 0].axvspan(90, 110, alpha=0.2, color='green', label='Target region')
    axes[1, 0].set_title(f'Raw Range Profile (Frame {frame_to_plot})')
    axes[1, 0].set_xlabel('Range Bin')
    axes[1, 0].set_ylabel('Magnitude')
    axes[1, 0].legend()
    axes[1, 0].grid(True, alpha=0.3)
    
    axes[1, 1].plot(range_bins, np.abs(mti_data[frame_to_plot, :]), 'b-', linewidth=2)
    axes[1, 1].axvspan(40, 60, alpha=0.2, color='red', label='Wall clutter')
    axes[1, 1].axvspan(90, 110, alpha=0.2, color='green', label='Target region')
    axes[1, 1].set_title(f'MTI Range Profile (Frame {frame_to_plot})')
    axes[1, 1].set_xlabel('Range Bin')
    axes[1, 1].set_ylabel('Magnitude')
    axes[1, 1].legend()
    axes[1, 1].grid(True, alpha=0.3)
    
    axes[1, 2].plot(range_bins, np.abs(svd_data[frame_to_plot, :]), 'b-', linewidth=2)
    axes[1, 2].axvspan(40, 60, alpha=0.2, color='red', label='Wall clutter')
    axes[1, 2].axvspan(90, 110, alpha=0.2, color='green', label='Target region')
    axes[1, 2].set_title(f'SVD Range Profile (Frame {frame_to_plot})')
    axes[1, 2].set_xlabel('Range Bin')
    axes[1, 2].set_ylabel('Magnitude')
    axes[1, 2].legend()
    axes[1, 2].grid(True, alpha=0.3)
    
    plt.tight_layout()
    return fig


def plot_snr_comparison(snr_results):
    """
    Create bar chart comparing SNR improvement across methods.
    """
    methods = ['Raw', 'MTI', 'SVD', 'Matched Filter']
    snr_values = [
        snr_results['raw']['processed_snr_db'],
        snr_results['mti']['processed_snr_db'],
        snr_results['svd']['processed_snr_db'],
        snr_results['matched']['processed_snr_db']
    ]
    
    fig, ax = plt.subplots(figsize=(10, 6))
    bars = ax.bar(methods, snr_values, color=['red', 'blue', 'green', 'purple'], alpha=0.7)
    
    ax.set_ylabel('Signal-to-Noise Ratio (dB)', fontsize=12)
    ax.set_title('SNR Improvement Across Processing Methods', fontsize=14, fontweight='bold')
    ax.grid(True, alpha=0.3, axis='y')
    
    # Add value labels on bars
    for bar, value in zip(bars, snr_values):
        height = bar.get_height()
        ax.text(bar.get_x() + bar.get_width()/2., height,
                f'{value:.1f} dB',
                ha='center', va='bottom', fontsize=11, fontweight='bold')
    
    plt.tight_layout()
    return fig


def plot_singular_values(singular_values):
    """
    Plot singular values to help you choose how many to remove.
    
    Bigger values = stronger clutter components to remove.
    """
    fig, ax = plt.subplots(figsize=(10, 6))
    
    ax.semilogy(range(len(singular_values)), singular_values, 'b-o', linewidth=2)
    ax.axvline(x=5, color='r', linestyle='--', label='Typical removal threshold')
    ax.set_xlabel('Singular Value Index', fontsize=12)
    ax.set_ylabel('Magnitude (log scale)', fontsize=12)
    ax.set_title('SVD Singular Values: Wall Clutter Dominance', fontsize=14, fontweight='bold')
    ax.grid(True, alpha=0.3, which='both')
    ax.legend()
    
    plt.tight_layout()
    return fig


# ============================================================================
# SECTION 7: MAIN EXECUTION EXAMPLE
# ============================================================================

def main():
    """
    Complete workflow: Generate data → Process → Analyze → Plot
    """
    
    print("\n" + "="*70)
    print("UWB RADAR SIGNAL PROCESSING - MTI, SVD, MATCHED FILTERING")
    print("="*70 + "\n")
    
    # ---- STEP 1: LOAD OR GENERATE DATA ----
    print("[1/5] Generating synthetic CIR data...")
    num_frames = 128
    num_samples = 256
    snr_db_input = 0  # Start with SNR=0 (very challenging)
    
    raw_cir_data = generate_synthetic_cir_data(num_frames, num_samples, snr_db_input)
    print(f"   Generated {num_frames} frames × {num_samples} range bins")
    print(f"   Input SNR: {snr_db_input} dB (signal power = noise power)")
    
    # ---- STEP 2: APPLY MTI FILTER ----
    print("\n[2/5] Applying MTI (Moving Target Indication)...")
    mti_filter = MTI_Filter()
    mti_output = mti_filter.process_all_frames(raw_cir_data)
    print(f"   MTI: Subtracted adjacent frames to remove wall clutter")
    
    # ---- STEP 3: APPLY SVD FILTER ----
    print("\n[3/5] Applying SVD (Singular Value Decomposition)...")
    svd_filter = SVD_Filter(num_singular_values_to_remove=5)
    svd_output, singular_values = svd_filter.process(raw_cir_data)
    print(f"   SVD: Removed 5 strongest singular values (wall components)")
    print(f"   First 3 singular values: {singular_values[:3]}")
    
    # ---- STEP 4: APPLY MATCHED FILTER ----
    print("\n[4/5] Applying Matched Filter...")
    matched_filter = MatchedFilter(template_type='gaussian', template_length=32)
    matched_output = matched_filter.process_all_frames(raw_cir_data)
    print(f"   Matched Filter: Correlated with Gaussian pulse template")
    
    # ---- STEP 5: CALCULATE SNR AND COMPARE ----
    print("\n[5/5] Calculating Signal-to-Noise Ratios...")
    
    snr_results = {
        'raw': analyze_processing_effectiveness(raw_cir_data, raw_cir_data),
        'mti': analyze_processing_effectiveness(raw_cir_data, mti_output),
        'svd': analyze_processing_effectiveness(raw_cir_data, svd_output),
        'matched': analyze_processing_effectiveness(raw_cir_data, matched_output)
    }
    
    # ---- DISPLAY RESULTS ----
    print("\n" + "="*70)
    print("RESULTS SUMMARY")
    print("="*70)
    
    print(f"\n{'Method':<20} {'SNR (dB)':<15} {'Improvement (dB)':<20}")
    print("-" * 55)
    
    for method in ['raw', 'mti', 'svd', 'matched']:
        snr = snr_results[method]['processed_snr_db']
        improvement = snr_results[method]['improvement_db']
        print(f"{method.upper():<20} {snr:>7.2f}         {improvement:>+7.2f}")
    
    print("\n" + "="*70)
    
    # ---- CREATE VISUALIZATIONS ----
    print("\nGenerating plots...")
    
    fig1 = plot_radar_processing_results(raw_cir_data, mti_output, svd_output, matched_output)
    fig1.savefig('/home/claude/radar_processing_comparison.png', dpi=150, bbox_inches='tight')
    print("✓ Saved: radar_processing_comparison.png")
    
    fig2 = plot_snr_comparison(snr_results)
    fig2.savefig('/home/claude/snr_comparison.png', dpi=150, bbox_inches='tight')
    print("✓ Saved: snr_comparison.png")
    
    fig3 = plot_singular_values(singular_values)
    fig3.savefig('/home/claude/singular_values.png', dpi=150, bbox_inches='tight')
    print("✓ Saved: singular_values.png")
    
    print("\n✓ All plots generated successfully!")
    print("\nTo view plots, run: plt.show()")
    
    return raw_cir_data, mti_output, svd_output, matched_output, snr_results


if __name__ == "__main__":
    raw_data, mti_data, svd_data, matched_data, results = main()
    
    # Uncomment to display plots
    # plt.show()
