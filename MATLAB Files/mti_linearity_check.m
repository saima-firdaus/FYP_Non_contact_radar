function out = mti_linearity_check(src, varargin)
%MTI_LINEARITY_CHECK  Is the receiver linear? Static echoes vs the direct path, against RXPWR and RXPACC.
%
%   MTI_LINEARITY_CHECK(folder)                    one capture
%   MTI_LINEARITY_CHECK({folderA, folderB, ...})   several, e.g. a TX-power sweep
%   out = MTI_LINEARITY_CHECK(..., 'EchoTaps', [24 31], 'SkipSeconds', 1)
%
% Works on cir_iq_capture / cir_mti_live folders (serial_log.txt) and on
% CIR_capture folders that still have 02_lde_aligned/ (magnitude only).
%
% For every frame, on the FP-aligned magnitude divided by RXPACC (what
% CIR_capture saves), it reads:
%   direct   the direct path at k0 (its peak, 0..8 taps after FP)
%   echoes   up to 3 static echoes, by default the strongest background
%            peaks at least 6 taps after the direct one
% If the front end is linear, one gain scales the whole CIR: echo/direct
% stays put whatever RXPWR, RXPACC or the TX power do (a flat line).
% Compression or clipping squeezes the strongest path first, so echo/direct
% RISES as the signal gets stronger.
%
% A single capture only spans a few dB of RXPWR, so it can only show gross
% compression. The real test is a TX-power sweep: record the same empty
% room at 3-4 TX power settings (setTXPower in setup_tag.cpp) and pass all
% the folders. Linear: echo/direct is the same in every folder.
%
% It also prints the largest raw |I| or |Q| seen. The accumulator values
% are int16, so 32767 is full scale; the headroom says how far from it the
% strongest sample was.
%
% When the session has phase timings (cir_iq_capture, CIR_capture) only
% background frames are fitted, since a person changes the echoes; phase 2
% is drawn in grey. Options: 'EchoTaps' ([] = auto), 'SkipSeconds' (1),
% 'Plot' (true).

addpath(fileparts(mfilename('fullpath')));
if exist('mti_read_capture', 'file') ~= 2
    error('mti_read_capture.m not found. Copy the WHOLE mti folder.');
end
o = struct('EchoTaps', [], 'SkipSeconds', 1, 'Plot', true);
for k = 1:2:numel(varargin)
    names = fieldnames(o);
    hit = find(strcmpi(names, varargin{k}), 1);
    if isempty(hit), error('Unknown option "%s".', char(varargin{k})); end
    o.(names{hit}) = varargin{k+1};
end
if ~iscell(src), src = {src}; end

g = (-10 : 0.25 : 60).';
R = cell(1, numel(src));
echoTaps = o.EchoTaps;
for s = 1:numel(src)
    R{s} = local_one(char(src{s}), g, o.SkipSeconds);
    if isempty(echoTaps)                     % pick once, from the first folder
        echoTaps = local_pick_echoes(g, R{s});
    end
end
for s = 1:numel(src)
    R{s} = local_measure(R{s}, g, echoTaps);
end

% ---- Report ----------------------------------------------------------------------------
fprintf('\n=== Linearity check: direct path at k0 = %+.2f taps, echoes at %s taps ===\n', ...
    R{1}.k0, mat2str(echoTaps, 3));
fprintf('%-28s %6s %9s %10s %9s', 'capture', 'frames', 'RXPWR', 'direct', 'max|I,Q|');
for e = 1:numel(echoTaps), fprintf(' %13s', sprintf('echo%+.0f/dir', echoTaps(e))); end
fprintf('\n');
for s = 1:numel(src)
    r = R{s};
    [~, nm] = fileparts(r.dir);
    if numel(nm) > 28, nm = ['...' nm(end-24:end)]; end
    fprintf('%-28s %6d %7.1f dB %10.3g %9s', nm, sum(r.bg), median(r.rxpwr(r.bg)), ...
        median(r.direct(r.bg)), local_headroom_str(r.maxIQ));
    for e = 1:numel(echoTaps), fprintf(' %10.2f dB', median(r.ratioDB(r.bg, e))); end
    fprintf('\n');
end
for s = 1:numel(src)
    r = R{s};
    [~, nm] = fileparts(r.dir);
    fprintf('\n%s (background frames only):\n', nm);
    fprintf('  RXPWR spans %.1f dB; direct/RXPACC moves %+.2f dB per dB of RXPWR\n', ...
        r.rxSpan, r.slopeDirect);
    for e = 1:numel(echoTaps)
        fprintf(['  echo %+5.1f / direct: %+.2f dB per dB of RXPWR  -> %+.2f dB across ' ...
                 'this capture\n'], echoTaps(e), r.slopeRatio(e), r.slopeRatio(e) * r.rxSpan);
    end
    if isfinite(r.accExp)
        fprintf('  raw direct peak grows as RXPACC^%.2f (1.00 = the coherent sum CIR_capture assumes)\n', ...
            r.accExp);
    end
    if isfinite(r.maxIQ)
        fprintf('  largest raw |I| or |Q|: %d of 32767 (%.1f dB of headroom)\n', ...
            round(r.maxIQ), 20 * log10(32767 / r.maxIQ));
    end
end
if numel(src) > 1
    rat = cellfun(@(r) median(r.ratioDB(r.bg, :), 1), R, 'UniformOutput', false);
    rat = vertcat(rat{:});
    fprintf(['\nAcross the captures echo/direct moves by %s dB (max - min per echo). ' ...
             'Under ~0.5 dB = linear.\n'], mat2str(round(100 * (max(rat, [], 1) - min(rat, [], 1))) / 100));
else
    fprintf(['\nFlat (under ~0.5 dB across the capture) = linear over this range. ' ...
             'One capture spans only a few dB;\na TX-power sweep over several ' ...
             'captures is the real test.\n']);
end
out = R;

if o.Plot
    local_plot(R, echoTaps);
end
end

% =============================================================================
function r = local_one(d, g, skipS)
[frames, info] = mti_read_capture(d);
nF = numel(frames);
r = struct('dir', d, 'mag', nan(numel(g), nF), 'rxpwr', nan(nF, 1), ...
           'rxpacc', nan(nF, 1), 'el', nan(nF, 1), 'maxIQ', NaN, 'rawPeak', nan(nF, 1));
mx = 0;
for i = 1:nF
    f = frames{i}; m = f.meta;
    acc = 1;
    if isfield(m, 'RXPACC') && m.RXPACC > 0, acc = m.RXPACC; end
    if isfield(f, 'taps')                        % CIR_capture folder: amplitude_norm
        taps = f.taps; a = abs(f.x);
    else
        taps = f.sample - m.FP_INDEX; a = hypot(f.re, f.im) / acc;
        mx = max([mx; abs(f.re); abs(f.im)]);
    end
    [u, ia] = unique(taps);
    if numel(u) >= 2, r.mag(:, i) = interp1(u, a(ia), g, 'linear', NaN); end
    if isfield(m, 'RXPWR'), r.rxpwr(i) = m.RXPWR; end
    r.rxpacc(i) = acc;
    if isfield(m, 'elapsed_s'), r.el(i) = m.elapsed_s; end
end
if info.coherent, r.maxIQ = mx; end
if all(isnan(r.el)), r.el = (0:nF-1).' * 0.1; end
S = info.session;
t = r.el - min(r.el);
r.bg = t >= skipS;
r.p2 = false(nF, 1);
if isfield(S, 'walk_prompt_at_s') && isnumeric(S.walk_prompt_at_s)
    r.bg = r.bg & r.el < S.walk_prompt_at_s;
    if isfield(S, 'walk_duration_s') && isnumeric(S.walk_duration_s)
        r.p2 = r.el >= S.walk_prompt_at_s + S.walk_duration_s;
    end
end
mu = local_nanmean(r.mag(:, r.bg));
w = find(g >= 0 & g <= 8);
[~, j] = max(mu(w));
r.k0 = g(w(j));
r.bgMean = mu;
end

% =============================================================================
function taps = local_pick_echoes(g, r)
% The 3 strongest local peaks of the background, >= 6 taps after the direct
% one and >= 3 taps apart: static reflections well clear of the direct pulse.
mu = r.bgMean;
isMax = false(size(mu));
isMax(2:end-1) = mu(2:end-1) >= mu(1:end-2) & mu(2:end-1) > mu(3:end);
c = find(isMax & g >= r.k0 + 6);
[~, ord] = sort(mu(c), 'descend');
taps = [];
for k = ord(:).'
    if isempty(taps) || all(abs(taps - g(c(k))) >= 3), taps(end+1) = g(c(k)); end %#ok<AGROW>
    if numel(taps) == 3, break; end
end
taps = sort(taps);
end

% =============================================================================
function r = local_measure(r, g, echoTaps)
[~, iD] = min(abs(g - r.k0));
r.direct = r.mag(iD, :).';
nE = numel(echoTaps);
r.echo = nan(numel(r.direct), nE);
for e = 1:nE
    [~, iE] = min(abs(g - echoTaps(e)));
    r.echo(:, e) = r.mag(iE, :).';
end
r.ratioDB = 20 * log10(r.echo ./ r.direct);
b = r.bg & isfinite(r.rxpwr) & isfinite(r.direct);
r.rxSpan = max(r.rxpwr(b)) - min(r.rxpwr(b));
r.slopeDirect = NaN; r.slopeRatio = nan(1, nE); r.accExp = NaN;
if sum(b) > 5 && r.rxSpan > 0
    p = polyfit(r.rxpwr(b), 20 * log10(r.direct(b)), 1); r.slopeDirect = p(1);
    for e = 1:nE
        ok = b & isfinite(r.ratioDB(:, e));
        p = polyfit(r.rxpwr(ok), r.ratioDB(ok, e), 1); r.slopeRatio(e) = p(1);
    end
end
raw = r.direct .* r.rxpacc;                      % back to accumulator units
if sum(b) > 5 && range_(log(r.rxpacc(b))) > 0
    p = polyfit(log(r.rxpacc(b)), log(raw(b)), 1); r.accExp = p(1);
end
end

% =============================================================================
function local_plot(R, echoTaps)
fig = figure('Color', 'w', 'Position', [80 60 1100 760]);
cols = [0 0.35 0.75; 0.85 0.33 0.1; 0 0.6 0.25; 0.5 0.2 0.6; 0.9 0.7 0.1; 0.3 0.3 0.3];
axs = cell(1, 4);
for q = 1:4, axs{q} = subplot(2, 2, q); hold(axs{q}, 'on'); grid(axs{q}, 'on'); end
hL = []; lg = {};
for s = 1:numel(R)
    r = R{s}; c = cols(mod(s-1, 6) + 1, :);
    [~, nm] = fileparts(r.dir);
    if numel(R) == 1, c = cols(1, :); end
    plot(axs{1}, r.rxpwr(r.p2), 20*log10(r.direct(r.p2)), '.', 'Color', [0.7 0.7 0.7]);
    h = plot(axs{1}, r.rxpwr(r.bg), 20*log10(r.direct(r.bg)), '.', 'Color', c, 'MarkerSize', 10);
    hL = [hL h]; lg{end+1} = nm; %#ok<AGROW>
    for e = 1:numel(echoTaps)
        ce = c;
        if numel(R) == 1, ce = cols(e + 1, :); end
        plot(axs{2}, r.rxpwr(r.p2), 20*log10(r.echo(r.p2, e)), '.', 'Color', [0.7 0.7 0.7]);
        plot(axs{2}, r.rxpwr(r.bg), 20*log10(r.echo(r.bg, e)), '.', 'Color', ce, 'MarkerSize', 10);
        plot(axs{3}, r.rxpwr(r.p2), r.ratioDB(r.p2, e), '.', 'Color', [0.7 0.7 0.7]);
        plot(axs{3}, r.rxpwr(r.bg), r.ratioDB(r.bg, e), '.', 'Color', ce, 'MarkerSize', 10);
    end
    raw = r.direct .* r.rxpacc;
    plot(axs{4}, r.rxpacc(r.p2), raw(r.p2), '.', 'Color', [0.7 0.7 0.7]);
    plot(axs{4}, r.rxpacc(r.bg), raw(r.bg), '.', 'Color', c, 'MarkerSize', 10);
end
xlabel(axs{1}, 'RXPWR (dBm, as reported)'); ylabel(axs{1}, 'Direct path / RXPACC (dB)');
title(axs{1}, 'Direct path vs RXPWR');
legend(axs{1}, hL, lg, 'Location', 'best', 'Interpreter', 'none');
xlabel(axs{2}, 'RXPWR (dBm)'); ylabel(axs{2}, 'Echo / RXPACC (dB)');
title(axs{2}, sprintf('Static echoes at %s taps', mat2str(echoTaps, 3)));
xlabel(axs{3}, 'RXPWR (dBm)'); ylabel(axs{3}, 'Echo / direct (dB)');
title(axs{3}, 'Echo / direct: flat = linear, rising = compression');
set(axs{4}, 'XScale', 'log', 'YScale', 'log');
acc = cellfun(@(r) [min(r.rxpacc) max(r.rxpacc)], R, 'UniformOutput', false);
acc = [acc{:}];
raw = cellfun(@(r) [min(r.direct .* r.rxpacc) max(r.direct .* r.rxpacc)], R, ...
    'UniformOutput', false);
raw = [raw{:}];
if all(isfinite(acc)) && all(isfinite(raw))
    xlim(axs{4}, [0.95 * min(acc) 1.05 * max(acc)]);
    ylim(axs{4}, [0.8 * min(raw) 1.25 * max(raw)]);
end
xlabel(axs{4}, 'RXPACC'); ylabel(axs{4}, 'Raw direct-path amplitude');
title(axs{4}, 'Raw direct peak vs RXPACC (a linear sum has slope 1)');
d = R{1}.dir;
print(fig, fullfile(d, 'mti_linearity_check.png'), '-dpng', '-r150');
fprintf('Saved %s\n', fullfile(d, 'mti_linearity_check.png'));
end

% =============================================================================
function s = local_headroom_str(mx)
if isfinite(mx), s = sprintf('%d', round(mx)); else, s = 'n/a'; end
end

function m = local_nanmean(A)
ok = isfinite(A); A(~ok) = 0;
m = sum(A, 2) ./ max(sum(ok, 2), 1);
m(sum(ok, 2) == 0) = NaN;
end

function v = range_(x)
v = max(x) - min(x);
end
