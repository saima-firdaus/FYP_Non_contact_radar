function out = cir_multi_trial(trialDirs, controlDir, varargin)
%CIR_MULTI_TRIAL  Do repeats of the same setup peak at the same tap?
%
%   out = CIR_MULTI_TRIAL({dir1, dir2, dir3}, controlDir)
%   out = CIR_MULTI_TRIAL(trialDirs, controlDir, 'Name', value, ...)
%
% trialDirs   several capture folders that are repeats of the SAME physical
%             setup - same distance, same standing position, same room
% controlDir  one empty-room capture, used as the drift floor for all of them
%
% One trial cannot tell a real detection from a lucky excursion: the
% difference trace has a peak somewhere no matter what, and in a single run
% there is nothing to say whether that somewhere means anything. Repeats can.
% If a person at a fixed position really is putting energy into the channel,
% the peak lands at the same taps_from_fp every time; if it is drift, the tap
% location wanders across the whole window.
%
% This is the "nice to have" wrapper: it adds no new signal processing, it
% just runs CIR_COMPARE_TRIAL on each folder and reports where the peaks fell.
%
% Name-value options:
%   'ExcludeMargin'    3      passed through to CIR_COMPARE_TRIAL
%   'DetectionFactor'  3      likewise
%   'TapMin'/'TapMax'  []     likewise
%   'ConsistencyTol'   2      taps: how close two trials' peaks have to be to
%                             count as landing in the same place
%   'Force'            false  rerun the per-capture phase analysis
%   'PlotEach'         false  also save each trial's own comparison figure
%   'Plot'             true   the across-trial summary figure
%   'OutputDir'        pwd    where the summary CSV and figure are written
%   'Verbose'          true
%
% See also CIR_COMPARE_TRIAL, CIR_PHASE_ANALYSIS.

p = inputParser;
p.addParameter('ExcludeMargin',   3,     @(x) isscalar(x) && x >= 0);
p.addParameter('DetectionFactor', 3,     @(x) isscalar(x) && x > 0);
p.addParameter('TapMin',          [],    @(x) isempty(x) || isscalar(x));
p.addParameter('TapMax',          [],    @(x) isempty(x) || isscalar(x));
p.addParameter('ConsistencyTol',  2,     @(x) isscalar(x) && x >= 0);
p.addParameter('Force',           false, @(x) islogical(x) || isnumeric(x));
p.addParameter('PlotEach',        false, @(x) islogical(x) || isnumeric(x));
p.addParameter('Plot',            true,  @(x) islogical(x) || isnumeric(x));
p.addParameter('OutputDir',       pwd,   @(x) ischar(x) || isstring(x));
p.addParameter('Verbose',         true,  @(x) islogical(x) || isnumeric(x));
p.parse(varargin{:});
opt = p.Results;

dirs = local_as_cellstr(trialDirs);
if numel(dirs) < 2
    warning(['Only %d trial given. The point of this wrapper is the spread ' ...
             'across repeats, which needs at least two.'], numel(dirs));
end
controlDir = char(controlDir);
outputDir  = char(opt.OutputDir);

% ---- Run the comparison on each trial ------------------------------------
n    = numel(dirs);
res  = cell(n, 1);
keep = false(n, 1);

for i = 1:n
    if opt.Verbose
        fprintf('\n--- Trial %d of %d ---\n', i, n);
    end
    try
        res{i} = cir_compare_trial(dirs{i}, controlDir, ...
            'ExcludeMargin',   opt.ExcludeMargin, ...
            'DetectionFactor', opt.DetectionFactor, ...
            'TapMin',          opt.TapMin, ...
            'TapMax',          opt.TapMax, ...
            'Force',           opt.Force, ...
            'Plot',            logical(opt.PlotEach), ...
            'Verbose',         opt.Verbose);
        keep(i) = true;
    catch ME
        % One unusable capture should not cost the whole batch.
        warning('Trial %s failed and was dropped: %s', dirs{i}, ME.message);
    end
end

res = res(keep);
if isempty(res)
    error('No trial could be analysed.');
end

% ---- Gather --------------------------------------------------------------
nOK      = numel(res);
peakTap  = zeros(nOK,1);
peakMag  = zeros(nOK,1);
ratio    = zeros(nOK,1);
detected = false(nOK,1);
labels   = strings(nOK,1);

for i = 1:nOK
    peakTap(i)  = res{i}.trialPeakTap;
    peakMag(i)  = res{i}.trialPeakMag;
    ratio(i)    = res{i}.ratio;
    detected(i) = res{i}.detected;
    if strlength(res{i}.trialLabel) > 0
        labels(i) = res{i}.trialLabel;
    else
        [~, nm]   = fileparts(res{i}.trialDir);
        labels(i) = string(nm);
    end
end

% ---- Spread of the peak location ----------------------------------------
tapMean   = mean(peakTap);
tapMedian = median(peakTap);
tapSD     = std(peakTap);
tapRange  = [min(peakTap) max(peakTap)];
inCluster = abs(peakTap - tapMedian) <= opt.ConsistencyTol;

if opt.Verbose
    fprintf('\n===== Across %d trial(s) =====\n', nOK);
    fprintf('Control (drift floor): %s\n\n', controlDir);
    fprintf('  %-28s %10s %12s %8s %10s\n', ...
        'trial', 'peak tap', 'peak mag', 'ratio', 'detected');
    for i = 1:nOK
        fprintf('  %-28s %+10.2f %12.5g %7.2fx %10s\n', ...
            local_trunc(labels(i), 28), peakTap(i), peakMag(i), ratio(i), ...
            string(detected(i)));
    end
    fprintf('\n');
    fprintf('  Peak taps_from_fp : mean %+.2f, median %+.2f, SD %.2f, range %+.2f to %+.2f\n', ...
        tapMean, tapMedian, tapSD, tapRange(1), tapRange(2));
    fprintf('  Within %g taps of the median: %d of %d trial(s)\n', ...
        opt.ConsistencyTol, sum(inCluster), nOK);
    fprintf('  Beat the drift floor (%.2fx): %d of %d trial(s)\n\n', ...
        opt.DetectionFactor, sum(detected), nOK);

    if sum(detected) == 0
        fprintf(['  No trial cleared the drift floor. Nothing here shows a ' ...
                 'person in the CIR.\n\n']);
    elseif sum(inCluster) == nOK && all(detected)
        fprintf(['  Every trial cleared the floor and every peak landed within ' ...
                 '%g taps\n  of the same place. That is the consistent result ' ...
                 'a single run cannot show.\n\n'], opt.ConsistencyTol);
    else
        fprintf(['  Mixed: the peaks do not all agree on a tap, so treat any ' ...
                 'single detection\n  above as provisional and collect more ' ...
                 'repeats.\n\n']);
    end
end

% ---- Save ---------------------------------------------------------------
T = table(labels, string(cellfun(@(r) r.trialDir, res, 'UniformOutput', false)), ...
    peakTap, peakMag, ratio, detected, inCluster, ...
    'VariableNames', {'run_label','trial_dir','peak_tap','peak_mag', ...
                      'ratio','detected','within_tol_of_median'});
if ~isfolder(outputDir), mkdir(outputDir); end
summaryFile = fullfile(outputDir, 'cir_multi_trial_summary.csv');
writetable(T, summaryFile);

out = struct();
out.trials         = res;
out.table          = T;
out.controlDir     = controlDir;
out.peakTap        = peakTap;
out.peakMag        = peakMag;
out.ratio          = ratio;
out.detected       = detected;
out.tapMean        = tapMean;
out.tapMedian      = tapMedian;
out.tapSD          = tapSD;
out.tapRange       = tapRange;
out.nWithinTol     = sum(inCluster);
out.consistencyTol = opt.ConsistencyTol;
out.summaryFile    = summaryFile;

if opt.Plot
    out.fig = local_plot(res, controlDir, peakTap, labels, detected, opt, ...
        tapMean, tapSD);
    exportgraphics(out.fig, fullfile(outputDir, 'cir_multi_trial.png'), ...
        'Resolution', 200);
    savefig(out.fig, fullfile(outputDir, 'cir_multi_trial.fig'));
end

if opt.Verbose
    fprintf('Saved %s\n', summaryFile);
end
end

% =========================================================================
function c = local_as_cellstr(v)
if ischar(v)
    c = {v};
elseif isstring(v)
    c = cellstr(v(:));
elseif iscell(v)
    c = cellfun(@char, v(:), 'UniformOutput', false);
else
    error('trialDirs must be a folder path, a string array or a cell array of paths.');
end
end

% =========================================================================
function s = local_trunc(str, n)
s = char(str);
if numel(s) > n
    s = [s(1:n-3) '...'];
end
end

% =========================================================================
function fig = local_plot(res, controlDir, peakTap, labels, detected, opt, ...
                          tapMean, tapSD)
%LOCAL_PLOT  All trial differences, and where each one peaked.
st  = aps006_style();
fig = figure('Color', st.figureColour, 'Position', [80 80 1000 760]);
tl  = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tl, 'Repeat trials against one drift-floor control', 'FontWeight', 'bold');

% ---- Panel 1: every difference trace ------------------------------------
ax1 = nexttile(tl); hold(ax1,'on'); grid(ax1,'on'); box(ax1,'on');
set(ax1, 'FontSize', st.fontSize);

ctrl = readtable(fullfile(controlDir, 'cir_diff.csv'));
hC = plot(ax1, ctrl.taps_from_fp, ctrl.amplitude_norm_diff, st.controlStyle, ...
    'Color', st.controlColour, 'LineWidth', st.controlWidth);

% Trials share the difference colour, lightened apart just enough to follow
% an individual trace without pretending each repeat is its own quantity.
nOK = numel(res);
hT  = gobjects(nOK,1);
for i = 1:nOK
    T = readtable(fullfile(res{i}.trialDir, 'cir_diff.csv'));
    shade = 0.55 * (i-1) / max(nOK-1, 1);
    col   = st.diffColour + shade * (1 - st.diffColour);
    hT(i) = plot(ax1, T.taps_from_fp, T.amplitude_norm_diff, '-', ...
        'Color', col, 'LineWidth', st.diffWidth);
end

yline(ax1, 0, '-', 'Color', st.zeroColour, 'LineWidth', st.zeroWidth);
xline(ax1, 0, '-', st.fpLabel, 'Color', st.fpColour, 'LineWidth', st.fpWidth, ...
    'LabelVerticalAlignment', 'top', 'LabelHorizontalAlignment', 'left', ...
    'FontSize', st.fontSize);
if opt.ExcludeMargin > 0
    yl = ylim(ax1);
    fill(ax1, [-opt.ExcludeMargin opt.ExcludeMargin opt.ExcludeMargin -opt.ExcludeMargin], ...
        [yl(1) yl(1) yl(2) yl(2)], st.excludeColour, ...
        'FaceAlpha', st.excludeAlpha, 'EdgeColor', 'none');
    ylim(ax1, yl);
end
xlabel(ax1, st.xLabelFP);
ylabel(ax1, '\Delta Amplitude / RXPACC');
title(ax1, 'Phase 2 - Background, one trace per trial');
legend(ax1, [hT(1); hC], {'trials', 'control (drift floor)'}, ...
    'Location', 'northeast', 'FontSize', st.fontSize);

% ---- Panel 2: where each trial peaked -----------------------------------
ax2 = nexttile(tl); hold(ax2,'on'); grid(ax2,'on'); box(ax2,'on');
set(ax2, 'FontSize', st.fontSize);

y = (1:nOK)';
if nOK > 1 && isfinite(tapSD) && tapSD > 0
    fill(ax2, [tapMean-tapSD tapMean+tapSD tapMean+tapSD tapMean-tapSD], ...
        [0.4 0.4 nOK+0.6 nOK+0.6], st.excludeColour, ...
        'FaceAlpha', st.excludeAlpha, 'EdgeColor', 'none');
end
xline(ax2, tapMean, '-', sprintf('mean %+.2f', tapMean), ...
    'Color', st.zeroColour, 'LineWidth', st.zeroWidth, ...
    'LabelVerticalAlignment', 'bottom', 'FontSize', st.fontSize);

hDet = gobjects(0); hNot = gobjects(0);
for i = 1:nOK
    if detected(i)
        hDet = plot(ax2, peakTap(i), y(i), st.peakMarker, ...
            'MarkerEdgeColor', st.peakColour, 'MarkerFaceColor', st.diffColour, ...
            'MarkerSize', st.peakSize, 'LineWidth', 1.2);
    else
        hNot = plot(ax2, peakTap(i), y(i), st.peakMarker, ...
            'MarkerEdgeColor', st.controlColour, 'MarkerFaceColor', 'none', ...
            'MarkerSize', st.peakSize, 'LineWidth', 1.0);
    end
end

set(ax2, 'YTick', y, 'YTickLabel', cellstr(labels), 'TickLabelInterpreter', 'none');
ylim(ax2, [0.4 nOK+0.6]);
xlabel(ax2, st.xLabelFP);
title(ax2, sprintf('Peak location per trial (SD %.2f taps, %d of %d within %g of the median)', ...
    tapSD, sum(abs(peakTap - median(peakTap)) <= opt.ConsistencyTol), nOK, ...
    opt.ConsistencyTol));

hLeg = gobjects(0); lLeg = {};
if ~isempty(hDet), hLeg(end+1) = hDet; lLeg{end+1} = 'beats drift floor'; end
if ~isempty(hNot), hLeg(end+1) = hNot; lLeg{end+1} = 'does not'; end
if ~isempty(hLeg)
    legend(ax2, hLeg, lLeg, 'Location', 'best', 'FontSize', st.fontSize);
end

linkaxes([ax1 ax2], 'x');
end
