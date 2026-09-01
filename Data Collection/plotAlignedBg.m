% plotAlignedBg.m
% Plots all aligned Test 6 (bg) frames — amplitude and real/imag vs tapsFromFP
close all; clear all; clc;
bgAlignedFolder = 'Test New - Aligned/obj';
bgFiles = dir(fullfile(bgAlignedFolder, '*.csv'));

figure();
tiledlayout(3,1);

ax1 = nexttile; hold(ax1,'on'); grid(ax1,'on');
ax2 = nexttile; hold(ax2,'on'); grid(ax2,'on');
ax3 = nexttile; hold(ax3,'on'); grid(ax3,'on');

for k = 1:numel(bgFiles)
    T = readtable(fullfile(bgAlignedFolder, bgFiles(k).name));

    plot(ax1, T.tapsFromFP, T.amplitude, 'DisplayName', sprintf('Frame %d', k));
    plot(ax2, T.tapsFromFP, T.real,      'DisplayName', sprintf('Frame %d', k));
    plot(ax3, T.tapsFromFP, T.imag,      'DisplayName', sprintf('Frame %d', k));
end

xlabel(ax1, 'Tap offset from first path'); ylabel(ax1, 'Amplitude  |I+jQ|');
title(ax1, 'Test 11 | home — aligned amplitude');
xline(ax1, 0, 'k--', 'first path');

xlabel(ax2, 'Tap offset from first path'); ylabel(ax2, 'Real (I)');
title(ax2, 'Aligned I component');
xline(ax2, 0, 'k--', 'first path');

xlabel(ax3, 'Tap offset from first path'); ylabel(ax3, 'Imag (Q)');
title(ax3, 'Aligned Q component');
xline(ax3, 0, 'k--', 'first path');

legend(ax1, 'show', 'Location', 'eastoutside');