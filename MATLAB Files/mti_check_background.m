function out = mti_check_background(src, varargin)
%MTI_CHECK_BACKGROUND  Does I/Q background subtraction work on these modules?
%
%   out = MTI_CHECK_BACKGROUND(src)
%   out = MTI_CHECK_BACKGROUND(src, 'MaxSeconds', 10, 'Plot', true)
%
% Record an EMPTY room with cir_mti_live for 10-20 s (nobody in front, don't
% walk off before it starts), then run this on that folder.
%
% The two modules run on separate crystals, so the carrier phase of every
% frame is effectively random: the raw I/Q of a static room spins from frame
% to frame. That drift is COMMON to every tap of one frame (the whole CIR
% rotates together), because it comes from the two oscillators, not from the
% room. So the phase of a wall echo RELATIVE to the direct path stays put.
% Dividing every frame by its own complex direct-path value (what mti_step
% does) removes the drift, and after that the background subtracts coherently.
%
% This script measures it on your data. For every tap it computes how much of
% that tap's energy is left after subtracting the empty-room average,
% three ways:
%
%   raw I/Q          FP-aligned only (what failed before)
%   normalised I/Q   FP-aligned + divided by the direct-path gain (mti_step)
%   magnitude        |CIR| only (what CIR_capture / cir_phase_analysis use)
%
% 0 dB = nothing cancelled; -20 dB = 99% of the static energy removed.
% Only settle frames are skipped: the whole capture after SettleSeconds is
% treated as empty.
%
% Plots: the direct-path phase over time (the drift), the phase of the
% strongest wall echo relative to the direct path (should be flat), and the
% cancellation per tap for the three methods.

% The mti_*.m helpers must sit in the same folder as this file.
addpath(fileparts(mfilename('fullpath')));
if exist('mti_config', 'file') ~= 2
    error(['mti_config.m not found. Copy the WHOLE mti folder (all mti_*.m ' ...
           'files) next to this script.']);
end

o = struct('MaxSeconds', Inf, 'Plot', true);
cfgArgs = {};
for k = 1:2:numel(varargin)
    if isfield(o, varargin{k}), o.(varargin{k}) = varargin{k+1};
    else, cfgArgs(end+1:end+2) = varargin(k:k+1); end %#ok<AGROW>
end
[frames, info] = mti_read_capture(src);
if ~info.coherent
    error(['%s has no I/Q (CIR_capture saves amplitude only). Record the ' ...
           'empty room with cir_mti_live.'], char(src));
end

% Run the normal chain but never finish "learning", so every frame is just
% aligned and normalised, nothing is subtracted or detected.
cfg = mti_config(cfgArgs{:}, 'LearnSeconds', 1e9);
S = mti_init(cfg);
X = []; Y = []; t = [];
for i = 1:numel(frames)
    [S, R] = mti_step(S, frames{i});
    if isempty(R.y), continue; end
    if R.t - S.t0 > o.MaxSeconds, break; end
    X(:, end+1) = R.xAligned; %#ok<AGROW>
    Y(:, end+1) = R.y;        %#ok<AGROW>
    t(end+1)    = R.t - S.t0; %#ok<AGROW>
end
if size(Y, 2) < 10
    error('Only %d usable frames - record at least 10 s.', size(Y, 2));
end
X(~isfinite(X)) = 0;
g = S.grid;

canc = @(Z) 10*log10(mean(abs(Z - mean(Z, 2)).^2, 2) ./ mean(abs(Z).^2, 2));
cRaw  = canc(X);
cNorm = canc(Y);
cMag  = canc(abs(X));

% Summary over the taps that carry real static energy after the first path
eY  = mean(abs(Y).^2, 2);
sig = g >= -1 & g <= 40 & eY > 0.05 * max(eY(g >= 5 & g <= 40));
w   = eY(sig) / sum(eY(sig));
avg = @(c) 10*log10(sum(w .* 10.^(c(sig)/10)));

% Phase of the direct path, and of the strongest wall echo relative to it
[~, iD] = min(abs(g - S.k0));
far = find(g >= S.k0 + 4 & g <= 40);
[~, j] = max(eY(far)); iW = far(j);
phDirect = unwrap(angle(X(iD, :)));
phWallRaw = unwrap(angle(X(iW, :)));
phWallRel = unwrap(angle(Y(iW, :)));

fprintf('\n=== Background cancellation, %d empty frames (%.1f s) ===\n', ...
    size(Y, 2), t(end) - t(1));
fprintf('Energy left after subtracting the empty-room mean (lower = better):\n');
fprintf('  raw I/Q        %6.1f dB   <- oscillator phase drift, cannot cancel\n', avg(cRaw));
fprintf('  normalised I/Q %6.1f dB   <- what cir_mti_live uses\n', avg(cNorm));
fprintf('  magnitude only %6.1f dB\n', avg(cMag));
fprintf('Direct path phase wandered over %.0f deg; wall echo at tap %+.1f moved %.0f deg raw,\n', ...
    rad2deg(range(phDirect)), g(iW), rad2deg(range(phWallRaw)));
fprintf('  but only %.1f deg RMS relative to the direct path.\n', ...
    rad2deg(std(phWallRel)));
if avg(cNorm) > -10
    fprintf(['  WARNING: normalised I/Q cancels poorly. Check nobody moved, and ' ...
             'that RXPWR is not saturating.\n  Fall back with ''Coherent'', false.\n']);
end

out = struct('grid', g, 't', t, 'cancelRaw', cRaw, 'cancelNorm', cNorm, ...
    'cancelMag', cMag, 'summaryDB', [avg(cRaw) avg(cNorm) avg(cMag)], ...
    'phaseDirect', phDirect, 'phaseWallRaw', phWallRaw, ...
    'phaseWallRel', phWallRel, 'wallTap', g(iW));

if o.Plot
    fig = figure('Color', 'w', 'Position', [80 60 1000 780]);
    ax1 = subplot(3, 1, 1); hold(ax1, 'on'); grid(ax1, 'on');
    plot(ax1, t, rad2deg(phDirect), '-', 'Color', [0.85 0.33 0.1], 'LineWidth', 1.3);
    plot(ax1, t, rad2deg(phWallRaw), '-', 'Color', [0.6 0.6 0.6]);
    ylabel(ax1, 'Phase (deg, unwrapped)');
    title(ax1, 'Raw I/Q phase: the whole CIR spins together (module oscillator drift)');
    legend(ax1, {'Direct path', sprintf('Wall echo, tap %+.1f', g(iW))}, 'Location', 'best');

    ax2 = subplot(3, 1, 2); hold(ax2, 'on'); grid(ax2, 'on');
    plot(ax2, t, rad2deg(phWallRel - mean(phWallRel)), '-', ...
        'Color', [0 0.35 0.75], 'LineWidth', 1.3);
    ylim(ax2, [-45 45]);
    xlabel(ax2, 'Time (s)'); ylabel(ax2, 'Phase (deg)');
    title(ax2, 'Same wall echo relative to the direct path: stable, so it can be subtracted');

    ax3 = subplot(3, 1, 3); hold(ax3, 'on'); grid(ax3, 'on');
    k = g >= -5 & g <= 45;
    plot(ax3, g(k), cRaw(k),  '-', 'Color', [0.85 0.33 0.1], 'LineWidth', 1.3);
    plot(ax3, g(k), cMag(k),  '-', 'Color', [0.6 0.6 0.6], 'LineWidth', 1.3);
    plot(ax3, g(k), cNorm(k), '-', 'Color', [0 0.35 0.75], 'LineWidth', 1.8);
    ylim(ax3, [-40 5]);
    xlabel(ax3, 'Taps relative to first path');
    ylabel(ax3, 'Left after subtraction (dB)');
    title(ax3, 'Background cancellation per tap (lower = better)');
    legend(ax3, {sprintf('Raw I/Q (%.0f dB)', avg(cRaw)), ...
        sprintf('Magnitude (%.0f dB)', avg(cMag)), ...
        sprintf('Normalised I/Q (%.0f dB)', avg(cNorm))}, 'Location', 'southeast');
    out.fig = fig;
    d = char(src); if ~exist(d, 'dir'), d = fileparts(d); end
    print(fig, fullfile(d, 'mti_background_check.png'), '-dpng', '-r150');
    fprintf('Saved mti_background_check.png\n');
end
end

function r = range(v)
r = max(v) - min(v);
end



% function out = mti_check_background(src, varargin)
% %MTI_CHECK_BACKGROUND  Does I/Q background subtraction work on these modules?
% %
% %   out = MTI_CHECK_BACKGROUND(src)
% %   out = MTI_CHECK_BACKGROUND(src, 'MaxSeconds', 10, 'Plot', true)
% %
% % Record an EMPTY room with cir_mti_live for 10-20 s (nobody in front, don't
% % walk off before it starts), then run this on that folder.
% %
% % The two modules run on separate crystals, so the carrier phase of every
% % frame is effectively random: the raw I/Q of a static room spins from frame
% % to frame. That drift is COMMON to every tap of one frame (the whole CIR
% % rotates together), because it comes from the two oscillators, not from the
% % room. So the phase of a wall echo RELATIVE to the direct path stays put.
% % Dividing every frame by its own complex direct-path value (what mti_step
% % does) removes the drift, and after that the background subtracts coherently.
% %
% % This script measures it on your data (skipping the first SkipSeconds,
% % 3 by default, while you walk out of view). For every tap it computes how much of
% % that tap's energy is left after subtracting the empty-room average,
% % three ways:
% %
% %   raw I/Q          FP-aligned only (what failed before)
% %   normalised I/Q   FP-aligned + divided by the direct-path gain (mti_step)
% %   magnitude        |CIR| only (what CIR_capture / cir_phase_analysis use)
% %
% % 0 dB = nothing cancelled; -20 dB = 99% of the static energy removed.
% % Only settle frames are skipped: the whole capture after SettleSeconds is
% % treated as empty.
% %
% % Plots: the direct-path phase over time (the drift), the phase of the
% % strongest wall echo relative to the direct path (should be flat), and the
% % cancellation per tap for the three methods.
% 
% % The mti_*.m helpers must sit in the same folder as this file.
% addpath(fileparts(mfilename('fullpath')));
% if exist('mti_config', 'file') ~= 2
%     error(['mti_config.m not found. Copy the WHOLE mti folder (all mti_*.m ' ...
%            'files) next to this script.']);
% end
% 
% o = struct('MaxSeconds', Inf, 'SkipSeconds', 3, 'Plot', true);
% cfgArgs = {};
% for k = 1:2:numel(varargin)
%     if isfield(o, varargin{k}), o.(varargin{k}) = varargin{k+1};
%     else, cfgArgs(end+1:end+2) = varargin(k:k+1); end %#ok<AGROW>
% end
% [frames, info] = mti_read_capture(src);
% if ~info.coherent
%     error(['%s has no I/Q (CIR_capture saves amplitude only). Record the ' ...
%            'empty room with cir_mti_live.'], char(src));
% end
% 
% % Run the normal chain but never finish "learning", so every frame is just
% % aligned and normalised, nothing is subtracted or detected.
% cfg = mti_config(cfgArgs{:}, 'LearnSeconds', 1e9);
% S = mti_init(cfg);
% X = []; Y = []; t = [];
% for i = 1:numel(frames)
%     [S, R] = mti_step(S, frames{i});
%     if isempty(R.y), continue; end
%     if R.t - S.t0 < o.SkipSeconds, continue; end      % you walking away
%     if R.t - S.t0 > o.MaxSeconds, break; end
%     X(:, end+1) = R.xAligned; %#ok<AGROW>
%     Y(:, end+1) = R.y;        %#ok<AGROW>
%     t(end+1)    = R.t - S.t0; %#ok<AGROW>
% end
% if size(Y, 2) < 10
%     error('Only %d usable frames - record at least 10 s.', size(Y, 2));
% end
% X(~isfinite(X)) = 0;
% g = S.grid;
% 
% % Fraction of each tap's energy left after subtracting its own mean over
% % the recording. 0 dB = nothing cancelled.
% canc = @(Z) 10*log10(mean(abs(Z - mean(Z, 2)).^2, 2) ./ mean(abs(Z).^2, 2));
% cRaw  = canc(X);
% cNorm = canc(Y);
% cMag  = canc(abs(X));        % magnitude, RXPACC-normalised only (CIR_capture style)
% cMagN = canc(abs(Y));        % magnitude, divided by the direct-path gain
% 
% % Summarise over STRONG static taps only (static power >= 10x the noise
% % floor). On noise-only taps a magnitude can never cancel below about
% % -6.7 dB (a Rayleigh variable's spread vs its mean square), while complex
% % noise sits at 0 dB, so weak taps would unfairly favour magnitude.
% stat  = abs(mean(Y, 2)).^2;
% noise = median(mean(abs(Y(S.noiseIdx, :)).^2, 2));
% sig   = g >= -1 & g <= 45 & stat >= 10 * noise;
% w     = stat(sig) / sum(stat(sig));
% avg   = @(c) 10*log10(sum(w .* 10.^(c(sig)/10)));
% 
% % Relative phase of an echo well clear of the direct pulse (>= 6 taps after
% % its peak), measured around its circular mean: no unwrapping, so a noisy
% % frame cannot add a 360-degree slip.
% [~, iD] = min(abs(g - S.k0));
% far = find(g >= S.k0 + 6 & g <= 45);
% [~, j] = max(stat(far)); iW = far(j);
% relDeg = rad2deg(angle(Y(iW, :) * conj(mean(Y(iW, :)))));
% phRms  = sqrt(mean(relDeg.^2));
% phMad  = 1.4826 * median(abs(relDeg - median(relDeg)));   % robust sigma
% nOut   = sum(abs(relDeg) > 45);
% dDir   = rad2deg(abs(angle(X(iD, 2:end) .* conj(X(iD, 1:end-1)))));
% phDirect  = unwrap(angle(X(iD, :)));
% phWallRaw = unwrap(angle(X(iW, :)));
% 
% fprintf('\n=== Background cancellation, %d empty frames (%.1f-%.1f s) ===\n', ...
%     size(Y, 2), t(1), t(end));
% if isfield(info, 'nBadFrames') && info.nBadFrames > 0
%     fprintf('(%d corrupted frames were dropped before this)\n', info.nBadFrames);
% end
% fprintf('Energy left after subtracting the empty-room mean, %d strong static taps:\n', sum(sig));
% fprintf('  raw I/Q               %6.1f dB   oscillator drift, cannot cancel\n', avg(cRaw));
% fprintf('  normalised I/Q        %6.1f dB   what cir_mti_live uses\n', avg(cNorm));
% fprintf('  magnitude (RXPACC)    %6.1f dB   CIR_capture / cir_phase_analysis style\n', avg(cMag));
% fprintf('  magnitude (direct)    %6.1f dB   magnitude divided by direct-path gain\n', avg(cMagN));
% fprintf('Direct-path phase moves a median %.0f deg between frames (random = 90).\n', median(dDir));
% fprintf('Echo at tap %+.1f relative to the direct path: %.1f deg RMS, %.1f deg robust,\n', ...
%     g(iW), phRms, phMad);
% fprintf('  %d of %d frames off by more than 45 deg.\n', nOut, numel(relDeg));
% fprintf('  (phase jitter alone limits coherent cancellation to about %.0f dB)\n', ...
%     10*log10(deg2rad(phMad)^2));
% % Magnitude always cancels a little better on a static scene (it throws the
% % phase noise away), but it is also blind to motion that only changes phase.
% % What matters is whether the relative phase is stable in absolute terms.
% if phMad > 15 || nOut > 0.05 * numel(relDeg) || avg(cNorm) > -15
%     fprintf(['  -> Relative phase is NOT stable enough for full coherent gain. Check ' ...
%              'nobody moved,\n     then compare cir_mti_analysis on a walking ' ...
%              'recording with and without ''Coherent'', false.\n']);
% else
%     fprintf('  -> Relative phase is stable: coherent (I/Q) MTI is usable on these modules.\n');
% end
% 
% out = struct('grid', g, 't', t, 'cancelRaw', cRaw, 'cancelNorm', cNorm, ...
%     'cancelMag', cMag, 'cancelMagDirect', cMagN, ...
%     'summaryDB', [avg(cRaw) avg(cNorm) avg(cMag) avg(cMagN)], ...
%     'phaseDirect', phDirect, 'phaseWallRaw', phWallRaw, ...
%     'relPhaseDeg', relDeg, 'wallTap', g(iW), 'strongTaps', sig);
% 
% if o.Plot
%     fig = figure('Color', 'w', 'Position', [80 60 1000 780]);
%     ax1 = subplot(3, 1, 1); hold(ax1, 'on'); grid(ax1, 'on');
%     plot(ax1, t, rad2deg(angle(X(iD, :))), '.', 'Color', [0.85 0.33 0.1], 'MarkerSize', 8);
%     plot(ax1, t, rad2deg(angle(X(iW, :))), '.', 'Color', [0.6 0.6 0.6], 'MarkerSize', 8);
%     ylim(ax1, [-180 180]);
%     ylabel(ax1, 'Raw phase (deg)');
%     title(ax1, 'Raw I/Q phase: effectively random every frame (module oscillator drift)');
%     legend(ax1, {'Direct path', sprintf('Echo, tap %+.1f', g(iW))}, 'Location', 'best');
% 
%     ax2 = subplot(3, 1, 2); hold(ax2, 'on'); grid(ax2, 'on');
%     plot(ax2, t, relDeg, '.-', 'Color', [0 0.35 0.75], 'LineWidth', 1, 'MarkerSize', 8);
%     ylim(ax2, [-90 90]);
%     xlabel(ax2, 'Time (s)'); ylabel(ax2, 'Phase (deg)');
%     title(ax2, sprintf(['Same echo relative to the direct path  (%.0f deg robust ' ...
%         'sigma, %d frames > 45 deg)'], phMad, nOut));
% 
%     ax3 = subplot(3, 1, 3); hold(ax3, 'on'); grid(ax3, 'on');
%     k = g >= -5 & g <= 45;
%     plot(ax3, g(k), cRaw(k),  '-', 'Color', [0.85 0.33 0.1], 'LineWidth', 1.3);
%     plot(ax3, g(k), cMag(k),  '-', 'Color', [0.6 0.6 0.6], 'LineWidth', 1.3);
%     plot(ax3, g(k), cNorm(k), '-', 'Color', [0 0.35 0.75], 'LineWidth', 1.8);
%     gs = g; gs(~sig) = NaN;
%     plot(ax3, gs(k), -38 * ones(sum(k), 1), 's', 'Color', [0.2 0.2 0.2], ...
%         'MarkerSize', 3, 'MarkerFaceColor', [0.2 0.2 0.2]);
%     ylim(ax3, [-40 5]);
%     xlabel(ax3, 'Taps relative to first path');
%     ylabel(ax3, 'Left after subtraction (dB)');
%     title(ax3, 'Background cancellation per tap (lower = better; dots = strong static taps used)');
%     legend(ax3, {sprintf('Raw I/Q (%.0f dB)', avg(cRaw)), ...
%         sprintf('Magnitude (%.0f dB)', avg(cMag)), ...
%         sprintf('Normalised I/Q (%.0f dB)', avg(cNorm))}, 'Location', 'southeast');
%     out.fig = fig;
%     d = char(src); if ~exist(d, 'dir'), d = fileparts(d); end
%     print(fig, fullfile(d, 'mti_background_check.png'), '-dpng', '-r150');
%     fprintf('Saved mti_background_check.png\n');
% end
% end
% 
% function r = range(v)
% r = max(v) - min(v);
% end
