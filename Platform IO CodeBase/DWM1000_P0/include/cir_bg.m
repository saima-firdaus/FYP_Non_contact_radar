% UWB_Background_Subtraction.m
% Analyzes static clutter and isolates dynamic targets

num_bg_frames = 5;  % Number of frames to use as the "empty room" baseline
total_frames = 14;  % Update this to your total number of captured frames

% 1. Calculate the Static Background Profile
I_bg_sum = 0;
Q_bg_sum = 0;
first_pass = true;
samples = [];

fprintf('Calculating background from first %d frames...\n', num_bg_frames);
for k = 1:num_bg_frames
    fname = sprintf('frame_%04d.csv', k);
    if ~isfile(fname), error('File %s not found!', fname); end
    
    % Read data (Assumes columns: sample, real, imag, amplitude)
    % readmatrix automatically skips text headers
    data = readmatrix(fname); 
    
    if first_pass
        samples = data(:, 1);
        I_bg_sum = zeros(size(samples));
        Q_bg_sum = zeros(size(samples));
        first_pass = false;
    end
    
    I_bg_sum = I_bg_sum + data(:, 2);
    Q_bg_sum = Q_bg_sum + data(:, 3);
end

% Average to get the master background signature
I_bg = I_bg_sum / num_bg_frames;
Q_bg = Q_bg_sum / num_bg_frames;

% 2. Process and Plot Target Frames
figure('Position', [100, 100, 800, 600]);
tiledlayout(2,1);

ax1 = nexttile; hold(ax1,'on'); grid(ax1,'on'); 
title(ax1, 'Raw CIR (Room + Clutter)');
xlabel(ax1, 'Accumulator Index'); ylabel(ax1, 'Amplitude');

ax2 = nexttile; hold(ax2,'on'); grid(ax2,'on'); 
title(ax2, 'Subtracted CIR (Moving Targets Only)');
xlabel(ax2, 'Accumulator Index'); ylabel(ax2, 'Amplitude');

fprintf('Processing remaining frames...\n');
for k = (num_bg_frames + 1):total_frames
    fname = sprintf('frame_%04d.csv', k);
    if ~isfile(fname), continue; end
    data = readmatrix(fname);
    
    I_raw = data(:, 2);
    Q_raw = data(:, 3);
    Amp_raw = data(:, 4);
    
    % The Magic: Subtract complex background from current frame
    I_sub = I_raw - I_bg;
    Q_sub = Q_raw - Q_bg;
    
    % Calculate the new isolated amplitude: sqrt(I^2 + Q^2)
    Amp_sub = sqrt(I_sub.^2 + Q_sub.^2);
    
    % Plot both for comparison
    plot(ax1, samples, Amp_raw);
    plot(ax2, samples, Amp_sub);
end

fprintf('Done!\n');