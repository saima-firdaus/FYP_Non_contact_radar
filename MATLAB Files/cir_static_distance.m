function out = cir_static_distance(captureDir, varargin)
%CIR_STATIC_DISTANCE  Distance to a still target from a static IQ session, with a calibrated range zero.
%
%   out = CIR_STATIC_DISTANCE(captureDir)
%   out = CIR_STATIC_DISTANCE(captureDir, 'TrueDistance', 2)                  report the error
%   out = CIR_STATIC_DISTANCE(captureDir, 'TrueDistance', 2, 'Calibrate', true) and store the zero
%   out = CIR_STATIC_DISTANCE()                newest Capture_IQ_* folder in pwd
%
% For a session recorded with cir_iq_capture / cir_iq_capture_static:
% empty room, walk to the mark, stand still (or place the object).
%
% Why a separate analysis. On the new PCB the empty-room CIR holds the
% direct path more than once - humps about +1, +6 and +10 taps after
% FP_INDEX - and the person's echo shows the same copies at the same
% spacing: the same signal reaches the receiver by routes with fixed extra
% delays (most likely leakage that bypasses the antenna cables and LNA, so
% it arrives first and FP_INDEX locks onto it). A distance is only right when
% the range zero and the echo come from the SAME route. The other scripts
% mix them: zero +6 (the tallest point 0..8 taps) with the person's
% strongest copy (route +10) reads 2.5 m for 2 m; zero at FP reads 3.4 m.
%
% Here:
%   zero    1. 'PeakOffsetTaps' if given;
%           2. else this channel's calibration (CalibrationFile, written by
%              'Calibrate', true from a run at a tape-measured distance),
%              moved onto the empty-room hump nearest to it in THIS capture
%              (FP_INDEX shifts a little between captures; the hump shows
%              where that route sits now);
%           3. else the tallest empty-room hump 0..15 taps after FP, the
%              strongest route - flagged as uncalibrated.
%   person  the STRONGEST change while standing: the weaker, earlier copies
%           of the echo would fool a 'nearest' rule. Two statistics of
%           |CIR|/RXPACC (as cir_phase_analysis2 and _variance):
%             mean  standing mean - background mean
%             SD    standing SD - background SD (BSDA)
%           plus a reading from every standing frame on its own.
%
% Calibrate once per hardware set-up (antennas, cables, LNA) and channel:
% stand at a tape-measured distance (2 m) and pass 'TrueDistance', 2,
% 'Calibrate', true. Then CHECK it at another distance (1.5 m, 3 m) without
% 'Calibrate': if that reads right too, the calibration holds. Start a new
% CalibrationFile (or delete the old one) when the hardware changes.
%
% Options:
%   'TrueDistance'    []     m from the modules' midpoint (default: session_info.csv)
%   'Calibrate'       false  with TrueDistance: store the zero this run implies
%   'PeakOffsetTaps'  []     force the zero (taps after FP)
%   'CalibrationFile' ''     default: static_k0_calibration.csv next to this file
%   'Separation'      []     m (default: session_info.csv)
%   'MinRangeM' 0.5, 'MaxRangeM' 6        where the target is searched for
%   'SettleAfterWalkS' 1     standing frames start this long after the walk
%   'Plot' true, 'Verbose' true
%
% Writes cir_static_distance.png and cir_static_distance.csv into the capture folder.

addpath(fileparts(mfilename('fullpath')));
if exist('mti_read_capture', 'file') ~= 2
    error(['mti_read_capture.m not found. Copy the WHOLE mti folder (all mti_*.m ' ...
           'files) next to this script.']);
end
if nargin < 1 || isempty(captureDir), captureDir = local_newest(pwd); end
captureDir = char(captureDir);

o = struct('TrueDistance', [], 'Calibrate', false, 'PeakOffsetTaps', [], ...
           'CalibrationFile', '', 'Separation', [], 'MinRangeM', 0.5, 'MaxRangeM', 6, ...
           'SettleAfterWalkS', 1, 'Plot', true, 'Verbose', true);
names = fieldnames(o);
for k = 1:2:numel(varargin)
    hit = find(strcmpi(names, varargin{k}), 1);
    if isempty(hit)
        error('cir_static_distance: unknown option "%s".', char(varargin{k}));
    end
    o.(names{hit}) = varargin{k+1};
end
calFile = char(o.CalibrationFile);
if isempty(calFile)
    calFile = fullfile(fileparts(mfilename('fullpath')), 'static_k0_calibration.csv');
end

% ---- Session --------------------------------------------------------------------
[frames, info] = mti_read_capture(captureDir);
Ss = info.session;
walkAt  = local_num(Ss, 'walk_prompt_at_s', NaN);
walkDur = local_num(Ss, 'walk_duration_s', NaN);
if ~isfinite(walkAt) || ~isfinite(walkDur)
    error('No phase timings in %s/session_info.csv: record with cir_iq_capture.', captureDir);
end
t2m = local_num(Ss, 'tap_to_metres', 0.30028);
tb  = local_num(Ss, 'taps_before_fp', 50);
ta  = local_num(Ss, 'taps_after_fp', 100);
sep = o.Separation;
if isempty(sep), sep = local_num(Ss, 'tag_anchor_dist_m', NaN); end
if ~isfinite(sep), sep = local_num(Ss, 'separation_m', NaN); end
if ~isfinite(sep), error('Separation not recorded in %s: pass ''Separation''.', captureDir); end
trueD = o.TrueDistance;
if isempty(trueD), trueD = local_num(Ss, 'true_distance_m', NaN); end
if o.Calibrate && ~isfinite(trueD)
    error('''Calibrate'' needs the tape-measured distance: pass ''TrueDistance''.');
end
ch = NaN;
if isfield(frames{1}.meta, 'CH'), ch = frames{1}.meta.CH; end
chKey = sprintf('%g', ch);

% ---- |CIR| / RXPACC of every frame on the FP grid ------------------------------------
step = 0.25;
g  = (-tb : step : ta).';
nF = numel(frames);
A  = nan(numel(g), nF); el = nan(1, nF); fp = nan(1, nF);
for i = 1:nF
    f = frames{i}; m = f.meta;
    if isfield(f, 'taps')                        % CIR_capture folder: amplitude only
        taps = f.taps(:); a = abs(f.x(:));
    else
        acc = 1;
        if isfield(m, 'RXPACC') && m.RXPACC > 0, acc = m.RXPACC; end
        taps = f.sample(:) - m.FP_INDEX;
        a = hypot(f.re(:), f.im(:)) / acc;
    end
    [u, ia] = unique(taps);
    if numel(u) >= 2, A(:, i) = interp1(u, a(ia), g, 'linear', NaN); end
    if isfield(m, 'elapsed_s'), el(i) = m.elapsed_s; end
    if isfield(m, 'FP_INDEX'),  fp(i) = m.FP_INDEX;  end
end
% A bad leading-edge lock moves the whole CIR. (No RXPWR filter: a person in
% the beam moves RXPWR by several dB, so it would throw away good frames.)
bad = abs(fp - median(fp, 'omitnan')) > 10;
isBg = el >= 1 & el < walkAt & ~bad;
isP2 = el >= walkAt + walkDur + o.SettleAfterWalkS & ~bad;
if sum(isBg) < 5 || sum(isP2) < 5
    error('Need frames in both phases: %d background, %d standing.', sum(isBg), sum(isP2));
end
[muB, sdB] = local_stats(A(:, isBg));
[muP, sdP] = local_stats(A(:, isP2));
dMean = muP - muB;
dSD   = sdP - sdB;

% ---- Empty-room humps 0..15 taps: the routes the direct path takes ----------------
w15 = g >= 0 & g <= 15 & isfinite(muB);
isMax = [false; muB(2:end-1) > muB(1:end-2) & muB(2:end-1) >= muB(3:end); false];
hz = find(isMax & w15 & muB >= max(muB(w15)) * 10^(-15/20));
humps = arrayfun(@(j) g(j) + local_parab(muB, j) * step, hz).';
humpDB = 20 * log10(muB(hz).' / max(muB(hz)));

% ---- Range zero ---------------------------------------------------------------------
cal = local_cal_read(calFile, chKey);
if ~isempty(o.PeakOffsetTaps)
    k0 = o.PeakOffsetTaps;
    k0src = 'given';
elseif cal.n > 0
    [dk, j] = min(abs(humps - cal.k0));
    if ~isempty(j) && dk <= 2
        k0 = humps(j);
        k0src = sprintf('calibrated: %+.2f from %d run(s), on this capture''s hump', cal.k0, cal.n);
    else
        k0 = cal.k0;
        k0src = sprintf('calibrated: %+.2f from %d run(s) (no hump within 2 taps)', cal.k0, cal.n);
    end
else
    [~, j] = max(muB(hz));
    k0 = humps(j);
    k0src = 'UNCALIBRATED: tallest empty-room hump 0-15 taps';
end
cfg = mti_config('Separation', sep);
cfg.TapToMetres = t2m;
dist = mti_geometry('tap2range', g, cfg, k0);
win  = isfinite(dist) & dist >= o.MinRangeM & dist <= o.MaxRangeM;

% ---- The target: strongest change while standing ------------------------------------
[tapM, rM] = local_strongest(max(dMean, 0), g, win, cfg, k0);
[tapS, rS] = local_strongest(max(dSD, 0),   g, win, cfg, k0);
iP = find(isP2);
readTap = nan(1, numel(iP));
for q = 1:numel(iP)
    dA = A(:, iP(q)) - muB;
    v = dA;
    v(~(dA ./ sdB > 3)) = NaN;               % only changes 3 sigma over the empty room
    readTap(q) = local_strongest(v, g, win, cfg, k0);
end
readR = mti_geometry('tap2range', readTap, cfg, k0);
rr = readR(isfinite(readR));
fr = struct('hit', mean(isfinite(readR)), 'median', NaN, 'spread', NaN);
if ~isempty(rr)
    fr.median = median(rr);
    fr.spread = 1.4826 * median(abs(rr - fr.median));
end

% ---- Truth: errors, and the zero this run implies -------------------------------------
k0impl = NaN;
if isfinite(trueD)
    tapP = median([tapM, tapS, median(readTap, 'omitnan')], 'omitnan');
    k0impl = tapP - mti_geometry('range2tap', trueD, cfg, 0);
end
if o.Calibrate
    [~, j] = min(abs(humps - k0impl));
    hTap = NaN; if ~isempty(j), hTap = humps(j); end
    [~, nm] = fileparts(captureDir);
    local_cal_append(calFile, nm, chKey, sep, trueD, k0impl, hTap);
    cal = local_cal_read(calFile, chKey);
end

% ---- Report -----------------------------------------------------------------------------
[~, nm] = fileparts(captureDir);
if o.Verbose
    fprintf('\n=== Static distance: %s ===\n', nm);
    fprintf('Channel %s, modules %.2f m apart; %d background / %d standing frames\n', ...
        chKey, sep, sum(isBg), sum(isP2));
    fprintf('Empty room : humps at');
    fprintf(' %+.2f (%.0f dB)', [humps; humpDB]);
    fprintf(' taps after FP\n');
    fprintf('Range zero : %+.2f taps  (%s)\n', k0, k0src);
    fprintf(['Distance   : mean change %.2f m | SD change (BSDA) %.2f m | single frames ' ...
             'median %.2f m (spread %.2f m, %.0f%% of frames)\n'], rM, rS, fr.median, ...
        fr.spread, 100 * fr.hit);
    if isfinite(trueD)
        fprintf(['True       : %.2f m -> errors %+.2f / %+.2f / %+.2f m; this run ' ...
                 'implies a zero of %+.2f taps\n'], trueD, rM - trueD, rS - trueD, ...
            fr.median - trueD, k0impl);
    end
    if o.Calibrate
        fprintf('Calibrated : stored in %s - channel %s zero is now %+.2f taps (median of %d run(s))\n', ...
            calFile, chKey, cal.k0, cal.n);
    elseif isempty(o.PeakOffsetTaps) && cal.n == 0
        fprintf(['NOTE       : channel %s is not calibrated. Stand at a tape-measured distance ' ...
                 'and run with\n             ''TrueDistance'', d, ''Calibrate'', true.\n'], chKey);
    end
end

% ---- Save ---------------------------------------------------------------------------
fid = fopen(fullfile(captureDir, 'cir_static_distance.csv'), 'w');
fprintf(fid, 'taps_from_fp,distance_m,bg_mean,bg_sd,stand_mean,stand_sd,mean_change,sd_change\n');
fprintf(fid, '%.4f,%.4f,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g\n', [g dist muB sdB muP sdP dMean dSD].');
fclose(fid);

out = struct('dir', captureDir, 'channel', ch, 'separation', sep, 'trueDistance', trueD, ...
    'k0', k0, 'k0Source', k0src, 'k0Implied', k0impl, 'humps', humps, 'humpDB', humpDB, ...
    'rangeMean', rM, 'rangeSD', rS, 'tapMean', tapM, 'tapSD', tapS, ...
    'frames', fr, 'frameReadings', readR, 'frameTimes', el(iP), ...
    'grid', g, 'distance', dist, 'bgMean', muB, 'bgSD', sdB, 'standMean', muP, ...
    'standSD', sdP, 'meanChange', dMean, 'sdChange', dSD, 'calibration', cal);

if o.Plot
    out.fig = local_plot(out, nm, chKey, o);
    print(out.fig, fullfile(captureDir, 'cir_static_distance.png'), '-dpng', '-r150');
    if o.Verbose, fprintf('Saved cir_static_distance.png / .csv\n'); end
end
end

% =============================================================================
function [mu, sd] = local_stats(X)
% Mean and SD over frames, ignoring NaN; a tap reached by fewer than 80% of
% the frames is dropped (cir_phase_analysis2's coverage rule).
ok = isfinite(X); n = sum(ok, 2);
X0 = X; X0(~ok) = 0;
mu = sum(X0, 2) ./ max(n, 1);
D = X - mu; D(~ok) = 0;
sd = sqrt(sum(D.^2, 2) ./ max(n - 1, 1));
thin = n < max(3, ceil(0.8 * size(X, 2)));
mu(thin) = NaN; sd(thin) = NaN;
end

function [tap, r] = local_strongest(v, g, win, cfg, k0)
% Largest positive value inside win, refined between grid points.
tap = NaN; r = NaN;
v = v(:); v(~win | ~isfinite(v)) = NaN;
[pk, j] = max(v);
if isempty(j) || ~(pk > 0), return; end
tap = g(j) + local_parab(v, j) * (g(2) - g(1));
r = mti_geometry('tap2range', tap, cfg, k0);
end

function d = local_parab(v, j)
% Sub-grid offset of a peak, in grid points (|d| <= 0.5).
d = 0;
if j < 2 || j > numel(v) - 1 || ~all(isfinite(v(j-1:j+1))), return; end
a = v(j-1); b = v(j); c = v(j+1);
den = a - 2*b + c;
if den < 0, d = 0.5 * (a - c) / den; end
end

% =============================================================================
function C = local_cal_read(file, chKey)
C = struct('n', 0, 'k0', NaN, 'file', file);
if ~exist(file, 'file'), return; end
T = readtable(file, 'Delimiter', ',', 'TextType', 'string');
if isempty(T) || ~all(ismember({'channel', 'k0_taps'}, T.Properties.VariableNames)), return; end
use = string(T.channel) == chKey & isfinite(T.k0_taps);
C.n = sum(use);
if C.n > 0, C.k0 = median(T.k0_taps(use)); end
end

function local_cal_append(file, capture, chKey, sep, trueD, k0impl, hTap)
isNew = ~exist(file, 'file');
fid = fopen(file, 'a');
if fid < 0, error('Cannot write the calibration file %s', file); end
if isNew
    fprintf(fid, 'date_time,capture,channel,separation_m,true_distance_m,k0_taps,hump_taps\n');
end
fprintf(fid, '%s,%s,%s,%g,%g,%.3f,%.3f\n', datestr(now, 'yyyy-mm-dd HH:MM:SS'), ... %#ok<TNOW1,DATST>
    capture, chKey, sep, trueD, k0impl, hTap);
fclose(fid);
end

% =============================================================================
function v = local_num(S, name, dflt)
v = dflt;
if isfield(S, name) && isnumeric(S.(name)) && isscalar(S.(name)) && isfinite(S.(name))
    v = S.(name);
end
end

function d = local_newest(root)
L = dir(fullfile(root, 'Capture_IQ_*'));
L = L([L.isdir]);
if isempty(L), error('No Capture_IQ_* folder in %s', root); end
[~, j] = max([L.datenum]);
d = fullfile(root, L(j).name);
end

% =============================================================================
function fig = local_plot(R, nm, chKey, o)
fig = figure('Color', 'w', 'Position', [60 40 1100 950]);
g = R.grid;

% 1. Empty room: the humps, and the zero
ax1 = subplot(3, 1, 1); hold(ax1, 'on'); grid(ax1, 'on');
top = max(R.bgMean(g >= -1 & g <= 40));
db = 20 * log10(R.bgMean / top);
k = g >= -5 & g <= 40;
plot(ax1, g(k), db(k), 'k-', 'LineWidth', 1.4, 'HandleVisibility', 'off');
for q = 1:numel(R.humps)
    plot(ax1, R.humps(q), interp1(g, db, R.humps(q)), 'o', 'Color', [0.45 0.45 0.45], ...
        'MarkerSize', 7, 'LineWidth', 1.2, 'HandleVisibility', 'off');
    text(ax1, R.humps(q), interp1(g, db, R.humps(q)) + 2.5, sprintf('%+.1f', R.humps(q)), ...
        'HorizontalAlignment', 'center', 'FontSize', 8, 'Color', [0.35 0.35 0.35]);
end
yl = [max(min(db(k)) - 3, -50) 8];
h = plot(ax1, [R.k0 R.k0], yl, '-', 'Color', [0.85 0.33 0.1], 'LineWidth', 2, ...
    'DisplayName', sprintf('range zero %+.2f taps (%s)', R.k0, strtok(R.k0Source, ':')));
if isfinite(R.k0Implied)
    h(2) = plot(ax1, [R.k0Implied R.k0Implied], yl, '--', 'Color', [0 0.6 0], 'LineWidth', 1.5, ...
        'DisplayName', sprintf('zero this run implies (%.2f m true): %+.2f', R.trueDistance, R.k0Implied));
end
plot(ax1, [0 0], yl, ':', 'Color', [0.4 0.4 0.4], 'HandleVisibility', 'off');
xlim(ax1, [-5 40]); ylim(ax1, yl);
xlabel(ax1, 'Taps after FP\_INDEX'); ylabel(ax1, 'dB re tallest');
title(ax1, 'Empty room |CIR|: circles = humps (routes of the direct path)', 'FontWeight', 'normal');
legend(ax1, h, 'Location', 'northeast');

% 2. Standing change vs distance
ax2 = subplot(3, 1, 2); hold(ax2, 'on'); grid(ax2, 'on');
ok = isfinite(R.distance) & R.distance <= o.MaxRangeM;
vM = max(R.meanChange, 0); vS = max(R.sdChange, 0);
hh = plot(ax2, R.distance(ok), vM(ok) / max(vM(ok)), '-', 'Color', [0 0.35 0.75], ...
    'LineWidth', 1.5, 'DisplayName', sprintf('mean change: %.2f m', R.rangeMean));
hh(2) = plot(ax2, R.distance(ok), vS(ok) / max(vS(ok)), '-', 'Color', [0.5 0.2 0.6], ...
    'LineWidth', 1.3, 'DisplayName', sprintf('SD change (BSDA): %.2f m', R.rangeSD));
plot(ax2, R.rangeMean, 1, 'd', 'MarkerFaceColor', [0 0.35 0.75], 'MarkerEdgeColor', 'k', ...
    'MarkerSize', 9, 'HandleVisibility', 'off');
plot(ax2, R.rangeSD, interp1(R.distance(ok), vS(ok) / max(vS(ok)), R.rangeSD), 'd', ...
    'MarkerFaceColor', [0.5 0.2 0.6], 'MarkerEdgeColor', 'k', 'MarkerSize', 9, 'HandleVisibility', 'off');
if isfinite(R.trueDistance)
    hh(3) = plot(ax2, [R.trueDistance R.trueDistance], [0 1.1], '--', 'Color', [0 0.6 0], ...
        'LineWidth', 1.5, 'DisplayName', sprintf('true %.2f m', R.trueDistance));
end
xlim(ax2, [0 o.MaxRangeM]); ylim(ax2, [0 1.1]);
xlabel(ax2, 'Distance from the midpoint of the modules (m)'); ylabel(ax2, 'change (norm.)');
title(ax2, 'Standing minus empty room: the target is the STRONGEST change', 'FontWeight', 'normal');
legend(ax2, hh, 'Location', 'northeast');

% 3. Every standing frame on its own
ax3 = subplot(3, 1, 3); hold(ax3, 'on'); grid(ax3, 'on');
plot(ax3, R.frameTimes, R.frameReadings, 'o', 'Color', [0 0.35 0.75], 'MarkerSize', 4);
if isfinite(R.frames.median)
    plot(ax3, R.frameTimes([1 end]), R.frames.median * [1 1], '-', 'Color', [0 0.35 0.75]);
end
if isfinite(R.trueDistance)
    plot(ax3, R.frameTimes([1 end]), R.trueDistance * [1 1], '--', 'Color', [0 0.6 0], 'LineWidth', 1.5);
end
ylim(ax3, [0 o.MaxRangeM]);
xlabel(ax3, 'Time (s)'); ylabel(ax3, 'Distance (m)');
title(ax3, sprintf('Single frames: median %.2f m, spread %.2f m, %.0f%% of frames', ...
    R.frames.median, R.frames.spread, 100 * R.frames.hit), 'FontWeight', 'normal');
sgtitle(fig, sprintf('%s  -  channel %s, modules %.2f m apart', nm, chKey, R.separation), ...
    'Interpreter', 'none', 'FontSize', 11);
end
