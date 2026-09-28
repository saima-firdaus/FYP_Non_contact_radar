# FYP Non-contact radar
Ive been using the jremington library for the DWM1000 ESP32 UWB Makerfabs radar.
https://github.com/jremington/UWB-Indoor-Localization_Arduino 

Ive modified it to work with my NLOS project and it is effectively giving me the CIR accumulator plots needed. To give you some context I am trying to modify the jremington library so I can plot the CIR accumulator graph and see the different peaks, my goal is to see the peak corresponding to a reflection off a human. Phase 0 will just use those Makerfabs modules however Phase 1 will do hardware upgrades. My goal is to compare the CIR graphs using many different signal processing methods (like filtering and averaging) for both phases and show that Phase 1 improved upon phase 0.

Currently I am testing different environmental setups like:

tag - anchor (unobstructed LOS) - (To see if the direct peak is the strongest or not, which it should be).

tag-anchor (with obstruction) - To see if the direct LOS peak is weak or not. (it should be)

tag-anchor (with obstruction and/or human standing to the side) - This is to see if there is a secondary peak coming off that human on the CIR graph.

Your goal is to use this information for understanding purposes, I have questions and am working on improvements. 

This is the GitHUB repo I am working on: https://github.com/saima-firdaus/FYP_Non_contact_radar. Im working off the old_version_BMDA branch.

I am a slow learner so I prefer simplicity and in depth explanations rather than heavy jargon, so please use this to frame your answers.

I am basing the software algorithms off the paper found here:
https://www.researchgate.net/publication/376302345_Impact_of_CIR_processing_for_UWB_radar_distance_estimation_with_the_DW1000_transceiver 

You can see the current software algorithm in use in the CIR_capture.m file and then the CIR_phase_analysis.m file. 

