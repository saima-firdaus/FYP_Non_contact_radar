function fig = plot_cir_aps006(sampleIdx, amp, meta, opts)
%PLOT_CIR_APS006  One frame's CIR in the style of Qorvo APS006 Part 3, Fig 1.
%
%   fig = PLOT_CIR_APS006(sampleIdx, amp, meta)
%   fig = PLOT_CIR_APS006(sampleIdx, amp, meta, opts)
%
% sampleIdx  absolute accumulator indices for this frame
% amp        RAW accumulator magnitude |I+jQ| at those indices. Not
%            amplitude/RXPACC: the noise threshold the DW1000 reports is in
%            raw accumulator units, so it is only meaningful against this
%            scale, and it is what the application note plots.
% meta       the frame's parsed header struct. Whatever it happens to
%            contain is used; whatever is missing is quietly left off the
%            figure, so captures from older firmware still plot.
%              FP_INDEX               -> red "Rep:Fp" line
%              PEAK_IDX, PEAK_AMPL    -> black "Rep:Peak" diamond
%              NOISE_THRESH, or
%              STD_NOISE x NTM        -> cyan "Rep: Noise Level" line
% opts       optional struct:
%              anchorId  number for the title, e.g. "Anchor 5"
%              blink     frame number for the title, e.g. "Blink 215"
%              tapMin    x-axis lower limit; [] auto-fits the captured window
%              tapMax    x-axis upper limit; [] likewise
%
% See also APS006_STYLE, CIR_PHASE_ANALYSIS.

if nargin < 4 || isempty(opts), opts = struct(); end
defaults = struct('anchorId', [], 'blink', [], 'tapMin', [], 'tapMax', []);
fn = fieldnames(defaults);
for i = 1:numel(fn)
    if ~isfield(opts, fn{i}) || isempty(opts.(fn{i}))
        opts.(fn{i}) = defaults.(fn{i});
    end
end

st  = aps006_style();
fig = figure('Color', st.figureColour, 'Position', [100 100 950 480]);
ax  = axes(fig);
hold(ax, 'on'); grid(ax, 'on'); box(ax, 'on');
set(ax, 'FontSize', st.fontSize);

hLeg  = gobjects(0);
lLeg  = {};

% ---- The impulse response ------------------------------------------------
h = plot(ax, sampleIdx, amp, '-', 'Color', st.cirColour, ...
    'LineWidth', st.cirWidth);
hLeg(end+1) = h;  lLeg{end+1} = 'CIR  |I+jQ|';

% ---- Rep:Fp, the LDE first path -----------------------------------------
if isfield(meta, 'FP_INDEX') && isfinite(meta.FP_INDEX)
    h = xline(ax, meta.FP_INDEX, '-', st.fpLabel, ...
        'Color', st.fpColour, 'LineWidth', st.fpWidth, ...
        'LabelVerticalAlignment', 'top', ...
        'LabelHorizontalAlignment', 'left', ...
        'FontSize', st.fontSize);
    hLeg(end+1) = h;
    lLeg{end+1} = sprintf('%s = %.2f', st.fpLabel, meta.FP_INDEX);
end

% ---- Rep:Peak, the LDE peak path ----------------------------------------
% The sketch only streams a window around the first path, so a peak the LDE
% reports outside that window has nowhere to be drawn. Say so rather than
% clamping it onto the edge of the axes, where it would read as a real path.
if isfield(meta, 'PEAK_IDX') && isfinite(meta.PEAK_IDX)
    peakIdx = meta.PEAK_IDX;
    if isfield(meta, 'PEAK_AMPL') && isfinite(meta.PEAK_AMPL) && meta.PEAK_AMPL > 0
        peakAmp = meta.PEAK_AMPL;
    else
        peakAmp = interp1(sampleIdx, amp, peakIdx, 'linear', NaN);
    end
    if peakIdx >= min(sampleIdx) && peakIdx <= max(sampleIdx) && isfinite(peakAmp)
        h = plot(ax, peakIdx, peakAmp, st.peakMarker, ...
            'MarkerEdgeColor', st.peakColour, 'MarkerFaceColor', 'none', ...
            'MarkerSize', st.peakSize, 'LineWidth', 1.2);
        hLeg(end+1) = h;
        lLeg{end+1} = sprintf('%s @ %d', st.peakLabel, round(peakIdx));
    else
        fprintf(['Rep:Peak is at tap %g, outside the captured window ' ...
                 '[%g %g] - marker omitted.\n'], ...
                 peakIdx, min(sampleIdx), max(sampleIdx));
    end
end

% ---- Rep: Noise Level, STD_NOISE x NTM ----------------------------------
% On a healthy frame the first path is thousands of accumulator counts and
% the threshold sits well below it, exactly as in the application note. On a
% marginal frame it can land above the whole CIR, and letting it set the
% y-axis would squash the impulse response flat against the bottom. Keep the
% axis on the data and say in the legend that the line is off the top.
ampMax     = max(amp(isfinite(amp)));
if isempty(ampMax), ampMax = 1; end
noiseLevel = local_noise_level(meta);
noiseOnScale = ~isnan(noiseLevel) && noiseLevel <= 2 * ampMax;
if ~isnan(noiseLevel)
    h = yline(ax, noiseLevel, '-', st.noiseLabel, ...
        'Color', st.noiseColour, 'LineWidth', st.noiseWidth, ...
        'LabelHorizontalAlignment', 'right', ...
        'LabelVerticalAlignment', 'bottom', ...
        'FontSize', st.fontSize);
    hLeg(end+1) = h;
    if noiseOnScale
        lLeg{end+1} = sprintf('%s = %.0f', st.noiseLabel, noiseLevel);
    else
        lLeg{end+1} = sprintf('%s = %.0f (off scale, above the CIR)', ...
            st.noiseLabel, noiseLevel);
    end
end

% ---- Axes ----------------------------------------------------------------
xlabel(ax, st.xLabelTap);
ylabel(ax, st.yLabelRaw);

yTop = 1.08 * ampMax;
if noiseOnScale
    yTop = max(yTop, 1.08 * noiseLevel);
end
ylim(ax, [min(0, min(amp)) max(yTop, eps)]);

if ~isempty(opts.tapMin) && ~isempty(opts.tapMax)
    xlim(ax, [opts.tapMin opts.tapMax]);
else
    xlim(ax, [min(sampleIdx) max(sampleIdx)]);
end

titleBits = {};
if ~isempty(opts.anchorId), titleBits{end+1} = sprintf('Anchor %g', opts.anchorId); end
if ~isempty(opts.blink),    titleBits{end+1} = sprintf('Blink %g',  opts.blink);    end
subBits = {};
if isfield(meta, 'RXPACC') && isfinite(meta.RXPACC)
    subBits{end+1} = sprintf('RXPACC %g', meta.RXPACC);
end
if isfield(meta, 'RXPWR') && isfinite(meta.RXPWR)
    subBits{end+1} = sprintf('RXPWR %.1f dBm', meta.RXPWR);
end
if isfield(meta, 'elapsed_s') && isfinite(meta.elapsed_s)
    subBits{end+1} = sprintf('t = %.1f s', meta.elapsed_s);
end

if isempty(titleBits)
    title(ax, 'DW1000 CIR');
else
    title(ax, strjoin(titleBits, '  '));
end
if ~isempty(subBits)
    subtitle(ax, strjoin(subBits, '   |   '));
end

legend(ax, hLeg, lLeg, 'Location', 'northeast', 'FontSize', st.fontSize);
end

% =========================================================================
function lvl = local_noise_level(meta)
%LOCAL_NOISE_LEVEL  STD_NOISE x NTM in raw accumulator units, or NaN.
lvl = NaN;
if isfield(meta, 'NOISE_THRESH') && isfinite(meta.NOISE_THRESH) && meta.NOISE_THRESH > 0
    lvl = meta.NOISE_THRESH;
elseif isfield(meta, 'STD_NOISE') && isfield(meta, 'NTM') && ...
       isfinite(meta.STD_NOISE) && isfinite(meta.NTM)
    lvl = meta.STD_NOISE * meta.NTM;
end
end
