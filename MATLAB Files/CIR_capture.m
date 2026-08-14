% cir_live_capture.m
%
% Live-captures DW1000 CIR frames from the ESP32 anchor over serial, parses
% them, saves each frame to CSV, and plots amplitude vs accumulator index.
%
% Expects the header line emitted by the corrected anchor sketch:
%   # FRAME,3,RX_TS,123456789,FP_INDEX,748.34,FP_INT,748,RXPACC,1024,RXPWR,-62.1,START,728
%   sample,real,imag,amplitude,amplitude_norm
%
% Usage: set PORT below, then run.

PORT = "COM3";
BAUD = 921600;              % must match Serial.begin() in the sketch
CAPTURE_SECONDS = 30;

s = serialport(PORT, BAUD);
configureTerminator(s, "LF");
flush(s);

fprintf("Listening on %s for %d seconds...\n", PORT, CAPTURE_SECONDS);

frames = containers.Map('KeyType','double','ValueType','any');
meta   = containers.Map('KeyType','double','ValueType','any');
currentFrame = NaN;
tStart = tic;

while toc(tStart) < CAPTURE_SECONDS
    if s.NumBytesAvailable == 0, continue; end
    line = strtrim(readline(s));
    if line == "", continue; end

    % ---- Frame header ----
    if startsWith(line, "# FRAME")
        parts = strsplit(line, ",");
        kv = struct();
        for k = 1:2:numel(parts)-1
            key = strtrim(erase(parts(k), "#"));
            kv.(matlab.lang.makeValidName(key)) = str2double(parts(k+1));
        end
        currentFrame = kv.FRAME;
        frames(currentFrame) = zeros(0,5);
        meta(currentFrame)   = kv;
        continue
    end

    if startsWith(line, "#") || startsWith(line, "sample,")
        continue
    end

    vals = str2double(strsplit(line, ","));
    if ~isnan(currentFrame) && numel(vals) == 5 && ~any(isnan(vals))
        frames(currentFrame) = [frames(currentFrame); vals];
    end
end

clear s

% ---- Save + plot ----
figure('Color','w'); 
tiledlayout(2,1);

% (a) absolute accumulator index
ax1 = nexttile; hold(ax1,'on'); grid(ax1,'on');
% (b) aligned on the first path
ax2 = nexttile; hold(ax2,'on'); grid(ax2,'on');

ks = sort(cell2mat(frames.keys));
for k = ks
    data = frames(k);
    if isempty(data), continue; end
    m = meta(k);

    T = array2table(data, 'VariableNames', ...
        {'sample','real','imag','amplitude','amplitude_norm'});
    fname = sprintf('frame_%04d.csv', k);
    writetable(T, fname);
    fprintf("Saved %s (%d samples, FP_INDEX=%.2f, RXPACC=%d, RXPWR=%.1f dBm)\n", ...
        fname, height(T), m.FP_INDEX, m.RXPACC, m.RXPWR);

    plot(ax1, data(:,1), data(:,4), 'DisplayName', sprintf('Frame %d', k));

    % Align on the LDE first path and convert taps to excess path length.
    % One accumulator tap = 1.0016 ns = 30.03 cm of propagation.
    tapsFromFP = data(:,1) - m.FP_INDEX;
    plot(ax2, tapsFromFP * 0.30028, data(:,5), 'DisplayName', sprintf('Frame %d', k));
end

xlabel(ax1, 'Accumulator index (tap)');
ylabel(ax1, 'Amplitude  |I+jQ|');
title(ax1, 'DW1000 CIR - absolute accumulator index');

xlabel(ax2, 'Excess path length relative to first path (m)');
ylabel(ax2, 'Amplitude / RXPACC');
title(ax2, 'DW1000 CIR - aligned on LDE first path');
xline(ax2, 0, 'k--', 'first path');

saveas(gcf, 'cir_plot.png');
fprintf("Done. Plot saved as cir_plot.png\n");