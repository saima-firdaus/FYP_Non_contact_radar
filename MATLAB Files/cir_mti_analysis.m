function out = cir_mti_analysis(src, varargin)
%CIR_MTI_ANALYSIS  Offline MTI on a saved capture: distance of the moving person vs time.
%
%   out = CIR_MTI_ANALYSIS(src)
%   out = CIR_MTI_ANALYSIS(src, 'Name', value, ...)
%   out = CIR_MTI_ANALYSIS()          newest Capture_MTI_* folder in pwd
%
% src is a Capture_MTI_* folder (or its serial_log.txt) recorded by
% cir_mti_live, or an old CIR_capture folder (magnitude-only, see
% mti_read_capture). Runs exactly the per-frame chain cir_mti_live runs
% (mti_step), over the whole capture, then plots:
%
%   1. distance vs time: raw detections (dots) and the tracked distance
%   2. how fast that distance is changing (+ = walking away)
%   3. how long the person was detected at each distance (histogram)
%
% plus a second figure, mti_compare: the same capture through both
% detectors, complex subtraction above variance, on the same axes, headed
% with the separation L and the range searched.
%
% The capture's own settings are used: MTIMode, Separation, MaxRange,
% LearnSeconds, SettleSeconds and ClutterAlpha come from its
% session_info.csv (what cir_mti_live / cir_mti_live_variance ran with), so a
% variance recording is analysed with the variance detector. Anything passed
% here overrides them.
%
% Options: anything MTI_CONFIG takes (Separation, MaxRange, MTIMode,
% ClutterAlpha, LearnSeconds, ThresholdFactor, ...) plus
%   'Plot'          true
%   'Save'          true    write mti_track.csv and the figures (.png/.fig)
%                           (replaces the live run's mti_track.csv)
%   'Compare'       true    also run the detector the capture was NOT
%                           recorded with, for the mti_compare figure
%   'ShowRangeTime' []      add a distance-time map of the detector's output
%                           over its threshold (panel 4), with the track on
%                           it; [] = on for variance captures, off otherwise
%
% The first LearnSeconds (after SettleSeconds) must be an empty scene: that
% is where the static room and the detection threshold are learned. Frames
% in that window never produce a distance.

% The mti_*.m helpers must sit in the same folder as this file.
addpath(fileparts(mfilename('fullpath')));
if exist('mti_config', 'file') ~= 2
    error(['mti_config.m not found. Copy the WHOLE mti folder (all mti_*.m ' ...
           'files) next to this script.']);
end

% ---- Arguments -------------------------------------------------------------
if nargin < 1 || isempty(src)
    src = local_newest(pwd);
end
plotIt = true; saveIt = true; showRT = []; compareIt = true;
cfgArgs = {};
for k = 1:2:numel(varargin)
    switch lower(varargin{k})
        case 'plot',          plotIt = logical(varargin{k+1});
        case 'save',          saveIt = logical(varargin{k+1});
        case 'compare',       compareIt = logical(varargin{k+1});
        case 'showrangetime', showRT = logical(varargin{k+1});
        otherwise,            cfgArgs(end+1:end+2) = varargin(k:k+1); %#ok<AGROW>
    end
end

[frames, info] = mti_read_capture(src);
% The settings the capture was recorded with, unless given here
sesMap = {'mti_mode', 'MTIMode'; 'separation_m', 'Separation'; 'max_range_m', 'MaxRange'; ...
          'learn_seconds', 'LearnSeconds'; 'settle_seconds', 'SettleSeconds'; ...
          'clutter_alpha', 'ClutterAlpha'};
sesArgs = {}; sesUsed = {};
for k = 1:size(sesMap, 1)
    if ~isfield(info.session, sesMap{k, 1}) || any(strcmpi(cfgArgs(1:2:end), sesMap{k, 2}))
        continue
    end
    v = info.session.(sesMap{k, 1});
    if isnumeric(v) && ~(isscalar(v) && isfinite(v)), continue; end
    if ~isnumeric(v), v = char(string(v)); end
    sesArgs(end+1:end+2) = {sesMap{k, 2}, v}; %#ok<AGROW>
    sesUsed{end+1} = sprintf('%s %s', sesMap{k, 2}, char(string(v))); %#ok<AGROW>
end
cfg = mti_config(sesArgs{:}, cfgArgs{:});
if isempty(showRT), showRT = strcmpi(cfg.MTIMode, 'variance'); end
if ~info.coherent
    cfg.Coherent = false;
    fprintf(['NOTE: %s has no I/Q (CIR_capture only saves amplitude), so ' ...
             'this is magnitude-only MTI.\n      Record with cir_mti_live ' ...
             'for the full coherent version.\n'], info.source);
end
if isfield(info.session, 'tap_to_metres') && isnumeric(info.session.tap_to_metres)
    cfg.TapToMetres = info.session.tap_to_metres;
end
% An old CIR_capture session has an empty-room background phase of its own:
% learn over exactly that, unless LearnSeconds was given explicitly.
if isfield(info.session, 'walk_prompt_at_s') && isnumeric(info.session.walk_prompt_at_s) ...
        && ~any(strcmpi(cfgArgs(1:2:end), 'LearnSeconds'))
    cfg.LearnSeconds = max(info.session.walk_prompt_at_s - cfg.SettleSeconds, 1);
end

% ---- Run -------------------------------------------------------------------
M = local_run(frames, cfg);
S = M.S; n = numel(frames);
t = M.t; fno = M.fno; rDet = M.rDet; rTrk = M.rTrk; vTrk = M.vTrk; snr = M.snr;
status = M.status; lag = M.lag; Emap = M.Emap;

out = struct('source', info.source, 'cfg', cfg, 't', t, 'frame', fno, ...
    'rDet', rDet, 'rTrack', rTrk, 'vTrack', vTrk, 'snrDB', snr, ...
    'status', {status}, 'rangeAxis', S.rangeAxis, 'grid', S.grid, ...
    'k0', S.k0, 'coherent', cfg.Coherent);
out.mtiOverThreshold = Emap;       % taps x frames, 1 = detection level

% ---- Summary ------------------------------------------------------------------
live = ~strcmp(status, 'settling') & ~strcmp(status, 'learning');
fprintf('\n=== MTI: %s ===\n', info.source);
fprintf('Frames      : %d (%.1f s, %.1f Hz)\n', n, t(end), (n-1)/max(t(end),eps));
if ~isempty(sesUsed)
    fprintf('Settings    : from session_info.csv - %s\n', strjoin(sesUsed, ', '));
end
fprintf('Geometry    : modules %.2f m apart, searching %.2f-%.2f m, direct-path peak +%.2f taps\n', ...
    cfg.Separation, cfg.MinRange, cfg.MaxRange, S.k0);
if strcmpi(cfg.MTIMode, 'variance')
    fprintf('MTI         : variance of |CIR| over %d frames (%s), x%.2f threshold (Pfa %g)\n', ...
        S.nWin, cfg.VarianceNormalise, S.thrFactor, cfg.VariancePfa);
else
    fprintf('MTI         : %s, %s\n', cfg.MTIMode, local_tf(cfg.Coherent, 'coherent I/Q', 'magnitude only'));
end
fprintf('Detections  : %d of %d frames after learning (%.0f%%)\n', ...
    sum(isfinite(rDet)), sum(live), 100*sum(isfinite(rDet))/max(sum(live),1));
if any(isfinite(rTrk))
    fprintf('Distance    : %.2f to %.2f m (tracked)\n', min(rTrk), max(rTrk));
end
if any(isfinite(lag))
    % elapsed_s is when MATLAB read each frame; t now follows the anchor's
    % RX timestamps, so the difference is how far the live loop was behind.
    lagRel = lag - min(lag);
    fprintf('Live lag    : median %.2f s, max %.2f s (host read time vs anchor timestamps)\n', ...
        median(lagRel(isfinite(lagRel))), max(lagRel));
    out.lag = lagRel;
end
truth = local_truth(src);
if ~isempty(truth)
    tr = interp1(truth(:,1) - truth(1,1), truth(:,2), t);
    ok = isfinite(tr) & isfinite(rTrk);
    if any(ok)
        e = rTrk(ok) - tr(ok);
        fprintf('vs truth    : bias %+.2f m, RMS %.2f m over %d frames\n', ...
            mean(e), sqrt(mean(e.^2)), sum(ok));
    end
    empty = live & ~isfinite(tr);
    fprintf('False alarms: %d detections in %d empty-scene frames\n', ...
        sum(isfinite(rDet(empty))), sum(empty));
    out.truth = [t tr];
end

% ---- The same capture through both detectors ----------------------------------------
% The one it was recorded with is the run above; the other is run here with
% every other setting the same.
if compareIt
    modes = {'clutter', 'variance'};
    C = cell(1, 2);
    for k = 1:2
        if strcmpi(cfg.MTIMode, modes{k})
            C{k} = M;
        else
            cfgK = cfg; cfgK.MTIMode = modes{k};
            C{k} = local_run(frames, cfgK);
        end
    end
    det = cellfun(@(c) 100 * sum(isfinite(c.rDet(c.live))) / max(sum(c.live), 1), C);
    fprintf('Compare     : complex subtraction detects in %.0f%%, variance in %.0f%% of frames after learning', det);
    both = isfinite(C{1}.rTrk) & isfinite(C{2}.rTrk);
    if any(both)
        fprintf('; where both track, they differ by a median %.2f m', ...
            median(abs(C{1}.rTrk(both) - C{2}.rTrk(both))));
    end
    fprintf('\n');
    out.compare = struct('mode', {modes}, 'rDet', {{C{1}.rDet, C{2}.rDet}}, ...
        'rTrack', {{C{1}.rTrk, C{2}.rTrk}}, 'detectedPct', det);
end

% ---- Save -----------------------------------------------------------------------
outDir = local_dir(src);
if saveIt
    fid = fopen(fullfile(outDir, 'mti_track.csv'), 'w');
    fprintf(fid, 'elapsed_s,frame,status,detected_m,tracked_m,speed_mps,snr_db\n');
    for i = 1:n
        fprintf(fid, '%.4f,%d,%s,%.4f,%.4f,%.4f,%.2f\n', t(i), fno(i), ...
            status{i}, rDet(i), rTrk(i), vTrk(i), snr(i));
    end
    fclose(fid);
    fprintf('Saved mti_track.csv\n');
end

% ---- Plot ------------------------------------------------------------------------
if plotIt
    nP = 3 + showRT;
    fig = figure('Color', 'w', 'Position', [80 60 1000 250*nP]);
    learnEnd = cfg.SettleSeconds + cfg.LearnSeconds;

    name = local_name(info.source);
    ax1 = subplot(nP, 1, 1);
    local_distance_panel(ax1, out, cfg, learnEnd, sprintf('Person distance vs time  -  %s', name));

    ax2 = subplot(nP, 1, 2); hold(ax2, 'on');
    plot(ax2, t, vTrk, '-', 'Color', [0.2 0.55 0.2], 'LineWidth', 1.5);
    plot(ax2, [0 t(end)], [0 0], 'k:');
    xlim(ax2, [0 t(end)]); grid(ax2, 'on');
    ylabel(ax2, 'Speed (m/s)');
    title(ax2, 'Rate of change of distance  (+ = moving away, - = approaching)');

    ax3 = subplot(nP, 1, 3); hold(ax3, 'on');
    edges = 0 : 0.1 : cfg.MaxRange + 0.1;
    rd = rDet(isfinite(rDet));
    cnt = accumarray(min(floor(rd / 0.1) + 1, numel(edges)), 1, [numel(edges) 1]);
    dtF = median(diff(t));
    bar(ax3, edges + 0.05, cnt(:) * dtF, 1, 'FaceColor', [0.45 0.2 0.6], ...
        'EdgeColor', 'w');
    grid(ax3, 'on'); xlim(ax3, [0 cfg.MaxRange + 0.2]);
    xlabel(ax3, 'Distance from midpoint of the modules (m)');
    ylabel(ax3, 'Time detected (s)');
    title(ax3, 'Where the moving person was detected (0.1 m bins)');

    if showRT && ~isempty(Emap)
        ax4 = subplot(nP, 1, 4);
        % Taps are not evenly spaced in distance (ellipse), so resample
        % onto an even distance axis before drawing.
        okr = isfinite(S.rangeAxis);
        rr  = (cfg.MinRange : 0.05 : cfg.MaxRange).';
        db  = 10*log10(Emap(okr, :));
        db(~isfinite(db)) = -10;
        db  = interp1(S.rangeAxis(okr), db, rr, 'linear', -10);
        imagesc(ax4, t, rr, db);
        axis(ax4, 'xy'); caxis(ax4, [-10 20]); cb = colorbar(ax4);
        ylabel(cb, 'dB over threshold');
        hold(ax4, 'on');
        plot(ax4, t, rTrk, 'r-', 'LineWidth', 1.5);
        plot(ax4, t, rDet, 'w.', 'MarkerSize', 5);
        xlim(ax4, [0 t(end)]); ylim(ax4, [cfg.MinRange cfg.MaxRange]);
        xlabel(ax4, 'Time (s)'); ylabel(ax4, 'Distance (m)');
        if strcmpi(cfg.MTIMode, 'variance')
            title(ax4, sprintf(['Variance of |CIR| over %d frames vs the empty room (dB over ' ...
                'threshold); red = track, white = detections'], S.nWin));
        else
            title(ax4, 'MTI over threshold (dB) by distance and time; red = track, white = detections');
        end
    end
    xlabel(ax2, 'Time (s)');
    out.fig = fig;

    st = aps006_style();
    figs = {fig, 'mti_analysis'};

    % The same capture through both detectors, on the same axes
    if compareIt
        figC = figure('Color', st.figureColour, 'Position', [120 40 1200 820]);
        tl = tiledlayout(figC, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
        title(tl, sprintf('Separation, d = %g m  |  Range = [%g, %g] m', cfg.Separation, cfg.MinRange, ...
            cfg.MaxRange), 'FontSize', st.labelFontSize + 1, 'FontWeight', 'bold');
        lbl = {'Complex subtraction (clutter map)', ...
               sprintf('Variance (BSDA), %d-frame window', C{2}.S.nWin)};
        axC = gobjects(1, 2);
        for k = 1:2
            D = struct('t', C{k}.t, 'rDet', C{k}.rDet, 'rTrack', C{k}.rTrk);
            if isfield(out, 'truth'), D.truth = out.truth; end
            axC(k) = nexttile(tl);
            local_distance_panel(axC(k), D, cfg, learnEnd, sprintf('%s: detected in %.0f%% of frames%s', ...
                lbl{k}, det(k), local_tf(strcmpi(cfg.MTIMode, modes{k}), '  (as recorded)', '')));
        end
        xlabel(axC(2), 'Time (s)', 'FontSize', st.labelFontSize);
        linkaxes(axC, 'xy');
        out.compareFig = figC;
        figs(end+1, :) = {figC, 'mti_compare'};
    end

    if saveIt
        for k = 1:size(figs, 1)
            print(figs{k, 1}, fullfile(outDir, [figs{k, 2} '.png']), '-dpng', '-r150');
            if exist('savefig', 'file') || exist('savefig', 'builtin')
                try, savefig(figs{k, 1}, fullfile(outDir, [figs{k, 2} '.fig'])); catch, end %#ok<NOCOM>
            end
        end
        fprintf('Saved %s (.png/.fig)\n', strjoin(figs(:, 2).', ', '));
    end
end
end

% =============================================================================
function M = local_run(frames, cfg)
% Every frame through mti_step, exactly as cir_mti_live runs it.
S = mti_init(cfg);
n = numel(frames);
M = struct('t', nan(n,1), 'fno', nan(n,1), 'rDet', nan(n,1), 'rTrk', nan(n,1), ...
           'vTrk', nan(n,1), 'snr', nan(n,1), 'status', {cell(n,1)}, 'lag', nan(n,1), ...
           'Emap', []);
for i = 1:n
    [S, R] = mti_step(S, frames{i});
    M.t(i) = R.t; M.fno(i) = R.frameNo; M.rDet(i) = R.rDet; M.rTrk(i) = R.rTrack;
    M.vTrk(i) = R.vTrack; M.snr(i) = R.snrDB; M.status{i} = R.status; M.lag(i) = R.lag;
    if ~isempty(R.energy)
        if isempty(M.Emap), M.Emap = nan(numel(R.energy), n); end
        M.Emap(:, i) = R.energy ./ R.threshold;
    end
end
M.t = M.t - M.t(1);
M.S = S;
M.live = ~strcmp(M.status, 'settling') & ~strcmp(M.status, 'learning');
end

% =============================================================================
function local_distance_panel(ax, D, cfg, learnEnd, ttl)
% Distance vs time in the APS006 look of the CIR plots (aps006_style): blue
% trace with asterisks, dashed grid, boxed axes. 0 to MaxRange, so runs with
% the same range gate share one scale. D has t, rDet, rTrack (and truth).
st = aps006_style();
hold(ax, 'on');
t = D.t;
yl = [0 cfg.MaxRange];
patch(ax, [0 learnEnd learnEnd 0], yl([1 1 2 2]), st.excludeColour, 'EdgeColor', 'none', ...
    'FaceAlpha', st.excludeAlpha, 'HandleVisibility', 'off');
text(ax, learnEnd/2, cfg.MaxRange/2, {'learning', 'empty room'}, ...
    'HorizontalAlignment', 'center', 'Color', [0.4 0.4 0.4], 'FontSize', st.fontSize);
h = plot(ax, t, D.rDet, '.', 'Color', [0.55 0.55 0.55], 'MarkerSize', 8);
step = max(1, round(0.5 / median(diff(t), 'omitnan')));      % an asterisk every ~0.5 s
h(2) = plot(ax, t, D.rTrack, '-', 'Color', st.cirColour, 'LineWidth', 1.2, ...
    'Marker', st.cirMarker, 'MarkerSize', st.cirMarkerSize, 'MarkerIndices', 1:step:numel(t));
names = {'Detection (this frame)', 'Tracked distance'};
if isfield(D, 'truth')
    h(3) = plot(ax, t, D.truth(:,2), '--', 'Color', st.fpColour, 'LineWidth', st.fpWidth);
    names{3} = 'True distance';
end
local_style_axes(ax, st);
ylim(ax, yl); xlim(ax, [0 t(end)]);
ylabel(ax, 'Distance from midpoint (m)', 'FontSize', st.labelFontSize);
title(ax, ttl, 'FontSize', st.labelFontSize, 'FontWeight', 'normal', 'Interpreter', 'none');
legend(ax, h, names, 'Location', 'northwest', 'FontSize', st.legendSize, 'Box', 'on', ...
    'EdgeColor', [0 0 0]);
end

function local_style_axes(ax, st)
% The axes styling cir_phase_analysis_variance / cir_phase_analysisD use.
grid(ax, 'on');
ax.GridLineStyle = st.gridStyle;
ax.GridColor     = st.gridColour;
ax.GridAlpha     = st.gridAlpha;
ax.Layer         = 'bottom';
ax.FontSize      = st.fontSize;
ax.LineWidth     = st.axesWidth;
ax.TickDir       = 'in';
box(ax, 'on');
end

% =============================================================================
function s = local_tf(c, a, b)
if c, s = a; else, s = b; end
end

function d = local_dir(src)
src = char(src);
if exist(src, 'dir'), d = src; else, d = fileparts(src); end
if isempty(d), d = pwd; end
end

function n = local_name(src)
[~, n, e] = fileparts(char(src));
if strcmp([n e], 'serial_log.txt'), [~, n] = fileparts(fileparts(char(src))); end
end

function tr = local_truth(src)
tr = [];
f = fullfile(local_dir(src), 'truth.csv');
if exist(f, 'file'), tr = dlmread(f, ',', 1, 0); end
end

function d = local_newest(root)
L = dir(fullfile(root, 'Capture_MTI_*'));
L = L([L.isdir]);
if isempty(L), error('No Capture_MTI_* folder in %s', root); end
[~, j] = max([L.datenum]);
d = fullfile(root, L(j).name);
end
