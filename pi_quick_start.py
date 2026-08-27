#!/usr/bin/env python3
"""
Quick-Start Template for Raspberry Pi 3 + DW1000 UWB Radar
Copy this file to your Pi and run: python3 pi_quick_start.py
"""

import numpy as np
import time
import sys

# ============================================================================
# STEP 1: Import your signal processing modules
# ============================================================================

# Copy radar_signal_processing.py and radar_rpi_implementation.py to Pi first
# Then import:
try:
    from radar_signal_processing import (
        MTI_Filter, 
        SVD_Filter, 
        MatchedFilter,
        calculate_snr,
        analyze_processing_effectiveness
    )
    print("✓ Imported signal processing module")
except ImportError as e:
    print(f"✗ Failed to import: {e}")
    print("  Make sure radar_signal_processing.py is in same directory")
    sys.exit(1)

# Try importing Pi-specific module
try:
    from radar_rpi_implementation import (
        DW1000DataCollector,
        RealtimeRadarProcessor,
        PerformanceMonitor,
        load_cir_from_file,
        save_cir_data
    )
    print("✓ Imported Raspberry Pi module")
except ImportError as e:
    print(f"⚠ Warning: Could not import Pi module: {e}")
    print("  Running in simulation mode only")

# ============================================================================
# STEP 2: Configuration (EDIT THESE FOR YOUR SETUP)
# ============================================================================

class Config:
    """Your system configuration"""
    
    # DW1000 Settings
    DW1000_SPI_BUS = 0
    DW1000_SPI_DEVICE = 0
    DW1000_CHIP_SELECT = 8  # GPIO pin
    
    # Data collection
    NUM_FRAMES_TO_COLLECT = 256
    NUM_SAMPLES_PER_FRAME = 256
    
    # Algorithm parameters
    MTI_DIFFERENCE_FRAMES = 1
    SVD_NUM_REMOVE = 5
    MATCHED_TEMPLATE_LENGTH = 32
    
    # Detection threshold
    DETECTION_THRESHOLD = 0.1  # Tune this based on experiments
    
    # Output paths
    DATA_SAVE_DIR = '/home/pi/radar_data/'  # Create this directory first!
    RESULTS_FILE = '/home/pi/radar_data/results.txt'
    

# ============================================================================
# STEP 3: Test Mode (Start Here - No Hardware Needed)
# ============================================================================

def test_with_synthetic_data():
    """Test everything using simulated radar data"""
    
    print("\n" + "="*70)
    print("TEST MODE: Synthetic Data (No DW1000 Hardware Needed)")
    print("="*70 + "\n")
    
    print("[1/4] Generating synthetic CIR data...")
    
    # Create fake radar data with known human and wall
    num_frames = Config.NUM_FRAMES_TO_COLLECT
    num_samples = Config.NUM_SAMPLES_PER_FRAME
    
    # Wall at bin 50 (strong), Human at bin 100 (weak)
    range_bins = np.arange(num_samples)
    cir_data = np.zeros((num_frames, num_samples))
    
    for frame in range(num_frames):
        # Wall reflection (stationary)
        wall = 1.0 * np.exp(-((range_bins - 50)**2) / 20)
        # Human (with breathing modulation)
        breathing = 0.05 * np.sin(2 * np.pi * 0.3 * frame / num_frames)
        human = (0.15 + breathing) * np.exp(-((range_bins - 100)**2) / 30)
        # Noise
        noise = 0.05 * np.random.randn(num_samples)
        
        cir_data[frame, :] = wall + human + noise
    
    print(f"   ✓ Generated {num_frames} frames × {num_samples} samples")
    
    # Process with MTI
    print("\n[2/4] Applying MTI Filter...")
    mti = MTI_Filter(num_difference_frames=Config.MTI_DIFFERENCE_FRAMES)
    mti_output = mti.process_all_frames(cir_data)
    print("   ✓ MTI processing complete")
    
    # Process with SVD
    print("\n[3/4] Applying SVD Filter...")
    svd = SVD_Filter(num_singular_values_to_remove=Config.SVD_NUM_REMOVE)
    svd_output, singular_values = svd.process(cir_data)
    print(f"   ✓ SVD processing complete")
    print(f"   First 3 singular values: {singular_values[:3]}")
    
    # Analyze
    print("\n[4/4] Calculating SNR Improvement...")
    
    # Define regions: wall (bins 40-60), human (bins 90-110)
    results = {
        'raw': analyze_processing_effectiveness(cir_data, cir_data,
                                                target_start=90, target_end=110,
                                                clutter_start=40, clutter_end=60),
        'mti': analyze_processing_effectiveness(cir_data, mti_output,
                                                target_start=90, target_end=110,
                                                clutter_start=40, clutter_end=60),
        'svd': analyze_processing_effectiveness(cir_data, svd_output,
                                                target_start=90, target_end=110,
                                                clutter_start=40, clutter_end=60),
    }
    
    # Print results
    print("\n" + "="*70)
    print("RESULTS")
    print("="*70)
    print(f"\n{'Method':<10} {'SNR (dB)':<15} {'Improvement':<15}")
    print("-"*40)
    
    for method in ['raw', 'mti', 'svd']:
        snr = results[method]['processed_snr_db']
        improve = results[method]['improvement_db']
        print(f"{method:<10} {snr:>7.2f}          {improve:>+7.2f}")
    
    print("\n" + "="*70)
    print("✓ TEST SUCCESSFUL - System working correctly!")
    print("="*70)
    
    return cir_data, mti_output, svd_output, results


# ============================================================================
# STEP 4: Minimal Real-Time Loop (For Hardware Testing)
# ============================================================================

def minimal_realtime_loop(duration_seconds=30):
    """
    Minimal real-time processing loop.
    
    Edit DW1000DataCollector code to connect to your hardware.
    For now, simulates data.
    """
    
    print("\n" + "="*70)
    print("REAL-TIME MODE: Live DW1000 Data Processing")
    print("="*70 + "\n")
    
    # Initialize components
    print("[Setup] Initializing processor...")
    processor = RealtimeRadarProcessor(
        num_frames_buffer=Config.NUM_FRAMES_TO_COLLECT,
        num_samples_per_frame=Config.NUM_SAMPLES_PER_FRAME
    )
    monitor = PerformanceMonitor()
    
    # In production, connect to actual DW1000:
    # collector = DW1000DataCollector(
    #     Config.DW1000_SPI_BUS,
    #     Config.DW1000_SPI_DEVICE,
    #     Config.DW1000_CHIP_SELECT
    # )
    
    print(f"[Setup] Ready. Running for {duration_seconds} seconds...\n")
    
    frame_count = 0
    start_time = time.time()
    
    try:
        while time.time() - start_time < duration_seconds:
            monitor.start_frame()
            
            # Get frame from DW1000 or simulate
            # if collector.connected:
            #     raw_frame = collector.get_cir_frame()
            # else:
            raw_frame = np.random.randn(Config.NUM_SAMPLES_PER_FRAME) * 0.1
            
            # Process
            monitor.start_processing()
            detection = processor.process_frame(raw_frame)
            monitor.end_processing()
            
            # Print status every second
            if frame_count % 32 == 0:  # ~1 per second at typical Pi frame rate
                stats = monitor.get_stats()
                det_rate = processor.get_detection_rate()
                
                elapsed = time.time() - start_time
                print(f"[{elapsed:5.1f}s] Frame {frame_count:4d} | "
                      f"Rate: {stats['frames_per_second']:5.1f} fps | "
                      f"Detect: {det_rate:5.1f}%")
            
            frame_count += 1
            monitor.end_frame()
    
    except KeyboardInterrupt:
        print("\n[User] Interrupted")
    
    # Summary
    print("\n" + "="*70)
    final_stats = monitor.get_stats()
    print(f"Processed {frame_count} frames in {time.time() - start_time:.1f} seconds")
    print(f"Average rate: {final_stats['frames_per_second']:.1f} fps")
    print(f"Processing time: {final_stats['avg_processing_time_ms']:.2f} ms/frame")
    print(f"CPU usage: {final_stats['processing_percentage']:.1f}%")
    print("="*70)


# ============================================================================
# STEP 5: Batch Analysis Mode
# ============================================================================

def batch_analyze_file(filename):
    """
    Analyze a previously recorded CIR file.
    
    Usage: batch_analyze_file('my_recording.npy')
    """
    
    print(f"\n[Loading] {filename}...")
    try:
        cir_data = load_cir_from_file(filename)
    except Exception as e:
        print(f"✗ Failed to load: {e}")
        return
    
    print(f"✓ Loaded {cir_data.shape}")
    
    # Process all frames
    print("[Processing] Applying all algorithms...")
    processor = RealtimeRadarProcessor(
        num_frames_buffer=cir_data.shape[0]
    )
    
    for frame_idx in range(cir_data.shape[0]):
        processor.process_frame(cir_data[frame_idx, :])
        if (frame_idx + 1) % 64 == 0:
            print(f"  {frame_idx + 1}/{cir_data.shape[0]}")
    
    # Get results
    data_matrices = processor.get_latest_data_matrix()
    
    # Calculate SNRs
    results = {
        'mti': analyze_processing_effectiveness(
            cir_data, data_matrices['mti']
        ),
        'matched': analyze_processing_effectiveness(
            cir_data, data_matrices['matched']
        ),
    }
    
    # Print summary
    print("\nResults:")
    for method, result in results.items():
        print(f"  {method.upper()}: SNR = {result['processed_snr_db']:.2f} dB "
              f"(+{result['improvement_db']:.2f} dB)")
    
    det_rate = processor.get_detection_rate()
    print(f"  Detection rate: {det_rate:.1f}%")
    
    return processor, data_matrices, results


# ============================================================================
# STEP 6: Main Menu
# ============================================================================

def main():
    """Interactive menu"""
    
    print("\n" + "="*70)
    print("UWB RADAR SIGNAL PROCESSING - RASPBERRY PI QUICK START")
    print("="*70)
    print("\nWhat would you like to do?\n")
    print("  1. Test with synthetic data (no hardware needed) [RECOMMENDED FIRST]")
    print("  2. Real-time processing loop (connect DW1000 hardware)")
    print("  3. Batch analyze recorded file")
    print("  4. Show configuration")
    print("  0. Exit")
    print("\nEnter choice [0-4]: ", end="", flush=True)
    
    choice = input().strip()
    
    if choice == '1':
        test_with_synthetic_data()
    
    elif choice == '2':
        duration = input("\nHow many seconds to run? [default=30]: ").strip()
        try:
            duration = int(duration) if duration else 30
        except ValueError:
            duration = 30
        minimal_realtime_loop(duration)
    
    elif choice == '3':
        filename = input("\nEnter filename: ").strip()
        batch_analyze_file(filename)
    
    elif choice == '4':
        print("\nCurrent Configuration:")
        print(f"  DW1000 SPI: bus={Config.DW1000_SPI_BUS}, "
              f"device={Config.DW1000_SPI_DEVICE}")
        print(f"  Frames to collect: {Config.NUM_FRAMES_TO_COLLECT}")
        print(f"  Samples per frame: {Config.NUM_SAMPLES_PER_FRAME}")
        print(f"  MTI difference frames: {Config.MTI_DIFFERENCE_FRAMES}")
        print(f"  SVD singular values to remove: {Config.SVD_NUM_REMOVE}")
        print(f"  Detection threshold: {Config.DETECTION_THRESHOLD}")
    
    elif choice == '0':
        print("Goodbye!")
        return
    
    # Ask if want to do something else
    input("\nPress Enter to continue...")
    main()


# ============================================================================
# RUN ME!
# ============================================================================

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nExiting...")
