function split_mti_compare(folder)
%SPLIT_MTI_COMPARE  The two panels of mti_compare.fig as two separate figures.
%
%   SPLIT_MTI_COMPARE(folder)   a Capture_MTI_* folder that already has
%                               mti_compare.fig (from cir_mti_analysis)
%   SPLIT_MTI_COMPARE()         the current folder
%
% Makes one figure for complex subtraction and one for variance, each with
% its own distance and time axes and the L / range heading, and saves them
% next to mti_compare.fig as mti_complex.png/.fig and mti_variance.png/.fig.
% Nothing is recomputed: the panels are copied from the saved figure.

if nargin < 1 || isempty(folder), folder = pwd; end
f = fullfile(folder, 'mti_compare.fig');
if ~exist(f, 'file')
    error('No mti_compare.fig in %s - run cir_mti_analysis on it first.', folder);
end
src = openfig(f, 'invisible');
cleaner = onCleanup(@() close(src));

heading = '';
tl = findobj(src, 'Type', 'tiledlayout');
if ~isempty(tl), heading = char(string(tl(1).Title.String)); end
ax = findobj(src, 'Type', 'axes');
ttl = arrayfun(@(a) strjoin(cellstr(string(a.Title.String)), ' '), ax, 'UniformOutput', false);

panels = {'Complex', 'mti_complex'; 'Variance', 'mti_variance'};
for k = 1:size(panels, 1)
    a = ax(startsWith(ttl, panels{k, 1}));
    if isempty(a), warning('No %s panel in %s.', panels{k, 1}, f); continue; end
    a = a(1);
    % Narrow, large-font version for three figures side by side in the report
    fig = figure('Color', src.Color, 'Position', [100 100 800 480]);
    if ~isempty(a.Legend)
        c = copyobj([a.Legend a], fig); axN = c(2); lg = c(1);
    else
        axN = copyobj(a, fig); lg = [];
    end
    set(axN, 'Units', 'normalized', 'OuterPosition', [0 0 1 1], 'FontSize', 14);
    xlabel(axN, 'Time (s)', 'FontSize', 16);
    ylabel(axN, a.YLabel.String, 'FontSize', 16);
    title(axN, {heading, a.Title.String}, 'FontSize', 16, 'FontWeight', 'normal', ...
        'Interpreter', 'none');
    if ~isempty(lg)      % below the axes, so it never covers the track
        set(lg, 'FontSize', 13, 'Location', 'southoutside', 'Orientation', 'horizontal');
    end
    set(findobj(axN, 'Type', 'text'), 'FontSize', 13);      % "learning empty room"
    exportgraphics(fig, fullfile(folder, [panels{k, 2} '.png']), 'Resolution', 200);   % cropped tight
    savefig(fig, fullfile(folder, [panels{k, 2} '.fig']));
    fprintf('Saved %s (.png/.fig)\n', fullfile(folder, panels{k, 2}));
end
end
