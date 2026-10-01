function outDir = mti_make_test_capture(outRoot, varargin)
%MTI_MAKE_TEST_CAPTURE  Synthetic capture in the anchor's exact serial format, with the truth.
%
%   outDir = MTI_MAKE_TEST_CAPTURE()             walking person, into pwd
%   outDir = MTI_MAKE_TEST_CAPTURE(outRoot, 'Name', value, ...)
%
% 'Scenario', 'walk' (default) writes Capture_MTI_SYNTH/serial_log.txt (what
% cir_mti_live records) and truth.csv (the true distance at each frame):
% EmptySeconds of empty room (settling + learning + a few seconds to check
% for false detections), 20 s walking 0.8 m <-> 3.1 m and back twice, then
% 6 s standing at 2 m waving an arm.
%
%   cir_mti_analysis(mti_make_test_capture())
%   cir_mti_live('Replay', mti_make_test_capture())
%
% 'Scenario', 'static' writes Capture_IQ_SYNTH/serial_log.txt plus a
% session_info.csv laid out like a cir_iq_capture session: 0-10 s empty,
% 10-20 s walking in, 20-30 s standing at StandAt, breathing and swaying:
%
%   d = mti_make_test_capture(pwd, 'Scenario', 'static', 'StandAt', 1.5);
%   cir_iq_capture('FromLog', d)       % CIR_capture-style files + comparison
%
% Scene: tag and anchor Separation apart, the room's static multipath
% roughly shaped like the ch5_sep1m capture. Every frame gets a random
% carrier phase, a small AGC gain change, FP_INDEX jitter and thermal noise
% (the nuisances the real pipeline has to remove), plus RelPhaseJitterDeg of
% random phase on every path except the direct one.
%
% Options:
%   'Scenario'          'walk'   or 'static'
%   'Separation'        1        m
%   'Seed'              1
%   'FrameRate'         10       frames/s
%   'NoiseSD'           0.3      thermal noise, amplitude/RXPACC units
%   'PersonAmp'         6        echo of the torso at 1 m, amplitude/RXPACC
%   'EmptySeconds'      16       walk only: empty room at the start
%   'StandAt'           1.5      static only: where the person stands (m)
%   'RelPhaseJitterDeg' 10       phase noise of each path relative to the
%                                direct path (your first background check
%                                measured 24 deg, partly inflated)
%   'BreathMM'          3        static: chest movement, +/- mm at 0.25 Hz
%   'SwayMM'            3        static: postural sway, RMS mm
%   'TxGainDB'          0        scales every path (a TX power change)
%   'ClipLevel'         Inf      accumulator magnitude where a soft limiter
%                                starts compressing (test for clipping)

if nargin < 1 || isempty(outRoot), outRoot = pwd; end
o = struct('Scenario', 'walk', 'Separation', 1, 'Seed', 1, 'FrameRate', 10, ...
           'NoiseSD', 0.3, 'PersonAmp', 6, 'EmptySeconds', 16, 'StandAt', 1.5, ...
           'RelPhaseJitterDeg', 10, 'BreathMM', 3, 'SwayMM', 3, ...
           'TxGainDB', 0, 'ClipLevel', Inf);
names = fieldnames(o);
for k = 1:2:numel(varargin)
    hit = find(strcmpi(names, varargin{k}), 1);
    if isempty(hit), error('mti_make_test_capture: unknown option "%s".', varargin{k}); end
    o.(names{hit}) = varargin{k+1};
end
isStatic = strcmpi(o.Scenario, 'static');

rand('seed', o.Seed); randn('seed', o.Seed); %#ok<RAND>
if exist('rng', 'file') == 2 || exist('rng', 'builtin') == 5
    try, rng(o.Seed); catch, end %#ok<NOCOM>
end

if isStatic
    outDir = fullfile(outRoot, 'Capture_IQ_SYNTH');
else
    outDir = fullfile(outRoot, 'Capture_MTI_SYNTH');
end
if ~exist(outDir, 'dir'), mkdir(outDir); end

c0   = 299792458;
fc   = 6489.6e6;                 % channel 5
lam  = c0 / fc;
Ts   = 1.0016e-9;                % accumulator tap
bw   = 499.2e6;
D    = o.Separation;
pulse = @(tau) sinc_(bw * tau) .* (abs(tau) < 6e-9) .* cos(pi*tau/12e-9).^2;
k0taps = 2;                      % pulse peak sits 2 taps after FP_INDEX
jit  = deg2rad(o.RelPhaseJitterDeg);
txg  = 10^(o.TxGainDB / 20);

% Static scene: excess delay (taps after the direct peak), amplitude, phase
statTap = [0 3 6 23 30 34 40 44 46];
statAmp = [18 11 8 10 4 5 6 5 7];
statPh  = 2*pi*rand(size(statTap)); statPh(1) = 0;
shadow  = 0.55 + 0.35*rand(size(statTap));   % how much a still person lets through

if isStatic
    T = 30; tBg = 10; tWalk = 10;
else
    tEmpty = o.EmptySeconds; tWalk = 20; T = tEmpty + tWalk + 6;
end
t = 0;
truth = zeros(0, 2);
fid = fopen(fullfile(outDir, 'serial_log.txt'), 'w');
fprintf(fid, '# DW1000 CIR capture - initialising\n# Mode: synthetic %s\n', o.Scenario);
n = 0;
ph = 2*pi*rand;                  % carrier phase between the two free-running modules
sway = 0; breathPh = 2*pi*rand;
while t < T
    n = n + 1;
    dt = (1/o.FrameRate) * (1 + 0.1*randn);
    t = t + dt;

    % ---- where the person is: rows of [distance, relative amplitude] ------
    still = false;
    if isStatic
        if t < tBg + 2
            r = NaN; scat = zeros(0,2);
        elseif t < tBg + tWalk - 2               % walking in from 3.4 m
            f = (t - tBg - 2) / (tWalk - 4);
            r = 3.4 + f * (o.StandAt - 3.4);
            scat = [r 1; r+0.12 0.6; r+0.25 0.4];
        else                                     % standing: breathing + sway
            r = o.StandAt;
            sway = sway * exp(-dt/3) + o.SwayMM/1000 * sqrt(1 - exp(-2*dt/3)) * randn;
            breath = o.BreathMM/1000 * sin(2*pi*0.25*t + breathPh);
            scat = [r + breath + sway, 1; r + 0.10 + sway, 0.4];
            still = true;
        end
    else
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
        if exP > 0 && ex > exP                          % shadowed by the body
            if still, a = a * shadow(k) * (1 + 0.03*randn);
            else,     a = a * (1 - 0.25*rand); end
        end
        p = statPh(k);
        if k > 1, p = p + jit*randn; end
        h = h + a * exp(1j*p) * pulse(tauRel - statTap(k)*Ts);
    end
    for k = 1:size(scat, 1)
        rr = scat(k,1);
        R1 = sqrt(rr^2 + (D/2)^2);
        ex = 2*R1 - D;
        a  = o.PersonAmp * scat(k,2) * (1.25 / R1^2);
        h  = h + a * exp(-1j*(2*pi*ex/lam) + 1j*jit*randn) * pulse(tauRel - ex/c0);
    end
    % Oscillator phase drift: a steady offset (~37 deg/frame) plus a random
    % walk, applied to the whole CIR at once - as between two real modules.
    ph = ph + deg2rad(37) + deg2rad(25)*randn;
    g  = 1 + 0.05*randn;                                % AGC gain change
    h = h * g * exp(1j*ph);
    h = h + o.NoiseSD/sqrt(2) * (randn(size(h)) + 1j*randn(size(h)));
    raw = h * rxpacc * txg;
    if isfinite(o.ClipLevel)                            % soft limiter (Rapp, p = 3)
        raw = raw ./ (1 + (abs(raw) / o.ClipLevel).^6).^(1/6);
    end
    I = max(min(round(real(raw)), 32767), -32768);      % int16 accumulator
    Q = max(min(round(imag(raw)), 32767), -32768);
    amp = sqrt(I.^2 + Q.^2);
    rxpwr = -60 + 20*log10(abs(g) * txg) + 0.2*randn;

    fprintf(fid, ['# FRAME,%d,RX_TS,%d,FP_INDEX,%.4f,FP_INT,%d,RXPACC,%d,' ...
        'RXPWR,%.2f,START,%d,elapsed_s,%.4f\n'], ...
        n, round(t / (1/(128*499.2e6))), fpRep, floor(fpRep), rxpacc, rxpwr, start, t);
    fprintf(fid, 'sample,real,imag,amplitude,amplitude_norm\n');
    fprintf(fid, '%d,%d,%d,%.2f,%.5f\n', [s I Q amp amp/rxpacc].');
    fprintf(fid, '# END\n');
end
fclose(fid);

fid = fopen(fullfile(outDir, 'truth.csv'), 'w');
fprintf(fid, 'elapsed_s,true_distance_m\n');
fprintf(fid, '%.4f,%.4f\n', truth.');
fclose(fid);

if isStatic
    % The same session_info.csv cir_iq_capture writes, so cir_iq_capture
    % ('FromLog', ...) and cir_phase_analysis_iq read it like a real run.
    fid = fopen(fullfile(outDir, 'session_info.csv'), 'w');
    fprintf(fid, ['run_label,run_stamp,capture_seconds,walk_prompt_at_s,' ...
        'walk_duration_s,taps_before_fp,taps_after_fp,mean_grid_step,' ...
        'tap_to_metres,port,baud,aligned_subdir,tag_anchor_dist_m,' ...
        'true_distance_m,capture_kind\n']);
    fprintf(fid, 'synthetic_static_%gm,SYNTH,%g,%g,%g,50,100,0.5,0.30028,none,0,02_lde_aligned,%g,%g,iq\n', ...
        o.StandAt, T, tBg, tWalk, D, o.StandAt);
    fclose(fid);
end
fprintf('Synthetic %s capture: %d frames -> %s\n', o.Scenario, n, outDir);
end

function y = sinc_(x)
y = ones(size(x));
k = x ~= 0;
y(k) = sin(pi*x(k)) ./ (pi*x(k));
end
