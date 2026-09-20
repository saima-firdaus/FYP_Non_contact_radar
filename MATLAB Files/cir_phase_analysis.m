function out = cir_phase_analysis(captureDir, varargin)
%CIR_PHASE_ANALYSIS  Split one capture into background / phase 2 and difference them.
%
%   out = CIR_PHASE_ANALYSIS(captureDir)
%   out = CIR_PHASE_ANALYSIS(captureDir, 'Name', value, ...)
%   out = CIR_PHASE_ANALYSIS()            % newest Capture_* folder in pwd
%
% CIR_capture.m records every frame's host-side arrival time as elapsed_s in
% frame_metadata.csv, and the phase boundaries it used in session_info.csv.
% This function reads both and cuts the session into:
%
%   background   elapsed_s <  WALK_PROMPT_AT_S
%   discard      the WALK_DURATION_S break - you were walking, so these
%                frames are dropped entirely
%   phase2       everything after the break
%
% Both phases come from the same continuous serial session, so the AGC and
% oscillator state they share is the whole point: nothing was reset between
% them, and the difference is not swamped by restart drift.
%
% Frame counts per phase always vary - the blink rate wanders and truncated
% frames never get written - so every average here is over however many
% valid frames actually landed in the window, never a fixed count.
%
% Name-value options:
%   'Plot'           true    draw and save the three-panel figure
%   'ShowSD'         true    shade +/- 1 SD across frames on the phase panels
%   'MinFrameFrac'   0.8     a grid point is only averaged where at least this
%                            fraction of the phase's frames reach it. FP_INDEX
%                            moves between frames, so the far ends of the grid
%                            are covered by some frames and not others, and a
%                            mean taken over a different subset of frames at
%                            one tap than at the next is not comparable with
%                            it - those taps come out as NaN instead. Set 0 to
%                            keep everything.
%   'WalkPromptAtS'  []      override session_info.csv (for older captures)
%   'WalkDurationS'  []      likewise
%   'Verbose'        true
%
% Writes into captureDir:
%   cir_mean_background.csv   taps_from_fp, amplitude_norm_mean,
%   cir_mean_phase2.csv       amplitude_norm_sd, n_frames
%   cir_diff.csv              phase 2 mean minus background mean
%   cir_phase_analysis.png / .fig
%
% Returns a struct with the grid, both phase means, the difference and the
% frame counts, so cir_compare_trial.m can reuse it without re-reading CSVs.
%
% See also CIR_COMPARE_TRIAL, CIR_MULTI_TRIAL, PLOT_CIR_APS006.

% ---- Arguments -----------------------------------------------------------
if nargin < 1 || isempty(captureDir)
    captureDir = local_newest_capture(pwd);
end
captureDir = char(captureDir);
if ~isfolder(captureDir)
    error('Capture folder not found: %s', captureDir);
end

p = inputParser;
p.addParameter('Plot',          true,  @(x) islogical(x) || isnumeric(x));
p.addParameter('ShowSD',        true,  @(x) islogical(x) || isnumeric(x));
p.addParameter('MinFrameFrac',  0.8,   @(x) isscalar(x) && x >= 0 && x <= 1);
p.addParameter('WalkPromptAtS', [],    @(x) isempty(x) || isscalar(x));
p.addParameter('WalkDurationS', [],    @(x) isempty(x) || isscalar(x));
p.addParameter('Verbose',       true,  @(x) islogical(x) || isnumeric(x));
p.parse(varargin{:});
opt = p.Results;

% ---- Session description -------------------------------------------------
S = local_read_session(captureDir);
if ~isempty(opt.WalkPromptAtS), S.walk_prompt_at_s = opt.WalkPromptAtS; end
if ~isempty(opt.WalkDurationS), S.walk_duration_s  = opt.WalkDurationS; end
if isnan(S.walk_prompt_at_s) || isnan(S.walk_duration_s)
    error(['No session_info.csv in %s and no phase timings given. Pass ' ...
           'WalkPromptAtS and WalkDurationS if this capture predates ' ...
           'session_info.csv.'], captureDir);
end
breakEndsAt = S.walk_prompt_at_s + S.walk_duration_s;

% ---- Frame metadata ------------------------------------------------------
metaFile = fullfile(captureDir, 'frame_metadata.csv');
if ~isfile(metaFile)
    error('No frame_metadata.csv in %s', captureDir);
end
M = readtable(metaFile);
if ~ismember('elapsed_s', M.Properties.VariableNames)
    error(['frame_metadata.csv in %s has no elapsed_s column, so its frames ' ...
           'cannot be assigned to a phase. It predates the phased capture ' ...
           'script - recapture with the current CIR_capture.m.'], captureDir);
end

el     = M.elapsed_s;
isBg   = el <  S.walk_prompt_at_s;
isWalk = el >= S.walk_prompt_at_s & el < breakEndsAt;
isP2   = el >= breakEndsAt;

if opt.Verbose
    fprintf('\n=== %s ===\n', captureDir);
    if strlength(S.run_label) > 0
        fprintf('Run label : %s\n', S.run_label);
    end
    fprintf('Phases    : background 0-%gs | break %g-%gs | phase2 %g-%gs\n', ...
        S.walk_prompt_at_s, S.walk_prompt_at_s, breakEndsAt, breakEndsAt, ...
        S.capture_seconds);
    fprintf('Frames    : %d background | %d discarded | %d phase2 (of %d)\n', ...
        sum(isBg), sum(isWalk), sum(isP2), height(M));
end

if sum(isBg) == 0 || sum(isP2) == 0
    error(['Need frames in both phases: got %d background and %d phase2. ' ...
           'This capture cannot be differenced.'], sum(isBg), sum(isP2));
end

% ---- Common delay grid ---------------------------------------------------
% The same grid CIR_capture.m averages onto, rebuilt from session_info.csv
% so that the two can never drift apart.
gTaps = (-S.taps_before_fp : S.mean_grid_step : S.taps_after_fp)';

bg = local_phase_average(captureDir, M(isBg, :), gTaps, S, 'background', opt);
p2 = local_phase_average(captureDir, M(isP2, :), gTaps, S, 'phase2',     opt);

% ---- Difference ----------------------------------------------------------
% Non-coherent magnitudes, so this is a change in reflected energy per tap,
% and it is free to go negative where the target shadowed an existing path.
dAmp = p2.mu - bg.mu;

% ---- Save ----------------------------------------------------------------
bgT = table(gTaps, bg.mu, bg.sd, bg.nPer, 'VariableNames', ...
    {'taps_from_fp','amplitude_norm_mean','amplitude_norm_sd','n_frames'});
p2T = table(gTaps, p2.mu, p2.sd, p2.nPer, 'VariableNames', ...
    {'taps_from_fp','amplitude_norm_mean','amplitude_norm_sd','n_frames'});
dT  = table(gTaps, dAmp, bg.mu, p2.mu, bg.nPer, p2.nPer, 'VariableNames', ...
    {'taps_from_fp','amplitude_norm_diff','background_mean','phase2_mean', ...
     'n_background','n_phase2'});

writetable(bgT, fullfile(captureDir, 'cir_mean_background.csv'));
writetable(p2T, fullfile(captureDir, 'cir_mean_phase2.csv'));
writetable(dT,  fullfile(captureDir, 'cir_diff.csv'));

if opt.Verbose
    fprintf('Saved cir_mean_background.csv, cir_mean_phase2.csv, cir_diff.csv\n');
end

% ---- Result --------------------------------------------------------------
out = struct();
out.dir        = captureDir;
out.session    = S;
out.gTaps      = gTaps;
out.background = bg;
out.phase2     = p2;
out.diff       = dAmp;
out.counts     = struct('background', sum(isBg), 'discarded', sum(isWalk), ...
                        'phase2', sum(isP2), 'total', height(M));

% ---- Figure --------------------------------------------------------------
if opt.Plot
    out.fig = local_plot(out, logical(opt.ShowSD));
    exportgraphics(out.fig, fullfile(captureDir, 'cir_phase_analysis.png'), ...
        'Resolution', 200);
    savefig(out.fig, fullfile(captureDir, 'cir_phase_analysis.fig'));
    if opt.Verbose
        fprintf('Saved cir_phase_analysis.png / .fig\n');
    end
end
end

% =========================================================================
function ph = local_phase_average(captureDir, Mp, gTaps, S, name, opt)
%LOCAL_PHASE_AVERAGE  Non-coherent average of one phase's frames.
%
% Each frame is resampled onto the shared taps-from-FP grid before averaging,
% because FP_INDEX is fractional and differs frame to frame. Magnitudes are
% averaged, never I/Q: the carrier phase of every path rotates between
% frames, so a coherent average would cancel real energy.

verbose  = opt.Verbose;
nWanted  = height(Mp);
ampGrid  = nan(numel(gTaps), nWanted);
nUsed    = 0;
nMissing = 0;

for i = 1:nWanted
    f = local_frame_path(captureDir, Mp, i, S.aligned_subdir);
    if isempty(f) || ~isfile(f)
        nMissing = nMissing + 1;
        continue
    end
    T = readtable(f);
    if ~all(ismember({'taps_from_fp','amplitude_norm'}, T.Properties.VariableNames))
        nMissing = nMissing + 1;
        continue
    end
    [uTaps, ia] = unique(T.taps_from_fp);
    if numel(uTaps) < 2
        nMissing = nMissing + 1;
        continue
    end
    nUsed = nUsed + 1;
    ampGrid(:, nUsed) = interp1(uTaps, T.amplitude_norm(ia), gTaps, 'linear', NaN);
end
ampGrid = ampGrid(:, 1:nUsed);

if nUsed == 0
    error('Phase "%s" has no readable aligned frame CSVs in %s', name, captureDir);
end
if nMissing > 0 && verbose
    fprintf('  %s: skipped %d unreadable/empty frame file(s).\n', name, nMissing);
end

nPer = sum(~isnan(ampGrid), 2);
mu   = mean(ampGrid, 2, 'omitnan');
sd   = std(ampGrid, 0, 2, 'omitnan');
mu(nPer == 0) = NaN;
sd(nPer <  2) = NaN;

% ---- Coverage ------------------------------------------------------------
% The grid runs from -TAPS_BEFORE_FP to +TAPS_AFTER_FP, but FP_INDEX drifts
% between frames, so near the ends only some frames reach a given tap. A mean
% over 6 of 41 frames at the last tap and over all 41 in the middle are not
% the same quantity, and differencing two such means manufactures excursions
% at the edges that have nothing to do with the scene. Drop the under-covered
% taps rather than let them turn into detections.
minPer = ceil(opt.MinFrameFrac * nUsed);
thin   = nPer < minPer;
mu(thin) = NaN;
sd(thin) = NaN;

ph = struct();
ph.name    = name;
ph.mu      = mu;
ph.sd      = sd;
ph.nPer    = nPer;
ph.nFrames = nUsed;
ph.noise   = local_phase_noise(Mp);

if verbose
    kept = ~isnan(mu);
    fprintf('  %s: averaged %d frame(s); kept %d of %d taps with >= %d frame(s)', ...
        name, nUsed, sum(kept), numel(gTaps), max(minPer,1));
    if any(kept)
        fprintf(' (taps %+g to %+g)', min(gTaps(kept)), max(gTaps(kept)));
    end
    fprintf('.\n');
end
end

% =========================================================================
function lvl = local_phase_noise(Mp)
%LOCAL_PHASE_NOISE  Averaged noise level for a phase, in amplitude/RXPACC units.
%
% The DW1000 reports STD_NOISE x NTM in raw accumulator magnitude, but these
% traces are averaged in amplitude/RXPACC, so each frame's threshold has to be
% divided by that frame's own RXPACC before averaging. Anything less than that
% - averaging raw thresholds, or borrowing one frame's RXPACC - puts the cyan
% line on the wrong scale, so when the columns needed are absent this returns
% NaN and the line is simply left off rather than guessed at.
lvl = NaN;
v = Mp.Properties.VariableNames;
if ~ismember('RXPACC', v), return; end

if ismember('NOISE_THRESH', v)
    thr = Mp.NOISE_THRESH;
elseif all(ismember({'STD_NOISE','NTM'}, v))
    thr = Mp.STD_NOISE .* Mp.NTM;
else
    return
end

acc = Mp.RXPACC;
ok  = isfinite(thr) & isfinite(acc) & acc > 0 & thr > 0;
if any(ok)
    lvl = mean(thr(ok) ./ acc(ok));
end
end

% =========================================================================
function f = local_frame_path(captureDir, Mp, i, alignedSubdir)
%LOCAL_FRAME_PATH  Where this row's aligned CSV lives.
% Prefers the path frame_metadata.csv recorded, and falls back to rebuilding
% it from the frame number so a hand-edited metadata file still resolves.
f = '';
v = Mp.Properties.VariableNames;

if ismember('aligned_csv', v)
    rel = Mp.aligned_csv(i);
    if iscell(rel)
        rel = rel{1};
    elseif isstring(rel)
        rel = char(rel);
    elseif ~ischar(rel)
        rel = '';
    end
    if ~isempty(rel)
        rel = strrep(rel, char(92), filesep);
        rel = strrep(rel, '/', filesep);
        f   = fullfile(captureDir, rel);
    end
end

if (isempty(f) || ~isfile(f)) && ismember('FRAME', v)
    f = fullfile(captureDir, alignedSubdir, ...
        sprintf('frame_%04d_aligned.csv', Mp.FRAME(i)));
end
end

% =========================================================================
function S = local_read_session(captureDir)
%LOCAL_READ_SESSION  session_info.csv, with defaults for anything absent.
S = struct('run_label', "", 'run_stamp', "", 'capture_seconds', NaN, ...
           'walk_prompt_at_s', NaN, 'walk_duration_s', NaN, ...
           'taps_before_fp', 50, 'taps_after_fp', 100, ...
           'mean_grid_step', 0.5, 'tap_to_metres', 0.30028, ...
           'aligned_subdir', '02_lde_aligned');

f = fullfile(captureDir, 'session_info.csv');
if ~isfile(f)
    warning('No session_info.csv in %s - falling back to script defaults.', ...
        captureDir);
    return
end

T  = readtable(f, 'TextType', 'string');
fn = fieldnames(S);
for i = 1:numel(fn)
    if ismember(fn{i}, T.Properties.VariableNames)
        val = T.(fn{i})(1);
        if isstring(val) || ischar(val)
            S.(fn{i}) = string(val);
        else
            S.(fn{i}) = val;
        end
    end
end
S.aligned_subdir = char(S.aligned_subdir);
S.run_label      = string(S.run_label);
end

% =========================================================================
function d = local_newest_capture(root)
%LOCAL_NEWEST_CAPTURE  Most recently modified Capture_* folder under root.
dd = dir(fullfile(root, 'Capture_*'));
dd = dd([dd.isdir]);
if isempty(dd)
    error('No Capture_* folder found in %s - pass a capture folder path.', root);
end
[~, newest] = max([dd.datenum]);
d = fullfile(root, dd(newest).name);
end

% =========================================================================
function fig = local_plot(R, showSD)
%LOCAL_PLOT  Background / phase 2 / difference, in APS006 visual language.
st  = aps006_style();
fig = figure('Color', st.figureColour, 'Position', [80 40 950 940]);
tl  = tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

ttl = 'CIR by phase';
if strlength(R.session.run_label) > 0
    ttl = sprintf('%s  -  %s', ttl, R.session.run_label);
end
% Interpreter none: run labels are full of underscores, and TeX would turn
% trial1_human_2m_los into subscripts.
title(tl, ttl, 'FontWeight', 'bold', 'Interpreter', 'none');

axList = gobjects(3,1);

% One y-range for both phase panels. Two panels meant to be compared by eye
% cannot be on scales that differ by however much autoscaling felt like - a
% background panel stretched to its own noise would read as the louder scene.
% The noise line is drawn after these limits are fixed, so a threshold far
% off the trace clips instead of flattening the CIR against the axis.
yr = local_y_range({R.background, R.phase2}, showSD);

axList(1) = local_phase_panel(tl, R.gTaps, R.background, st, showSD, yr, ...
    sprintf('Background (n = %d frames)', R.background.nFrames));
axList(2) = local_phase_panel(tl, R.gTaps, R.phase2, st, showSD, yr, ...
    sprintf('Phase 2, target present (n = %d frames)', R.phase2.nFrames));

% ---- Difference ----------------------------------------------------------
ax = nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
set(ax, 'FontSize', st.fontSize);
yline(ax, 0, '-', 'Color', st.zeroColour, 'LineWidth', st.zeroWidth);
h = plot(ax, R.gTaps, R.diff, '-', 'Color', st.diffColour, ...
    'LineWidth', st.diffWidth);
hFp = xline(ax, 0, '-', st.fpLabel, 'Color', st.fpColour, ...
    'LineWidth', st.fpWidth, 'LabelVerticalAlignment', 'top', ...
    'LabelHorizontalAlignment', 'left', 'FontSize', st.fontSize);
xlabel(ax, st.xLabelFP);
ylabel(ax, '\Delta Amplitude / RXPACC');
title(ax, 'Difference (Phase 2 - Background)');
legend(ax, [h hFp], {'Phase 2 - Background', 'aligned first path'}, ...
    'Location', 'northeast', 'FontSize', st.fontSize);
axList(3) = ax;

linkaxes(axList, 'x');
xlim(axList(1), [min(R.gTaps) max(R.gTaps)]);
end

% =========================================================================
function yr = local_y_range(phases, showSD)
%LOCAL_Y_RANGE  A single y-range covering every phase trace on the figure.
lo = []; hi = [];
for i = 1:numel(phases)
    mu = phases{i}.mu;
    sd = phases{i}.sd;
    if showSD
        band = [mu - sd; mu + sd];
    else
        band = mu;
    end
    band = band(isfinite(band));
    if isempty(band), continue; end
    lo = min([lo; band]);
    hi = max([hi; band]);
end
if isempty(lo)
    yr = [0 1];
    return
end
pad = 0.06 * max(hi - lo, eps);
yr  = [lo - pad, hi + pad];
end

% =========================================================================
function ax = local_phase_panel(tl, gTaps, ph, st, showSD, yr, titleStr)
%LOCAL_PHASE_PANEL  One averaged phase, drawn like the single-frame figure.
%
% Same conventions as PLOT_CIR_APS006: red vertical "Rep:Fp" line and, where
% the metadata supports one, the cyan noise level. The first path sits at
% taps_from_fp = 0 by construction here, since every frame was aligned onto
% it before averaging.
ax = nexttile(tl); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
set(ax, 'FontSize', st.fontSize);

hLeg = gobjects(0); lLeg = {};

if showSD
    ok = ~isnan(ph.mu) & ~isnan(ph.sd);
    if any(ok)
        xs = gTaps(ok);
        lo = ph.mu(ok) - ph.sd(ok);
        hi = ph.mu(ok) + ph.sd(ok);
        h  = fill(ax, [xs; flipud(xs)], [lo; flipud(hi)], st.sdFaceColour, ...
            'FaceAlpha', st.sdFaceAlpha, 'EdgeColor', 'none');
        hLeg(end+1) = h; lLeg{end+1} = '\pm1 SD across frames';
    end
end

h = plot(ax, gTaps, ph.mu, '-', 'Color', st.cirColour, 'LineWidth', st.cirWidth);
hLeg(end+1) = h; lLeg{end+1} = 'mean CIR';

h = xline(ax, 0, '-', st.fpLabel, 'Color', st.fpColour, ...
    'LineWidth', st.fpWidth, 'LabelVerticalAlignment', 'top', ...
    'LabelHorizontalAlignment', 'left', 'FontSize', st.fontSize);
hLeg(end+1) = h; lLeg{end+1} = 'aligned first path';

ylim(ax, yr);   % fixed before the noise line, so the line cannot rescale it

if ~isnan(ph.noise)
    h = yline(ax, ph.noise, '-', st.noiseLabel, 'Color', st.noiseColour, ...
        'LineWidth', st.noiseWidth, 'LabelHorizontalAlignment', 'right', ...
        'LabelVerticalAlignment', 'bottom', 'FontSize', st.fontSize);
    hLeg(end+1) = h;
    if ph.noise < yr(1) || ph.noise > yr(2)
        % Say so rather than let it look absent: a threshold off the top of
        % the panel means the averaged CIR never cleared it.
        lLeg{end+1} = sprintf('%s = %.4g (off scale)', st.noiseLabel, ph.noise);
    else
        lLeg{end+1} = sprintf('%s (mean)', st.noiseLabel);
    end
end

ylabel(ax, st.yLabelNorm);
title(ax, titleStr);
legend(ax, hLeg, lLeg, 'Location', 'northeast', 'FontSize', st.fontSize);
end
