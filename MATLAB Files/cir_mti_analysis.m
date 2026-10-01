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
% Options: anything MTI_CONFIG takes (Separation, MaxRange, MTIMode,
% ClutterAlpha, LearnSeconds, ThresholdFactor, ...) plus
%   'Plot'          true
%   'Save'          true    write mti_track.csv and mti_analysis.png/.fig
%   'ShowRangeTime' false   add a distance-time intensity map (panel 4)
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
plotIt = true; saveIt = true; showRT = false;
cfgArgs = {};
for k = 1:2:numel(varargin)
    switch lower(varargin{k})
        case 'plot',          plotIt = logical(varargin{k+1});
        case 'save',          saveIt = logical(varargin{k+1});
        case 'showrangetime', showRT = logical(varargin{k+1});
        otherwise,            cfgArgs(end+1:end+2) = varargin(k:k+1); %#ok<AGROW>
    end
end

[frames, info] = mti_read_capture(src);
cfg = mti_config(cfgArgs{:});
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
S = mti_init(cfg);
n = numel(frames);
t = nan(n,1); fno = nan(n,1); rDet = nan(n,1); rTrk = nan(n,1);
vTrk = nan(n,1); snr = nan(n,1); status = cell(n,1); lag = nan(n,1);
Emap = [];
for i = 1:n
    [S, R] = mti_step(S, frames{i});
    t(i) = R.t; fno(i) = R.frameNo; rDet(i) = R.rDet; rTrk(i) = R.rTrack;
    vTrk(i) = R.vTrack; snr(i) = R.snrDB; status{i} = R.status; lag(i) = R.lag;
    if ~isempty(R.energy)
        if isempty(Emap), Emap = nan(numel(R.energy), n); end
        Emap(:, i) = R.energy ./ R.threshold;
    end
end
t = t - t(1);

out = struct('source', info.source, 'cfg', cfg, 't', t, 'frame', fno, ...
    'rDet', rDet, 'rTrack', rTrk, 'vTrack', vTrk, 'snrDB', snr, ...
    'status', {status}, 'rangeAxis', S.rangeAxis, 'grid', S.grid, ...
    'k0', S.k0, 'coherent', cfg.Coherent);
out.mtiOverThreshold = Emap;       % taps x frames, 1 = detection level

% ---- Summary ------------------------------------------------------------------
live = ~strcmp(status, 'settling') & ~strcmp(status, 'learning');
fprintf('\n=== MTI: %s ===\n', info.source);
fprintf('Frames      : %d (%.1f s, %.1f Hz)\n', n, t(end), (n-1)/max(t(end),eps));
fprintf('Geometry    : modules %.2f m apart, searching %.2f-%.2f m, direct-path peak +%.2f taps\n', ...
    cfg.Separation, cfg.MinRange, cfg.MaxRange, S.k0);
fprintf('MTI         : %s, %s\n', cfg.MTIMode, local_tf(cfg.Coherent, 'coherent I/Q', 'magnitude only'));
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

    ax1 = subplot(nP, 1, 1); hold(ax1, 'on');
    yl = [0 cfg.MaxRange + 0.9];
    patch(ax1, [0 learnEnd learnEnd 0], yl([1 1 2 2]), [0.92 0.92 0.92], ...
        'EdgeColor', 'none');
    h = plot(ax1, t, rDet, '.', 'Color', [0.55 0.55 0.55], 'MarkerSize', 9);
    h(2) = plot(ax1, t, rTrk, '-', 'Color', [0 0.35 0.75], 'LineWidth', 2);
    names = {'Detection (this frame)', 'Tracked distance'};
    if isfield(out, 'truth')
        h(3) = plot(ax1, t, out.truth(:,2), '--', 'Color', [0.85 0.33 0.1], ...
            'LineWidth', 1.2);
        names{3} = 'True distance';
    end
    text(ax1, learnEnd/2, cfg.MaxRange/2, {'learning', 'empty room'}, ...
        'HorizontalAlignment', 'center', 'Color', [0.4 0.4 0.4]);
    ylim(ax1, yl); xlim(ax1, [0 t(end)]); grid(ax1, 'on');
    ylabel(ax1, 'Distance from midpoint (m)');
    title(ax1, sprintf('Person distance vs time  -  %s', local_name(info.source)), ...
        'Interpreter', 'none');
    legend(ax1, h, names, 'Location', 'north', 'Orientation', 'horizontal');

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
        axis(ax4, 'xy'); caxis(ax4, [-10 20]); colorbar(ax4);
        xlabel(ax4, 'Time (s)'); ylabel(ax4, 'Distance (m)');
        title(ax4, 'MTI over threshold (dB) by distance and time');
    end
    xlabel(ax2, 'Time (s)');
    out.fig = fig;

    if saveIt
        print(fig, fullfile(outDir, 'mti_analysis.png'), '-dpng', '-r150');
        if exist('savefig', 'file') || exist('savefig', 'builtin')
            try, savefig(fig, fullfile(outDir, 'mti_analysis.fig')); catch, end %#ok<NOCOM>
        end
        fprintf('Saved mti_analysis.png\n');
    end
end
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
