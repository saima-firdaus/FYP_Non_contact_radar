% cir_live_capture.m
% Live-captures DW1000 CIR frames from the ESP32 anchor over serial,
% parses them, saves each frame to CSV, and plots magnitude^2 vs sample.
%
% Usage: edit PORT below to match your ESP32's COM port, then run.

PORT = "COM3";      % <-- change to your ESP32's port (Device Manager)
BAUD = 115200;
CAPTURE_SECONDS = 30;   % how long to listen before stopping

s = serialport(PORT, BAUD);
configureTerminator(s, "LF");
flush(s);

fprintf("Listening on %s for %d seconds...\n", PORT, CAPTURE_SECONDS);

frames = containers.Map('KeyType', 'double', 'ValueType', 'any');
currentFrame = NaN;
tStart = tic;

while toc(tStart) < CAPTURE_SECONDS
    if s.NumBytesAvailable > 0
        line = strtrim(readline(s));
        if line == ""
            continue
        end

        % Frame header: "# Frame 3"
        tok = regexp(line, '^#\s*Frame\s+(\d+)', 'tokens');
        if ~isempty(tok)
            currentFrame = str2double(tok{1}{1});
            frames(currentFrame) = zeros(0, 4);
            continue
        end

        % Skip comment/header lines
        if startsWith(line, "#") || startsWith(line, "sample,")
            continue
        end

        % Data row: "sample,real,imag,magSq"
        parts = str2double(strsplit(line, ","));
        if ~isnan(currentFrame) && numel(parts) == 4 && ~any(isnan(parts))
            frames(currentFrame) = [frames(currentFrame); parts];
        end
    end
end

clear s  % close the serial port

% ---- Save each frame to CSV and plot ----
figure; hold on;
keys = cell2mat(frames.keys);
for k = sort(keys)
    data = frames(k);
    if isempty(data)
        continue
    end
    T = array2table(data, 'VariableNames', {'sample','real','imag','magnitude_sq'});
    fname = sprintf('frame_%04d.csv', k);
    writetable(T, fname);
    fprintf("Saved %s (%d samples)\n", fname, height(T));

    plot(data(:,1), data(:,4), 'DisplayName', sprintf('Frame %d', k));
end

xlabel('CIR Sample Index');
ylabel('Magnitude^2 (I^2 + Q^2)');
title('DW1000 CIR Accumulator Output');
legend show;
saveas(gcf, 'cir_plot.png');
fprintf("Done. Plot saved as cir_plot.png\n");