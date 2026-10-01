function out = cir_mti_live(varargin)
%CIR_MTI_LIVE  Live distance of a moving person from the DW1000 CIR stream (MTI).
%
%   CIR_MTI_LIVE()                          live from COM4 at 921600
%   CIR_MTI_LIVE('Port', "COM5")            another port
%   CIR_MTI_LIVE('Replay', folderOrLog)     replay a saved capture instead
%   out = CIR_MTI_LIVE(...)                 also return the whole track
%
% Reads the same serial stream CIR_capture.m reads (NLOS_anchor.cpp output),
% but keeps I and Q, which CIR_capture does not save, and runs every frame
% through the MTI chain as it arrives (mti_step). Shows:
%
%   - a big readout: distance from the midpoint of the modules, and whether
%     the person is approaching or moving away
%   - distance vs time for the last WindowS seconds
%   - a top view: the two modules, the ellipse the echo puts the person on,
%     and the person's position on the centre line
%   - the current MTI profile vs distance against the detection threshold
%
% and prints one line per update in the Command Window. Close the figure or
% press Ctrl+C to stop.
%
% HOW TO RUN A SESSION
%   1. Power the tag and anchor, place them Separation apart, facing the room.
%   2. Run cir_mti_live. Opening the port resets the ESP32; wait for frames.
%   3. Keep the area in front of the modules EMPTY until "READY" is printed
%      (SettleSeconds + LearnSeconds, 13 s by default). That is where the
%      static room and the threshold are learned.
%   4. Walk in front of the modules / move your arms. Distance updates live.
%
% Every live run records Capture_MTI_yyyymmdd_HHMMSS/ with serial_log.txt
% (raw anchor output + host time, replayable), session_info.csv and
% mti_track.csv. Re-run the analysis offline with cir_mti_analysis(folder),
% or watch it again with cir_mti_live('Replay', folder).
%
% Options:
%   'Port'          "COM4"     serial port (same as CIR_capture.m)
%   'Baud'          921600
%   'StartupDelayS' 0          wait before opening the port
%   'Replay'        ''         Capture_MTI_* folder, serial_log.txt, or an
%                              old CIR_capture folder (magnitude-only)
%   'ReplaySpeed'   1          1 = real time, 4 = 4x faster, Inf = no waiting
%   'DurationS'     Inf        stop after this long
%   'Record'        true       save the live session (ignored for replay)
%   'OutputRoot'    pwd
%   'Display'       true       false = Command Window readout only
%   'WindowS'       20         seconds of history on the distance plot
%   'PrintEvery'    0.5        seconds between Command Window lines
% plus anything MTI_CONFIG takes: 'Separation', 'MaxRange', 'MTIMode',
% 'ClutterAlpha', 'LearnSeconds', 'ThresholdFactor', 'Pick', ...

% The mti_*.m helpers must sit in the same folder as this file.
addpath(fileparts(mfilename('fullpath')));
if exist('mti_config', 'file') ~= 2
    error(['mti_config.m not found. Copy the WHOLE mti folder (all mti_*.m ' ...
           'files) next to this script.']);
end

% ---- Options ----------------------------------------------------------------------
o = struct('Port', "COM4", 'Baud', 921600, 'StartupDelayS', 0, 'Replay', '', ...
           'ReplaySpeed', 1, 'DurationS', Inf, 'Record', true, ...
           'OutputRoot', pwd, 'Display', true, 'WindowS', 20, 'PrintEvery', 0.5);
cfgArgs = {};
names = fieldnames(o);
for k = 1:2:numel(varargin)
    hit = find(strcmpi(names, varargin{k}), 1);
    if isempty(hit)
        cfgArgs(end+1:end+2) = varargin(k:k+1); %#ok<AGROW>
    else
        o.(names{hit}) = varargin{k+1};
    end
end
cfg = mti_config(cfgArgs{:});
isReplay = ~isempty(o.Replay);

% ---- Source ----------------------------------------------------------------------------
L = struct('fid', -1, 'dir', '', 'port', []);
if isReplay
    [frames, info] = mti_read_capture(o.Replay);
    if ~info.coherent
        cfg.Coherent = false;
        fprintf(['NOTE: this capture has no I/Q (CIR_capture saves amplitude ' ...
                 'only) - magnitude-only MTI.\n']);
    end
    fprintf('Replaying %d frames from %s at %gx\n', numel(frames), ...
        char(o.Replay), o.ReplaySpeed);
else
    if o.StartupDelayS > 0
        fprintf('Waiting %g s before opening the port...\n', o.StartupDelayS);
        pause(o.StartupDelayS);
    end
    if o.Record
        L.dir = fullfile(o.OutputRoot, ['Capture_MTI_' datestr(now, 'yyyymmdd_HHMMSS')]); %#ok<TNOW1,DATST>
        mkdir(L.dir);
        L.fid = fopen(fullfile(L.dir, 'serial_log.txt'), 'w');
        local_write_session(L.dir, cfg, o);
        fprintf('Recording to %s\n', L.dir);
    end
    L.port = serialport(o.Port, o.Baud);
    configureTerminator(L.port, "LF");
    flush(L.port);
    fprintf('Listening on %s at %d baud.\n', char(o.Port), o.Baud);
end
cleaner = onCleanup(@() local_close(L));

fprintf(['\n>>> Keep the area in front of the modules EMPTY for the first ' ...
         '%g s (learning the room).\n\n'], cfg.SettleSeconds + cfg.LearnSeconds);

% ---- State ---------------------------------------------------------------------------------
S   = mti_init(cfg);
P   = mti_parse_line();
G   = [];
if o.Display, G = local_make_figure(cfg, o); end
H   = struct('t', zeros(0,1), 'rDet', zeros(0,1), 'rTrack', zeros(0,1), ...
             'vTrack', zeros(0,1), 'snr', zeros(0,1), 'status', {{}}, ...
             'frame', zeros(0,1));
lastPrint = -Inf; lastDraw = 0; lastStatus = ''; announcedReady = false;
iReplay = 0; tWall = tic; tFirstFrame = NaN;
lastR = [];

% ---- Main loop --------------------------------------------------------------------------
while true
    if toc(tWall) >= o.DurationS, break; end
    if o.Display && ~ishandle(G.fig), break; end

    % -- collect whatever frames are ready --
    newFrames = {};
    if isReplay
        if iReplay >= numel(frames), break; end
        f = frames{iReplay + 1};
        if isnan(tFirstFrame), tFirstFrame = local_frame_t(f, iReplay); end
        due = (local_frame_t(f, iReplay) - tFirstFrame) / o.ReplaySpeed;
        if isinf(o.ReplaySpeed) || toc(tWall) >= due
            iReplay = iReplay + 1;
            newFrames{1} = f;
        else
            pause(min(0.01, due - toc(tWall)));
        end
    else
        nLines = 0;
        while L.port.NumBytesAvailable > 0 && nLines < 400
            ln = char(strtrim(readline(L.port)));
            nLines = nLines + 1;
            if strncmp(ln, '# FRAME', 7)
                % Stamp the host arrival time into the header itself, so the
                % log replays with the same timing and the parser picks it up
                ln = sprintf('%s,elapsed_s,%.4f', ln, toc(tWall));
            end
            if L.fid > 0, fprintf(L.fid, '%s\n', ln); end
            [P, f] = mti_parse_line(P, ln);
            if ~isempty(f), newFrames{end+1} = f; end %#ok<AGROW>
        end
        if isempty(newFrames), pause(0.002); end
    end

    % -- process them --
    for k = 1:numel(newFrames)
        [S, R] = mti_step(S, newFrames{k});
        H.t(end+1,1) = R.t; H.rDet(end+1,1) = R.rDet;
        H.rTrack(end+1,1) = R.rTrack; H.vTrack(end+1,1) = R.vTrack;
        H.snr(end+1,1) = R.snrDB; H.status{end+1,1} = R.status;
        H.frame(end+1,1) = R.frameNo;
        lastR = R;

        if ~announcedReady && S.learned
            fprintf('\n>>> READY - move in front of the modules now.\n\n');
            announcedReady = true;
        end
        % One line every PrintEvery seconds while there is a target, and one
        % whenever the state changes (coasting counts as still tracking).
        st = R.status;
        if strcmp(st, 'coasting'), st = 'tracking'; end
        changed = ~strcmp(st, lastStatus);
        periodic = strcmp(st, 'tracking') && R.t - lastPrint >= o.PrintEvery;
        if changed || periodic
            fprintf('%s\n', local_readout(R));
            lastPrint = R.t;
            lastStatus = st;
        end
    end

    % -- redraw at most ~15 times a second; while MATLAB is behind the
    %    modules, only once a second so it can catch up --
    behind = ~isempty(lastR) && isfinite(lastR.lag) && lastR.lag > 0.3;
    if o.Display && ~isempty(newFrames) && toc(tWall) - lastDraw > 0.066 ...
            && (~behind || toc(tWall) - lastDraw > 1)
        local_update_figure(G, S, H, lastR, cfg, o);
        try, drawnow('limitrate'); catch, drawnow; end %#ok<NOCOM>
        lastDraw = toc(tWall);
    end
end

if o.Display && ishandle(G.fig) && ~isempty(lastR)
    local_update_figure(G, S, H, lastR, cfg, o);
    drawnow;
end

% ---- Save + return ---------------------------------------------------------------------
if ~isReplay && P.nBadFrames > 0
    fprintf('Dropped %d corrupted frame(s) (truncated or spliced) of %d.\n', ...
        P.nBadFrames, P.nBadFrames + P.nFrames);
end
if ~isReplay && ~isempty(L.dir)
    local_write_track(fullfile(L.dir, 'mti_track.csv'), H);
    fprintf('\nSaved %s\n', L.dir);
    fprintf('Analyse offline: cir_mti_analysis(''%s'')\n', L.dir);
end
out = H;
out.cfg = cfg;
out.dir = L.dir;
end

% =============================================================================
function t = local_frame_t(f, i)
if isfield(f.meta, 'elapsed_s') && isfinite(f.meta.elapsed_s)
    t = f.meta.elapsed_s;
else
    t = i * 0.1;
end
end

% =============================================================================
function s = local_readout(R)
switch R.status
    case 'tracking'
        s = sprintf('%6.1f s | distance %5.2f m | %s | SNR %4.1f dB', ...
            R.t, R.rTrack, local_motion_words(R.vTrack), R.snrDB);
        if isfinite(R.lag) && R.lag > 0.5
            s = sprintf('%s | MATLAB %.1f s behind', s, R.lag);
        end
    case 'coasting'
        s = sprintf('%6.1f s | distance %5.2f m | (holding - no fresh echo)', ...
            R.t, R.rTrack);
    case 'learning'
        s = sprintf('%6.1f s | learning empty room ... keep clear', R.t);
    case 'settling'
        s = sprintf('%6.1f s | frames arriving, settling ...', R.t);
    otherwise
        s = sprintf('%6.1f s | no moving target', R.t);
end
end

function w = local_motion_words(v)
if ~isfinite(v) || abs(v) < 0.1
    w = 'about still        ';
elseif v > 0
    w = sprintf('moving AWAY %4.2f m/s', v);
else
    w = sprintf('APPROACHING %4.2f m/s', -v);
end
end

% =============================================================================
function G = local_make_figure(cfg, o)
G.fig = figure('Color', 'w', 'Name', 'DW1000 MTI - live distance', ...
               'NumberTitle', 'off', 'Position', [60 60 1150 760]);
rMax = cfg.MaxRange + 0.3;

% Distance vs time
G.ax1 = subplot(2, 2, [1 2]); hold(G.ax1, 'on'); grid(G.ax1, 'on');
G.hDet = plot(G.ax1, NaN, NaN, '.', 'Color', [0.6 0.6 0.6], 'MarkerSize', 10);
G.hTrk = plot(G.ax1, NaN, NaN, '-', 'Color', [0 0.35 0.75], 'LineWidth', 2.5);
G.hNow = plot(G.ax1, NaN, NaN, 'o', 'MarkerSize', 12, 'LineWidth', 2, ...
              'MarkerFaceColor', [0.85 0.33 0.1], 'MarkerEdgeColor', 'k');
ylim(G.ax1, [0 rMax]); xlim(G.ax1, [0 o.WindowS]);
ylabel(G.ax1, 'Distance from midpoint (m)');
xlabel(G.ax1, 'Time (s)');
G.title = title(G.ax1, 'Waiting for frames...', 'FontSize', 20, 'FontWeight', 'bold');
legend(G.ax1, [G.hDet G.hTrk], {'Detection', 'Tracked distance'}, ...
       'Location', 'northwest');

% Top view
G.ax2 = subplot(2, 2, 3); hold(G.ax2, 'on'); grid(G.ax2, 'on');
D = cfg.Separation;
plot(G.ax2, [-D/2 D/2], [0 0], 's', 'MarkerSize', 10, 'LineWidth', 2, ...
     'MarkerFaceColor', [0.3 0.3 0.3], 'MarkerEdgeColor', 'k');
text(G.ax2, -D/2, -0.28, 'tag', 'HorizontalAlignment', 'center');
text(G.ax2,  D/2, -0.28, 'anchor', 'HorizontalAlignment', 'center');
for r = 1:floor(cfg.MaxRange)                     % faint 1 m range rings
    [ex, ey] = local_ellipse(r, D);
    plot(G.ax2, ex, ey, ':', 'Color', [0.8 0.8 0.8]);
    text(G.ax2, 0.03, r + 0.06, sprintf('%d m', r), 'Color', [0.6 0.6 0.6]);
end
G.hEll = plot(G.ax2, NaN, NaN, '-', 'Color', [0 0.35 0.75], 'LineWidth', 1.5);
G.hPer = plot(G.ax2, NaN, NaN, 'o', 'MarkerSize', 16, 'LineWidth', 2, ...
              'MarkerFaceColor', [0.85 0.33 0.1], 'MarkerEdgeColor', 'k');
axis(G.ax2, 'equal');
xlim(G.ax2, [-2.2 2.2]); ylim(G.ax2, [-0.5 rMax]);
xlabel(G.ax2, 'Across (m)'); ylabel(G.ax2, 'In front (m)');
title(G.ax2, 'Top view: echo ellipse and centre-line position');

% MTI profile
G.ax3 = subplot(2, 2, 4); hold(G.ax3, 'on'); grid(G.ax3, 'on');
G.hPro = plot(G.ax3, NaN, NaN, '-', 'Color', [0.45 0.2 0.6], 'LineWidth', 1.5);
plot(G.ax3, [0 rMax], [0 0], '--', 'Color', [0 0.6 0.7], 'LineWidth', 1.2);
G.hPk  = plot(G.ax3, NaN, NaN, 'v', 'MarkerSize', 10, 'LineWidth', 1.5, ...
              'MarkerFaceColor', [0.85 0.33 0.1], 'MarkerEdgeColor', 'k');
xlim(G.ax3, [0 rMax]); ylim(G.ax3, [-15 25]);
xlabel(G.ax3, 'Distance from midpoint (m)');
ylabel(G.ax3, 'MTI over threshold (dB)');
title(G.ax3, 'Motion now, by distance (above dashed line = detected)');
end

% =============================================================================
function local_update_figure(G, S, H, R, cfg, o)
if isempty(H.t), return; end
t0 = H.t(1);
tt = H.t - t0;
tNow = tt(end);
win = tt >= tNow - o.WindowS;
set(G.hDet, 'XData', tt(win), 'YData', H.rDet(win));
set(G.hTrk, 'XData', tt(win), 'YData', H.rTrack(win));
set(G.hNow, 'XData', tNow, 'YData', H.rTrack(end));
xlim(G.ax1, [max(0, tNow - o.WindowS), max(o.WindowS, tNow) + 0.5]);

switch R.status
    case {'tracking', 'coasting'}
        v = R.vTrack;
        if ~isfinite(v) || abs(v) < 0.1
            arrow = 'still';
        elseif v > 0
            arrow = sprintf('moving away %.1f m/s', v);
        else
            arrow = sprintf('approaching %.1f m/s', -v);
        end
        str = sprintf('%.2f m   (%s)', R.rTrack, arrow);
        col = [0 0 0];
        if strcmp(R.status, 'coasting'), col = [0.5 0.5 0.5]; end
    case 'learning'
        str = sprintf('Learning empty room ... %d%%  (keep clear)', ...
            round(100 * R.learnProgress));
        col = [0.75 0.45 0];
    case 'settling'
        str = 'Frames arriving, settling ...';
        col = [0.75 0.45 0];
    otherwise
        str = 'No moving target';
        col = [0.5 0.5 0.5];
end
set(G.title, 'String', str, 'Color', col);

if isfinite(R.rTrack)
    [ex, ey] = local_ellipse(R.rTrack, cfg.Separation);
    set(G.hEll, 'XData', ex, 'YData', ey);
    set(G.hPer, 'XData', 0, 'YData', R.rTrack);
else
    set(G.hEll, 'XData', NaN, 'YData', NaN);
    set(G.hPer, 'XData', NaN, 'YData', NaN);
end

if ~isempty(R.energy)
    ok = isfinite(S.rangeAxis);
    db = 10 * log10(R.energy(ok) ./ R.threshold(ok));
    db(~isfinite(db)) = -15;
    set(G.hPro, 'XData', S.rangeAxis(ok), 'YData', db);
    if isfinite(R.rDet)
        set(G.hPk, 'XData', R.rDet, 'YData', min(R.snrDB - 10*log10(cfg.ThresholdFactor), 25));
    else
        set(G.hPk, 'XData', NaN, 'YData', NaN);
    end
end
end

% =============================================================================
function [x, y] = local_ellipse(r, D)
% Front half of the ellipse with foci (+/-D/2, 0) and semi-minor axis r.
a = sqrt(r^2 + (D/2)^2);
th = linspace(0, pi, 90);
x = a * cos(th);
y = r * sin(th);
end

% =============================================================================
function local_write_session(d, cfg, o)
fid = fopen(fullfile(d, 'session_info.csv'), 'w');
fprintf(fid, ['run_stamp,port,baud,separation_m,tap_to_metres,mti_mode,' ...
              'clutter_alpha,learn_seconds,settle_seconds,max_range_m\n']);
fprintf(fid, '%s,%s,%d,%g,%g,%s,%g,%g,%g,%g\n', datestr(now, 'yyyymmdd_HHMMSS'), ... %#ok<TNOW1,DATST>
    char(o.Port), o.Baud, cfg.Separation, cfg.TapToMetres, cfg.MTIMode, ...
    cfg.ClutterAlpha, cfg.LearnSeconds, cfg.SettleSeconds, cfg.MaxRange);
fclose(fid);
end

function local_write_track(file, H)
fid = fopen(file, 'w');
fprintf(fid, 'elapsed_s,frame,status,detected_m,tracked_m,speed_mps,snr_db\n');
for i = 1:numel(H.t)
    fprintf(fid, '%.4f,%d,%s,%.4f,%.4f,%.4f,%.2f\n', H.t(i), H.frame(i), ...
        H.status{i}, H.rDet(i), H.rTrack(i), H.vTrack(i), H.snr(i));
end
fclose(fid);
end

function local_close(L)
if L.fid > 0
    try, fclose(L.fid); catch, end %#ok<NOCOM>
end
% serialport closes when its last reference is cleared
end
