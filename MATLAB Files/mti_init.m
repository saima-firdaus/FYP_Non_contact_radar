function S = mti_init(cfg)
%MTI_INIT  Fresh state for the frame-by-frame MTI processor (see MTI_STEP).
%
%   S = MTI_INIT(cfg)      cfg from MTI_CONFIG
%
% The processor is a plain struct passed in and out of MTI_STEP, so the
% live display and the offline analysis run literally the same code.

if nargin < 1 || isempty(cfg)
    cfg = mti_config();
end

S = struct();
S.cfg   = cfg;
S.grid  = (-cfg.TapsBeforeFP : cfg.GridStep : cfg.TapsAfterFP).';
nG      = numel(S.grid);

% Reference direct path (set from the first settled frame)
S.haveRef  = false;
S.refX     = [];                 % complex (or real) reference profile
S.dirIdx   = find(S.grid >= cfg.DirectWindow(1) & S.grid <= cfg.DirectWindow(2));
S.k0       = NaN;                % lead-edge-to-peak offset, taps
S.rangeAxis = nan(nG, 1);        % distance of every grid tap (NaN = none)
S.gate     = false(nG, 1);       % taps inside MinRange..MaxRange
S.noiseIdx = find(S.grid >= cfg.NoiseWindow(1) & S.grid <= cfg.NoiseWindow(2));

% Timing
S.nIn      = 0;                  % frames fed in
S.t0       = NaN;                % time of first frame
S.lastRxTs = NaN;                % for elapsed time from RX_TS if needed
S.rxTime   = 0;

% Learning (empty scene)
S.learnY   = zeros(nG, 0);
S.learned  = false;
S.B        = zeros(nG, 1);       % clutter map (static scene)
S.thr      = inf(nG, 1);         % detection threshold per tap
S.noise    = NaN;

% MTI
S.prevY    = [];
S.eBuf     = zeros(nG, 0);       % last IntegrateFrames energies

% Track
S.track    = struct('active', false, 'r', NaN, 'v', 0, 't', NaN, ...
                    'tLastDet', NaN);
end
