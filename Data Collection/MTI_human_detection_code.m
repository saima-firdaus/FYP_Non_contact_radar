clc;
clear;
close all;


%% ===============================
% Load files
% ================================

files = dir('frame_*.csv');

numFrames = length(files);

fprintf("Loaded %d frames\n",numFrames);



%% ===============================
% Find common CIR length
% ================================

minSamples = inf;

for k = 1:numFrames

    data = readmatrix(files(k).name);

    minSamples = min(minSamples,size(data,1));

end


fprintf("Using %d CIR samples\n",minSamples);



%% ===============================
% Import CIR data
% ================================


for k = 1:numFrames


    data = readmatrix(files(k).name);


    % force same CIR length

    data = data(1:minSamples,:);


    sample(:,k)=data(:,1);

    I(:,k)=data(:,2);

    Q(:,k)=data(:,3);


end



%% ===============================
% Convert CIR samples to distance
% ================================


c = 3e8;

sample_period = 1.0016e-9;


range_resolution = c*sample_period/2;


distance = (0:minSamples-1)' * range_resolution;


fprintf("\nRange resolution %.3f m/sample\n",range_resolution);



%% ===============================
% Complex CIR
% ================================


CIR = I + 1j*Q;


Amplitude = abs(CIR);



%% ===============================
% MTI PROCESSING
% ================================


% consecutive frame subtraction

MTI = diff(CIR,1,2);


MTI_mag = abs(MTI);



%% ===============================
% MTI energy profile
% ================================


range_energy = mean(MTI_mag,2);


range_energy = range_energy ./ max(range_energy);



%% ===============================
% Remove invalid edge peaks
% ================================


% ignore unrealistic first/last taps

valid = distance > 0.3 & distance < 5;


detect_signal = zeros(size(range_energy));

detect_signal(valid)=range_energy(valid);



%% ===============================
% Automatic peak detection
% ================================


threshold = mean(detect_signal(valid)) + ...
            3*std(detect_signal(valid));


[pks,locs] = findpeaks(detect_signal,...
    'MinPeakHeight',threshold,...
    'MinPeakDistance',5);



detected_distance = distance(locs);



%% ===============================
% Plot 1
% Raw CIR vs distance
% ================================


figure;

plot(distance,mean(Amplitude,2),'LineWidth',1.5);

grid on;

xlabel("Distance (m)");

ylabel("Amplitude");

title("Average Raw CIR vs Distance");





%% ===============================
% Plot 2
% MTI Human Detection
% ================================


figure;

plot(distance,range_energy,...
    'LineWidth',1.5);


hold on;


plot(detected_distance,...
     pks,...
     'ro',...
     'MarkerSize',10,...
     'LineWidth',2);



xlabel("Distance (m)");

ylabel("Normalised MTI Energy");


title("Automatic Human Motion Detection");


legend("MTI Energy","Detected Peaks");


grid on;



%% ===============================
% Plot 3
% MTI Heatmap
% ================================


figure;


imagesc(1:numFrames-1,...
        distance,...
        MTI_mag);


axis xy;


xlabel("Frame Number");

ylabel("Distance (m)");


title("MTI CIR Heatmap");


colorbar;



%% ===============================
% Print detections
% ================================


fprintf("\n============================\n");
fprintf("Detected Moving Targets\n");
fprintf("============================\n");


if isempty(locs)

    fprintf("No moving targets detected\n");


else

    for i=1:length(locs)

        fprintf("Peak %d : %.2f metres\n",...
            i,...
            detected_distance(i));

    end

end