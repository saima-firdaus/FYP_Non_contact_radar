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
%   'Separation'     []      tag-anchor separation in metres, for the distance
%                            axis on the difference panel. Normally resolved
%                            automatically - see local_separation - so this is
%                            only for captures that recorded it wrongly.
%   'MaxRangeM'      6       x-limit on the difference panel, in metres. The
%                            converted axis runs to tens of metres at the far
%                            taps (see local_offset_metres), which squeezes
%                            everything room-sized into the left edge. Inf
%                            shows the whole converted grid.
%   'NoiseSigmaK'    3       detection threshold on the difference panel, in
%                            sigma, where sigma is estimated from the trace's
%                            own negative excursions (see local_neg_noise).
%   'Verbose'        true
%
% Writes into captureDir:
%   cir_mean_background.csv   taps_from_fp, amplitude_norm_mean,
%   cir_mean_phase2.csv       amplitude_norm_sd, n_frames
%   cir_diff.csv              phase 2 mean minus background mean, plus the
%                             ellipse-geometry offset in metres and the
%                             negative-clipped difference actually plotted
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
p.addParameter('Separation',    [],    @(x) isempty(x) || (isscalar(x) && x > 0));
p.addParameter('MaxRangeM',     6,     @(x) isscalar(x) && x > 0);
p.addParameter('NoiseSigmaK',   3,     @(x) isscalar(x) && x >= 0);
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
% Non-coherent magnitudes, so this is a change in reflected energy per tap.
dAmp = p2.mu - bg.mu;

% ---- Distance axis and negative excursions -------------------------------
% A person standing in the scene ADDS a propagation path (tag -> person ->
% anchor), so at that path's delay the difference can only go up. It follows
% that a negative excursion is never a target range. Negatives come from the
% person shadowing a path the empty room already had, from a new reflection
% landing out of phase with a static one in the same delay bin, and from the
% noise/AGC floor - all real effects, none of them "the person is here".
%
% So they are clipped out of the plotted trace. What they are good for is
% measuring the floor: the negative half of the trace is noise-only by
% construction, which makes it an honest estimate of how big a positive bump
% has to be before it means anything. That estimate is taken BEFORE clipping
% and drawn as the detection threshold, so removing the negatives does not
% throw away the one thing they were telling you.
sepM = local_separation(S, M, opt);
[offM, resFloorM] = local_offset_metres(gTaps, S.tap_to_metres, sepM);

noiseSigma = local_neg_noise(dAmp);
detThresh  = opt.NoiseSigmaK * noiseSigma;

dPos = dAmp;
dPos(dPos < 0) = 0;      % NaN < 0 is false, so thin taps stay NaN, not zero

if opt.Verbose
    if isnan(sepM)
        fprintf(['Separation : unknown - difference panel stays on the tap ' ...
                 'axis. Pass Separation to convert it.\n']);
    else
        fprintf('Separation : %.3g m (foci) -> offset resolvable from %.2f m\n', ...
            sepM, resFloorM);
    end
    if isfinite(detThresh)
        fprintf('Noise floor: sigma %.4g from %d negative sample(s), threshold %gx = %.4g\n', ...
            noiseSigma, sum(dAmp < 0), opt.NoiseSigmaK, detThresh);
    end
end

% ---- Save ----------------------------------------------------------------
bgT = table(gTaps, bg.mu, bg.sd, bg.nPer, 'VariableNames', ...
    {'taps_from_fp','amplitude_norm_mean','amplitude_norm_sd','n_frames'});
p2T = table(gTaps, p2.mu, p2.sd, p2.nPer, 'VariableNames', ...
    {'taps_from_fp','amplitude_norm_mean','amplitude_norm_sd','n_frames'});
dT  = table(gTaps, offM, dAmp, dPos, bg.mu, p2.mu, bg.nPer, p2.nPer, ...
    'VariableNames', ...
    {'taps_from_fp','offset_m','amplitude_norm_diff','amplitude_norm_diff_pos', ...
     'background_mean','phase2_mean','n_background','n_phase2'});

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
out.diffPos    = dPos;        % negatives clipped - what the final panel draws
out.offsetM    = offM;        % ellipse offset from the tag-anchor baseline
out.separation = sepM;
out.resFloorM  = resFloorM;   % nearest offset one tap can express
out.noiseSigma = noiseSigma;
out.detThresh  = detThresh;
out.maxRangeM  = opt.MaxRangeM;
out.sigmaK     = opt.NoiseSigmaK;
out.counts     = struct('background', sum(isBg), 'discarded', sum(isWalk), ...
                        'phase2', sum(isP2), 'total', height(M));

% ---- Figure --------------------------------------------------------------
if opt.Plot
    out.fig = local_plot(out, logical(opt.ShowSD));
    exportgraphics(out.fig, fullfile(captureDir, 'cir_phase_analysis2.png'), ...
        'Resolution', 200);
    savefig(out.fig, fullfile(captureDir, 'cir_phase_analysis2.fig'));
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
ph.rxpwr   = local_phase_rxpwr(Mp);

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
function D = local_separation(S, M, opt)
%LOCAL_SEPARATION  Tag-anchor separation in metres, from wherever it survives.
%
% The separation is the focal distance of the ellipse the difference panel is
% drawn against, so getting it wrong silently rescales that whole axis. It is
% looked for in descending order of trustworthiness: an explicit override, the
% session description, what CIR_capture.m stamped into every frame's metadata,
% and only then the run label. Returns NaN if none of them have it, and the
% caller falls back to the tap axis rather than inventing a distance.
D = NaN;

if ~isempty(opt.Separation)
    D = opt.Separation;
    return
end

if isfield(S, 'tag_anchor_dist_m') && isscalar(S.tag_anchor_dist_m) && ...
        isnumeric(S.tag_anchor_dist_m) && isfinite(S.tag_anchor_dist_m) && ...
        S.tag_anchor_dist_m > 0
    D = S.tag_anchor_dist_m;
    return
end

if ismember('tag_anchor_dist_m', M.Properties.VariableNames)
    v = M.tag_anchor_dist_m;
    v = v(isfinite(v) & v > 0);
    if ~isempty(v)
        % Every row of one capture carries the same value; median rather than
        % the first row only so a single mangled row cannot set the axis.
        D = median(v);
        return
    end
end

% Last resort: the run label. "ch5_sep1m_bg" -> 1, "sep0p5m" -> 0.5. This is
% a naming convention, not a measurement, so it is only reached when nothing
% actually recorded the number.
tok = regexp(char(S.run_label), 'sep([0-9]+(?:p[0-9]+)?)m', 'tokens', 'once');
if ~isempty(tok)
    val = str2double(strrep(tok{1}, 'p', '.'));
    if isfinite(val) && val > 0
        D = val;
        warning(['Separation %g m parsed from the run label "%s" - nothing in ' ...
                 'this capture recorded it. Pass Separation to be sure.'], ...
                 val, S.run_label);
    end
end
end

% =========================================================================
function [b, resFloor] = local_offset_metres(gTaps, tapToMetres, D)
%LOCAL_OFFSET_METRES  Tap delay -> perpendicular offset from the baseline.
%
% The tag and the anchor are the two foci of an ellipse, D apart. A reflection
% off a person arriving `excess` metres later than the direct path travelled
% tag -> person -> anchor = D + excess in total, and every point with that
% total path length lies on the ellipse with semi-major axis
%
%   a = (D + excess)/2,   c = D/2,   b = sqrt(a^2 - c^2)
%
% b is the semi-minor axis: how far the ellipse reaches perpendicular to the
% tag-anchor line at its closest approach. With both modules side by side and
% the person moving up and down in front of them, that is the distance being
% asked for.
%
% Two things this cannot do, both geometry rather than implementation:
%
%   - b is the offset only if the person is broadside to the midpoint of the
%     baseline. Anywhere else on the same ellipse gives the same delay at a
%     larger true offset, so b is a lower bound, not a fix.
%   - taps at or before the first path have a < c and no real solution: no
%     path can be shorter than the direct one. Those come back NaN, which is
%     why the left half of the tap axis simply has no distance equivalent.
%
% resFloor is b at the first tap after the first path - the nearest offset the
% delay resolution can express at all. Below it the geometry is blind.
b        = nan(size(gTaps));
resFloor = NaN;
if isnan(D) || D <= 0
    return
end

excess = gTaps * tapToMetres;
c      = D / 2;
a      = (excess + D) / 2;

ok = excess > 0;                 % strictly after the first path
b(ok) = sqrt(max(a(ok).^2 - c^2, 0));

if any(ok)
    resFloor = min(b(ok));
end
end

% =========================================================================
function sigma = local_neg_noise(d)
%LOCAL_NEG_NOISE  Noise scale of the difference trace, from its negatives.
%
% A target can only ADD energy at its own delay, so every negative sample in
% the difference is noise, clutter or shadowing - never a detection. That
% makes the negative half a clean, assumption-free sample of the floor.
%
% Estimated robustly rather than as an RMS: one deep shadowing notch (the
% -4 kind of excursion) would drag an RMS up and hide real returns behind an
% inflated threshold. For a half-normal, median(|x|) = 0.6745 sigma.
sigma = NaN;
neg = d(isfinite(d) & d < 0);
if numel(neg) < 5
    return
end
sigma = median(abs(neg)) / 0.6745;
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
function p = local_phase_rxpwr(Mp)
%LOCAL_PHASE_RXPWR  Mean RXPWR over a phase's frames, in dBm, or NaN.
%
% Averaged in dBm as reported rather than converted to linear power first.
% This is a label on a figure, not a radiometric quantity - what it is for is
% spotting that the receive power sat in a different place in phase 2 than it
% did in the background, which is drift showing itself.
p = NaN;
if ~ismember('RXPWR', Mp.Properties.VariableNames), return; end
v = Mp.RXPWR;
v = v(isfinite(v));
if ~isempty(v), p = mean(v); end
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
           'tag_anchor_dist_m', NaN, ...
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
%LOCAL_PLOT  Background / phase 2 / difference, drawn like APS006 Figure 1.
%
% Same instrument as plot_cir_aps006.m: blue asterisk-marked trace, red
% first-path line, filled black diamond on the peak, cyan noise level,
% dashed black grid. Every value comes from aps006_style so the single-frame
% figure and these three panels cannot drift apart.
st  = aps006_style();
fig = figure('Position', [80 40 950 940]);
tl  = tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

ttl = 'CIR by phase';
if strlength(R.session.run_label) > 0
    ttl = sprintf('%s  -  %s', ttl, R.session.run_label);
end
% Interpreter none: run labels are full of underscores, and TeX would turn
% trial1_human_2m_los into subscripts.
title(tl, ttl, 'FontSize', st.labelFontSize + 1, 'FontWeight', 'bold', ...
    'Interpreter', 'none');

axList = gobjects(3,1);

% One y-range for both phase panels. Two panels meant to be compared by eye
% cannot be on scales that differ by however much autoscaling felt like - a
% background panel stretched to its own noise would read as the louder scene.
% The noise line is drawn after these limits are fixed, so a threshold far
% off the trace clips instead of flattening the CIR against the axis.
yr = local_y_range({R.background, R.phase2}, showSD, st);

axList(1) = local_phase_panel(tl, R.gTaps, R.background, st, showSD, yr, ...
    sprintf('Background (n = %d frames)', R.background.nFrames));
axList(2) = local_phase_panel(tl, R.gTaps, R.phase2, st, showSD, yr, ...
    sprintf('Phase 2, target present (n = %d frames)', R.phase2.nFrames));

% ---- Difference, on the ellipse distance axis -----------------------------
axList(3) = local_diff_panel(tl, R, st);

% Only the two phase panels share an axis. The difference panel is in metres
% now, and linking a metre axis to a tap axis would force one of them to the
% other's numeric limits.
linkaxes(axList(1:2), 'x');
xlim(axList(1), [min(R.gTaps) max(R.gTaps)]);
end

% =========================================================================
function ax = local_diff_panel(tl, R, st)
%LOCAL_DIFF_PANEL  Phase 2 minus background, against distance from the baseline.
%
% Two things differ from the panels above it. The x axis is the perpendicular
% offset from the tag-anchor baseline, not taps, via the ellipse geometry in
% local_offset_metres - the delay axis is what the chip measures, but the
% distance axis is the thing being asked of the experiment. And the trace is
% clipped at zero, because a target can only add energy at its own delay, so
% no negative sample can be a target return. The floor those negatives
% measured is kept as the dashed threshold.
ax = nexttile(tl); hold(ax,'on');

if isnan(R.separation)
    % Nothing recorded the separation, so there is no honest distance axis.
    % Draw the tap axis rather than a fabricated one.
    local_diff_on_taps(ax, R, st);
    return
end

x  = R.offsetM;
y  = R.diffPos;
ok = isfinite(x) & isfinite(y);

if ~any(ok)
    % Separation known but nothing survived the conversion and the coverage
    % filter - fall back rather than hand xlim an empty limit.
    local_diff_on_taps(ax, R, st);
    return
end

xMax = min(R.maxRangeM, max(x(ok)));
if ~isfinite(xMax) || xMax <= R.resFloorM
    xMax = max(x(ok));
end
inView = ok & x <= xMax;

% max ignores NaN, so an absent threshold simply does not contribute.
yTop = max([y(inView); R.detThresh; eps]) * st.headroom;
dr   = [0 yTop];

plot(ax, [0 xMax], [0 0], '-', 'Color', st.zeroColour, 'LineWidth', st.zeroWidth);

hD = plot(ax, x(ok), y(ok), '-', 'Color', st.diffColour, ...
    'LineWidth', st.cirWidth, 'Marker', st.cirMarker, ...
    'MarkerSize', st.cirMarkerSize, ...
    'DisplayName', 'Phase 2 - Background (added energy)');

% Where the first path itself lands. Not the y axis: one tap of delay already
% maps to resFloorM of offset, so everything left of this line is a range the
% geometry physically cannot report, not a range that came back empty.
hF = plot(ax, [R.resFloorM R.resFloorM], dr, '-', 'Color', st.fpColour, ...
    'LineWidth', st.fpWidth, ...
    'DisplayName', sprintf('Resolution floor (%.2f m)', R.resFloorM));

hT = gobjects(0);
if isfinite(R.detThresh) && R.detThresh > 0
    hT = plot(ax, [0 xMax], [R.detThresh R.detThresh], '--', ...
        'Color', st.noiseColour, 'LineWidth', st.noiseWidth, ...
        'DisplayName', sprintf('%g\\sigma from negatives (%.3g)', ...
            R.sigmaK, R.detThresh));
end

% The strongest added return in view - the range the eye should go to, and
% the closest thing this panel has to "the person is there".
hP = gobjects(0);
cand = y; cand(~inView) = NaN;
[pk, j] = max(cand);
if isfinite(pk) && pk > 0
    hP = plot(ax, x(j), pk, st.peakMarker, ...
        'Color', st.peakColour, 'MarkerFaceColor', st.peakFace, ...
        'MarkerSize', st.peakSize, ...
        'DisplayName', sprintf('Peak @ %.2f m', x(j)));
end

local_style_axes(ax, st);
xlim(ax, [0 xMax]);
ylim(ax, dr);
xlabel(ax, 'Offset from tag-anchor baseline (m)', 'FontSize', st.labelFontSize);
ylabel(ax, ['\Delta ' st.yLabelNorm], 'FontSize', st.labelFontSize);
title(ax, 'Difference (Phase 2 - Background), negatives removed', ...
    'FontSize', st.labelFontSize, 'FontWeight', 'normal');
subtitle(ax, sprintf('ellipse geometry, foci %.3g m apart', R.separation), ...
    'FontSize', st.fontSize, 'FontWeight', 'normal');
legend(ax, [hD hF hT hP], 'Location', 'northeast', ...
    'FontSize', st.legendSize, 'Box', 'on', 'EdgeColor', [0 0 0]);
end

% =========================================================================
function local_diff_on_taps(ax, R, st)
%LOCAL_DIFF_ON_TAPS  Fallback difference panel when no separation is known.
dr = local_pad_range(R.diffPos, st);
plot(ax, [min(R.gTaps) max(R.gTaps)], [0 0], '-', ...
    'Color', st.zeroColour, 'LineWidth', st.zeroWidth);
hD = plot(ax, R.gTaps, R.diffPos, '-', 'Color', st.diffColour, ...
    'LineWidth', st.cirWidth, 'Marker', st.cirMarker, ...
    'MarkerSize', st.cirMarkerSize, ...
    'MarkerIndices', local_marker_indices(R.gTaps), ...
    'DisplayName', 'Phase 2 - Background (added energy)');
hF = plot(ax, [0 0], dr, '-', 'Color', st.fpColour, ...
    'LineWidth', st.fpWidth, 'DisplayName', st.fpLabel);

local_style_axes(ax, st);
xlim(ax, [min(R.gTaps) max(R.gTaps)]);
ylim(ax, dr);
xlabel(ax, st.xLabelFP, 'FontSize', st.labelFontSize);
ylabel(ax, ['\Delta ' st.yLabelNorm], 'FontSize', st.labelFontSize);
title(ax, 'Difference (Phase 2 - Background), negatives removed', ...
    'FontSize', st.labelFontSize, 'FontWeight', 'normal');
subtitle(ax, 'no separation recorded - pass Separation for a distance axis', ...
    'FontSize', st.fontSize, 'FontWeight', 'normal');
legend(ax, [hD hF], 'Location', 'northeast', ...
    'FontSize', st.legendSize, 'Box', 'on', 'EdgeColor', [0 0 0]);
end

% =========================================================================
function ax = local_phase_panel(tl, gTaps, ph, st, showSD, yr, titleStr)
%LOCAL_PHASE_PANEL  One averaged phase, drawn like the single-frame figure.
%
% The first path sits at taps_from_fp = 0 by construction, since every frame
% was aligned onto it before averaging, so the red line goes there rather
% than at FP_INDEX. The diamond marks the peak of the averaged trace; it is
% deliberately labelled "Peak" and not "Rep:Peak", because the chip reports
% Rep:Peak for one frame and never reported this.
ax = nexttile(tl); hold(ax,'on');

hSD = gobjects(0);
if showSD
    ok = ~isnan(ph.mu) & ~isnan(ph.sd);
    if any(ok)
        xs  = gTaps(ok);
        lo  = ph.mu(ok) - ph.sd(ok);
        hi  = ph.mu(ok) + ph.sd(ok);
        hSD = fill(ax, [xs; flipud(xs)], [lo; flipud(hi)], st.sdFaceColour, ...
            'FaceAlpha', st.sdFaceAlpha, 'EdgeColor', 'none', ...
            'DisplayName', '\pm1 SD across frames');
    end
end

hC = plot(ax, gTaps, ph.mu, '-', 'Color', st.cirColour, ...
    'LineWidth', st.cirWidth, 'Marker', st.cirMarker, ...
    'MarkerSize', st.cirMarkerSize, ...
    'MarkerIndices', local_marker_indices(gTaps), ...
    'DisplayName', 'Mean CIR');

hF = plot(ax, [0 0], yr, '-', 'Color', st.fpColour, ...
    'LineWidth', st.fpWidth, 'DisplayName', st.fpLabel);

hP = gobjects(0);
[~, j] = max(ph.mu);
if ~isempty(j) && isfinite(ph.mu(j))
    hP = plot(ax, gTaps(j), ph.mu(j), st.peakMarker, ...
        'Color', st.peakColour, 'MarkerFaceColor', st.peakFace, ...
        'MarkerSize', st.peakSize, ...
        'DisplayName', sprintf('Peak @ %+g', gTaps(j)));
end

hN = gobjects(0);
if ~isnan(ph.noise)
    if ph.noise < yr(1) || ph.noise > yr(2)
        % Say so rather than let it look absent: a threshold off the top of
        % the panel means the averaged CIR never cleared it.
        nLabel = sprintf('%s (off scale, %.4g)', st.noiseLabel, ph.noise);
    else
        nLabel = st.noiseLabel;
    end
    hN = plot(ax, [min(gTaps) max(gTaps)], [ph.noise ph.noise], '-', ...
        'Color', st.noiseColour, 'LineWidth', st.noiseWidth, ...
        'DisplayName', nLabel);
end

local_style_axes(ax, st);
xlim(ax, [min(gTaps) max(gTaps)]);
ylim(ax, yr);   % fixed before anything else can rescale it
ylabel(ax, st.yLabelNorm, 'FontSize', st.labelFontSize);
title(ax, titleStr, 'FontSize', st.labelFontSize, 'FontWeight', 'normal');

if ~isnan(ph.rxpwr)
    subtitle(ax, sprintf('RXPWR %.1f dBm (mean)', ph.rxpwr), ...
        'FontSize', st.fontSize, ...
        'FontWeight', 'normal');
end

legend(ax, [hC hF hP hN hSD], 'Location', 'northeast', ...
    'FontSize', st.legendSize, 'Box', 'on', 'EdgeColor', [0 0 0]);
end

% =========================================================================
function local_style_axes(ax, st)
%LOCAL_STYLE_AXES  The application note's axes, straight out of the style.
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

% =========================================================================
function idx = local_marker_indices(gTaps)
%LOCAL_MARKER_INDICES  One asterisk per tap, whatever the grid step is.
%
% plot_cir_aps006 puts a marker on every accumulator sample, i.e. one per
% tap. The averaging grid is finer than that (MEAN_GRID_STEP is 0.5 taps by
% default), so mark every Nth point instead of every one - otherwise the same
% style comes out twice as dense here as on the single-frame figure.
step = 1;
if numel(gTaps) > 1
    gridStep = median(diff(gTaps));
    if gridStep > 0
        step = max(1, round(1 / gridStep));
    end
end
idx = 1:step:numel(gTaps);
end

% =========================================================================
function yr = local_y_range(phases, showSD, st)
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
% The note's axis starts at zero and leaves headroom above the peak; keep
% that unless the SD band actually reaches below zero.
yr = [min(0, lo), max(hi * st.headroom, eps)];
end

% =========================================================================
function r = local_pad_range(v, st)
%LOCAL_PAD_RANGE  Symmetric-ish limits for a trace that can go negative.
v = v(isfinite(v));
if isempty(v), r = [-1 1]; return; end
lo = min(v); hi = max(v);
pad = (st.headroom - 1) * max(hi - lo, eps);
r = [lo - pad, hi + pad];
end
