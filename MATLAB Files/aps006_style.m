function st = aps006_style()
%APS006_STYLE  The one place the CIR plots agree on how they look.
%
% Qorvo APS006 Part 3, Figure 1 draws a CIR with three annotations on top,
% and every plot in this pipeline follows the same conventions so that a
% single frame, a phase average and a difference trace can be read side by
% side without relearning the colours:
%
%   cir     the impulse response itself
%   fp      "Rep:Fp", the LDE first path - red vertical line
%   peak    "Rep:Peak", the LDE peak path - black diamond
%   noise   "Rep: Noise Level", STD_NOISE x NTM - cyan horizontal line
%   diff    a phase-2-minus-background difference, which can go negative
%   zero    a neutral reference line (zero amplitude, or zero taps)
%
% Change a colour here and every figure in the pipeline follows.

st = struct();

st.cirColour    = [0.00 0.45 0.74];   % blue
st.cirWidth     = 1.2;

st.fpColour     = [0.85 0.10 0.10];   % red
st.fpWidth      = 1.4;
st.fpLabel      = 'Rep:Fp';

st.peakColour   = [0 0 0];            % black
st.peakMarker   = 'd';
st.peakSize     = 8;
st.peakLabel    = 'Rep:Peak';

st.noiseColour  = [0.00 0.75 0.85];   % cyan
st.noiseWidth   = 1.2;
st.noiseLabel   = 'Rep: Noise Level';

st.diffColour   = [0.49 0.18 0.56];   % purple, so it is never mistaken
st.diffWidth    = 1.3;                % for one of the two phase traces

st.controlColour = [0.35 0.35 0.35];  % the empty-room control difference,
st.controlStyle  = '--';              % dashed and grey: a floor, not a signal
st.controlWidth  = 1.2;

st.excludeColour = [0.80 0.80 0.80];  % the ignored band around the first path
st.excludeAlpha  = 0.35;

st.zeroColour   = [0.45 0.45 0.45];   % grey
st.zeroWidth    = 1.0;

st.sdFaceColour = [0.00 0.45 0.74];   % +/- 1 SD band, matches the CIR trace
st.sdFaceAlpha  = 0.15;

st.figureColour = 'w';
st.fontSize     = 10;

st.xLabelTap    = 'Accumulator index (tap)';
st.xLabelFP     = 'Taps from first path';
st.yLabelRaw    = 'Amplitude  |I+jQ|';
st.yLabelNorm   = 'Amplitude / RXPACC';
end
