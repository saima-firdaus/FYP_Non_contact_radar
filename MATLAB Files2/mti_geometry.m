function out = mti_geometry(what, value, cfg, peakOffsetTaps)
%MTI_GEOMETRY  Convert between FP-relative taps and distance in front of the modules.
%
%   r   = MTI_GEOMETRY('tap2range', taps,   cfg, k0)
%   tap = MTI_GEOMETRY('range2tap', ranges, cfg, k0)
%
% k0 is the lead-edge-to-peak offset of the direct path in taps (FP_INDEX
% marks where the pulse starts rising; its maximum lands k0 taps later).
% Every reflected pulse has the same shape, so the reflection's peak sits
% k0 taps after its own leading edge too, and
%
%   excess = (tap - k0) * TapToMetres
%
% Distance r is the ellipse's semi-minor axis, i.e. distance from the
% midpoint of the two modules for a person straight in front of them:
%
%   r = sqrt(((D + excess)/2)^2 - (D/2)^2),   excess = 2*sqrt(r^2 + (D/2)^2) - D
%
% Taps at or before the direct-path peak have no real distance: NaN.

D = cfg.Separation;
c = D / 2;

switch lower(what)
    case 'tap2range'
        excess = (value - peakOffsetTaps) * cfg.TapToMetres;
        out = nan(size(value));
        ok = excess > 0;
        a = (D + excess(ok)) / 2;
        out(ok) = sqrt(max(a.^2 - c^2, 0));
    case 'range2tap'
        excess = 2 * sqrt(value.^2 + c^2) - D;
        out = peakOffsetTaps + excess / cfg.TapToMetres;
    otherwise
        error('mti_geometry: unknown conversion "%s".', what);
end
end
