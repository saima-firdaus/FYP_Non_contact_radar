function st = aps006_style()
%APS006_STYLE  The one place the CIR plots agree on how they look.
%
% Every value here is lifted from plot_cir_aps006.m, which draws a single
% frame the way Figure 1 of Qorvo APS006 Part 3 does. The phase averages and
% the difference traces reuse them so that a single frame, a phase mean and a
% trial-versus-control overlay all read as the same instrument:
%
%   cir     the impulse response itself - blue, thin, asterisk per sample
%   fp      "Rep:Fp", the first path - red vertical line
%   peak    "Rep:Peak" - filled black diamond sitting on the curve
%   noise   "Rep: Noise Level", STD_NOISE x NTM - cyan horizontal line
%   diff    a phase-2-minus-background difference, which can go negative
%   zero    a neutral reference line (zero amplitude, or zero taps)
%
% Change a value here and every figure in the pipeline follows. If you change
% one that plot_cir_aps006.m hardcodes, change it there too - that file is
% the reference, this one is the copy the other plots read.

st = struct();

% ---- The CIR trace -------------------------------------------------------
st.cirColour     = [0 0 1];            % pure blue, as the note draws it
st.cirWidth      = 0.6;
st.cirMarker     = '*';
st.cirMarkerSize = 4;

% ---- Rep:Fp --------------------------------------------------------------
st.fpColour     = [1 0 0];            % red
st.fpWidth      = 1.5;
st.fpLabel      = 'Rep:Fp';

% ---- Rep:Peak ------------------------------------------------------------
st.peakColour   = [0 0 0];            % black
st.peakMarker   = 'd';
st.peakFace     = 'k';                % filled, unlike an ordinary marker
st.peakSize     = 7;
st.peakLabel    = 'Rep:Peak';

% ---- Rep: Noise Level ----------------------------------------------------
st.noiseColour  = [0 0.75 0.85];      % cyan
st.noiseWidth   = 1.8;
st.noiseLabel   = 'Rep: Noise Level';

% ---- Traces that have no equivalent on a single-frame plot ---------------
st.diffColour   = [0.49 0.18 0.56];   % purple, so it is never mistaken
st.diffWidth    = 1.3;                % for one of the two phase traces

st.controlColour = [0.35 0.35 0.35];  % the empty-room control difference,
st.controlStyle  = '--';              % dashed and grey: a floor, not a signal
st.controlWidth  = 1.2;

st.excludeColour = [0.80 0.80 0.80];  % the ignored band around the first path
st.excludeAlpha  = 0.35;

st.zeroColour   = [0.45 0.45 0.45];   % grey
st.zeroWidth    = 1.0;

st.sdFaceColour = [0 0 1];            % +/- 1 SD band, matches the CIR trace
st.sdFaceAlpha  = 0.12;

% ---- Axes ----------------------------------------------------------------
st.figureColour  = 'w';
st.gridStyle     = '--';
st.gridColour    = [0 0 0];
st.gridAlpha     = 0.32;
st.axesWidth     = 0.75;
st.fontSize      = 11;                % tick labels
st.labelFontSize = 12;                % x/y labels and titles
st.legendSize    = 10;
st.headroom      = 1.12;              % ylim top = headroom x the peak

st.xLabelTap    = 'Sample Index';
st.xLabelFP     = 'Taps from First Path';
st.yLabelRaw    = 'CIR Amplitude';
st.yLabelNorm   = 'CIR Amplitude / RXPACC';
end
