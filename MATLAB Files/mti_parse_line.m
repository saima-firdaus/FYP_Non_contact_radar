function [P, frame] = mti_parse_line(P, line)
%MTI_PARSE_LINE  Incremental parser for the anchor's serial CIR stream.
%
%   P = MTI_PARSE_LINE()                 fresh parser state
%   [P, frame] = MTI_PARSE_LINE(P, line) feed one line; frame is a struct
%                                        once "# END" closes a frame, else []
%
% Understands exactly what NLOS_anchor.cpp prints (the same format
% CIR_capture.m reads):
%
%   # FRAME,3,RX_TS,123,FP_INDEX,748.34,FP_INT,748,RXPACC,1024,...,START,728
%   sample,real,imag,amplitude,amplitude_norm
%   730,-412,183,450.83,0.7233
%   ...
%   # END
%
% Every key,value pair on the header is kept in frame.meta, so extra fields
% (TAG_SEQ, or the elapsed_s that cir_mti_live appends when it logs a frame)
% come through without a change here. Frames with no "# END" are dropped,
% and a sample row whose index is outside START..START+1024 is rejected, the
% same guard CIR_capture.m uses against rows spliced by a dropped byte.
%
% frame fields:
%   meta     struct of header values (FRAME, FP_INDEX, RXPACC, ...)
%   sample   absolute accumulator index (column)
%   re, im   raw I and Q (columns)

frame = [];
if nargin == 0
    P = struct('meta', [], 'rows', zeros(0,3), 'nRows', 0, ...
               'inFrame', false, 'nRejected', 0, 'nFrames', 0);
    return
end

line = strtrim(char(line));
if isempty(line)
    return
end

if line(1) == '#'
    if strncmp(line, '# FRAME', 7)
        parts = strsplit(line, ',');
        meta = struct();
        for k = 1:2:numel(parts)-1
            key = strtrim(strrep(parts{k}, '#', ''));
            key = regexprep(key, '[^A-Za-z0-9_]', '_');
            if isempty(key) || ~isletter(key(1)), key = ['x' key]; end %#ok<AGROW>
            meta.(key) = str2double(parts{k+1});
        end
        P.meta    = meta;
        P.rows    = zeros(200, 3);
        P.nRows   = 0;
        P.inFrame = isfield(meta, 'FRAME');
    elseif strncmp(line, '# END', 5)
        if P.inFrame && P.nRows > 0
            rows = sortrows(P.rows(1:P.nRows, :), 1);
            frame = struct('meta', P.meta, 'sample', rows(:,1), ...
                           're', rows(:,2), 'im', rows(:,3));
            P.nFrames = P.nFrames + 1;
        end
        P.inFrame = false;
        P.nRows   = 0;
    end
    return
end

if ~P.inFrame || ~(line(1) == '-' || (line(1) >= '0' && line(1) <= '9'))
    return                                  % column header, boot text, ...
end

vals = sscanf(line, '%f,%f,%f,%f,%f');
if numel(vals) ~= 5
    P.nRejected = P.nRejected + 1;
    return
end
s = vals(1);
if isfield(P.meta, 'START') && isfinite(P.meta.START) && ...
        (s < P.meta.START || s > P.meta.START + 1024 || mod(s,1) ~= 0)
    P.nRejected = P.nRejected + 1;
    return
end

P.nRows = P.nRows + 1;
if P.nRows > size(P.rows, 1)
    P.rows(end+200, 3) = 0;
end
P.rows(P.nRows, :) = vals(1:3).';
end
