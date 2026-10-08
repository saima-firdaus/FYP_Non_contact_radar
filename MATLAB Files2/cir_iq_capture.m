function outDir = cir_iq_capture(varargin)
%CIR_IQ_CAPTURE  CIR_capture.m's static session, keeping I/Q, then magnitude vs complex.
%
%   cir_iq_capture()                                  COM4, 30 s session
%   cir_iq_capture('Port', 'COM5', 'TrueDistance', 1.5, 'RunLabel', 'stand_1p5m')
%   cir_iq_capture('FromLog', folder)                 rebuild from a saved serial_log.txt
%   outDir = cir_iq_capture(...)
%
% The same session as CIR_capture.m (which stays untouched):
%
%   t = 0 .. 10 s    background: keep the scene empty
%   10 .. 20 s       walk to your mark (captured, not used)
%   20 .. 30 s       phase 2: stand still where you want to be measured
%
% and the same files, so cir_phase_analysis2 still runs on the folder:
%
%   Capture_IQ_yyyymmdd_HHMMSS/
%     serial_log.txt       every line from the anchor + host arrival time (I/Q)
%     02_lde_aligned/      frame_0001_aligned.csv ... one per frame: the
%                          CIR_capture columns plus real and imag; cir_mean.csv
%     frame_metadata.csv   header values per frame, elapsed_s, aligned_csv, ...
%     session_info.csv     phase timings, separation, where you stood
%     cir_iq_compare.png   the comparison figure (cir_phase_analysis_iq)
%
% What is different from CIR_capture.m:
%   - I and Q are kept (serial_log.txt, and real/imag in the aligned CSVs).
%   - Corrupted frames (truncated, or two frames spliced together after a
%     lost line; about 6% of your last capture) are dropped before anything
%     is written, so both methods, and cir_phase_analysis2, see the same
%     clean frames.
%   - At the end it runs cir_phase_analysis_iq on the folder: the magnitude
%     method (cir_phase_analysis2's) and the complex I/Q method (the MTI
%     chain's) side by side on the same frames, with where you stood marked
%     when you give TrueDistance.
%
% Options (defaults are CIR_capture.m's constants):
%   'Port'           'COM4'
%   'Baud'           921600
%   'CaptureSeconds' 30
%   'StartupDelayS'  10      wait before opening the port (opening it resets
%                            the ESP32)
%   'WalkPromptAtS'  10      background ends here
%   'WalkDurationS'  10      break to walk to your mark
%   'RunLabel'       'iq_static'
%   'Separation'     1       tag-anchor distance in m (TAG_ANCHOR_DIST_M)
%   'TrueDistance'   NaN     where you will stand, in m from the midpoint
%                            of the modules (tape-measured), for the figure
%   'OutputRoot'     pwd
%   'TapsBeforeFP'   50,  'TapsAfterFP' 100 (must match the sketch)
%   'GridStep'       0.5,  'TapToMetres' 0.30028
%   'Analyse'        true    run cir_phase_analysis_iq at the end
%   'FromLog'        ''      no port: rebuild the files of a folder that
%                            already has a serial_log.txt
%
% Don't run this and CIR_capture.m or cir_mti_live on the port at once.

% The mti_*.m helpers must sit in the same folder as this file.
addpath(fileparts(mfilename('fullpath')));
if exist('mti_parse_line', 'file') ~= 2
    error(['mti_parse_line.m not found. Copy the WHOLE mti folder (all mti_*.m ' ...
           'files) next to this script.']);
end

o = struct('Port', 'COM4', 'Baud', 921600, 'CaptureSeconds', 30, ...
           'StartupDelayS', 10, 'WalkPromptAtS', 10, 'WalkDurationS', 10, ...
           'RunLabel', 'iq_static', 'Separation', 1, 'TrueDistance', NaN, ...
           'OutputRoot', pwd, 'TapsBeforeFP', 50, 'TapsAfterFP', 100, ...
           'GridStep', 0.5, 'TapToMetres', 0.30028, 'Analyse', true, ...
           'FromLog', '');
names = fieldnames(o);
given = {};
for k = 1:2:numel(varargin)
    hit = find(strcmpi(names, varargin{k}), 1);
    if isempty(hit)
        error('cir_iq_capture: unknown option "%s".', char(varargin{k}));
    end
    o.(names{hit}) = varargin{k+1};
    given{end+1} = names{hit}; %#ok<AGROW>
end
if ~isempty(o.FromLog)
    o = local_session_defaults(o, given);   % a rebuild keeps the recorded timings
end
if o.WalkPromptAtS + o.WalkDurationS >= o.CaptureSeconds
    error(['No time left for phase 2: WalkPromptAtS (%g) + WalkDurationS (%g) ' ...
           'must be less than CaptureSeconds (%g).'], ...
           o.WalkPromptAtS, o.WalkDurationS, o.CaptureSeconds);
end
ALIGNED = '02_lde_aligned';

if ~isempty(o.FromLog)
    % ---- Rebuild from a log that was already recorded -------------------
    src = char(o.FromLog);
    if exist(src, 'dir')
        outDir = src;
        logFile = fullfile(src, 'serial_log.txt');
    else
        logFile = src;
        outDir = fileparts(src);
        if isempty(outDir), outDir = pwd; end
    end
    if ~exist(logFile, 'file')
        error('No serial_log.txt at %s', src);
    end
    [frames, P] = local_parse_file(logFile);
    if ~exist(fullfile(outDir, 'session_info.csv'), 'file')
        local_write_session(outDir, o, 'rebuilt', ALIGNED);
    end
    fprintf('Rebuilding %s from serial_log.txt\n', outDir);
else
    % ---- Live capture ----------------------------------------------------
    if o.StartupDelayS > 0
        fprintf('Waiting %g s before opening the port...\n', o.StartupDelayS);
        pause(o.StartupDelayS);
    end
    stamp  = datestr(now, 'yyyymmdd_HHMMSS'); %#ok<TNOW1,DATST>
    outDir = fullfile(o.OutputRoot, ['Capture_IQ_' stamp]);
    mkdir(outDir);
    % Written before the port opens, so an interrupted run still has its
    % phase boundaries (same reason as in CIR_capture.m).
    local_write_session(outDir, o, stamp, ALIGNED);
    fprintf('Saving this capture to %s\n', outDir);
    fprintf('  phases -> background 0-%gs | break %g-%gs | phase2 %g-%gs\n', ...
        o.WalkPromptAtS, o.WalkPromptAtS, o.WalkPromptAtS + o.WalkDurationS, ...
        o.WalkPromptAtS + o.WalkDurationS, o.CaptureSeconds);
    [frames, P] = local_capture(outDir, o);
end

nFr = numel(frames);
if P.nBadFrames > 0
    fprintf('Dropped %d corrupted frame(s) (truncated or spliced) of %d.\n', ...
        P.nBadFrames, P.nBadFrames + nFr);
end
if P.nRejected > 0
    fprintf('Discarded %d malformed sample line(s).\n', P.nRejected);
end
if nFr == 0
    error('No complete frames were captured - check the anchor is streaming.');
end

% ---- CIR_capture-compatible files ------------------------------------------
el = local_write_frames(outDir, frames, o, ALIGNED);
brk = o.WalkPromptAtS + o.WalkDurationS;
nBg = sum(el < o.WalkPromptAtS);
nWk = sum(el >= o.WalkPromptAtS & el < brk);
nP2 = sum(el >= brk);
fprintf('Frames per phase: background %d | break %d (not used) | phase2 %d\n', ...
    nBg, nWk, nP2);
if nBg == 0 || nP2 == 0
    warning('One of the phases captured no frames - this run cannot be compared.');
end

% ---- APS006-style single-frame figure, as CIR_capture draws it --------------
if exist('plot_cir_aps006', 'file') == 2
    try
        f = frames{1};
        fig = plot_cir_aps006(f.sample, hypot(f.re, f.im), f.meta, ...
            struct('anchorId', 1, 'blink', f.meta.FRAME));
        print(fig, fullfile(outDir, 'cir_plot.png'), '-dpng', '-r200');
    catch err
        fprintf('(single-frame APS006 figure skipped: %s)\n', err.message);
    end
end

% ---- Comparison --------------------------------------------------------------
if o.Analyse && nBg > 0 && nP2 > 0
    args = {};
    if isfinite(o.TrueDistance), args = {'TrueDistance', o.TrueDistance}; end
    cir_phase_analysis_iq(outDir, args{:});
end
fprintf('Done. All output written to %s\n', outDir);
fprintf('Re-run the comparison: cir_phase_analysis_iq(''%s'')\n', outDir);
fprintf('Original magnitude figure: cir_phase_analysis2(''%s'')\n', outDir);
end

% =============================================================================
function [frames, P] = local_capture(outDir, o)
% Same reading as cir_mti_live: stamp the host time into every header,
% log every line, parse as it arrives. Cues are printed, never paused, so the
% port is drained the whole time (CIR_capture.m does the same).
logFid = fopen(fullfile(outDir, 'serial_log.txt'), 'w');
closeLog = onCleanup(@() fclose(logFid)); %#ok<NASGU>
port = serialport(char(o.Port), o.Baud);
configureTerminator(port, "LF");
flush(port);
fprintf('Listening on %s for %g seconds...\n', char(o.Port), o.CaptureSeconds);

P = mti_parse_line();
frames = cell(1, 0);
brk = o.WalkPromptAtS + o.WalkDurationS;
walkSaid = false; p2Said = false;
t0 = tic;
while true
    el = toc(t0);
    if el >= o.CaptureSeconds, break; end
    if ~walkSaid && el >= o.WalkPromptAtS
        fprintf('\n>>> Walk to your position now, stand still by t=%gs.\n', brk);
        fprintf('>>> (frames from %gs to %gs are captured but not used)\n\n', ...
            o.WalkPromptAtS, brk);
        walkSaid = true;
    end
    if ~p2Said && el >= brk
        fprintf('\n>>> PHASE 2 - hold still until t=%gs.\n\n', o.CaptureSeconds);
        p2Said = true;
    end
    nLines = 0;
    while port.NumBytesAvailable > 0 && nLines < 400
        ln = char(strtrim(readline(port)));
        nLines = nLines + 1;
        if strncmp(ln, '# FRAME', 7)
            ln = sprintf('%s,elapsed_s,%.4f', ln, toc(t0));
        end
        fprintf(logFid, '%s\n', ln);
        [P, f] = mti_parse_line(P, ln);
        if ~isempty(f), frames{end+1} = f; end %#ok<AGROW>
    end
    if nLines == 0, pause(0.002); end
end
clear port
end

% =============================================================================
function [frames, P] = local_parse_file(file)
fid = fopen(file, 'r');
if fid < 0, error('Cannot open %s', file); end
c = onCleanup(@() fclose(fid));
P = mti_parse_line();
frames = cell(1, 0);
while true
    ln = fgetl(fid);
    if ~ischar(ln), break; end
    [P, f] = mti_parse_line(P, ln);
    if ~isempty(f), frames{end+1} = f; end %#ok<AGROW>
end
end

% =============================================================================
function el = local_write_frames(outDir, frames, o, alignedSub)
% One aligned CSV per frame + frame_metadata.csv + cir_mean.csv, in the
% layout CIR_capture.m writes (cir_phase_analysis2 reads these).
alignedDir = fullfile(outDir, alignedSub);
if ~exist(alignedDir, 'dir'), mkdir(alignedDir); end
g = (-o.TapsBeforeFP : o.GridStep : o.TapsAfterFP)';
nF = numel(frames);
ampGrid = nan(numel(g), nF);
el = nan(nF, 1);
rows = cell(nF, 1);
used = containers.Map();
for i = 1:nF
    f = frames{i};
    m = f.meta;
    taps = f.sample - m.FP_INDEX;
    amp  = hypot(f.re, f.im);
    acc  = 1;
    if isfield(m, 'RXPACC') && m.RXPACC > 0, acc = m.RXPACC; end
    nrm  = amp / acc;

    name = sprintf('frame_%04d_aligned.csv', m.FRAME);
    if isKey(used, name)              % frame counter restarted mid-capture
        name = sprintf('frame_%04d_%03d_aligned.csv', m.FRAME, i);
    end
    used(name) = true;
    fid = fopen(fullfile(alignedDir, name), 'w');
    fprintf(fid, 'sample,taps_from_fp,amplitude,amplitude_norm,real,imag\n');
    fprintf(fid, '%d,%.4f,%.2f,%.5f,%d,%d\n', [f.sample taps amp nrm f.re f.im].');
    fclose(fid);

    [u, ia] = unique(taps);
    if numel(u) >= 2
        ampGrid(:, i) = interp1(u, nrm(ia), g, 'linear', NaN);
    end
    m.tag_anchor_dist_m = o.Separation;
    m.n_samples   = numel(f.sample);
    m.aligned_csv = [alignedSub '/' name];
    rows{i} = m;
    if isfield(m, 'elapsed_s'), el(i) = m.elapsed_s; end
end

% frame_metadata.csv: every header field, in the order the anchor sends them
cols = {};
for i = 1:nF
    fn = fieldnames(rows{i});
    for k = 1:numel(fn)
        if ~any(strcmp(cols, fn{k})), cols{end+1} = fn{k}; end %#ok<AGROW>
    end
end
fid = fopen(fullfile(outDir, 'frame_metadata.csv'), 'w');
fprintf(fid, '%s\n', strjoin(cols, ','));
for i = 1:nF
    parts = cell(1, numel(cols));
    for k = 1:numel(cols)
        if isfield(rows{i}, cols{k}), v = rows{i}.(cols{k}); else, v = NaN; end
        if ischar(v), parts{k} = v; else, parts{k} = sprintf('%.15g', v); end
    end
    fprintf(fid, '%s\n', strjoin(parts, ','));
end
fclose(fid);

% cir_mean.csv: whole-session average, as CIR_capture.m writes it
n  = sum(isfinite(ampGrid), 2);
A0 = ampGrid; A0(~isfinite(A0)) = 0;
mu = sum(A0, 2) ./ max(n, 1);
D0 = ampGrid - mu; D0(~isfinite(D0)) = 0;
sd = sqrt(sum(D0.^2, 2) ./ max(n - 1, 1));
mu(n == 0) = NaN; sd(n < 2) = NaN;
fid = fopen(fullfile(alignedDir, 'cir_mean.csv'), 'w');
fprintf(fid, 'taps_from_fp,amplitude_norm_mean,amplitude_norm_sd,n_frames\n');
fprintf(fid, '%.4f,%.6f,%.6f,%d\n', [g mu sd n].');
fclose(fid);
fprintf('Saved %d aligned frames, frame_metadata.csv and cir_mean.csv\n', nF);
end

% =============================================================================
function o = local_session_defaults(o, given)
% For 'FromLog': take phase timings, separation, grid and where you stood
% from the folder's own session_info.csv, unless passed explicitly.
src = char(o.FromLog);
if ~exist(src, 'dir'), src = fileparts(src); end
f = fullfile(src, 'session_info.csv');
if isempty(src) || ~exist(f, 'file'), return; end
fid = fopen(f, 'r');
hdr = strtrim(strsplit(fgetl(fid), ','));
row = fgetl(fid);
fclose(fid);
if ~ischar(row), return; end
val = strsplit(row, ',');
map = {'walk_prompt_at_s', 'WalkPromptAtS'; 'walk_duration_s', 'WalkDurationS'; ...
       'capture_seconds', 'CaptureSeconds'; 'tag_anchor_dist_m', 'Separation'; ...
       'true_distance_m', 'TrueDistance'; 'taps_before_fp', 'TapsBeforeFP'; ...
       'taps_after_fp', 'TapsAfterFP'; 'mean_grid_step', 'GridStep'; ...
       'tap_to_metres', 'TapToMetres'};
for k = 1:size(map, 1)
    j = find(strcmpi(hdr, map{k, 1}), 1);
    if isempty(j) || j > numel(val) || any(strcmp(given, map{k, 2})), continue; end
    v = str2double(val{j});
    if isfinite(v), o.(map{k, 2}) = v; end
end
end

% =============================================================================
function local_write_session(outDir, o, stamp, alignedSub)
% CIR_capture.m's session_info.csv columns, plus the separation and where
% you stood, which cir_phase_analysis_iq reads back.
lbl = strrep(char(o.RunLabel), ',', '_');
td  = '';
if isfinite(o.TrueDistance), td = sprintf('%g', o.TrueDistance); end
fid = fopen(fullfile(outDir, 'session_info.csv'), 'w');
fprintf(fid, ['run_label,run_stamp,capture_seconds,walk_prompt_at_s,' ...
    'walk_duration_s,taps_before_fp,taps_after_fp,mean_grid_step,' ...
    'tap_to_metres,port,baud,aligned_subdir,tag_anchor_dist_m,' ...
    'true_distance_m,capture_kind\n']);
fprintf(fid, '%s,%s,%g,%g,%g,%g,%g,%g,%g,%s,%d,%s,%g,%s,iq\n', lbl, stamp, ...
    o.CaptureSeconds, o.WalkPromptAtS, o.WalkDurationS, o.TapsBeforeFP, ...
    o.TapsAfterFP, o.GridStep, o.TapToMetres, char(o.Port), o.Baud, ...
    alignedSub, o.Separation, td);
fclose(fid);
end
