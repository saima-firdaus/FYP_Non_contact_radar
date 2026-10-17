function outDir = cir_iq_capture_static(varargin)
%CIR_IQ_CAPTURE_STATIC  Static IQ session (cir_iq_capture) analysed with a calibrated range zero.
%
%   cir_iq_capture_static('Separation', 0.5, 'TrueDistance', 2, 'Calibrate', true)   first run
%   cir_iq_capture_static('Separation', 0.5, 'TrueDistance', 3)                      check / use
%   cir_iq_capture_static('FromLog', folder, 'TrueDistance', 2)    rebuild + analyse a saved session
%   outDir = cir_iq_capture_static(...)
%
% Records exactly what cir_iq_capture records - the same 30 s session (10 s
% empty, 10 s walk to your mark, 10 s standing still), the same files, so
% every other analysis still runs on the folder - then runs
% cir_static_distance instead of cir_phase_analysis_iq: the range zero comes
% from the route the target's echo actually arrives by (calibrated per
% channel), and the target is the strongest change while standing.
%
% First session on a hardware set-up and channel: stand at a tape-measured
% distance and pass 'TrueDistance', d, 'Calibrate', true. Then check at a
% different distance without 'Calibrate'. Keep giving 'TrueDistance' whenever
% you know it, to see the error.
%
% Options: everything cir_iq_capture takes ('Port', 'Separation',
% 'TrueDistance', 'RunLabel', ...) plus cir_static_distance's ('Calibrate',
% 'PeakOffsetTaps', 'CalibrationFile', 'MinRangeM', 'MaxRangeM', ...).
% Pass 'Separation' every time: cir_iq_capture's default is not your set-up.

anaOnly = {'Calibrate', 'PeakOffsetTaps', 'CalibrationFile', 'MinRangeM', 'MaxRangeM', ...
           'SettleAfterWalkS', 'Plot', 'Verbose'};
both    = {'TrueDistance', 'Separation'};
capArgs = {}; anaArgs = {};
for k = 1:2:numel(varargin)
    name = varargin{k};
    if any(strcmpi(name, anaOnly)) || any(strcmpi(name, both))
        anaArgs(end+1:end+2) = varargin(k:k+1); %#ok<AGROW>
    end
    if ~any(strcmpi(name, anaOnly))
        capArgs(end+1:end+2) = varargin(k:k+1); %#ok<AGROW>
    end
end
outDir = cir_iq_capture(capArgs{:}, 'Analyse', false);
cir_static_distance(outDir, anaArgs{:});
fprintf('Re-run this analysis: cir_static_distance(''%s'')\n', outDir);
end
