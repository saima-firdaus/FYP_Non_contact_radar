"""
Raspberry Pi 3 Implementation for DW1000 UWB Radar
Real-time processing with MTI, SVD, and matched filtering

This script connects to your DW1000 module and processes CIR data in real-time.

HARDWARE CONNECTIONS:
- DW1000 SPI to Raspberry Pi GPIO
- See pinout in DW1000 datasheet
"""

import numpy as np
import time
from collections import deque
import json

# Try importing DW1000 library (install with: pip install dw1000)
# If not available, fallback to file-based data loading
try:
    from dw1000.module import DW1000
    DW1000_AVAILABLE = True
except ImportError:
    DW1000_AVAILABLE = False
    print("Warning: DW1000 library not available")
    print("Install with: pip install dw1000")

# Import our signal processing modules
from radar_signal_processing import MTI_Filter, SVD_Filter, MatchedFilter, calculate_snr


# ============================================================================
# SECTION 1: DW1000 DATA ACQUISITION
# ============================================================================

class DW1000DataCollector:
    """
    Interface to DW1000 receiver on Raspberry Pi.
    Collects Channel Impulse Response (CIR) frames.
    """
    
    def __init__(self, spi_bus=0, spi_device=0, chip_select=8):
        """
        Initialize DW1000 hardware interface.
        
        Parameters:
        -----------
        spi_bus : int
            SPI bus number (0 on Raspberry Pi)
        spi_device : int
            SPI device number (0 or 1)
        chip_select : int
            GPIO pin for chip select
        """
        
        self.spi_bus = spi_bus
        self.spi_device = spi_device
        self.chip_select = chip_select
        
        if DW1000_AVAILABLE:
            try:
                self.dw1000 = DW1000(spi_bus, spi_device, chip_select)
                self.connected = True
                print(f"✓ DW1000 connected on SPI{spi_bus}.{spi_device}")
            except Exception as e:
                print(f"✗ Failed to connect to DW1000: {e}")
                self.connected = False
        else:
            self.connected = False
            print("Running in simulation mode (no DW1000 hardware)")
    
    def get_cir_frame(self):
        """
        Read one Channel Impulse Response frame from DW1000.
        
        Returns:
        --------
        cir_frame : ndarray (1024,)
            Raw CIR data (1024 samples typical)
        """
        
        if not self.connected:
            raise RuntimeError("DW1000 not connected. Can't read CIR.")
        
        try:
            # Request CIR data from DW1000
            # CIR is accessed via SPI from internal accumulator memory
            cir_raw = self.dw1000.get_cir()
            
            # CIR is complex (I and Q components), extract magnitude
            cir_magnitude = np.abs(cir_raw)
            
            return cir_magnitude
            
        except Exception as e:
            print(f"Error reading CIR: {e}")
            return None
    
    def get_rxdiag(self):
        """
        Get receive diagnostics (signal quality metrics).
        
        Returns:
        --------
        dict : Diagnostic information
            - first_path_index: Location of first received pulse
            - peak_power: Strongest signal component
            - std_noise: Noise level estimate
        """
        
        if not self.connected:
            return None
        
        try:
            # Read receive diagnostics from DW1000
            diagnostics = {
                'first_path_index': self.dw1000.get_fp_index(),
                'peak_power': self.dw1000.get_peak_power(),
                'std_noise': self.dw1000.get_std_noise()
            }
            return diagnostics
        except Exception as e:
            print(f"Error reading diagnostics: {e}")
            return None


def load_cir_from_file(filename):
    """
    Load previously recorded CIR data from file.
    
    Useful for testing before hardware is available.
    
    File format options:
    - .npy: NumPy binary format (best for large data)
    - .csv: Text format (human readable)
    - .json: JSON format (metadata friendly)
    """
    
    if filename.endswith('.npy'):
        data = np.load(filename)
        print(f"Loaded {data.shape} data from {filename}")
        return data
    
    elif filename.endswith('.csv'):
        data = np.loadtxt(filename, delimiter=',')
        print(f"Loaded {data.shape} data from {filename}")
        return data
    
    elif filename.endswith('.json'):
        with open(filename, 'r') as f:
            data_dict = json.load(f)
        data = np.array(data_dict['cir_data'])
        print(f"Loaded {data.shape} data from {filename}")
        return data
    
    else:
        raise ValueError("Unsupported file format. Use .npy, .csv, or .json")


def save_cir_data(cir_data, filename):
    """
    Save CIR data for later analysis.
    
    Use .npy for efficiency, or .csv for shareability.
    """
    
    if filename.endswith('.npy'):
        np.save(filename, cir_data)
        print(f"Saved {cir_data.shape} data to {filename}")
    
    elif filename.endswith('.csv'):
        np.savetxt(filename, cir_data, delimiter=',')
        print(f"Saved {cir_data.shape} data to {filename}")


# ============================================================================
# SECTION 2: REAL-TIME PROCESSING PIPELINE
# ============================================================================

class RealtimeRadarProcessor:
    """
    Process radar data in real-time on Raspberry Pi.
    
    Maintains circular buffers and updates displays efficiently.
    """
    
    def __init__(self, num_frames_buffer=64, num_samples_per_frame=256):
        """
        Initialize real-time processor.
        
        Parameters:
        -----------
        num_frames_buffer : int
            How many frames to keep in circular buffer
        num_samples_per_frame : int
            Range bins per frame (depends on DW1000 config)
        """
        
        self.num_frames = num_frames_buffer
        self.num_samples = num_samples_per_frame
        
        # Circular buffers (preallocated for efficiency on Pi)
        self.raw_buffer = deque(maxlen=num_frames_buffer)
        self.mti_buffer = deque(maxlen=num_frames_buffer)
        self.svd_buffer = deque(maxlen=num_frames_buffer)
        self.matched_buffer = deque(maxlen=num_frames_buffer)
        
        # Initialize filters
        self.mti_filter = MTI_Filter()
        self.svd_filter = SVD_Filter(num_singular_values_to_remove=3)
        self.matched_filter = MatchedFilter(template_type='gaussian', 
                                            template_length=32)
        
        # Detection history
        self.detection_history = deque(maxlen=num_frames_buffer)
    
    def process_frame(self, raw_frame):
        """
        Process a single incoming frame through all algorithms.
        
        Parameters:
        -----------
        raw_frame : ndarray (num_samples,)
            Raw CIR data from DW1000
        
        Returns:
        --------
        dict : Processed frame and detection info
        """
        
        # Store raw
        self.raw_buffer.append(raw_frame)
        
        # Apply MTI (needs previous frame)
        mti_frame = self.mti_filter.process_frame(raw_frame)
        self.mti_buffer.append(mti_frame)
        
        # Apply matched filter
        matched_frame = self.matched_filter.process_frame(raw_frame)
        self.matched_buffer.append(matched_frame)
        
        # SVD needs full buffer, apply only when buffer is full
        if len(self.raw_buffer) >= self.num_frames:
            raw_matrix = np.array(list(self.raw_buffer))
            svd_output, _ = self.svd_filter.process(raw_matrix)
            svd_frame = svd_output[-1, :]  # Latest frame
            self.svd_buffer.append(svd_frame)
        
        # Simple detection: peak detection with threshold
        detection = {
            'timestamp': time.time(),
            'raw_peak': np.max(np.abs(raw_frame)),
            'mti_peak': np.max(np.abs(mti_frame)),
            'matched_peak': np.max(np.abs(matched_frame)),
            'human_detected': False
        }
        
        # Detection logic: MTI peak above threshold suggests movement
        if detection['mti_peak'] > 0.1:  # Threshold (tune based on experiments)
            detection['human_detected'] = True
        
        self.detection_history.append(detection)
        
        return detection
    
    def get_latest_data_matrix(self, num_frames=None):
        """
        Get the current buffered data as a matrix for analysis.
        
        Returns data in shape (num_frames, num_samples).
        """
        
        if num_frames is None:
            num_frames = len(self.raw_buffer)
        
        raw_matrix = np.array(list(self.raw_buffer)[-num_frames:])
        mti_matrix = np.array(list(self.mti_buffer)[-num_frames:])
        svd_matrix = np.array(list(self.svd_buffer)[-num_frames:]) if len(self.svd_buffer) > 0 else None
        matched_matrix = np.array(list(self.matched_buffer)[-num_frames:])
        
        return {
            'raw': raw_matrix,
            'mti': mti_matrix,
            'svd': svd_matrix,
            'matched': matched_matrix
        }
    
    def get_detection_rate(self, window_size=16):
        """
        Calculate human detection rate in recent frames.
        
        Returns percentage of frames in recent window with detections.
        """
        
        recent = list(self.detection_history)[-window_size:]
        if len(recent) == 0:
            return 0
        
        detections = sum(1 for d in recent if d['human_detected'])
        rate = 100 * detections / len(recent)
        
        return rate


# ============================================================================
# SECTION 3: PERFORMANCE MONITORING
# ============================================================================

class PerformanceMonitor:
    """
    Track processing performance metrics on Raspberry Pi.
    
    Important because Pi has limited CPU - you need to know if
    processing is keeping up with incoming data rate.
    """
    
    def __init__(self):
        self.frame_times = deque(maxlen=100)
        self.processing_times = deque(maxlen=100)
    
    def start_frame(self):
        """Call at start of frame processing."""
        self.frame_start = time.time()
    
    def end_frame(self):
        """Call at end of frame processing."""
        frame_time = time.time() - self.frame_start
        self.frame_times.append(frame_time)
    
    def start_processing(self):
        """Call at start of signal processing step."""
        self.process_start = time.time()
    
    def end_processing(self):
        """Call at end of signal processing step."""
        process_time = time.time() - self.process_start
        self.processing_times.append(process_time)
    
    def get_stats(self):
        """Get processing performance statistics."""
        
        if len(self.frame_times) == 0:
            return None
        
        frame_times = np.array(list(self.frame_times))
        process_times = np.array(list(self.processing_times))
        
        # DW1000 typical PRF (pulse repetition frequency) is around 64 MHz
        # With 1024 samples, frame rate is roughly 62.5 kHz
        # But in practice, expect something like 10-100 Hz depending on config
        
        stats = {
            'avg_frame_time_ms': 1000 * np.mean(frame_times),
            'avg_processing_time_ms': 1000 * np.mean(process_times),
            'max_frame_time_ms': 1000 * np.max(frame_times),
            'processing_percentage': 100 * np.mean(process_times) / np.mean(frame_times),
            'frames_per_second': 1.0 / np.mean(frame_times) if len(frame_times) > 0 else 0
        }
        
        return stats


# ============================================================================
# SECTION 4: EXAMPLE USAGE
# ============================================================================

def example_realtime_processing():
    """
    Example: Real-time processing loop.
    
    This is what you'd run on the Raspberry Pi.
    """
    
    print("\n" + "="*70)
    print("REAL-TIME RADAR PROCESSING ON RASPBERRY PI")
    print("="*70 + "\n")
    
    # Initialize hardware and processor
    print("[Setup] Initializing DW1000 data collector...")
    collector = DW1000DataCollector()
    
    print("[Setup] Initializing real-time processor...")
    processor = RealtimeRadarProcessor(num_frames_buffer=64, 
                                       num_samples_per_frame=256)
    
    print("[Setup] Initializing performance monitor...")
    monitor = PerformanceMonitor()
    
    # Processing loop
    print("[Running] Starting real-time processing loop...\n")
    
    frame_count = 0
    max_frames = 500  # Process 500 frames then stop (for demo)
    
    try:
        while frame_count < max_frames:
            monitor.start_frame()
            
            # Read frame from DW1000
            try:
                if collector.connected:
                    raw_frame = collector.get_cir_frame()
                else:
                    # Simulation mode: generate fake data
                    raw_frame = np.random.randn(256) * 0.1
                
                if raw_frame is None:
                    continue
                
                # Process frame
                monitor.start_processing()
                detection = processor.process_frame(raw_frame)
                monitor.end_processing()
                
                # Print progress every 50 frames
                if frame_count % 50 == 0:
                    stats = monitor.get_stats()
                    detection_rate = processor.get_detection_rate()
                    
                    print(f"Frame {frame_count}: {stats['frames_per_second']:.1f} fps | "
                          f"Detect rate: {detection_rate:.0f}% | "
                          f"Processing: {stats['processing_percentage']:.1f}%")
                
                frame_count += 1
                
            except KeyboardInterrupt:
                break
            
            except Exception as e:
                print(f"Error: {e}")
                continue
            
            monitor.end_frame()
    
    except KeyboardInterrupt:
        print("\n[Stop] Interrupted by user")
    
    # Summary
    print("\n" + "="*70)
    print("PROCESSING COMPLETE")
    print("="*70)
    
    final_stats = monitor.get_stats()
    print(f"\nPerformance Summary:")
    print(f"  Total frames: {frame_count}")
    print(f"  Average frame rate: {final_stats['frames_per_second']:.1f} fps")
    print(f"  Processing time: {final_stats['avg_processing_time_ms']:.2f} ms/frame")
    print(f"  CPU utilization: {final_stats['processing_percentage']:.1f}%")
    
    detection_rate = processor.get_detection_rate(window_size=min(64, frame_count))
    print(f"  Human detection rate: {detection_rate:.1f}%")
    
    # Get final data for analysis
    data_matrices = processor.get_latest_data_matrix(num_frames=64)
    
    print(f"\nFinal data buffers:")
    print(f"  Raw: {data_matrices['raw'].shape}")
    print(f"  MTI: {data_matrices['mti'].shape}")
    print(f"  Matched: {data_matrices['matched'].shape}")
    
    return processor, monitor, data_matrices


def example_batch_processing():
    """
    Example: Load saved data and process it.
    
    Use this to analyze recorded experiments.
    """
    
    print("\n" + "="*70)
    print("BATCH PROCESSING OF RECORDED DATA")
    print("="*70 + "\n")
    
    # Load data
    print("[1/3] Loading recorded CIR data...")
    try:
        # Point this to your actual recorded data file
        cir_data = load_cir_from_file('recorded_cir_data.npy')
    except FileNotFoundError:
        print("   File not found. Generate synthetic data instead.")
        from radar_signal_processing import generate_synthetic_cir_data
        cir_data = generate_synthetic_cir_data(num_frames=256, num_samples=256)
    
    # Process all frames
    print(f"\n[2/3] Processing {cir_data.shape[0]} frames...")
    processor = RealtimeRadarProcessor(num_frames_buffer=cir_data.shape[0])
    
    for frame_idx in range(cir_data.shape[0]):
        processor.process_frame(cir_data[frame_idx, :])
        
        if (frame_idx + 1) % 50 == 0:
            print(f"   Processed {frame_idx + 1}/{cir_data.shape[0]} frames")
    
    # Analyze
    print("\n[3/3] Analyzing results...")
    data_matrices = processor.get_latest_data_matrix()
    
    # Calculate SNR for each method
    from radar_signal_processing import analyze_processing_effectiveness
    
    results = {
        'mti': analyze_processing_effectiveness(cir_data, data_matrices['mti']),
        'matched': analyze_processing_effectiveness(cir_data, data_matrices['matched'])
    }
    
    print("\nSNR Results:")
    for method, result in results.items():
        print(f"  {method.upper()}: {result['processed_snr_db']:.2f} dB "
              f"(improvement: {result['improvement_db']:+.2f} dB)")
    
    detection_rate = processor.get_detection_rate(window_size=min(64, len(processor.detection_history)))
    print(f"\nDetection rate: {detection_rate:.1f}%")
    
    return processor, data_matrices, results


# ============================================================================
# MAIN
# ============================================================================

if __name__ == "__main__":
    
    # Choose which example to run:
    
    # Option 1: Real-time processing (if running on Pi with DW1000)
    # processor, monitor, data = example_realtime_processing()
    
    # Option 2: Batch processing of recorded data
    processor, data, results = example_batch_processing()
    
    print("\n✓ Done!")
