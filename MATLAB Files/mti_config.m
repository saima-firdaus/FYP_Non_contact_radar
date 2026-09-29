function cfg = mti_config(varargin)
%MTI_CONFIG  Default settings for the moving-target (MTI) pipeline.
%
%   cfg = MTI_CONFIG()                     defaults
%   cfg = MTI_CONFIG('Name', value, ...)   defaults with overrides
%   cfg = MTI_CONFIG(cfg, 'Name', value)   start from an existing cfg
%
% Every script in this folder (cir_mti_live, cir_mti_analysis) builds its
% settings through here, so this is the one place to change a default.
%
% ---- Geometry ------------------------------------------------------------
% The tag (TX) and the anchor (RX) sit side by side, Separation apart. A
% person in front of them adds a path TX -> person -> RX that arrives
% excess = |TX P| + |P RX| - Separation later than the direct path. All
% points with the same excess lie on one ellipse with the modules at its
% foci. The distance reported is the ellipse's semi-minor axis
%
%   b = sqrt(((Separation + excess)/2)^2 - (Separation/2)^2)
%
% which is exactly the distance from the midpoint of the two modules when
% the person is straight in front of it (the "central" walking line). Off
% centre it is a slight under-estimate. Same convention as
% cir_phase_analysis2.m, so the numbers line up with the static results.

cfg = struct();

cfg.Separation     = 1.0;       % m, tag-anchor spacing (foci of the ellipse)
cfg.TapToMetres    = 0.30028;   % one accumulator tap = 1.0016 ns of path
cfg.MinRange       = 0.50;      % m, nearest distance searched. Closer than
                                % this the echo sits on the direct path's own
                                % pulse and cannot be separated from it.
cfg.MaxRange       = 3.50;      % m, furthest distance searched (walk <= 3.2 m)

% ---- Delay grid ----------------------------------------------------------
% Every frame is resampled onto this grid of taps relative to FP_INDEX
% before anything is compared across frames. 0.25 tap is finer than
% CIR_capture's 0.5 so the sub-tap re-alignment below has room to work.
cfg.TapsBeforeFP   = 50;        % matches CIR_BEFORE_FP in the anchor sketch
cfg.TapsAfterFP    = 100;       % matches CIR_AFTER_FP
cfg.GridStep       = 0.25;      % taps

% ---- Frame alignment / normalisation --------------------------------------
% Coherent: use I and Q. Each frame is rotated and scaled so the direct path
% has the same complex value in every frame. That removes the random
% carrier phase (the two modules' oscillators are not locked) and AGC gain
% changes in one step, which is what makes coherent clutter removal possible.
% Set false only for old captures that stored magnitude alone.
cfg.Coherent       = true;
% Refine FP_INDEX by matching the direct-path shape against the reference,
% +/- FineAlignMaxTaps, in FineAlignStep steps. FP_INDEX jitters by a
% fraction of a tap, and on the steep edge of the direct path that jitter
% alone looks like motion at close range.
cfg.FineAlign      = true;
cfg.FineAlignMaxTaps = 0.75;
cfg.FineAlignStep  = 0.05;
cfg.DirectWindow   = [-3 8];    % taps: where the direct path lives

% ---- Clutter removal (the MTI filter) --------------------------------------
%  'clutter'  y_n - B_n. B is the static scene: learned while the scene is
%             empty, then slowly updated (exponential average, ClutterAlpha
%             per frame). Keeps a person visible while they walk, and for a
%             few seconds after they stop.
%  'diff'     y_n - y_(n-1), the classic two-pulse canceller. Only sees
%             what changed since the last frame, so a person who pauses
%             disappears at once. Good for arm motions.
cfg.MTIMode        = 'clutter';
cfg.ClutterAlpha   = 0.02;      % 0 = frozen background; 0.02 at ~10 Hz ~ 5 s memory
cfg.ClutterFreeze  = 20;        % taps with motion on them update this many times slower
cfg.LearnSeconds   = 5;         % keep the scene EMPTY for this long at the start
cfg.SettleSeconds  = 1;         % frames dropped first (AGC / oscillator settling)

% ---- Detection -----------------------------------------------------------
% MTI energy |MTI|^2 is averaged over the last IntegrateFrames frames, then
% compared tap by tap with ThresholdFactor x (the residual energy that tap
% showed while the scene was empty, or the thermal noise floor, whichever
% is larger). That per-tap "clutter map" threshold is what stops the edge of
% the huge direct path from producing false detections at short range.
cfg.IntegrateFrames = 3;
cfg.ThresholdFactor = 4;        % 6 dB over the empty-scene residual. Raise if
                                % you see false detections, lower for range.
cfg.NoiseWindow    = [-45 -8];  % taps before the first path: noise only
%  'nearest'   first detection above threshold, i.e. the shortest path.
%              Anything the person shadows or re-reflects can only arrive
%              LATER than the person's own echo (a path through a point is
%              never shorter than TX -> point -> RX), so the earliest
%              detection is the person, not an artefact behind them.
%  'strongest' the largest detection in range.
cfg.Pick           = 'nearest';
cfg.NearestWithinDB = 10;       % 'nearest' ignores echoes this far below the
                                % strongest (pulse sidelobes ring ~3 taps early)
cfg.MinWidthTaps   = 0.5;       % a detection must stay above threshold this wide

% ---- Tracking ------------------------------------------------------------
% alpha-beta filter on distance. Detections further than GateMetres from
% the prediction are ignored while a track exists, unless nothing else is
% found for ReacquireSeconds. The track coasts on its last velocity for
% CoastSeconds with no detection before it is dropped.
cfg.TrackAlpha     = 0.5;
cfg.TrackBeta      = 0.15;
cfg.GateMetres     = 0.7;
cfg.CoastSeconds   = 1.5;
cfg.ReacquireSeconds = 0.6;
cfg.MaxSpeed       = 3.0;       % m/s, clamps the velocity estimate

% ---- Overrides -----------------------------------------------------------
args = varargin;
if ~isempty(args) && isstruct(args{1})
    base = args{1};
    f = fieldnames(base);
    for k = 1:numel(f)
        cfg.(f{k}) = base.(f{k});
    end
    args = args(2:end);
end
if mod(numel(args), 2) ~= 0
    error('mti_config: options must be Name, value pairs.');
end
known = fieldnames(cfg);
for k = 1:2:numel(args)
    name = args{k};
    hit = find(strcmpi(known, name), 1);
    if isempty(hit)
        error('mti_config: unknown option "%s".', name);
    end
    cfg.(known{hit}) = args{k+1};
end

if ~any(strcmpi(cfg.MTIMode, {'clutter','diff'}))
    error('MTIMode must be ''clutter'' or ''diff''.');
end
if ~any(strcmpi(cfg.Pick, {'nearest','strongest'}))
    error('Pick must be ''nearest'' or ''strongest''.');
end
end
