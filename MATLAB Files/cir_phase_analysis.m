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
% Each phase gives two things per tap: the mean across frames and the SD
% across frames. Both are differenced, phase 2 minus background, so there are
% two detection traces - a change in level and a change in spread - and both
% are also put on a distance axis, measured out from the tag-anchor midpoint.
%
% Name-value options:
%   'Plot'           true    draw and save the six-panel figure
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
%   'TagAnchorDistM' []      tag-anchor separation D in metres, for the
%                            distance axis. Empty takes it from
%                            session_info.csv, else from the
%                            tag_anchor_dist_m column of frame_metadata.csv.
%   'Verbose'        true
%
% Writes into captureDir:
%   cir_mean_background.csv   taps_from_fp, amplitude_norm_mean,
%   cir_mean_phase2.csv       amplitude_norm_sd, n_frames
%   cir_diff.csv              phase 2 mean minus background mean, phase 2 SD
%                             minus background SD, and each tap's distance
%                             from the tag-anchor midpoint
%   cir_mean_variance_plot.png / .fig
%
% Returns a struct with the grid, both phase means, both differences, the
% distance axis and the frame counts, so cir_compare_trial.m can reuse it
% without re-reading CSVs.
%
% See also CIR_COMPARE_TRIAL, CIR_MULTI_TRIAL, CIR_TAPS_TO_DISTANCE,
%          PLOT_CIR_APS006.

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
p.addParameter('TagAnchorDistM', [],   @(x) isempty(x) || (isscalar(x) && x >= 0));
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

% ---- Tag-anchor separation -----------------------------------------------
% Needed for the distance axis only. Resolved into S the same way the phase
% timings are, so out.session always carries the value that was used.
[S.tag_anchor_dist_m, distSrc] = local_tag_anchor_dist(captureDir, S, M, ...
    opt.TagAnchorDistM);

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
    fprintf('Tag-anchor: D = %g m (from %s)\n', S.tag_anchor_dist_m, distSrc);
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

% The same subtraction on the spread across frames instead of the level: a
% target can change how much a tap fluctuates from frame to frame without
% moving its mean much. Plain SD minus SD, not sqrt(Var_p2 - Var_bg), so it
% too is free to go negative, and it is NaN wherever either phase's SD is -
% which already covers the taps MinFrameFrac dropped.
dSd = p2.sd - bg.sd;

% ---- Distance ------------------------------------------------------------
% Each tap's distance out from the tag-anchor midpoint, NaN before the first
% path. Uses the same tap_to_metres the capture recorded.
distM = cir_taps_to_distance(gTaps, S.tag_anchor_dist_m, S.tap_to_metres);

% ---- Save ----------------------------------------------------------------
bgT = table(gTaps, bg.mu, bg.sd, bg.nPer, 'VariableNames', ...
    {'taps_from_fp','amplitude_norm_mean','amplitude_norm_sd','n_frames'});
p2T = table(gTaps, p2.mu, p2.sd, p2.nPer, 'VariableNames', ...
    {'taps_from_fp','amplitude_norm_mean','amplitude_norm_sd','n_frames'});
% New columns go on the end, so anything reading the old ones by name or by
% position is unaffected.
dT  = table(gTaps, dAmp, bg.mu, p2.mu, bg.nPer, p2.nPer, ...
    dSd, bg.sd, p2.sd, distM, 'VariableNames', ...
    {'taps_from_fp','amplitude_norm_diff','background_mean','phase2_mean', ...
     'n_background','n_phase2', ...
     'amplitude_norm_sd_diff','background_sd','phase2_sd', ...
     'distance_from_midpoint_m'});

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
out.sdDiff     = dSd;
out.distM      = distM;
out.counts     = struct('background', sum(isBg), 'discarded', sum(isWalk), ...
                        'phase2', sum(isP2), 'total', height(M));

% ---- Figure --------------------------------------------------------------
if opt.Plot
    out.fig = local_plot(out, logical(opt.ShowSD));
    % Named for what is on it: the mean difference and the spread (SD)
    % difference side by side.
    saved = local_save_figure(out.fig, captureDir, {'cir_mean_variance_plot'});
    if opt.Verbose && ~isempty(saved)
        fprintf('Saved %s\n', strjoin(saved, ', '));
    end
end
end

% =========================================================================
function saved = local_save_figure(fig, captureDir, baseNames)
%LOCAL_SAVE_FIGURE  Save fig as <name>.png and <name>.fig for each name.
%
% The figure is rendered once, to a PNG and a .fig in tempdir, and those
% are then copied to every destination. Rendering once is what keeps the
% copies identical: after the first export MATLAB shrinks the window to fit
% the screen, so a second export straight from the figure comes out shorter
% than the first.
%
% Each copy is made on its own, so one destination that cannot be written
% does not stop the rest. The usual culprit is the old file still being open
% somewhere - an image viewer, the File Explorer preview pane - or briefly
% held by OneDrive or a virus scanner; writing straight into such a file is
% what made exportgraphics fail with "PNG library failed: Could not open
% file". A held file gets a few retries, since those locks are often gone
% within a second, and after that a warning naming it: the CSVs and every
% other figure file are already saved, and throwing all of that away over
% one locked file would be worse than leaving that one file stale.
nTries = 3;
tmp    = struct('png', [tempname '.png'], 'fig', [tempname '.fig']);
exportgraphics(fig, tmp.png, 'Resolution', 200);
savefig(fig, tmp.fig);

saved = {};
for ext = {'png', 'fig'}
    for i = 1:numel(baseNames)
        name = [baseNames{i} '.' ext{1}];
        dest = fullfile(captureDir, name);
        for attempt = 1:nTries
            try
                copyfile(tmp.(ext{1}), dest);
                saved{end+1} = name; %#ok<AGROW>
                break
            catch ME
                if attempt < nTries
                    pause(1);
                else
                    warning(['Could not write %s after %d tries (%s).\n' ...
                             'It is most likely open in another program ' ...
                             '(image viewer, File Explorer preview pane) or ' ...
                             'being synced by OneDrive. Close it and rerun - ' ...
                             'everything else from this run was saved.'], ...
                             dest, nTries, ME.message);
                end
            end
        end
    end
end
delete(tmp.png, tmp.fig);
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
%
% tag_anchor_dist_m has no default: session_info.csv only carries it for
% captures made since CIR_capture.m started writing it there, and for older
% ones local_tag_anchor_dist falls back to frame_metadata.csv, not a guess.
S = struct('run_label', "", 'run_stamp', "", 'capture_seconds', NaN, ...
           'walk_prompt_at_s', NaN, 'walk_duration_s', NaN, ...
           'taps_before_fp', 50, 'taps_after_fp', 100, ...
           'mean_grid_step', 0.5, 'tap_to_metres', 0.30028, ...
           'aligned_subdir', '02_lde_aligned', 'tag_anchor_dist_m', NaN);

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
function [D, src] = local_tag_anchor_dist(captureDir, S, M, optD)
%LOCAL_TAG_ANCHOR_DIST  The tag-anchor separation, and where it came from.
%
% Tried in order: the TagAnchorDistM option, session_info.csv, then the
% tag_anchor_dist_m column that frame_metadata.csv has carried on every frame
% all along - which is what lets captures from before session_info.csv had
% the field still resolve. The column holds one value per frame even though
% it is set once per run, so a spread in it means the file was edited or
% stitched together, and deserves a warning rather than a silent pick.
if ~isempty(optD)
    D   = optD;
    src = 'TagAnchorDistM option';
    return
end

if isnumeric(S.tag_anchor_dist_m) && isfinite(S.tag_anchor_dist_m)
    D   = S.tag_anchor_dist_m;
    src = 'session_info.csv';
    return
end

if ismember('tag_anchor_dist_m', M.Properties.VariableNames) && ...
        isnumeric(M.tag_anchor_dist_m)
    v = M.tag_anchor_dist_m;
    v = v(isfinite(v));
    if ~isempty(v)
        D   = v(1);
        src = 'frame_metadata.csv';
        if any(v ~= D)
            warning(['tag_anchor_dist_m is not constant across frames in ' ...
                     '%s (%g to %g m). Using the first, %g m.'], ...
                     captureDir, min(v), max(v), D);
        end
        return
    end
end

error(['No tag-anchor separation for %s: session_info.csv has no ' ...
       'tag_anchor_dist_m, and frame_metadata.csv has no finite ' ...
       'tag_anchor_dist_m column. Pass it in metres, e.g. ' ...
       'cir_phase_analysis(captureDir, ''TagAnchorDistM'', 2.0).'], captureDir);
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
%LOCAL_PLOT  Both phases and both differences, drawn like APS006 Figure 1.
%
% Same instrument as plot_cir_aps006.m: blue asterisk-marked trace, red
% first-path line, filled black diamond on the peak, cyan noise level,
% dashed black grid. Every value comes from aps006_style so the single-frame
% figure and these six panels cannot drift apart.
%
% The left column is the mean method and the right column the SD method:
%
%   row 1   background mean CIR           phase 2 mean CIR
%   row 2   mean difference vs taps       SD difference vs taps
%   row 3   mean difference vs distance   SD difference vs distance
st  = aps006_style();
fig = figure('Color', st.figureColour, 'Position', [60 40 1500 1000]);
tl  = tiledlayout(fig, 3, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

ttl = 'CIR by phase';
if strlength(R.session.run_label) > 0
    ttl = sprintf('%s  -  %s', ttl, R.session.run_label);
end
% Interpreter none: run labels are full of underscores, and TeX would turn
% trial1_human_2m_los into subscripts.
title(tl, ttl, 'FontSize', st.labelFontSize + 1, 'FontWeight', 'bold', ...
    'Interpreter', 'none');

axList = gobjects(6,1);

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

% ---- Differences on the tap axis -----------------------------------------
tapRange = [min(R.gTaps) max(R.gTaps)];
tapMarks = local_marker_indices(R.gTaps);

axList(3) = local_diff_panel(tl, R.gTaps, R.diff, tapRange, tapMarks, st, ...
    st.diffColour, 'Phase 2 - Background', ...
    'Difference (Phase 2 - Background)', ...
    st.xLabelFP, ['\Delta ' st.yLabelNorm], 'Peak @ %+g');
axList(4) = local_diff_panel(tl, R.gTaps, R.sdDiff, tapRange, tapMarks, st, ...
    st.sdDiffColour, 'Phase 2 SD - Background SD', ...
    'SD Difference (Phase 2 - Background)', ...
    st.xLabelFP, ['\Delta SD ' st.yLabelNorm], 'Peak @ %+g');

% ---- The same two differences on distance --------------------------------
% Only taps >= 0 have a distance: nothing reflected arrives before the first
% path. The markers are still picked on the tap grid, so each asterisk here
% is the same sample as one on the tap panel above it, and the spacing
% between them shows how the distance axis stretches near the first path.
fwd       = R.gTaps >= 0;
distX     = R.distM(fwd);
distRange = [0 max(distX)];
distMarks = local_marker_indices(R.gTaps(fwd));
distSub   = sprintf('Tag-anchor separation D = %.2f m', ...
    R.session.tag_anchor_dist_m);

axList(5) = local_diff_panel(tl, distX, R.diff(fwd), distRange, distMarks, ...
    st, st.diffColour, 'Phase 2 - Background', ...
    'Difference vs distance', ...
    st.xLabelDist, ['\Delta ' st.yLabelNorm], 'Peak @ %.2f m');
axList(6) = local_diff_panel(tl, distX, R.sdDiff(fwd), distRange, distMarks, ...
    st, st.sdDiffColour, 'Phase 2 SD - Background SD', ...
    'SD Difference vs distance', ...
    st.xLabelDist, ['\Delta SD ' st.yLabelNorm], 'Peak @ %.2f m');
for ax = axList(5:6)'
    subtitle(ax, distSub, 'FontSize', st.fontSize, 'FontWeight', 'normal');
end

% Link only panels that share an axis. Distance is not a linear function of
% taps, so a tap panel and a distance panel zoomed "together" would be
% showing different stretches of the channel.
linkaxes(axList(1:4), 'x');
linkaxes(axList(5:6), 'x');
xlim(axList(1), tapRange);
xlim(axList(5), distRange);
end

% =========================================================================
function ax = local_diff_panel(tl, x, y, xr, mIdx, st, colour, traceName, ...
                               titleStr, xLabel, yLabel, peakFmt)
%LOCAL_DIFF_PANEL  One phase-2-minus-background trace, on taps or distance.
%
% All four difference panels are drawn here so that they cannot drift
% apart: grey zero line, red first-path line at x = 0 (tap 0 is the first
% path, and it maps to 0 m), the trace in the asterisk style, and a filled
% black diamond on the largest excursion either way. mIdx picks which points
% get an asterisk, so a distance panel can mark the same samples as the tap
% panel it pairs with.
ax = nexttile(tl); hold(ax,'on');
plot(ax, xr, [0 0], '-', 'Color', st.zeroColour, 'LineWidth', st.zeroWidth);
% cirWidth, not diffWidth: an asterisk drawn with a heavier stroke fills in
% and reads as a dot, which would make this panel's marker look like a
% different symbol from the phase panels'.
hD = plot(ax, x, y, '-', 'Color', colour, ...
    'LineWidth', st.cirWidth, 'Marker', st.cirMarker, ...
    'MarkerSize', st.cirMarkerSize, ...
    'MarkerIndices', mIdx, ...
    'DisplayName', traceName);

dr = local_pad_range(y, st);
hF = plot(ax, [0 0], dr, '-', 'Color', st.fpColour, ...
    'LineWidth', st.fpWidth, 'DisplayName', st.fpLabel);

% The largest excursion either way. Same filled diamond as Rep:Peak, because
% it plays the same role: this is the tap the eye should go to.
hP = gobjects(0);
[~, j] = max(abs(y));
if ~isempty(j) && isfinite(y(j))
    hP = plot(ax, x(j), y(j), st.peakMarker, ...
        'Color', st.peakColour, 'MarkerFaceColor', st.peakFace, ...
        'MarkerSize', st.peakSize, ...
        'DisplayName', sprintf(peakFmt, x(j)));
end

local_style_axes(ax, st);
xlim(ax, xr);
ylim(ax, dr);
xlabel(ax, xLabel, 'FontSize', st.labelFontSize);
ylabel(ax, yLabel, 'FontSize', st.labelFontSize);
title(ax, titleStr, 'FontSize', st.labelFontSize, 'FontWeight', 'normal');
legend(ax, [hD hF hP], 'Location', 'northeast', ...
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
