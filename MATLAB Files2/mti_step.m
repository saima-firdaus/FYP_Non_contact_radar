function [S, R] = mti_step(S, frame)
%MTI_STEP  Push one CIR frame through the MTI chain and the distance tracker.
%
%   [S, R] = MTI_STEP(S, frame)
%
% frame is either what MTI_PARSE_LINE returns (sample, re, im, meta), or an
% amplitude-only frame from an old CIR_capture folder (taps, x, meta with
% coherent = false). S comes from MTI_INIT.
%
% Chain, per frame:
%   1. put the frame on the FP-relative grid (FP_INDEX, then a sub-tap
%      refinement against the reference direct path)
%   2. divide by the frame's complex direct-path gain: removes the random
%      carrier phase between the two free-running modules and any AGC change
%   3. remove the static scene: clutter map (y - B) or two-pulse canceller
%      (y_n - y_n-1)
%   4. integrate |MTI|^2 over a few frames, threshold it tap by tap against
%      what the empty scene produced, pick the person's echo
%   5. convert tap -> distance on the ellipse and smooth with an alpha-beta
%      tracker
%
% R fields:
%   t          elapsed seconds, spaced by the anchor's own RX timestamps
%   lag        seconds the host read this frame after it arrived (live only)
%   status     'settling' | 'learning' | 'tracking' | 'coasting' | 'no target'
%   rDet       raw detected distance this frame (m), NaN if none
%   rTrack     tracked distance (m), NaN if no track
%   vTrack     rate of change of distance (m/s), + = moving away
%   snrDB      detection strength over threshold+noise, dB
%   energy     integrated MTI energy on the grid
%   threshold  per-tap threshold on the grid
%   shift      sub-tap alignment applied (taps)
%   learnProgress  0..1 while learning
%   xAligned   the frame on the grid before normalisation (for diagnostics)
%   y          the frame after direct-path gain/phase normalisation
%   gain       the complex direct-path gain that was divided out

cfg = S.cfg;
S.nIn = S.nIn + 1;
nG = numel(S.grid);

R = struct('t', NaN, 'status', 'settling', 'rDet', NaN, 'rTrack', NaN, ...
           'vTrack', NaN, 'snrDB', NaN, 'energy', [], 'threshold', [], ...
           'shift', 0, 'learnProgress', 0, 'frameNo', NaN, 'lag', NaN, ...
           'xAligned', [], 'y', [], 'gain', NaN);

% ---- 0. Time ----------------------------------------------------------------
[t, S] = local_time(frame, S);
if isfield(frame.meta, 'FRAME'), R.frameNo = frame.meta.FRAME; end
if isnan(S.t0), S.t0 = t; end
R.t = t;
if isfield(frame.meta, 'elapsed_s') && isfinite(frame.meta.elapsed_s)
    R.lag = frame.meta.elapsed_s - t;          % how far the host read behind
end

if t - S.t0 < cfg.SettleSeconds
    return
end

% ---- 1. Onto the grid ---------------------------------------------------------
[taps, x, coherent] = local_frame_samples(frame, cfg);
if numel(taps) < 4
    R.status = 'bad frame';
    return
end
coherent = coherent && cfg.Coherent;
ppRe = spline(taps, real(x));
if coherent, ppIm = spline(taps, imag(x)); else, ppIm = []; end
inRange = S.grid >= taps(1) & S.grid <= taps(end);

if ~S.haveRef
    xg = local_eval(ppRe, ppIm, S.grid, inRange);
    S  = local_set_reference(S, xg);
end

shift = 0;
if cfg.FineAlign
    shift = local_fine_shift(S, ppRe, ppIm);
end
xg = local_eval(ppRe, ppIm, S.grid + shift, ...
                (S.grid + shift) >= taps(1) & (S.grid + shift) <= taps(end));
R.shift = shift;

% ---- 2. Direct-path gain normalisation -------------------------------------
% Least-squares complex gain of this frame against the reference over the
% direct-path window: y = xg / g makes the direct path identical in every
% frame, so what is left to change is the scene in front of the modules.
d  = S.dirIdx;
ok = isfinite(xg(d));
if ~any(ok)
    R.status = 'bad frame';
    return
end
ref = S.refX(d(ok));
g   = (ref' * xg(d(ok))) / (ref' * ref);
if ~isfinite(g) || abs(g) == 0
    R.status = 'bad frame';
    return
end
y = xg / g;
if ~coherent, y = abs(y); end
y(~isfinite(y)) = 0;
R.xAligned = xg;              % FP-aligned frame before gain/phase normalisation
R.y        = y;               % after: what the clutter map sees
R.gain     = g;               % complex direct-path gain removed from this frame

% ---- 3a. Learn the empty scene --------------------------------------------------
if ~S.learned
    S.learnY(:, end+1) = y;
    R.status = 'learning';
    R.learnProgress = min((t - S.t0 - cfg.SettleSeconds) / cfg.LearnSeconds, 1);
    if t - S.t0 >= cfg.SettleSeconds + cfg.LearnSeconds && size(S.learnY, 2) >= 3
        S = local_finish_learning(S);
    end
    S.prevY = y;
    return
end

% ---- 3b. Clutter removal ------------------------------------------------------------
if strcmpi(cfg.MTIMode, 'diff')
    m = y - S.prevY;
else
    m = y - S.B;
end
S.prevY = y;

% ---- 4. Integrate + detect ------------------------------------------------------------
e = abs(m).^2;
S.eBuf(:, end+1) = e;
if size(S.eBuf, 2) > cfg.IntegrateFrames
    S.eBuf = S.eBuf(:, end-cfg.IntegrateFrames+1:end);
end
E = mean(S.eBuf, 2);

% Clutter map update. Taps where something is moving right now are updated
% ClutterFreeze times more slowly: otherwise a person who lingers is slowly
% written into the "static" scene, and when they walk off, the stale copy
% left behind shows up as a ghost target where they used to be.
if ~strcmpi(cfg.MTIMode, 'diff')
    busy = E > S.thr;
    busy = busy | [busy(2:end); false] | [false; busy(1:end-1)];
    a = cfg.ClutterAlpha * ones(nG, 1);
    a(busy) = cfg.ClutterAlpha / cfg.ClutterFreeze;
    S.B = (1 - a) .* S.B + a .* y;
end
R.energy    = E;
R.threshold = S.thr;

cand = local_candidates(S, E);

% ---- 5. Pick + track ------------------------------------------------------------------
[S, R] = local_track(S, R, cand, t);
end

% =============================================================================
function [t, S] = local_time(frame, S)
% Frame time. The spacing comes from the DW1000 RX timestamp (40-bit, 15.65
% ps ticks, wraps every 17.2 s), which is when the anchor actually received
% the frame. The host arrival time (elapsed_s) only anchors the first frame
% and counts wraps across long gaps: when MATLAB falls behind, it reads a
% backlog of frames in a burst a few ms apart, and host time would make the
% tracker see impossible speeds and the display lag. Without RX_TS, host
% time is used; without either, 10 Hz is assumed.
m = frame.meta;
hasEl = isfield(m, 'elapsed_s') && isfinite(m.elapsed_s);
hasTs = isfield(m, 'RX_TS') && isfinite(m.RX_TS);
if hasTs && isfinite(S.lastRxTs)
    tick = 1 / (128 * 499.2e6);
    wrapS = 2^40 * tick;
    dt = mod(m.RX_TS - S.lastRxTs, 2^40) * tick;
    if hasEl && isfinite(S.lastElapsed)
        dHost = m.elapsed_s - S.lastElapsed;
        dt = dt + wrapS * max(0, round((dHost - dt) / wrapS));
        if dt > dHost + 5 && dt > 5
            dt = max(dHost, 0);        % counter jumped (anchor reset): trust the host
        end
    end
    t = S.rxTime + dt;
elseif hasEl
    t = m.elapsed_s;
elseif hasTs
    t = 0;
else
    t = (S.nIn - 1) * 0.1;
end
if hasTs, S.lastRxTs = m.RX_TS; end
if hasEl, S.lastElapsed = m.elapsed_s; end
S.rxTime = t;
end

% =============================================================================
function [taps, x, coherent] = local_frame_samples(frame, cfg)
if isfield(frame, 'taps')
    taps = frame.taps(:);
    x    = frame.x(:);
    coherent = ~isreal(x) || (isfield(frame, 'coherent') && frame.coherent);
else
    fp = frame.meta.FP_INDEX;
    norm = 1;
    if isfield(frame.meta, 'RXPACC') && frame.meta.RXPACC > 0
        norm = frame.meta.RXPACC;
    end
    taps = frame.sample(:) - fp;
    x    = complex(frame.re(:), frame.im(:)) / norm;
    coherent = true;
end
[taps, ia] = unique(taps);
x = x(ia);
if ~coherent, x = abs(x); end
if ~cfg.Coherent, x = abs(x); coherent = false; end
end

% =============================================================================
function xg = local_eval(ppRe, ppIm, q, inRange)
xg = zeros(size(q));
if isempty(ppIm)
    xg(inRange) = ppval(ppRe, q(inRange));
else
    xg(inRange) = complex(ppval(ppRe, q(inRange)), ppval(ppIm, q(inRange)));
end
xg(~inRange) = NaN;
end

% =============================================================================
function S = local_set_reference(S, xg)
cfg = S.cfg;
xg(~isfinite(xg)) = 0;
% Rotate so the direct-path peak is real and positive; the reference sets
% the phase every later frame is referred to.
pk = S.grid >= 0 & S.grid <= 8;
mag = abs(xg);
mag(~pk) = -Inf;
[~, j] = max(mag);
S.refX = xg * conj(xg(j)) / abs(xg(j));
if isreal(xg), S.refX = abs(xg); end
S.k0   = S.grid(j);
if isfield(cfg, 'PeakOffsetTaps') && ~isempty(cfg.PeakOffsetTaps)
    S.k0 = cfg.PeakOffsetTaps;
end
S.haveRef = true;

S.rangeAxis = mti_geometry('tap2range', S.grid, cfg, S.k0);
S.gate = S.rangeAxis >= cfg.MinRange & S.rangeAxis <= cfg.MaxRange;
end

% =============================================================================
function shift = local_fine_shift(S, ppRe, ppIm)
% Sub-tap shift that best lines the direct path's magnitude up with the
% reference. Normalised correlation, so the frame's gain does not matter.
cfg = S.cfg;
d   = S.dirIdx;
q0  = S.grid(d);
refMag = abs(S.refX(d));
refMag = refMag - mean(refMag);
shifts = -cfg.FineAlignMaxTaps : cfg.FineAlignStep : cfg.FineAlignMaxTaps;
score  = -inf(size(shifts));
lo = ppRe.breaks(1); hi = ppRe.breaks(end);
for k = 1:numel(shifts)
    q = q0 + shifts(k);
    if q(1) < lo || q(end) > hi, continue; end
    if isempty(ppIm)
        m = abs(ppval(ppRe, q));
    else
        m = abs(complex(ppval(ppRe, q), ppval(ppIm, q)));
    end
    m = m - mean(m);
    den = norm(m) * norm(refMag);
    if den > 0, score(k) = (m' * refMag) / den; end
end
[best, j] = max(score);
if ~isfinite(best)
    shift = 0;
    return
end
shift = shifts(j);
% Parabolic refinement between the neighbouring steps
if j > 1 && j < numel(shifts) && all(isfinite(score(j-1:j+1)))
    a = score(j-1); b = score(j); c = score(j+1);
    den = a - 2*b + c;
    if den < 0
        shift = shift + 0.5 * (a - c) / den * cfg.FineAlignStep;
    end
end
end

% =============================================================================
function S = local_finish_learning(S)
cfg = S.cfg;
Y = S.learnY;
S.B = mean(Y, 2);

% Residual energy the MTI filter lets through while nothing moves: that is
% the floor a real target has to beat, tap by tap.
if strcmpi(cfg.MTIMode, 'diff')
    res = abs(diff(Y, 1, 2)).^2;
else
    res = abs(Y - S.B).^2;
end
V = mean(res, 2);

% Averaging IntegrateFrames frames lowers the spread of the energy, not its
% mean, so the mean residual is the right floor. Spread it +/- 1 tap so a
% target sitting between two quiet taps next to a noisy one is not favoured.
w = max(1, round(1 / cfg.GridStep));
Vd = V;
for k = 1:w
    Vd = max(Vd, [V(1+k:end); V(end)*ones(k,1)]);
    Vd = max(Vd, [V(1)*ones(k,1); V(1:end-k)]);
end
S.noise = median(V(S.noiseIdx));
if ~isfinite(S.noise) || S.noise <= 0
    S.noise = median(V(V > 0));
end
S.thr = cfg.ThresholdFactor * max(Vd, S.noise);
S.learned = true;
S.learnY  = [];
S.eBuf    = zeros(numel(S.grid), 0);
end

% =============================================================================
function cand = local_candidates(S, E)
% Contiguous runs above threshold inside the range gate; each run reports
% its peak (parabolic sub-grid refinement), distance and strength.
cfg = S.cfg;
ratio = E ./ S.thr;
above = ratio > 1 & S.gate;
cand = struct('r', {}, 'tap', {}, 'ratio', {}, 'energy', {});
if ~any(above), return; end

edges = diff([0; above; 0]);
starts = find(edges == 1);
stops  = find(edges == -1) - 1;
minW = max(1, round(cfg.MinWidthTaps / cfg.GridStep));
for k = 1:numel(starts)
    idx = starts(k):stops(k);
    if numel(idx) < minW, continue; end
    [~, j] = max(E(idx));
    i = idx(j);
    tap = S.grid(i);
    if i > 1 && i < numel(E)
        a = E(i-1); b = E(i); c = E(i+1);
        den = a - 2*b + c;
        if den < 0
            tap = tap + 0.5 * (a - c) / den * cfg.GridStep;
        end
    end
    r = mti_geometry('tap2range', tap, cfg, S.k0);
    if ~isfinite(r) || r < cfg.MinRange || r > cfg.MaxRange, continue; end
    cand(end+1) = struct('r', r, 'tap', tap, 'ratio', max(ratio(idx)), ...
                         'energy', E(i)); %#ok<AGROW>
end
end

% =============================================================================
function [S, R] = local_track(S, R, cand, t)
cfg = S.cfg;
T = S.track;

% Predict
if T.active
    dt = t - T.t;
    rPred = T.r + T.v * dt;
else
    dt = NaN;
    rPred = NaN;
end

% Gate: while a track is fresh, only accept detections near its prediction
use = cand;
if T.active && ~isempty(cand) && (t - T.tLastDet) < cfg.ReacquireSeconds
    near = abs([cand.r] - rPred) <= cfg.GateMetres;
    use = cand(near);
end

pick = [];
if ~isempty(use)
    if strcmpi(cfg.Pick, 'nearest')
        % Earliest echo that is within NearestWithinDB of the strongest one.
        % Weaker ones just before a strong echo are the pulse's own sidelobes.
        en = [use.energy];
        strong = en >= max(en) / 10^(cfg.NearestWithinDB / 10);
        rr = [use.r];
        rr(~strong) = Inf;
        [~, j] = min(rr);
    else
        [~, j] = max([use.ratio]);
    end
    pick = use(j);
end

if ~isempty(pick)
    R.rDet  = pick.r;
    R.snrDB = 10 * log10(pick.ratio * cfg.ThresholdFactor);
    if ~T.active || abs(pick.r - rPred) > cfg.GateMetres
        % New track, or re-acquired somewhere else
        T.active = true;
        T.r = pick.r;
        T.v = 0;
    else
        res = pick.r - rPred;
        T.r = rPred + cfg.TrackAlpha * res;
        if dt > 0
            T.v = T.v + cfg.TrackBeta * res / dt;
        end
        T.v = max(min(T.v, cfg.MaxSpeed), -cfg.MaxSpeed);
        T.r = min(max(T.r, cfg.MinRange), cfg.MaxRange);
    end
    T.t = t;
    T.tLastDet = t;
    R.status = 'tracking';
elseif T.active && (t - T.tLastDet) <= cfg.CoastSeconds
    T.r = min(max(rPred, cfg.MinRange), cfg.MaxRange);
    T.t = t;
    T.v = T.v * 0.8;              % a person who vanished is more likely stopping
    R.status = 'coasting';
else
    T.active = false;
    T.r = NaN;
    T.v = 0;
    R.status = 'no target';
end

if T.active
    R.rTrack = T.r;
    R.vTrack = T.v;
end
S.track = T;
end
