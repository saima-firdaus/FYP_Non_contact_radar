function [frames, info] = mti_read_capture(src)
%MTI_READ_CAPTURE  Load every frame of a saved capture, ready for MTI_STEP.
%
%   [frames, info] = MTI_READ_CAPTURE(src)
%
% src can be:
%   - a serial_log.txt written by cir_mti_live (raw anchor output, I and Q)
%   - a folder holding one (Capture_MTI_* folders)
%   - an existing CIR_capture.m folder (Capture_yyyymmdd_HHMMSS). Those only
%     saved amplitude_norm per frame, not I/Q, so they replay in magnitude-only
%     mode: motion still shows up, but weaker and noisier than with I/Q.
%
% frames is a cell array of frame structs in time order. info.coherent says
% whether I/Q was available; info.session holds session_info.csv values when
% the folder has one.

src = char(src);
info = struct('source', src, 'coherent', true, 'session', struct(), ...
              'kind', '');

if exist(src, 'dir')
    logFile = fullfile(src, 'serial_log.txt');
    if exist(logFile, 'file')
        [frames, info] = local_read_log(logFile, info);
    elseif exist(fullfile(src, 'frame_metadata.csv'), 'file')
        [frames, info] = local_read_aligned(src, info);
    else
        error(['%s has neither serial_log.txt (cir_mti_live) nor ' ...
               'frame_metadata.csv (CIR_capture).'], src);
    end
    info.session = local_read_session(src);
elseif exist(src, 'file')
    [frames, info] = local_read_log(src, info);
else
    error('Capture not found: %s', src);
end
end

% =============================================================================
function [frames, info] = local_read_log(file, info)
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
info.kind = 'serial_log';
info.coherent = true;
info.nRejected = P.nRejected;
end

% =============================================================================
function [frames, info] = local_read_aligned(dirName, info)
% Old CIR_capture folders: metadata + one aligned CSV per frame (no I/Q).
[hdr, rows] = local_read_csv(fullfile(dirName, 'frame_metadata.csv'));
col = @(name) find(strcmpi(hdr, name), 1);
iCsv = col('aligned_csv');
if isempty(iCsv)
    error('frame_metadata.csv has no aligned_csv column.');
end
numCols = setdiff(1:numel(hdr), iCsv);
frames = cell(1, 0);
nMissing = 0;
for r = 1:size(rows, 1)
    rel = strrep(strrep(rows{r, iCsv}, '\', filesep), '/', filesep);
    f = fullfile(dirName, rel);
    if ~exist(f, 'file'), nMissing = nMissing + 1; continue; end
    [h2, d2] = local_read_csv(f);
    it = find(strcmpi(h2, 'taps_from_fp'), 1);
    ia = find(strcmpi(h2, 'amplitude_norm'), 1);
    if isempty(it) || isempty(ia), nMissing = nMissing + 1; continue; end
    meta = struct();
    for k = numCols
        meta.(regexprep(hdr{k}, '[^A-Za-z0-9_]', '_')) = str2double(rows{r, k});
    end
    frames{end+1} = struct('meta', meta, ...
        'taps', str2double(d2(:, it)), 'x', str2double(d2(:, ia)), ...
        'coherent', false); %#ok<AGROW>
end
if isempty(frames)
    error(['None of the %d per-frame files listed in frame_metadata.csv ' ...
           'exist under %s (the 02_lde_aligned folder is needed).'], ...
           size(rows, 1), dirName);
end
if nMissing > 0
    warning('%d frame file(s) listed in frame_metadata.csv were missing.', nMissing);
end
info.kind = 'cir_capture_aligned';
info.coherent = false;
end

% =============================================================================
function [hdr, rows] = local_read_csv(file)
fid = fopen(file, 'r');
if fid < 0, error('Cannot open %s', file); end
c = onCleanup(@() fclose(fid));
hdr = strtrim(strsplit(fgetl(fid), ','));
rows = cell(0, numel(hdr));
while true
    ln = fgetl(fid);
    if ~ischar(ln), break; end
    if isempty(strtrim(ln)), continue; end
    p = strsplit(ln, ',');
    if numel(p) < numel(hdr), p(end+1:numel(hdr)) = {''}; end
    rows(end+1, :) = p(1:numel(hdr)); %#ok<AGROW>
end
end

% =============================================================================
function S = local_read_session(dirName)
S = struct();
f = fullfile(dirName, 'session_info.csv');
if ~exist(f, 'file'), return; end
[hdr, rows] = local_read_csv(f);
if isempty(rows), return; end
for k = 1:numel(hdr)
    v = str2double(rows{1, k});
    key = regexprep(hdr{k}, '[^A-Za-z0-9_]', '_');
    if isnan(v), S.(key) = rows{1, k}; else, S.(key) = v; end
end
end
