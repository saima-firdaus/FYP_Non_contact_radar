function distM = cir_taps_to_distance(taps, tagAnchorDistM, tapToMetres)
%CIR_TAPS_TO_DISTANCE  Taps from the first path -> distance out from the tag-anchor midpoint.
%
%   distM = CIR_TAPS_TO_DISTANCE(taps, D)
%   distM = CIR_TAPS_TO_DISTANCE(taps, D, tapToMetres)
%
% taps_from_fp is how much further a reflection travelled than the first
% path, and the first path is the direct tag -> anchor path, D long. A person
% standing a distance d straight out from the midpoint of that baseline
% reflects along two equal legs of sqrt(d^2 + (D/2)^2) each, so:
%
%   excess_m   = taps * tapToMetres
%   one_side_m = (excess_m + D) / 2     <- + D: the excess sits on top of the
%                                          direct path, it is not all of it
%   d          = sqrt(one_side_m^2 - (D/2)^2)
%
% Every point on the ellipse with the tag and anchor as its foci has the same
% delay. This returns the one straight out from the midpoint, which is where
% the target is meant to stand.
%
% Negative taps arrive before the first path, which no reflection can, so
% they come out NaN. tapToMetres defaults to 0.30028 (one 1.0016 ns tap), the
% same TAP_TO_METRES that CIR_capture.m writes into session_info.csv.
%
% Sanity checks, with the default tapToMetres:
%   D = 1.5 m, taps =  9.23  ->  2.00 m
%   D = 1.0 m, taps = 16.93  ->  3.00 m
%
% See also CIR_PHASE_ANALYSIS.

if nargin < 3 || isempty(tapToMetres)
    tapToMetres = 0.30028;
end

% Only taps >= 0 are computed at all: a negative one would put a negative
% number under the square root, and the complex result would survive even
% after being overwritten with NaN.
distM = nan(size(taps));
ok    = taps >= 0;

oneSideM  = (taps(ok) * tapToMetres + tagAnchorDistM) / 2;
distM(ok) = sqrt(oneSideM.^2 - (tagAnchorDistM / 2)^2);
end
