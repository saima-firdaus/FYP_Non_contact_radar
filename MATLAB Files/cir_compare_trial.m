function out = cir_compare_trial(trialDir, controlDir, varargin)
%CIR_COMPARE_TRIAL  Does a trial's CIR change beat an empty-room control?
%
%   out = CIR_COMPARE_TRIAL(trialDir, controlDir)
%   out = CIR_COMPARE_TRIAL(trialDir, controlDir, 'Name', value, ...)
%
% trialDir    a capture folder from CIR_capture.m where somebody walked in
%             during the break and stood still for phase 2
% controlDir  a capture folder run exactly the same way with the room empty
%             throughout: nobody walks, nothing moves
%
% The control is not a spare experiment, it is the measurement of how much
% the difference trace moves on its own. Even inside one continuous serial
% session the AGC and the crystal wander, so phase 2 minus background is
% never flat. Whatever the empty room produces is the floor, and a trial only
% counts as a detection when it clears that floor by a decent margin.
%
% Name-value options:
%   'ExcludeMargin'    3      taps either side of taps_from_fp = 0 that are
%                             ignored. The frames were aligned on FP_INDEX,
%                             which is fractional and estimated per frame, so
%                             the residual right at the first path is an
%                             alignment artefact rather than a reflection.
%                             Widen it if the alignment is noisy.
%   'DetectionFactor'  3      how many times the control's peak the trial's
%                             peak has to reach before it is called a
%                             detection
%   'TapMin'/'TapMax'  []     further restrict the search window, e.g. to the
%                             taps where a target at a known range could be
%   'Force'            false  rerun cir_phase_analysis even if cir_diff.csv
%                             is already there
%   'Plot'             true
%   'Verbose'          true
%
% Writes cir_compare_vs_control.png / .fig and cir_compare_summary.csv into
% trialDir, and returns the peaks and the verdict as a struct.
%
% See also CIR_PHASE_ANALYSIS, CIR_MULTI_TRIAL.

p = inputParser;
p.addParameter('ExcludeMargin',   3,     @(x) isscalar(x) && x >= 0);
p.addParameter('DetectionFactor', 3,     @(x) isscalar(x) && x > 0);
p.addParameter('TapMin',          [],    @(x) isempty(x) || isscalar(x));
p.addParameter('TapMax',          [],    @(x) isempty(x) || isscalar(x));
p.addParameter('Force',           false, @(x) islogical(x) || isnumeric(x));
p.addParameter('Plot',            true,  @(x) islogical(x) || isnumeric(x));
p.addParameter('Verbose',         true,  @(x) islogical(x) || isnumeric(x));
p.parse(varargin{:});
opt = p.Results;

trialDir   = char(trialDir);
controlDir = char(controlDir);

% ---- Make sure both have been phase-analysed ----------------------------
trial   = cir_diff_for(trialDir,   opt.Force, opt.Verbose);
control = cir_diff_for(controlDir, opt.Force, opt.Verbose);

if numel(trial.taps) ~= numel(control.taps) || ...
        any(abs(trial.taps - control.taps) > 1e-9)
    warning(['Trial and control were averaged onto different tap grids. ' ...
             'Each peak is still found on its own grid, but check that the ' ...
             'two captures used the same TAPS_BEFORE_FP / TAPS_AFTER_FP / ' ...
             'MEAN_GRID_STEP before reading much into the comparison.']);
end

% ---- Peak search --------------------------------------------------------
tPk = local_peak(trial.taps,   trial.diff,   opt);
cPk = local_peak(control.taps, control.diff, opt);

ratio    = tPk.mag / cPk.mag;
detected = isfinite(ratio) && ratio >= opt.DetectionFactor;

% ---- Report -------------------------------------------------------------
if opt.Verbose
    fprintf('\n===== Trial vs drift-floor control =====\n');
    fprintf('Trial   : %s\n', trialDir);
    if strlength(trial.label) > 0
        fprintf('          label "%s", %d background / %d phase2 frames\n', ...
            trial.label, trial.nBg, trial.nP2);
    end
    fprintf('Control : %s\n', controlDir);
    if strlength(control.label) > 0
        fprintf('          label "%s", %d background / %d phase2 frames\n', ...
            control.label, control.nBg, control.nP2);
    end
    fprintf('Searched: |taps_from_fp| > %g%s\n', opt.ExcludeMargin, ...
        local_window_text(opt));
    fprintf('\n');
    fprintf('  Trial peak   : %.5g at taps_from_fp = %+.2f (%s)\n', ...
        tPk.mag, tPk.tap, local_sign_text(tPk.signed));
    fprintf('  Control peak : %.5g at taps_from_fp = %+.2f   <- drift floor\n', ...
        cPk.mag, cPk.tap);
    fprintf('  Ratio        : %.2fx  (threshold %.2fx)\n', ratio, opt.DetectionFactor);
    fprintf('\n');
    if detected
        fprintf(['  VERDICT: DETECTED. The trial peak at tap %+.2f is %.2fx ' ...
                 'the drift floor.\n'], tPk.tap, ratio);
    else
        fprintf(['  VERDICT: NOT DETECTED. The trial peak is only %.2fx the ' ...
                 'drift floor,\n           which an empty room produces on ' ...
                 'its own. Nothing here separates\n           a person from ' ...
                 'the hardware wandering.\n'], ratio);
    end
    fprintf('\n');
end

% ---- Result -------------------------------------------------------------
out = struct();
out.trialDir        = trialDir;
out.controlDir      = controlDir;
out.trialLabel      = trial.label;
out.controlLabel    = control.label;
out.trialPeakTap    = tPk.tap;
out.trialPeakMag    = tPk.mag;
out.trialPeakSigned = tPk.signed;
out.controlPeakTap  = cPk.tap;
out.controlPeakMag  = cPk.mag;
out.ratio           = ratio;
out.detected        = detected;
out.excludeMargin   = opt.ExcludeMargin;
out.detectionFactor = opt.DetectionFactor;
out.nTrialFrames    = [trial.nBg trial.nP2];
out.nControlFrames  = [control.nBg control.nP2];

summaryT = table(string(trialDir), string(controlDir), string(trial.label), ...
    tPk.tap, tPk.mag, tPk.signed, cPk.tap, cPk.mag, ratio, detected, ...
    opt.ExcludeMargin, opt.DetectionFactor, trial.nBg, trial.nP2, ...
    'VariableNames', {'trial_dir','control_dir','run_label', ...
        'trial_peak_tap','trial_peak_mag','trial_peak_signed', ...
        'control_peak_tap','control_peak_mag','ratio','detected', ...
        'exclude_margin','detection_factor','n_background','n_phase2'});
writetable(summaryT, fullfile(trialDir, 'cir_compare_summary.csv'));

% ---- Figure -------------------------------------------------------------
if opt.Plot
    out.fig = local_plot(trial, control, tPk, cPk, opt, detected, ratio);
    exportgraphics(out.fig, fullfile(trialDir, 'cir_compare_vs_control.png'), ...
        'Resolution', 200);
    savefig(out.fig, fullfile(trialDir, 'cir_compare_vs_control.fig'));
    if opt.Verbose
        fprintf('Saved cir_compare_vs_control.png / .fig and cir_compare_summary.csv\n');
    end
end
end

% =========================================================================
function D = cir_diff_for(captureDir, force, verbose)
%CIR_DIFF_FOR  cir_diff.csv for a capture, running the phase analysis if needed.
if ~isfolder(captureDir)
    error('Capture folder not found: %s', captureDir);
end

diffFile = fullfile(captureDir, 'cir_diff.csv');
if force || ~isfile(diffFile)
    if verbose
        fprintf('Running phase analysis on %s ...\n', captureDir);
    end
    cir_phase_analysis(captureDir, 'Verbose', verbose);
end

T = readtable(diffFile);
if ~all(ismember({'taps_from_fp','amplitude_norm_diff'}, T.Properties.VariableNames))
    error(['%s does not look like a cir_diff.csv from cir_phase_analysis. ' ...
           'Delete it and rerun with Force true.'], diffFile);
end

D = struct();
D.dir   = captureDir;
D.taps  = T.taps_from_fp;
D.diff  = T.amplitude_norm_diff;
D.label = local_run_label(captureDir);
D.nBg   = NaN;
D.nP2   = NaN;
if ismember('n_background', T.Properties.VariableNames)
    D.nBg = max(T.n_background);
end
if ismember('n_phase2', T.Properties.VariableNames)
    D.nP2 = max(T.n_phase2);
end
end

% =========================================================================
function pk = local_peak(taps, d, opt)
%LOCAL_PEAK  Largest |difference| outside the first-path margin.
%
% Absolute value, because a body both adds a reflection and shadows paths
% that were there before - a strong negative excursion is just as much a
% change in the channel as a positive one. The signed value is kept so the
% report can say which it was.
mask = isfinite(d) & abs(taps) > opt.ExcludeMargin;
if ~isempty(opt.TapMin), mask = mask & taps >= opt.TapMin; end
if ~isempty(opt.TapMax), mask = mask & taps <= opt.TapMax; end

if ~any(mask)
    error(['No taps left to search: ExcludeMargin %g with window [%s %s] ' ...
           'removes the whole trace.'], opt.ExcludeMargin, ...
           num2str(opt.TapMin), num2str(opt.TapMax));
end

idx  = find(mask);
[~, j] = max(abs(d(idx)));
k    = idx(j);

pk = struct('tap', taps(k), 'mag', abs(d(k)), 'signed', d(k), 'mask', mask);
end

% =========================================================================
function lbl = local_run_label(captureDir)
%LOCAL_RUN_LABEL  The run_label from session_info.csv, or "".
lbl = "";
f = fullfile(captureDir, 'session_info.csv');
if ~isfile(f), return; end
T = readtable(f, 'TextType', 'string');
if ismember('run_label', T.Properties.VariableNames)
    lbl = string(T.run_label(1));
end
end

% =========================================================================
function s = local_sign_text(v)
if v >= 0
    s = 'added energy';
else
    s = 'lost energy';
end
end

% =========================================================================
function s = local_window_text(opt)
if isempty(opt.TapMin) && isempty(opt.TapMax)
    s = '';
elseif isempty(opt.TapMin)
    s = sprintf(', taps <= %g', opt.TapMax);
elseif isempty(opt.TapMax)
    s = sprintf(', taps >= %g', opt.TapMin);
else
    s = sprintf(', taps in [%g %g]', opt.TapMin, opt.TapMax);
end
end

% =========================================================================
function fig = local_plot(trial, control, tPk, cPk, opt, detected, ratio)
%LOCAL_PLOT  Both difference traces on one tap axis.
st  = aps006_style();
fig = figure('Color', st.figureColour, 'Position', [80 120 1000 520]);
ax  = axes(fig);
hold(ax,'on'); grid(ax,'on'); box(ax,'on');
set(ax, 'FontSize', st.fontSize);

allT = [trial.taps; control.taps];
xRange = [min(allT) max(allT)];
allD = [trial.diff; control.diff];
allD = allD(isfinite(allD));
if isempty(allD), allD = [-1; 1]; end
yPad = 0.08 * max(max(allD) - min(allD), eps);
yRange = [min(allD) - yPad, max(allD) + yPad];

% ---- The ignored band around the first path -----------------------------
if opt.ExcludeMargin > 0
    hEx = fill(ax, [-opt.ExcludeMargin opt.ExcludeMargin ...
                     opt.ExcludeMargin -opt.ExcludeMargin], ...
                   [yRange(1) yRange(1) yRange(2) yRange(2)], ...
                   st.excludeColour, 'FaceAlpha', st.excludeAlpha, ...
                   'EdgeColor', 'none');
else
    hEx = gobjects(0);
end

yline(ax, 0, '-', 'Color', st.zeroColour, 'LineWidth', st.zeroWidth);

hC = plot(ax, control.taps, control.diff, st.controlStyle, ...
    'Color', st.controlColour, 'LineWidth', st.controlWidth);
hT = plot(ax, trial.taps, trial.diff, '-', ...
    'Color', st.diffColour, 'LineWidth', st.diffWidth);

% Peak markers keep the APS006 convention: a black diamond is "the peak".
hP = plot(ax, tPk.tap, tPk.signed, st.peakMarker, ...
    'MarkerEdgeColor', st.peakColour, 'MarkerFaceColor', 'none', ...
    'MarkerSize', st.peakSize, 'LineWidth', 1.2);
plot(ax, cPk.tap, cPk.signed, st.peakMarker, ...
    'MarkerEdgeColor', st.controlColour, 'MarkerFaceColor', 'none', ...
    'MarkerSize', st.peakSize - 2, 'LineWidth', 1.0);

hFp = xline(ax, 0, '-', st.fpLabel, 'Color', st.fpColour, ...
    'LineWidth', st.fpWidth, 'LabelVerticalAlignment', 'top', ...
    'LabelHorizontalAlignment', 'left', 'FontSize', st.fontSize);

xlim(ax, xRange);
ylim(ax, yRange);
xlabel(ax, st.xLabelFP);
ylabel(ax, '\Delta Amplitude / RXPACC');

if detected
    verdict = sprintf('DETECTED at tap %+.2f  (%.2fx drift floor)', tPk.tap, ratio);
else
    verdict = sprintf('not detected  (%.2fx drift floor, need %.2fx)', ...
        ratio, opt.DetectionFactor);
end
title(ax, 'Phase 2 - Background: trial vs empty-room control');
subtitle(ax, verdict);

hLeg = [hT hC hP hFp];
lLeg = {sprintf('trial %s', local_short(trial)), ...
        sprintf('control %s (drift floor)', local_short(control)), ...
        sprintf('%s of trial', st.peakLabel), ...
        'aligned first path'};
if ~isempty(hEx)
    hLeg(end+1) = hEx;
    lLeg{end+1} = sprintf('ignored: |taps| <= %g', opt.ExcludeMargin);
end
legend(ax, hLeg, lLeg, 'Location', 'northeast', 'FontSize', st.fontSize, ...
    'Interpreter', 'none');   % run labels and folder names contain underscores
end

% =========================================================================
function s = local_short(D)
%LOCAL_SHORT  Run label if there is one, else the folder name.
if strlength(D.label) > 0
    s = char(D.label);
else
    [~, name] = fileparts(D.dir);
    s = name;
end
end
