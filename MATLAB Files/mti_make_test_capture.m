function outDir = mti_make_test_capture(outRoot, varargin)
%MTI_MAKE_TEST_CAPTURE  Synthetic walking-person capture, in the anchor's exact serial format.
%
%   outDir = MTI_MAKE_TEST_CAPTURE()             writes into pwd
%   outDir = MTI_MAKE_TEST_CAPTURE(outRoot, 'Name', value, ...)
%
% Writes Capture_MTI_SYNTH/serial_log.txt (what cir_mti_live records) and
% truth.csv (the true distance at each frame), so the whole chain can be
% checked with no hardware:
%
%   cir_mti_analysis(mti_make_test_capture())
%   cir_mti_live('Replay', mti_make_test_capture())
%
% Scene (defaults): tag and anchor 1 m apart, the room's static multipath
% roughly shaped like the ch5_sep1m capture, 9 s empty (6 s learning + 3 s
% to check for false detections), 20 s walking
% 0.8 m <-> 3.1 m and back twice, then 6 s standing at 2 m waving an arm.
% Every frame gets a random carrier phase, a small AGC gain change, FP_INDEX
% jitter and thermal noise - the nuisances the real pipeline has to remove.
%
% Options: 'Separation' (1), 'Seed' (1), 'FrameRate' (10), 'NoiseSD' (0.3),
% 'PersonAmp' (6, CIR amplitude/RXPACC of the echo at 1 m), 'EmptySeconds' (9).

if nargin < 1 || isempty(outRoot), outRoot = pwd; end
o = struct('Separation', 1, 'Seed', 1, 'FrameRate', 10, 'NoiseSD', 0.3, ...
           'PersonAmp', 6, 'EmptySeconds', 9);
for k = 1:2:numel(varargin), o.(varargin{k}) = varargin{k+1}; end

rand('seed', o.Seed); randn('seed', o.Seed); %#ok<RAND>
if exist('rng', 'file') == 2 || exist('rng', 'builtin') == 5
    try, rng(o.Seed); catch, end %#ok<NOCOM>
end

outDir = fullfile(outRoot, 'Capture_MTI_SYNTH');
if ~exist(outDir, 'dir'), mkdir(outDir); end

c0   = 299792458;
fc   = 6489.6e6;                 % channel 5
Ts   = 1.0016e-9;                % accumulator tap
bw   = 499.2e6;
D    = o.Separation;
pulse = @(tau) sinc_(bw * tau) .* (abs(tau) < 6e-9) .* cos(pi*tau/12e-9).^2;
k0taps = 2;                      % pulse peak sits 2 taps after FP_INDEX

% Static scene: excess delay (taps after the direct peak), amplitude, phase
statTap = [0 3 6 23 30 34 40 44 46];
statAmp = [18 11 8 10 4 5 6 5 7];
statPh  = 2*pi*rand(size(statTap)); statPh(1) = 0;

tEmpty = o.EmptySeconds; tWalk = 20; T = tEmpty + tWalk + 6;
t = 0; frames = {};
truth = zeros(0, 2);
fid = fopen(fullfile(outDir, 'serial_log.txt'), 'w');
fprintf(fid, '# DW1000 CIR capture - initialising\n# Mode: synthetic\n');
n = 0;
ph = 2*pi*rand;                  % carrier phase between the two free-running modules
while t < T
    n = n + 1;
    t = t + (1/o.FrameRate) * (1 + 0.1*randn);

    % ---- where the person is -------------------------------------------
    if t < tEmpty
        r = NaN; scat = zeros(0,2);
    elseif t < tEmpty + tWalk
        r = 1.95 - 1.15 * cos(2*pi*(t - tEmpty) / 10);
        scat = [r 1; r+0.12 0.6; r+0.25 0.4];            % torso, limbs
    else
        r = 2.0;
        arm = 1.85 + 0.15*sin(2*pi*1.0*(t - tEmpty - tWalk));
        scat = [r 0.25; arm 0.35];                       % mostly the arm moves
    end
    truth(end+1, :) = [t r]; %#ok<AGROW>

    % ---- build the CIR ----------------------------------------------------
    fpTrue = 750 + 0.4*randn;                           % where the direct path starts
    fpRep  = fpTrue + 0.08*randn;                       % LDE estimate jitter
    rxpacc = round(900 + 20*randn);
    start  = floor(fpRep) - 50;
    s      = (start : start + 149).';
    tauRel = (s - (fpTrue + k0taps)) * Ts;              % relative to direct peak
    h = zeros(size(s));
    exP = -1;
    if ~isempty(scat)
        exP = 2*sqrt(scat(1,1)^2 + (D/2)^2) - D;
    end
    for k = 1:numel(statTap)
        a = statAmp(k);
        ex = statTap(k) * Ts * c0;
        if exP > 0 && ex > exP, a = a * (1 - 0.25*rand); end   % shadowed by the body
        h = h + a * exp(1j*statPh(k)) * pulse(tauRel - statTap(k)*Ts);
    end
    for k = 1:size(scat, 1)
        rr = scat(k,1);
        R1 = sqrt(rr^2 + (D/2)^2);
        ex = 2*R1 - D;
        a  = o.PersonAmp * scat(k,2) * (1.25 / R1^2);
        h  = h + a * exp(-1j*2*pi*fc*ex/c0) * pulse(tauRel - ex/c0);
    end
    % Oscillator phase drift: a steady offset (~37 deg/frame) plus a random
    % walk, applied to the whole CIR at once - as between two real modules.
    ph = ph + deg2rad(37) + deg2rad(25)*randn;
    h = h * (1 + 0.05*randn) * exp(1j*ph);              % AGC + carrier phase
    h = h + o.NoiseSD/sqrt(2) * (randn(size(h)) + 1j*randn(size(h)));
    raw = h * rxpacc;
    I = round(real(raw)); Q = round(imag(raw));
    amp = sqrt(I.^2 + Q.^2);

    fprintf(fid, ['# FRAME,%d,RX_TS,%d,FP_INDEX,%.4f,FP_INT,%d,RXPACC,%d,' ...
        'RXPWR,-60.0,START,%d,elapsed_s,%.4f\n'], ...
        n, round(t / (1/(128*499.2e6))), fpRep, floor(fpRep), rxpacc, start, t);
    fprintf(fid, 'sample,real,imag,amplitude,amplitude_norm\n');
    fprintf(fid, '%d,%d,%d,%.2f,%.5f\n', [s I Q amp amp/rxpacc].');
    fprintf(fid, '# END\n');
end
fclose(fid);

fid = fopen(fullfile(outDir, 'truth.csv'), 'w');
fprintf(fid, 'elapsed_s,true_distance_m\n');
fprintf(fid, '%.4f,%.4f\n', truth.');
fclose(fid);
fprintf('Synthetic capture: %d frames -> %s\n', n, outDir);
end

function y = sinc_(x)
y = ones(size(x));
k = x ~= 0;
y(k) = sin(pi*x(k)) ./ (pi*x(k));
end
