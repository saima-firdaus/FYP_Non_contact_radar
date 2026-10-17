function out = cir_mti_live_variance(varargin)
%CIR_MTI_LIVE_VARIANCE  Live distance of a moving person, variance (BSDA) detector.
%
%   CIR_MTI_LIVE_VARIANCE()                     live from the default port
%   CIR_MTI_LIVE_VARIANCE('Port', "COM5")       another port
%   CIR_MTI_LIVE_VARIANCE('Replay', folder)     replay any Capture_MTI_* recording
%   out = CIR_MTI_LIVE_VARIANCE(...)            also return the whole track
%
% CIR_MTI_LIVE with the detector swapped. Same session (keep the area EMPTY
% until "READY" is printed), same display, same Capture_MTI_* recording
% (mti_mode = variances in session_info.csv). Instead of subtracting the
% complex background:
%
%   - every frame is put on the FP grid exactly as before, but only its
%     magnitude is kept (|CIR| / RXPACC, as CIR_capture saves it), so no
%     phase reference is needed
%   - per tap, the variance of that magnitude over the last VarianceSeconds
%     is compared with the variance the empty room showed over windows of
%     the same length
%   - the threshold is the F-distribution quantile for VariancePfa, the same
%     per-tap test cir_phase_analysis_variance applies offline
%
% A still scene has no variance whatever its level, so slow drift of the
% static scene (AGC, temperature, a reference path that wanders) does not
% produce detections: that is why it is the steadier detector. The price is
% the window: a walker is smeared over the range they covered in it.
%
% Compare both detectors on the same recording:
%   cir_mti_analysis(folder)                           complex subtraction
%   cir_mti_analysis(folder, 'MTIMode', 'variance')    this detector
%
% Options: everything CIR_MTI_LIVE takes, plus
%   'VarianceSeconds'   1.5       window; shorter = less smear, noisier
%   'VariancePfa'       1e-3      per-tap false-alarm probability
%   'VarianceNormalise' 'rxpacc'  or 'direct' (also divide by the direct-path
%                                 gain; only when the direct path is strong)

out = cir_mti_live('MTIMode', 'variance', varargin{:});
end
