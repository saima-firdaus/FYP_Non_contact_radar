function fig = plot_cir_aps006(sample, amp, meta, opts)
% PLOT_CIR_APS006  One CIR frame, drawn like Figure 1 of Qorvo APS006 Part 3.
%
%   fig = plot_cir_aps006(sample, amp, meta)
%   fig = plot_cir_aps006(sample, amp, meta, opts)
%
% Plots one frame's channel impulse response on the absolute accumulator
% axis, with the three diagnostics the DW1000's LDE reports for that frame
% drawn on top:
%
%   CIR               blue line with asterisk markers
%   Rep:Fp            red vertical line at FP_INDEX
%   Rep:Peak          black diamond at LDE_PPINDX
%   Rep: Noise Level  cyan horizontal line at STD_NOISE x NTM
%
% Inputs
%   sample  absolute accumulator index, one per CIR sample
%   amp     RAW accumulator magnitude |I+jQ| at that sample. Do NOT pass
%           amplitude/RXPACC: the noise threshold is in raw accumulator
%           units, and the raw scale is what puts the y-axis on the x10^4
%           range the application note shows.
%   meta    struct or table row of that frame's header values. Uses
%           FP_INDEX, and where present PEAK_IDX, NOISE_THRESH, STD_NOISE
%           and NTM. Missing fields degrade gracefully.
%   opts    optional struct:
%             .anchorId  number shown in the title (default 5)
%             .blink     frame/blink number shown in the title
%             .tapMin    x-axis lower limit (default: min(sample))
%             .tapMax    x-axis upper limit (default: max(sample))
%             .axes      draw into this axes instead of a new figure
%
% See also CIR_CAPTURE.

    if nargin < 4, opts = struct(); end
    anchorId = getOpt(opts, 'anchorId', 5);
    blink    = getOpt(opts, 'blink',    NaN);
    tapMin   = getOpt(opts, 'tapMin',   []);
    tapMax   = getOpt(opts, 'tapMax',   []);

    sample = sample(:);
    amp    = amp(:);
    good   = isfinite(sample) & isfinite(amp);
    sample = sample(good);
    amp    = amp(good);
    if numel(sample) < 2
        error('Need at least two finite CIR samples to plot.');
    end

    if isfield(opts, 'axes') && ~isempty(opts.axes)
        ax  = opts.axes;
        fig = ancestor(ax, 'figure');
    else
        fig = figure('Color', 'w', 'Position', [120 90 900 520]);
        ax  = axes(fig);
    end
    hold(ax, 'on');

    yTop = max(amp) * 1.12;

    % ---- CIR ------------------------------------------------------------
    hCIR = plot(ax, sample, amp, '-*', 'Color', [0 0 1], ...
                'LineWidth', 0.6, 'MarkerSize', 4, 'DisplayName', 'CIR');

    % ---- Rep:Fp ---------------------------------------------------------
    fp = metaField(meta, 'FP_INDEX');
    hFp = gobjects(0);
    if ~isnan(fp)
        hFp = plot(ax, [fp fp], [0 yTop], 'r-', 'LineWidth', 1.5, ...
                   'DisplayName', 'Rep:Fp');
    end

    % ---- Rep:Peak -------------------------------------------------------
    % The chip reports the peak INDEX; its height is read off the measured
    % CIR so the marker sits exactly on the curve, as it does in the note.
    pkIdx = metaField(meta, 'PEAK_IDX');
    if isnan(pkIdx)
        [~, j] = max(amp);          % captures predating LDE_PPINDX
    else
        [~, j] = min(abs(sample - pkIdx));
    end
    hPk = plot(ax, sample(j), amp(j), 'kd', 'MarkerSize', 7, ...
               'MarkerFaceColor', 'k', 'DisplayName', 'Rep:Peak');

    % ---- Rep: Noise Level -----------------------------------------------
    % APS006 Table 1: noise threshold = STD_NOISE x NTM.
    nt = metaField(meta, 'NOISE_THRESH');
    if isnan(nt)
        sn  = metaField(meta, 'STD_NOISE');
        ntm = metaField(meta, 'NTM');
        if isnan(ntm), ntm = 13; end    % what setDefaults() writes
        if ~isnan(sn), nt = sn * ntm; end
    end
    hNz = gobjects(0);
    if ~isnan(nt)
        hNz = plot(ax, [min(sample) max(sample)], [nt nt], '-', ...
                   'Color', [0 0.75 0.85], 'LineWidth', 1.8, ...
                   'DisplayName', 'Rep: Noise Level');
    end

    % ---- Axes styling, to match the application note ---------------------
    grid(ax, 'on');
    ax.GridLineStyle  = '--';
    ax.GridColor      = [0 0 0];
    ax.GridAlpha      = 0.32;
    ax.Layer          = 'bottom';
    ax.FontSize       = 11;
    ax.LineWidth      = 0.75;
    ax.TickDir        = 'in';
    ax.YAxis.Exponent = 4;              % the note's "x 10^4"
    box(ax, 'on');

    if isempty(tapMin), tapMin = min(sample); end
    if isempty(tapMax), tapMax = max(sample); end
    xlim(ax, [tapMin tapMax]);
    ylim(ax, [0 yTop]);

    xlabel(ax, 'Sample Index', 'FontSize', 12);
    ylabel(ax, 'CIR Amplitude', 'FontSize', 12);
    if isnan(blink)
        title(ax, sprintf('Anchor %d', anchorId), ...
              'FontSize', 12, 'FontWeight', 'normal');
    else
        title(ax, sprintf('Anchor %d  Blink %d', anchorId, blink), ...
              'FontSize', 12, 'FontWeight', 'normal');
    end

    % ---- RXPWR ----------------------------------------------------------
    % The one header value carried onto the figure. RXPACC and the capture
    % timestamp stay in frame_metadata.csv where they belong: they say
    % nothing you can read off the curve.
    rxPwr = metaField(meta, 'RXPWR');
    if ~isnan(rxPwr)
        subtitle(ax, sprintf('RXPWR %.1f dBm', rxPwr), ...
                 'FontSize', 11, 'FontWeight', 'normal');
    end

    legend(ax, [hCIR hFp hPk hNz], 'Location', 'northeast', ...
           'FontSize', 10, 'Box', 'on', 'EdgeColor', [0 0 0]);
end


function v = getOpt(s, name, dflt)
    if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
        v = s.(name);
    else
        v = dflt;
    end
end

function v = metaField(meta, name)
% Reads one header value out of either a struct or a one-row table.
    v = NaN;
    if isstruct(meta)
        if isfield(meta, name), v = double(meta.(name)); end
    elseif istable(meta)
        if ismember(name, meta.Properties.VariableNames)
            v = double(meta.(name)(1));
        end
    end
    if isempty(v), v = NaN; end
    v = v(1);
end
